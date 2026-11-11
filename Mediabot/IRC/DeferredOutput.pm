package Mediabot::IRC::DeferredOutput;

use strict;
use warnings;
use utf8;
use Scalar::Util qw(refaddr weaken);
use Mediabot::IRC::Timer ();
use Time::HiRes ();

# Existing bounded AntiFlood queue. Keep state keys, head reinsertion, timing
# and dynamic Helpers callbacks; this is separate from explicit paced batches.
sub botPrivmsg { return Mediabot::Helpers::botPrivmsg(@_); }
sub botAction { return Mediabot::Helpers::botAction(@_); }

# A response has one monotonic deadline shared by all its remaining lines.
# Queue retries must retain this identity and never refresh its lifetime.
sub _flood_queue_now {
    return Time::HiRes::clock_gettime(Time::HiRes::CLOCK_MONOTONIC());
}

sub _expire_flood_output {
    my ($self, $to, $q, $now) = @_;
    my (@keep, %expired);
    for my $item (@{$q->{items}}) {
        # Old in-memory entries have no trustworthy enqueue timestamp. Give
        # them one bounded grace period when first observed after an upgrade.
        my $response = $item->[3] ||= { expires_at => $now + 120 };
        if ($now >= $response->{expires_at}) {
            $expired{refaddr($response)}++;
        } else {
            push @keep, $item;
        }
    }
    @{$q->{items}} = @keep;
    for my $lines (values %expired) {
        eval { $self->{logger}->log(3,
            "AntiFlood expired one queued response on $to ($lines remaining lines)") };
        eval { $self->{metrics}->inc('mediabot_antiflood_expired_responses_total') }
            if $self->{metrics};
    }
    return scalar keys %expired;
}

