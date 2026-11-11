package Mediabot::Channel::NicklistTimers;
use strict;
use warnings;
use Scalar::Util qw(refaddr weaken);
use Hash::Util::FieldHash qw(fieldhash);

# Keep the public registry's timer values intact. Metadata does not own timers.
fieldhash my %owned;

sub _revoke {
    my ($timer, $fallback_loop) = @_;
    my $state = delete $owned{$timer};
    if ($state) {
        delete $state->{bot};
        return delete $state->{loop};
    }
    return $fallback_loop;
}

sub _cleanup {
    my ($bot, $name, $timer, $loop) = @_;
    my @errors;
    eval { $loop->remove($timer) if $loop; 1 }
        or push @errors, 'remove: ' . ($@ || 'unknown error');
    eval { $timer->stop if $timer->can('stop'); 1 }
        or push @errors, 'stop: ' . ($@ || 'unknown error');
    if (@errors) {
        $bot->{logger}->log(1, "Failed to stop nicklist timer for $name: " . join('; ', @errors));
        return 0;
    }
    return 1;
}

sub _stop_detached {
    my ($bot) = @_;
    my $timers = $bot->{channel_nicklist_timers} || {};
    $bot->{channel_nicklist_timers} = {};
    # Revoke every callback before any external cleanup can reenter.
    my @jobs = map { [$_, $timers->{$_}, _revoke($timers->{$_}, $bot->{loop})] }
        grep { $timers->{$_} } keys %$timers;
    my $ok = 1;
    for my $job (@jobs) {
        $ok = 0 unless _cleanup($bot, @$job);
    }
    $bot->{logger}->log(1, $ok ? 'Stopped all channel nicklist timers'
        : 'Channel nicklist timers retired; physical cleanup incomplete');
    return $ok;
}

sub stop_all {
    my ($bot) = @_;
    $bot->{_nicklist_setup_token} = {};
    return _stop_detached($bot);
}

sub stop_one {
    my ($bot, $name) = @_;
    return unless defined $name && $name ne '';
    my $timer = delete $bot->{channel_nicklist_timers}{$name};
    return unless $timer;
    my $loop = _revoke($timer, $bot->{loop});
    my $ok = _cleanup($bot, $name, $timer, $loop);
    $bot->{logger}->log(1, "Stopped nicklist timer for $name") if $ok;
    return $ok;
}

sub _current {
    my ($bot, $token) = @_;
    return $bot->{_nicklist_setup_token}
        && refaddr($bot->{_nicklist_setup_token}) == refaddr($token);
}

sub setup {
    my ($bot, $factory) = @_;
    my $conf = $bot->{conf};
    unless ($conf) {
        $bot->{logger}->log(1, 'setup_channel_nicklist_timers() called without config');
        return;
    }
    unless ($bot->{loop}) {
        $bot->{logger}->log(1, 'setup_channel_nicklist_timers() called without IO::Async loop');
        return;
    }
    $factory ||= sub {
        require IO::Async::Timer::Periodic;
        return IO::Async::Timer::Periodic->new(@_);
    };
    my $token = $bot->{_nicklist_setup_token} = {};
    _stop_detached($bot);
    return 1 unless _current($bot, $token);
    my $interval = $conf->get('main.MAIN_CHANNEL_NICKLIST_REFRESH_INTERVAL');
    $interval = 300 unless defined $interval && $interval =~ /^\d+$/ && $interval > 0;
    for my $name (sort keys %{ $bot->{channels} || {} }) {
        last unless _current($bot, $token);
        next unless $bot->{channels}{lc $name};
        next if $bot->{channel_nicklist_timers}{$name};
        my $loop = $bot->{loop};
        my $state = { bot => $bot, loop => $loop };
        weaken($state->{bot});
        weaken($state->{loop});
        my $weak_timer;
        my $timer = eval { $factory->(
            interval => $interval, first_interval => $interval,
            on_tick => sub {
                my $owner = $state->{bot} or return;
                return unless $weak_timer;
                my $current = $owner->{channel_nicklist_timers}{$name};
                return unless $current && refaddr($current) == refaddr($weak_timer);
                $owner->refresh_channel_nicklist($name);
            },
        ) };
        unless ($timer) {
            my $error = $@ || "Periodic timer factory returned no timer\n";
            delete $state->{bot};
            delete $state->{loop};
            die $error;
        }
        $weak_timer = $timer;
        weaken($weak_timer);
        $owned{$timer} = $state;
        unless (_current($bot, $token) && !$bot->{channel_nicklist_timers}{$name}) {
            _cleanup($bot, $name, $timer, _revoke($timer, $loop));
            next;
        }
        $bot->{channel_nicklist_timers}{$name} = $timer;
        my $is_live = sub {
            my $current = $bot->{channel_nicklist_timers}{$name};
            return _current($bot, $token) && $current && refaddr($current) == refaddr($timer);
        };
        my $ok = eval {
            $loop->add($timer);
            $timer->start if $is_live->();
            1;
        };
        my $error = $@;
        unless ($ok && $is_live->()) {
            my $current = $bot->{channel_nicklist_timers}{$name};
            delete $bot->{channel_nicklist_timers}{$name}
                if $current && refaddr($current) == refaddr($timer);
            # A late add/start may have attached a timer after reentrant retirement.
            _cleanup($bot, $name, $timer, _revoke($timer, $loop));
            die $error unless $ok;
            next;
        }
        $bot->{logger}->log(1, "Started nicklist refresh timer for $name (interval=${interval}s)");
    }
    if (_current($bot, $token)) {
        my $count = scalar keys %{ $bot->{channel_nicklist_timers} || {} };
        $bot->{logger}->log(1, "Nicklist timer setup complete ($count timers)");
    }
    return 1;
}

1;
