package Mediabot::RSS::Runtime;

use strict;
use warnings;
use Mediabot::IRC::TextBudget qw(_utf8_text_bytes);
use utf8;
use Scalar::Util qw(refaddr weaken);

use IO::Async::Timer::Countdown;
use Mediabot::AsyncWorker;
use Mediabot::Helpers ();
use Mediabot::RSS qw(format_rss_announcement);
use Mediabot::RSS::Poller;
use Mediabot::RSS::Pacing;
use Mediabot::RSS::Repository;
use Mediabot::URLShortener qw(make_bot_shortener format_event);

our $VERSION = '1.0';

sub new {
    my ($class, %args) = @_;
    my $bot = $args{bot} or die "bot is required";
    my $loop = $args{loop} || eval { $bot->getLoop } || $bot->{loop};
    die "loop is required" unless $loop;

    my $max_workers = int($args{max_workers} // 4);
    $max_workers = 1 if $max_workers < 1;
    $max_workers = 8 if $max_workers > 8;

    my $delay = 0 + ($args{output_delay} // 2);
    $delay = 0.1 if $delay < 0.1;
    $delay = 10  if $delay > 10;

    return bless {
        bot           => $bot,
        pacing        => $args{pacing} || Mediabot::RSS::Pacing->new(bot => $bot),
        loop          => $loop,
        max_workers   => $max_workers,
        dispatch_limit => int($args{dispatch_limit} // 20),
        worker_timeout => 0 + ($args{worker_timeout} // 60),
        output_delay  => $delay,
        inflight      => {},
        inflight_channels => {},
        outq          => {},
        queued        => {},
        workers       => {},
        worker_class  => $args{worker_class} || 'Mediabot::AsyncWorker',
    }, $class;
}

sub _log {
    my ($self, $level, $text) = @_;
    return unless $self->{bot}{logger};
    eval { $self->{bot}{logger}->log($level, $text) };
}

sub _parent_dbh {
    my ($self) = @_;
    my $bot = $self->{bot};
    my $dbh = eval { $bot->{db}->ensure_connected } if $bot->{db};
    $dbh ||= $bot->{dbh};
    return $dbh;
}

sub _parent_repo {
    my ($self) = @_;
    my $dbh = $self->_parent_dbh or return;
    return Mediabot::RSS::Repository->new(dbh => $dbh);
}

sub inflight_count { scalar keys %{ $_[0]->{inflight} || {} } }
sub queued_count   { scalar keys %{ $_[0]->{queued} || {} } }

sub diagnostic_status { return $_[0]->{pacing}->observe($_[1]) }

sub tick {
    my ($self) = @_;
    my $bot = $self->{bot};

    # mediabot.pl sets _start_time only after the IRC login Future has
    # completed. Never let a scheduler tick publish while login is incomplete.
    return 0 unless $bot->{_start_time};

    my $capacity = $self->{max_workers} - $self->inflight_count;
    if ($capacity <= 0) {
        $self->_drain_ready_channels;
        return 0;
    }

    my $repo = eval { $self->_parent_repo };
    unless ($repo) {
        $self->_log(1, 'rss_poll_dispatch: parent database unavailable');
        return 0;
    }

    my $due = eval { $repo->list_due_feeds($self->{dispatch_limit}) };
    if ($@ || ref($due) ne 'ARRAY') {
        my $err = $@ || 'invalid due-feed result';
        $err =~ s/[\r\n\0]+/ /g;
        $self->_log(1, 'rss_poll_dispatch: due-feed lookup failed: ' . substr($err, 0, 240));
        return 0;
    }

    my $started = 0;
    local $self->{dispatching} = 1;
    for my $feed (@$due) {
        last if $started >= $capacity;
        next unless ref($feed) eq 'HASH';
        my $id = $feed->{id_rss_feed};
        next unless defined($id) && $id =~ /^\d+$/;
        next if $self->{inflight}{$id};
        $started++ if $self->_start_feed_worker($feed);
    }
    $self->{dispatching} = 0;
    $self->_drain_ready_channels;
    return $started;
}

sub _child_poll {
    my ($self, $feed) = @_;
    my $bot = $self->{bot};

    # The fork inherits parent DBI objects. They must never be disconnected by
    # child destruction; all worker SQL uses a fresh isolated handle.
    eval { $bot->{dbh}{InactiveDestroy} = 1 if $bot->{dbh} };
    eval { $bot->{db}{dbh}{InactiveDestroy} = 1 if $bot->{db} && $bot->{db}{dbh} };

    my $db = $bot->{db};
    return { ok => 0, error => 'isolated_db', detail => 'database wrapper unavailable' }
        unless $db && eval { $db->can('connect_isolated_handle') };

    my ($dbh, $db_error) = $db->connect_isolated_handle;
    return { ok => 0, error => 'isolated_db', detail => ($db_error || 'connection failed') }
        unless $dbh;

    my $value;
    my $ok = eval {
        my $repo = Mediabot::RSS::Repository->new(dbh => $dbh);
        my $poller = Mediabot::RSS::Poller->new(repo => $repo, pacing => $self->{pacing});
        my $res = $poller->poll_feed($feed);

        $value = {
            %$res,
            id_rss_feed => 0 + $feed->{id_rss_feed},
            channel     => $feed->{channel},
            label       => $feed->{label},
            announcements => [],
            shorturl_events => [],
        };

        if ($res->{ok} && ref($res->{pending}) eq 'ARRAY' && @{ $res->{pending} }) {
            my $shorten = make_bot_shortener(
                bot         => $bot,
                on_event    => sub {
                    my ($event) = @_;
                    return unless ref($event) eq 'HASH';
                    push @{ $value->{shorturl_events} }, $event
                        if @{ $value->{shorturl_events} } < 8;
                },
            );
            my $policy = $self->{pacing}->status($feed->{channel});
            for my $item (@{ $res->{pending} }) {
                next unless ref($item) eq 'HASH';
                next unless defined($item->{item_key}) && $item->{item_key} =~ /^[0-9a-f]{64}$/i;
                my $url = $item->{url} // '';
                my $display_url = length($url) ? $shorten->($url) : '';
                my $line = format_rss_announcement(
                    label => $feed->{label},
                    title => $item->{title},
                    url   => $display_url,
                    max_bytes => $policy->{active} ? 400 : undef,
                );
                next unless defined($line) && length($line);
                push @{ $value->{announcements} }, {
                    item_key => lc($item->{item_key}),
                    line     => $line,
                };
            }
        }
        1;
    };

    unless ($ok) {
        my $err = $@ || 'RSS worker exception';
        $err =~ s/[\r\n\0]+/ /g;
        $value = { ok => 0, error => 'worker_poll', detail => substr($err, 0, 240),
                   id_rss_feed => 0 + $feed->{id_rss_feed}, channel => $feed->{channel},
                   label => $feed->{label}, announcements => [] };
    }

    eval { $dbh->disconnect };
    return $value;
}

sub _start_feed_worker {
    my ($self, $feed) = @_;
    my $id = 0 + $feed->{id_rss_feed};
    return 0 if $self->{inflight}{$id};

    my $ticket = {};
    $self->{inflight}{$id} = $ticket;
    $self->{inflight_channels}{$id} = lc($feed->{channel} // "");
    my $completed = 0;
    my $complete = sub {
        my ($result) = @_;
        return if $completed++;
        my $current = $self->{inflight}{$id};
        return unless ref($current) && refaddr($current) == refaddr($ticket);
        # Release this attempt before invoking code that can start its successor.
        delete $self->{inflight}{$id};
        delete $self->{inflight_channels}{$id};
        delete $self->{workers}{$id};
        my $handled = eval {
            local $self->{dispatching} = 1;
            $self->_worker_done($feed, $result);
            1;
        };
        $self->_log(1, "rss_poll_dispatch: completion failed feed=$id") unless $handled;
        my $drained = eval { $self->_drain_ready_channels; 1 };
        $self->_log(1, "rss_poll_dispatch: output drain failed feed=$id") unless $drained;
    };
    my $worker_class = $self->{worker_class};
    unless (defined($worker_class) && !ref($worker_class)
        && eval { $worker_class->can('start') }) {
        $complete->({ok => 0, error => 'worker_launch', detail => 'RSS worker class is unavailable'});
        return 0;
    }

    my $worker;
    my $launched = eval { $worker = $worker_class->start(
        loop       => $self->{loop},
        label      => "rss poll $id",
        timeout    => $self->{worker_timeout},
        max_output => 256 * 1024,
        child      => sub { $self->_child_poll($feed) },
        on_done    => $complete,
    ); 1 };

    unless ($launched && $worker) {
        # A native setup failure may already have completed inline. The same
        # terminal callback contains exceptions/refusals without double handling.
        $complete->({ok => 0, error => 'worker_launch',
            detail => $launched ? 'RSS worker launch refused' : 'RSS worker launch failed'});
        return 0;
    }

    unless ($completed) {
        $self->{workers}{$id} = $worker;
        $self->_log(3, "rss_poll_dispatch: worker started feed=$id label=$feed->{label}");
    }
    return 1;
}

sub _record_parent_error {
    my ($self, $feed_id, $text) = @_;
    $text = 'RSS worker failure' unless defined($text) && length($text);
    $text =~ s/[\r\n\0]+/ /g;
    my $repo = eval { $self->_parent_repo } or return 0;
    return eval { $repo->record_poll_error($feed_id, substr($text, 0, 255)); 1 } ? 1 : 0;
}

sub _worker_done {
    my ($self, $feed, $result) = @_;
    my $id = 0 + $feed->{id_rss_feed};
    # A failed/empty/new-baseline poll must not leave an old prepared candidate.
    $self->_drop_feed_candidate(lc($feed->{channel} // ""), $id);

    unless (ref($result) eq 'HASH' && $result->{ok} && ref($result->{value}) eq 'HASH') {
        my $detail = ref($result) eq 'HASH'
            ? ($result->{detail} // $result->{error} // 'worker failure')
            : 'invalid worker result';
        $self->_record_parent_error($id, $detail);
        $self->_log(1, "rss_poll_dispatch: worker failed feed=$id: $detail");
        return 0;
    }

    my $value = $result->{value};
    unless ($value->{ok}) {
        my $detail = $value->{detail} // $value->{error} // 'poll failed';
        $self->_log(2, "rss_poll_dispatch: poll failed feed=$id: $detail");
        return 0;
    }

    my $shorturl_events = $value->{shorturl_events};
    $shorturl_events = [] unless ref($shorturl_events) eq 'ARRAY';
    for my $event (@$shorturl_events) {
        next unless ref($event) eq 'HASH';
        my $level = int($event->{level} // 1);
        $level = 0 if $level < 0;
        $level = 4 if $level > 4;
        $self->_log($level, format_event($event));
    }

    if ($value->{baseline}) {
        $self->_log(2, "rss_poll_dispatch: silent baseline feed=$id label=$feed->{label} inserted="
            . int($value->{inserted} || 0));
        return 1;
    }

    my $ann = $value->{announcements};
    $ann = [] unless ref($ann) eq 'ARRAY';
    if (@$ann) {
        $self->_enqueue_announcements(
            feed_id => $id,
            channel => $feed->{channel},
            label   => $feed->{label},
            items   => $ann,
        );
    }

    $self->_log(3, "rss_poll_dispatch: poll completed feed=$id pending=" . scalar(@$ann));
    return 1;
}

# Paced channels retain a bounded, replaceable candidate per feed, never a
# backlog of articles. Wait for this channel's current workers before choosing:
# completion speed and SQL dispatch order must not decide who gets the slot.
sub _drop_feed_candidate {
    my ($self, $ckey, $feed_id) = @_;
    my $q = $self->{outq}{$ckey} or return;
    return unless $q->{paced};
    my @keep;
    for my $item (@{$q->{items}}) {
        if ($item->{feed_id} == $feed_id) { delete $self->{queued}{$item->{qid}} }
        else { push @keep, $item }
    }
    $q->{items} = \@keep;
}
sub _channel_busy {
    my ($self, $ckey) = @_;
    return 1 if $self->{dispatching};
    return scalar grep {$_ eq $ckey} values %{$self->{inflight_channels}};
}
sub _drain_ready_channels {
    my ($self) = @_;
    for my $ckey (sort keys %{$self->{outq}}) {
        my $q = $self->{outq}{$ckey};
        next unless $q->{paced} && !$q->{timer} && !$self->_channel_busy($ckey);
        $self->_drain_channel($ckey);
    }
}
sub _enqueue_announcements {
    my ($self, %args) = @_;
    my $feed_id = $args{feed_id};
    my $channel = $args{channel};
    return 0 unless defined($feed_id) && $feed_id =~ /^\d+$/;
    return 0 unless defined($channel) && $channel =~ /^[#&!+]/;
    return 0 unless ref($args{items}) eq 'ARRAY';
    my $policy = eval { $self->{pacing}->status($channel) };
    return 0 unless $policy;
    my $paced = $policy->{active} ? 1 : 0;
    my $ckey = lc $channel;
    my $q = ($self->{outq}{$ckey} ||= {
        channel => $channel, items => [], timer => undef, draining => 0, paced => $paced,
    });
    # Changing mode discards prepared output from the old policy.
    if ($q->{paced} != $paced) {
        delete $self->{queued}{$_->{qid}} for @{$q->{items}};
        my $arm = delete $q->{arm};
        $arm->{cancelled} = 1 if $arm;
        if (my $timer = delete $q->{timer}) {
            eval { $timer->stop };
            eval { $self->{loop}->remove($timer) };
        }
        $q->{items} = []; $q->{paced} = $paced;
    }
    $self->_drop_feed_candidate($ckey, $feed_id) if $paced;
    my $added = 0;
    for my $item (@{ $args{items} }) {
        next unless ref($item) eq 'HASH';
        my $key = $item->{item_key};
        my $line = $item->{line};
        next unless defined($key) && $key =~ /^[0-9a-f]{64}$/i;
        next unless defined($line) && !ref($line) && length($line);
        next if $paced && _utf8_text_bytes($line) > 400;
        my $qid = $feed_id . ':' . lc($key);
        next if $self->{queued}{$qid};
        last if $paced && $self->queued_count >= 1000;
        $self->{queued}{$qid} = 1;
        push @{ $q->{items} }, {
            qid => $qid, feed_id => 0 + $feed_id, item_key => lc($key),
            line => $line, label => ($args{label} // ''),
        };
        $added++;
        last if $paced;
    }
    $self->_drain_channel($ckey) if $added && !$q->{draining} && !$q->{timer}
        && (!$paced || !$self->_channel_busy($ckey));
    return $added;
}

sub _arm_next {
    my ($self, $ckey) = @_;
    my $q = $self->{outq}{$ckey} or return 0;
    return 0 unless @{ $q->{items} || [] };
    return 1 if $q->{timer};

    my ($owner, $queue, $loop) = ($self, $q, $self->{loop});
    weaken($owner); weaken($queue); weaken($loop);
    my $arm = $q->{arm} = {};
    my $owned = sub {
        return unless $owner && $queue && $owner->{outq}{$ckey}
            && refaddr($owner->{outq}{$ckey}) == refaddr($queue)
            && $queue->{arm} && refaddr($queue->{arm}) == refaddr($arm);
        return ($owner, $queue);
    };
    my $cleanup = sub {
        my ($timer) = @_; return unless $timer;
        eval { $timer->stop };
        eval { $loop->remove($timer) } if $loop;
    };
    my ($timer, $weak_timer);
    my $started = eval {
        $timer = IO::Async::Timer::Countdown->new(
            delay => $self->{output_delay},
            on_expire => sub {
                return if $arm->{cancelled} || $arm->{done}++;
                my ($current_owner, $current) = $owned->();
                if ($current_owner) {
                    delete $current->{arm};
                    delete $current->{timer};
                }
                $cleanup->($weak_timer);
                return unless $current_owner && $current_owner->{outq}{$ckey}
                    && refaddr($current_owner->{outq}{$ckey}) == refaddr($current)
                    && !$current->{arm} && !$current->{timer};
                $current_owner->_drain_channel($ckey);
            },
        );
        $weak_timer = $timer; weaken($weak_timer);
        if ($owned->()) {
            $q->{timer} = $timer;
            $self->{loop}->add($timer);
            $timer->start if $owned->();
        }
        1;
    };
    return 1 if $started && $owned->();
    if (!$started && $owned->()) {
        # Revoke prepared output before cleanup can reenter. Unsent articles
        # remain pending in SQL and can be prepared again by a later poll.
        $arm->{cancelled} = 1;
        delete $q->{arm}; delete $q->{timer};
        delete $self->{queued}{$_->{qid}} for @{$q->{items}};
        $q->{items} = [];
        delete $self->{outq}{$ckey};
        $cleanup->($timer);
        $self->_log(1, 'rss_poll_dispatch: output timer unavailable; unsent items remain pending');
        return 0;
    }
    # Inline expiry or cleanup may already have installed a successor.
    $cleanup->($timer);
    return 1;
}

sub _drain_channel {
    my ($self, $ckey) = @_;
    my $q = $self->{outq}{$ckey} or return 0;
    return 0 if $q->{draining};
    unless (@{$q->{items} || []}) {
        delete $self->{outq}{$ckey};
        return 0;
    }
    my $policy = eval { $self->{pacing}->status($q->{channel}) };
    unless ($policy) {
        $self->_log(1, "rss_poll_dispatch: pacing state unavailable; output held");
        unless ($q->{paced}) {
            delete $self->{queued}{$_->{qid}} for @{$q->{items}};
            delete $self->{outq}{$ckey};
        }
        return 0;
    }
    my $paced = $policy->{active};
    # Never release a protected cache as a legacy catch-up burst.
    if ($q->{paced} && !$paced) {
        delete $self->{queued}{$_->{qid}} for @{$q->{items}};
        delete $self->{outq}{$ckey};
        return 0;
    }
    my $repo = eval { $self->_parent_repo };
    unless ($repo) {
        unless ($paced) {
            delete $self->{queued}{$_->{qid}} for @{$q->{items}};
            delete $self->{outq}{$ckey};
        }
        return 0;
    }
    if ($paced) {
        return 0 if $policy->{wait} || $self->_channel_busy($ckey);
        return 0 unless eval { $self->{bot}{irc}->is_connected };
        my (@ready, @drop);
        for my $candidate (@{$q->{items}}) {
            my ($enabled, $latest);
            my $ok = eval {
                $enabled = $repo->is_feed_enabled($candidate->{feed_id});
                $latest = $repo->paced_pending_items($candidate->{feed_id}) if $enabled;
                1;
            };
            return 0 unless $ok;
            if ($enabled && $latest && @$latest
                && $latest->[0]{item_key} eq $candidate->{item_key}
                && _utf8_text_bytes($candidate->{line}) <= 400) {
                push @ready, $candidate;
            }
            else {
                push @drop, $candidate->{qid};
                $self->_log(3, "rss_poll_dispatch: dropped queued item for deleted/disabled feed=$candidate->{feed_id} or superseded article");
            }
        }
        delete $self->{queued}{$_} for @drop;
        $q->{items} = \@ready;
        $q->{paced} = 1;
        my $order = eval { $self->{pacing}->rotation_order($q->{channel},
            [map {$_->{feed_id}} @ready]) };
        return 0 unless $order;
        my %rank; @rank{@$order} = (0 .. $#$order);
        $q->{items} = [sort {$rank{$a->{feed_id}} <=> $rank{$b->{feed_id}}} @ready];
    }
    my $item = shift @{ $q->{items} || [] };
    unless ($item) {
        delete $self->{outq}{$ckey};
        return 0;
    }
    $q->{draining} = 1;
    delete $self->{queued}{ $item->{qid} };
    my $enabled = eval { $repo->is_feed_enabled($item->{feed_id}) };
    if ($enabled) {
        my $allowed = !$paced;
        if ($paced) {
            my $slot = eval { $self->{pacing}->reserve($q->{channel}, feed_id => $item->{feed_id}) };
            $allowed = $slot && $slot->{allowed};
        }
        my $accepted = eval {
            $allowed ? Mediabot::Helpers::botPrivmsg($self->{bot}, $q->{channel}, $item->{line},
                $paced ? {no_defer => 1} : undef) : 0
        };
        if ($accepted) {
            my $marked = eval {
                $repo->mark_announced($item->{feed_id}, [ $item->{item_key} ])
            };
            if (!$marked) {
                $self->_log(1, "rss_poll_dispatch: sent but could not mark announced feed=$item->{feed_id} key=$item->{item_key}");
            }
        }
        else {
            $self->_log(2, "rss_poll_dispatch: output rejected; item remains pending feed=$item->{feed_id} key=$item->{item_key}");
            if ($paced) {
                push @{$q->{items}}, $item;
                $self->{queued}{$item->{qid}} = 1;
            }
        }
    }
    else {
        $self->_log(3, "rss_poll_dispatch: dropped queued item for deleted/disabled feed=$item->{feed_id}");
    }
    $q->{draining} = 0;
    if (@{ $q->{items} || [] }) {
        # Only the scheduler may reconsider paced candidates. No per-item timer
        # or deferred AntiFlood output can bypass the shared gap / daily quota.
        $self->_arm_next($ckey) unless $paced;
    }
    else {
        delete $self->{outq}{$ckey};
    }
    return 1;
}

1;