sub _defer_flooded_send {
    my ($self, $kind, $to, $msg, $send_options) = @_;

    my $q = $self->{_flood_outq}{$to} //= { items => [], armed => 0 };
    my $retry = (refaddr($self->{_flood_draining}) // 0) == refaddr($q);
    my $now = _flood_queue_now();
    _expire_flood_output($self, $to, $q, $now) unless $retry;
    my $response = $retry ? $self->{_flood_response} : undef;
    $response ||= { expires_at => $now + 120 };
    # Queue physical IRC lines so an oversized response can make progress
    # even when its total cost exceeds the channel or connection allowance.
    my @chunks = Mediabot::Helpers::_split_text_for_irc($msg, $kind eq 'action' ? 391 : 400);
    @chunks = ($msg) unless @chunks;
    my @items;
    for my $chunk (@chunks) {
        my $item = [$kind, $chunk];
        push @$item, {ping_started_at => $send_options->{ping_started_at}}
            if ref($send_options) eq 'HASH' && defined($send_options->{ping_started_at})
                && !ref($send_options->{ping_started_at});
        # Keep the whole response for badword checks across chunk boundaries.
        my $source = ref($send_options) eq 'HASH' ? $send_options->{flood_source_text} : undef;
        $source = $msg if @chunks > 1 && !defined($source);
        if (defined($source) && !ref($source)) {
            $item->[2] ||= {};
            $item->[2]{flood_source_text} = $source;
        }
        $item->[3] = $response;
        push @items, $item;
    }
    if (@{$q->{items}} + @items > 30) {
        $self->{logger}->log(3,
            "flood queue full on $to — dropping one $kind message");
        return undef;
    }
    if ($retry) {
        # Preserve line order ahead of later replies, including a legacy
        # unsplit item already queued before this code was loaded.
        unshift @{$q->{items}}, @items;
        return undef;
    }
    push @{$q->{items}}, @items;
    $self->{logger}->log(4, "botPrivmsg/botAction deferred by AntiFlood on $to ("
        . scalar(@{ $q->{items} }) . " queued)");
    Mediabot::Helpers::_arm_flood_drain($self, $to);
    return 1;
}

sub _flood_queue_current {
    my ($self, $to, $expected) = @_;
    return 0 unless $expected;
    my $queues = $self->{_flood_outq} or return 0;
    my $current = $queues->{$to} or return 0;
    return refaddr($current) == refaddr($expected);
}

# Read existing silence deadlines without charging budgets, refreshing SQL,
# or creating AntiFlood state. Keep ordinary retries at two seconds: skipping
# full windows here would change the existing single-line silence policy.
sub _flood_retry_delay {
    my ($self, $to, $now) = @_;
    $now = time() unless defined $now;
    my $delay = 2;
    my $channels = $self->{_af};
    my $channel = $channels ? $channels->{$to} : undef;
    my $global = $self->{_global_af};
    for my $state ($global, $channel) {
        next unless $state;
        my $until = $state->{silenced_until} // 0;
        my $remaining = $until - $now;
        $delay = $remaining if $remaining > $delay;
    }
    # Re-enter the normal sender at least every ten seconds so chanset/config
    # changes and clock adjustments cannot strand output behind an old timer.
    return $delay > 10 ? 10 : $delay;
}

# Called with the detached old registry, after the new IRC transport is visible.
# Revoke every queue before stop/remove can re-enter and create successor work.
sub retire_flood_queues {
    my ($self, $queues) = @_;
    return 1 unless $queues;
    my @old = values %$queues;
    %$queues = ();
    my @timers;
    for my $q (@old) {
        delete $q->{arm};
        push @timers, delete $q->{timer};
        @{$q->{items}} = ();
        $q->{armed} = 0;
    }
    my $ok = 1;
    for my $timer (@timers) {
        $ok = 0 unless Mediabot::IRC::Timer::cancel_countdown($timer);
    }
    _report_retirement_failure($self) unless $ok;
    return $ok;
}

sub _report_retirement_failure {
    my ($self) = @_;
    eval { $self->{logger}->log(1,
        'AntiFlood output revoked; timer cleanup incomplete') if $self->{logger}; };
    return;
}

sub _arm_flood_drain {
    my ($self, $to) = @_;
    my $q = $self->{_flood_outq}{$to} or return;
    return if $q->{armed};

    my $loop = eval { $self->getLoop } // $self->{loop};
    unless ($loop) {
        # Pas de boucle (tests unitaires, arret) : la file reste, un prochain
        # envoi reel la rearmera.
        return;
    }
    $q->{armed} = 1;
    my $arm = $q->{arm} = {};
    my $expected = $q;
    weaken($expected);
    my $started = eval {
        my $timer = Mediabot::IRC::Timer::countdown(
            loop => $loop,
            delay => _flood_retry_delay($self, $to),
            on_expire => sub {
                return unless _flood_queue_current($self, $to, $expected);
                return unless (refaddr($expected->{arm}) // 0) == refaddr($arm);
                delete $expected->{arm};
                delete $expected->{timer};
                Mediabot::Helpers::_drain_flood_queue($self, $to);
            },
        );
        if (_flood_queue_current($self, $to, $q)
                && (refaddr($q->{arm}) // 0) == refaddr($arm)) {
            $q->{timer} = $timer;
        } elsif ($timer) {
            # Inline expiry may already own a successor; connection replacement
            # may have retired this arm before its handle was returned.
            _report_retirement_failure($self)
                unless Mediabot::IRC::Timer::cancel_countdown($timer);
        }
        1;
    };
    unless ($started) {
        my $error = $@;
        if ((refaddr($q->{arm}) // 0) == refaddr($arm)) {
            delete $q->{arm};
            delete $q->{timer};
            $q->{armed} = 0;
        }
        die $error;
    }
    return 1;
}

sub _drain_flood_queue {
    my ($self, $to) = @_;
    my $q = $self->{_flood_outq}{$to} or return;
    delete $q->{arm};
    my $timer = delete $q->{timer};
    if ($timer) {
        _report_retirement_failure($self)
            unless Mediabot::IRC::Timer::cancel_countdown($timer);
        return unless _flood_queue_current($self, $to, $q);
    }
    $q->{armed} = 0;

    _expire_flood_output($self, $to, $q, _flood_queue_now());
    my $item = shift @{ $q->{items} };
    my $sent = eval {
        if ($item) {
            my ($kind, $msg, $send_options) = @$item;
            local $self->{_flood_draining} = $q;
            local $self->{_flood_response} = $item->[3];
            if ($kind eq 'action') { botAction($self, $to, $msg, $send_options) }
            else                   { botPrivmsg($self, $to, $msg, $send_options) }
        }
        1;
    };
    my $send_error = $@;
    # A send exception must not strand the rest of the queue. Do not retry the
    # attempted item: the transport may have sent it before raising the error.
    my $rearmed = eval {
        Mediabot::Helpers::_arm_flood_drain($self, $to)
            if @{ $q->{items} } && _flood_queue_current($self, $to, $q);
        1;
    };
    my $arm_error = $@;
    die $send_error unless $sent;
    die $arm_error unless $rearmed;
    return 1;
}

1;
