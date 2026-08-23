package Mediabot::RSS::Runtime;

use strict;
use warnings;
use utf8;

use IO::Async::Timer::Countdown;
use Mediabot::AsyncWorker;
use Mediabot::Helpers ();
use Mediabot::RSS qw(format_rss_announcement);
use Mediabot::RSS::Poller;
use Mediabot::RSS::Repository;
use Mediabot::RSS::TinyURL qw(make_shortener);

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
        loop          => $loop,
        max_workers   => $max_workers,
        dispatch_limit => int($args{dispatch_limit} // 20),
        worker_timeout => 0 + ($args{worker_timeout} // 60),
        output_delay  => $delay,
        inflight      => {},
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

sub tick {
    my ($self) = @_;
    my $bot = $self->{bot};

    # mediabot.pl sets _start_time only after the IRC login Future has
    # completed. Never let a scheduler tick publish while login is incomplete.
    return 0 unless $bot->{_start_time};

    my $capacity = $self->{max_workers} - $self->inflight_count;
    return 0 if $capacity <= 0;

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
    for my $feed (@$due) {
        last if $started >= $capacity;
        next unless ref($feed) eq 'HASH';
        my $id = $feed->{id_rss_feed};
        next unless defined($id) && $id =~ /^\d+$/;
        next if $self->{inflight}{$id};
        $started++ if $self->_start_feed_worker($feed);
    }
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
        my $poller = Mediabot::RSS::Poller->new(repo => $repo);
        my $res = $poller->poll_feed($feed);

        $value = {
            %$res,
            id_rss_feed => 0 + $feed->{id_rss_feed},
            channel     => $feed->{channel},
            label       => $feed->{label},
            announcements => [],
        };

        if ($res->{ok} && ref($res->{pending}) eq 'ARRAY' && @{ $res->{pending} }) {
            my $shorten = make_shortener();
            for my $item (@{ $res->{pending} }) {
                next unless ref($item) eq 'HASH';
                next unless defined($item->{item_key}) && $item->{item_key} =~ /^[0-9a-f]{64}$/i;
                my $url = $item->{url} // '';
                my $display_url = length($url) ? $shorten->($url) : '';
                my $line = format_rss_announcement(
                    label => $feed->{label},
                    title => $item->{title},
                    url   => $display_url,
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

    $self->{inflight}{$id} = 1;
    my $worker_class = $self->{worker_class};
    unless (defined($worker_class) && !ref($worker_class)
        && eval { $worker_class->can('start') }) {
        delete $self->{inflight}{$id};
        $self->_log(1, "rss_poll_dispatch: worker class is unavailable");
        return 0;
    }

    my $worker;
    $worker = $worker_class->start(
        loop       => $self->{loop},
        label      => "rss poll $id",
        timeout    => $self->{worker_timeout},
        max_output => 256 * 1024,
        child      => sub { $self->_child_poll($feed) },
        on_done    => sub {
            my ($result) = @_;
            delete $self->{inflight}{$id};
            delete $self->{workers}{$id};
            $self->_worker_done($feed, $result);
        },
    );

    unless ($worker) {
        delete $self->{inflight}{$id};
        return 0;
    }

    $self->{workers}{$id} = $worker;
    $self->_log(3, "rss_poll_dispatch: worker started feed=$id label=$feed->{label}");
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

sub _enqueue_announcements {
    my ($self, %args) = @_;
    my $feed_id = $args{feed_id};
    my $channel = $args{channel};
    return 0 unless defined($feed_id) && $feed_id =~ /^\d+$/;
    return 0 unless defined($channel) && $channel =~ /^[#&!+]/;
    return 0 unless ref($args{items}) eq 'ARRAY';

    my $q = ($self->{outq}{lc $channel} ||= { channel => $channel, items => [], timer => undef, draining => 0 });
    my $added = 0;
    for my $item (@{ $args{items} }) {
        next unless ref($item) eq 'HASH';
        my $key = $item->{item_key};
        my $line = $item->{line};
        next unless defined($key) && $key =~ /^[0-9a-f]{64}$/i;
        next unless defined($line) && !ref($line) && length($line);
        my $qid = $feed_id . ':' . lc($key);
        next if $self->{queued}{$qid};
        $self->{queued}{$qid} = 1;
        push @{ $q->{items} }, {
            qid => $qid, feed_id => 0 + $feed_id, item_key => lc($key),
            line => $line, label => ($args{label} // ''),
        };
        $added++;
    }

    $self->_drain_channel(lc $channel) if $added && !$q->{draining} && !$q->{timer};
    return $added;
}

sub _arm_next {
    my ($self, $ckey) = @_;
    my $q = $self->{outq}{$ckey} or return 0;
    return 0 unless @{ $q->{items} || [] };
    return 1 if $q->{timer};

    my $timer;
    $timer = IO::Async::Timer::Countdown->new(
        delay => $self->{output_delay},
        on_expire => sub {
            my $current = $self->{outq}{$ckey} or return;
            my $owned = delete $current->{timer};
            eval { $self->{loop}->remove($owned) } if $owned;
            $self->_drain_channel($ckey);
        },
    );
    $q->{timer} = $timer;
    $self->{loop}->add($timer);
    $timer->start;
    return 1;
}

sub _drain_channel {
    my ($self, $ckey) = @_;
    my $q = $self->{outq}{$ckey} or return 0;
    return 0 if $q->{draining};
    my $item = shift @{ $q->{items} || [] };
    unless ($item) {
        delete $self->{outq}{$ckey};
        return 0;
    }

    $q->{draining} = 1;
    delete $self->{queued}{ $item->{qid} };

    my $repo = eval { $self->_parent_repo };
    my $enabled = $repo ? eval { $repo->is_feed_enabled($item->{feed_id}) } : 0;
    if ($enabled) {
        my $accepted = eval {
            Mediabot::Helpers::botPrivmsg($self->{bot}, $q->{channel}, $item->{line})
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
        }
    }
    else {
        $self->_log(3, "rss_poll_dispatch: dropped queued item for deleted/disabled feed=$item->{feed_id}");
    }

    $q->{draining} = 0;
    if (@{ $q->{items} || [] }) {
        $self->_arm_next($ckey);
    }
    else {
        delete $self->{outq}{$ckey};
    }
    return 1;
}

1;
