package Mediabot::VDM::Runtime;

use strict;
use warnings;
use utf8;

use Mediabot::VDM qw(evaluate_vdm_gate format_vdm_line vdm_repeat_window_seconds);
use Mediabot::VDM::AsyncFetcher;

sub new {
    my ($class, %args) = @_;
    my $bot = $args{bot} or die "bot is required";
    my $loop = $args{loop} || eval { $bot->getLoop } || $bot->{loop};

    my $max_channels = int($args{max_channels} // 256);
    $max_channels = 1 if $max_channels < 1;
    $max_channels = 1024 if $max_channels > 1024;

    my $max_recent = int($args{max_recent} // 32);
    $max_recent = 1 if $max_recent < 1;
    $max_recent = 128 if $max_recent > 128;

    my $fetcher = $args{fetcher};
    if (!$fetcher && $loop) {
        $fetcher = Mediabot::VDM::AsyncFetcher->new(loop => $loop);
    }

    return bless {
        bot          => $bot,
        loop         => $loop,
        fetcher      => $fetcher,
        now_cb       => ref($args{now_cb}) eq 'CODE' ? $args{now_cb} : sub { time() },
        chanset_cb   => ref($args{chanset_cb}) eq 'CODE' ? $args{chanset_cb} : sub {
            my ($owner, $channel) = @_;
            require Mediabot::Helpers;
            return Mediabot::Helpers::chanset_enabled($owner, $channel, 'VDM', default => 0);
        },
        notice_cb    => ref($args{notice_cb}) eq 'CODE' ? $args{notice_cb} : sub {
            my ($owner, $nick, $text) = @_;
            require Mediabot::Helpers;
            return Mediabot::Helpers::botNotice($owner, $nick, $text);
        },
        send_cb      => ref($args{send_cb}) eq 'CODE' ? $args{send_cb} : sub {
            my ($owner, $channel, $text) = @_;
            require Mediabot::Helpers;
            return Mediabot::Helpers::botPrivmsg($owner, $channel, $text);
        },
        connected_cb => ref($args{connected_cb}) eq 'CODE' ? $args{connected_cb} : sub {
            my ($owner) = @_;
            my $irc = eval { $owner->{irc} } or return 0;
            return eval { $irc->is_connected } ? 1 : 0;
        },
        joined_cb    => ref($args{joined_cb}) eq 'CODE' ? $args{joined_cb} : sub {
            my ($owner, $channel) = @_;
            my $key = _channel_key($channel);
            return 0 unless defined $key;
            my $channels = eval { $owner->{channels} };
            return 0 unless ref($channels) eq 'HASH';
            return exists($channels->{$key}) ? 1 : 0;
        },
        max_channels => $max_channels,
        max_recent   => $max_recent,
        channel_states => {},
        request_seq    => 0,
    }, $class;
}

sub _log {
    my ($self, $level, $text) = @_;
    my $logger = eval { $self->{bot}{logger} } or return;
    $text = '' unless defined($text) && !ref($text);
    $text =~ s/[\r\n\0]+/ /g;
    eval { $logger->log($level, $text) };
}

sub _now {
    my ($self) = @_;
    my $now = eval { $self->{now_cb}->() };
    return time() unless defined($now) && !ref($now) && $now =~ /\A-?(?:\d+(?:\.\d*)?|\.\d+)\z/;
    return 0 + $now;
}

sub _channel_key {
    my ($channel) = @_;
    return undef unless defined($channel) && !ref($channel) && $channel =~ /^#/;
    return lc($channel);
}

sub _channel_state {
    my ($self, $channel) = @_;
    my $key = _channel_key($channel);
    return undef unless defined $key;

    if (!exists $self->{channel_states}{$key}) {
        if (keys(%{ $self->{channel_states} }) >= $self->{max_channels}) {
            my ($oldest) = sort {
                ($self->{channel_states}{$a}{touched} // 0) <=> ($self->{channel_states}{$b}{touched} // 0)
            } keys %{ $self->{channel_states} };
            delete $self->{channel_states}{$oldest} if defined $oldest;
        }
        $self->{channel_states}{$key} = {
            channel => $channel,
            touched => $self->_now,
            pending => undef,
            recent  => [],
        };
    }

    my $state = $self->{channel_states}{$key};
    $state->{channel} = $channel;
    $state->{touched} = $self->_now;
    return $state;
}

sub _prune_recent {
    my ($self, $state) = @_;
    return unless $state && ref($state->{recent}) eq 'ARRAY';

    my $now = $self->_now;
    my $window = vdm_repeat_window_seconds();
    my @keep = grep {
        ref($_) eq 'HASH'
        && defined($_->{id})
        && defined($_->{ts})
        && ($now - $_->{ts}) < $window
    } @{ $state->{recent} };

    splice(@keep, $self->{max_recent}) if @keep > $self->{max_recent};
    $state->{recent} = \@keep;
}

sub _recent_id {
    my ($self, $state, $id) = @_;
    return 0 unless defined($id) && !ref($id);
    $self->_prune_recent($state);
    for my $entry (@{ $state->{recent} || [] }) {
        return 1 if defined($entry->{id}) && "$entry->{id}" eq "$id";
    }
    return 0;
}

sub _remember_id {
    my ($self, $state, $id) = @_;
    return 0 unless defined($id) && !ref($id);
    $self->_prune_recent($state);
    unshift @{ $state->{recent} }, { id => "$id", ts => $self->_now };
    splice @{ $state->{recent} }, $self->{max_recent}
        if @{ $state->{recent} } > $self->{max_recent};
    return 1;
}

sub _irc_connected {
    my ($self) = @_;
    return eval { $self->{connected_cb}->($self->{bot}) } ? 1 : 0;
}

sub _channel_joined {
    my ($self, $channel) = @_;
    return eval { $self->{joined_cb}->($self->{bot}, $channel) } ? 1 : 0;
}

sub _vdm_enabled {
    my ($self, $channel) = @_;
    return eval { $self->{chanset_cb}->($self->{bot}, $channel) } ? 1 : 0;
}

sub _manual_gate {
    my ($self, $channel) = @_;
    return evaluate_vdm_gate(
        mode           => 'manual',
        channel        => $channel,
        vdm_enabled    => $self->_vdm_enabled($channel),
        runtime_active => 1,
        irc_connected  => $self->_irc_connected,
        channel_joined => $self->_channel_joined($channel),
    );
}

sub _safe_notice {
    my ($self, $nick, $text) = @_;
    return 0 unless defined($nick) && !ref($nick) && length($nick);
    return 0 unless defined($text) && !ref($text) && length($text);
    return eval { $self->{notice_cb}->($self->{bot}, $nick, $text) } ? 1 : 0;
}

sub _pick_item {
    my ($self, $state, $items) = @_;
    return undef unless ref($items) eq 'ARRAY';

    for my $item (@$items) {
        next unless ref($item) eq 'HASH';
        my $id = $item->{id};
        my $story = $item->{story};
        next if $self->_recent_id($state, $id);
        my $line = format_vdm_line(id => $id, story => $story);
        next unless defined($line) && length($line);
        return { item => $item, line => $line };
    }
    return undef;
}

sub request_manual {
    my ($self, $ctx) = @_;
    return 0 unless $ctx && eval { $ctx->can('channel') } && eval { $ctx->can('nick') };

    my $channel = $ctx->channel;
    my $nick = $ctx->nick;
    my $key = _channel_key($channel);
    unless (defined $key) {
        $self->_safe_notice($nick, 'VDM is available only from a channel.');
        return 1;
    }

    my $gate = $self->_manual_gate($channel);
    unless ($gate->{action} && $gate->{action} eq 'allow') {
        my $reason = $gate->{reason} // 'denied';
        if ($reason eq 'vdm_disabled') {
            $self->_safe_notice($nick, "VDM is disabled on $channel (chanset -VDM).");
        }
        else {
            $self->_safe_notice($nick, 'VDM is temporarily unavailable on this channel.');
        }
        $self->_log(3, "[VDM] channel=$channel action=no_fetch reason=$reason mode=manual");
        return 1;
    }

    my $state = $self->_channel_state($channel) or return 0;
    if ($state->{pending}) {
        $self->_safe_notice($nick, 'A VDM request is already in flight on this channel.');
        $self->_log(4, "[VDM] channel=$channel action=no_fetch reason=inflight mode=manual");
        return 1;
    }

    my $fetcher = $self->{fetcher};
    unless ($fetcher && eval { $fetcher->can('fetch') }) {
        $self->_safe_notice($nick, 'VDM is temporarily unavailable.');
        $self->_log(1, "[VDM] channel=$channel action=no_fetch reason=fetcher_unavailable mode=manual");
        return 1;
    }

    my $request_id = ++$self->{request_seq};
    $state->{pending} = $request_id;
    $state->{touched} = $self->_now;

    my $accepted = $fetcher->fetch(
        on_done => sub {
            my ($result) = @_;
            my $current = $self->{channel_states}{$key};
            return unless $current && defined($current->{pending}) && $current->{pending} == $request_id;
            delete $current->{pending};
            $current->{touched} = $self->_now;

            my $late_gate = $self->_manual_gate($channel);
            unless ($late_gate->{action} && $late_gate->{action} eq 'allow') {
                my $reason = $late_gate->{reason} // 'revoked';
                $self->_log(3, "[VDM] channel=$channel action=no_send reason=$reason mode=manual request_id=$request_id");
                return;
            }

            unless (ref($result) eq 'HASH' && $result->{ok} && ref($result->{items}) eq 'ARRAY') {
                my $reason = ref($result) eq 'HASH' ? ($result->{error} // 'fetch_failed') : 'invalid_result';
                $reason =~ s/[^A-Za-z0-9_.:-]+/_/g;
                $self->_safe_notice($nick, 'VDM feed is temporarily unavailable.');
                $self->_log(2, "[VDM] channel=$channel action=no_send reason=$reason mode=manual request_id=$request_id");
                return;
            }

            my $picked = $self->_pick_item($current, $result->{items});
            unless ($picked) {
                $self->_safe_notice($nick, 'No fresh VDM is available right now.');
                $self->_log(3, "[VDM] channel=$channel action=no_send reason=repeat_window mode=manual request_id=$request_id");
                return;
            }

            my $accepted_send = eval {
                $self->{send_cb}->($self->{bot}, $channel, $picked->{line})
            };
            unless ($accepted_send) {
                $self->_log(2, "[VDM] channel=$channel action=no_send reason=output_rejected mode=manual request_id=$request_id");
                return;
            }

            $self->_remember_id($current, $picked->{item}{id});
            $self->_log(3, "[VDM] channel=$channel action=sent mode=manual request_id=$request_id story_id=$picked->{item}{id}");
        },
    );

    unless ($accepted) {
        delete $state->{pending} if defined($state->{pending}) && $state->{pending} == $request_id;
        $self->_safe_notice($nick, 'VDM is temporarily unavailable.');
        $self->_log(2, "[VDM] channel=$channel action=no_fetch reason=worker_busy mode=manual request_id=$request_id");
        return 1;
    }

    $self->_log(4, "[VDM] channel=$channel action=fetch_started mode=manual request_id=$request_id");
    return 1;
}

sub request_spark {
    my ($self, %args) = @_;

    my $channel = $args{channel};
    my $key = _channel_key($channel);
    return 0 unless defined $key;

    my $spark_enabled_cb = $args{spark_enabled_cb};
    my $activity_current_cb = $args{activity_current_cb};
    my $deliver_cb = $args{deliver_cb};
    return 0 unless ref($spark_enabled_cb) eq 'CODE'
        && ref($activity_current_cb) eq 'CODE'
        && ref($deliver_cb) eq 'CODE';

    unless (eval { $activity_current_cb->() }) {
        $self->_log(4, "[VDM] channel=$channel action=no_fetch reason=stale_activity mode=spark");
        return 0;
    }

    my $spark_enabled = eval { $spark_enabled_cb->() } ? 1 : 0;
    my $gate = evaluate_vdm_gate(
        mode           => 'spark',
        channel        => $channel,
        vdm_enabled    => $self->_vdm_enabled($channel),
        spark_enabled  => $spark_enabled,
        runtime_active => 1,
        irc_connected  => $self->_irc_connected,
        channel_joined => $self->_channel_joined($channel),
    );
    unless ($gate->{action} && $gate->{action} eq 'allow') {
        my $reason = $gate->{reason} // 'denied';
        $self->_log(4, "[VDM] channel=$channel action=no_fetch reason=$reason mode=spark");
        return 0;
    }

    my $state = $self->_channel_state($channel) or return 0;
    if ($state->{pending}) {
        $self->_log(4, "[VDM] channel=$channel action=no_fetch reason=inflight mode=spark");
        return 0;
    }

    my $fetcher = $self->{fetcher};
    unless ($fetcher && eval { $fetcher->can('fetch') }) {
        $self->_log(1, "[VDM] channel=$channel action=no_fetch reason=fetcher_unavailable mode=spark");
        return 0;
    }

    my $request_id = ++$self->{request_seq};
    $state->{pending} = $request_id;
    $state->{touched} = $self->_now;

    my $accepted = $fetcher->fetch(
        on_done => sub {
            my ($result) = @_;
            my $current = $self->{channel_states}{$key};
            return unless $current && defined($current->{pending}) && $current->{pending} == $request_id;
            delete $current->{pending};
            $current->{touched} = $self->_now;

            unless (eval { $activity_current_cb->() }) {
                $self->_log(3, "[VDM] channel=$channel action=no_send reason=stale_activity mode=spark request_id=$request_id");
                return;
            }

            my $late_spark_enabled = eval { $spark_enabled_cb->() } ? 1 : 0;
            my $late_gate = evaluate_vdm_gate(
                mode           => 'spark',
                channel        => $channel,
                vdm_enabled    => $self->_vdm_enabled($channel),
                spark_enabled  => $late_spark_enabled,
                runtime_active => 1,
                irc_connected  => $self->_irc_connected,
                channel_joined => $self->_channel_joined($channel),
            );
            unless ($late_gate->{action} && $late_gate->{action} eq 'allow') {
                my $reason = $late_gate->{reason} // 'revoked';
                $self->_log(3, "[VDM] channel=$channel action=no_send reason=$reason mode=spark request_id=$request_id");
                return;
            }

            unless (ref($result) eq 'HASH' && $result->{ok} && ref($result->{items}) eq 'ARRAY') {
                my $reason = ref($result) eq 'HASH' ? ($result->{error} // 'fetch_failed') : 'invalid_result';
                $reason =~ s/[^A-Za-z0-9_.:-]+/_/g;
                $self->_log(2, "[VDM] channel=$channel action=no_send reason=$reason mode=spark request_id=$request_id");
                return;
            }

            my $picked = $self->_pick_item($current, $result->{items});
            unless ($picked) {
                $self->_log(3, "[VDM] channel=$channel action=no_send reason=repeat_window mode=spark request_id=$request_id");
                return;
            }

            my $delivery = eval { $deliver_cb->($picked->{item}) };
            unless (ref($delivery) eq 'HASH' && ($delivery->{action} // '') eq 'sent') {
                my $reason = ref($delivery) eq 'HASH' ? ($delivery->{reason} // 'delivery_failed') : 'delivery_failed';
                $reason =~ s/[^A-Za-z0-9_.:-]+/_/g;
                $self->_log(3, "[VDM] channel=$channel action=no_send reason=$reason mode=spark request_id=$request_id");
                return;
            }

            $self->_remember_id($current, $picked->{item}{id});
            $self->_log(3, "[VDM] channel=$channel action=sent mode=spark request_id=$request_id story_id=$picked->{item}{id}");
        },
    );

    unless ($accepted) {
        delete $state->{pending} if defined($state->{pending}) && $state->{pending} == $request_id;
        $self->_log(2, "[VDM] channel=$channel action=no_fetch reason=worker_busy mode=spark request_id=$request_id");
        return 0;
    }

    $self->_log(4, "[VDM] channel=$channel action=fetch_started mode=spark request_id=$request_id");
    return $request_id;
}

sub channel_pending {
    my ($self, $channel) = @_;
    my $key = _channel_key($channel);
    return 0 unless defined($key) && exists($self->{channel_states}{$key});
    return $self->{channel_states}{$key}{pending} ? 1 : 0;
}

sub clear_channel {
    my ($self, $channel) = @_;
    my $key = _channel_key($channel);
    return 0 unless defined($key);
    return delete($self->{channel_states}{$key}) ? 1 : 0;
}

sub mbVdm_ctx {
    my ($ctx) = @_;
    return 0 unless $ctx && eval { $ctx->can('bot') };
    my $bot = $ctx->bot or return 0;

    my $runtime = $bot->{_vdm_runtime};
    unless ($runtime && eval { $runtime->can('request_manual') }) {
        my $loop = eval { $bot->getLoop } || $bot->{loop};
        $runtime = __PACKAGE__->new(bot => $bot, loop => $loop);
        $bot->{_vdm_runtime} = $runtime;
    }

    return $runtime->request_manual($ctx);
}

1;
