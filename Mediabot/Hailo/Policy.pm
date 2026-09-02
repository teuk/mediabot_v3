package Mediabot::Hailo::Policy;

use strict;
use warnings;
use utf8;

use Carp qw(croak);

our $VERSION = '1.0';

sub _plain {
    my ($value) = @_;
    return defined($value) && !ref($value);
}

sub _bounded_int {
    my ($value, $default, $min, $max) = @_;
    return $default unless _plain($value) && "$value" =~ /^\d+\z/;
    my $number = int($value);
    return $min if $number < $min;
    return $max if $number > $max;
    return $number;
}

sub _key {
    my ($value) = @_;
    return undef unless _plain($value) && length("$value");
    return lc "$value";
}

sub new {
    my ($class, %args) = @_;
    my $now_cb = ref($args{now_cb}) eq 'CODE' ? $args{now_cb} : sub { time() };
    my $rng_cb = ref($args{rng_cb}) eq 'CODE' ? $args{rng_cb} : sub { rand(100) };

    return bless {
        now_cb         => $now_cb,
        rng_cb         => $rng_cb,
        learn_interval => _bounded_int($args{learn_interval}, 5, 0, 3600),
        reply_interval => _bounded_int($args{reply_interval}, 5, 0, 3600),
        flood_max      => _bounded_int($args{flood_max}, 4, 1, 100),
        flood_window   => _bounded_int($args{flood_window}, 30, 1, 3600),
        min_words      => _bounded_int($args{min_words}, 3, 1, 100),
        max_words      => _bounded_int($args{max_words}, 20, 0, 500),
        key_reply_rate => _bounded_int($args{key_reply_rate}, 95, 0, 100),
        max_channels   => _bounded_int($args{max_channels}, 256, 1, 4096),
        max_users      => _bounded_int($args{max_users_per_channel}, 512, 1, 4096),
        channel_states => {},
    }, $class;
}

sub _now {
    my ($self) = @_;
    my $now = eval { $self->{now_cb}->() };
    return time() unless _plain($now) && "$now" =~ /^-?(?:\d+(?:[.]\d*)?|[.]\d+)\z/;
    return 0 + $now;
}

sub _roll {
    my ($self) = @_;
    my $roll = eval { $self->{rng_cb}->() };
    return 99 unless _plain($roll) && "$roll" =~ /^-?(?:\d+(?:[.]\d*)?|[.]\d+)\z/;
    $roll = 0 + $roll;
    $roll = 0 if $roll < 0;
    $roll = 99.999 if $roll >= 100;
    return $roll;
}

sub _channel_state {
    my ($self, $channel) = @_;
    my $key = _key($channel);
    return undef unless defined $key;

    if (!exists $self->{channel_states}{$key}) {
        if (keys(%{ $self->{channel_states} }) >= $self->{max_channels}) {
            my ($oldest) = sort {
                ($self->{channel_states}{$a}{touched} // 0)
                    <=> ($self->{channel_states}{$b}{touched} // 0)
            } keys %{ $self->{channel_states} };
            delete $self->{channel_states}{$oldest} if defined $oldest;
        }
        $self->{channel_states}{$key} = {
            touched => $self->_now,
            users   => {},
            replies => [],
        };
    }
    my $state = $self->{channel_states}{$key};
    $state->{touched} = $self->_now;
    return $state;
}

sub _user_state {
    my ($self, $channel_state, $speaker) = @_;
    my $key = _key($speaker);
    return undef unless $channel_state && defined $key;

    if (!exists $channel_state->{users}{$key}) {
        if (keys(%{ $channel_state->{users} }) >= $self->{max_users}) {
            my ($oldest) = sort {
                ($channel_state->{users}{$a}{touched} // 0)
                    <=> ($channel_state->{users}{$b}{touched} // 0)
            } keys %{ $channel_state->{users} };
            delete $channel_state->{users}{$oldest} if defined $oldest;
        }
        $channel_state->{users}{$key} = {
            touched    => $self->_now,
            last_learn => undef,
            last_reply => undef,
        };
    }
    my $state = $channel_state->{users}{$key};
    $state->{touched} = $self->_now;
    return $state;
}

sub _word_count {
    my ($text) = @_;
    return 0 unless _plain($text);
    my @words = "$text" =~ /[\p{L}\p{N}]+(?:['’][\p{L}\p{N}]+)?/gu;
    return scalar @words;
}

sub _force_mode {
    my ($text, $authorized) = @_;
    return ('normal', $text) unless $authorized && _plain($text) && length($text);
    my $prefix = substr($text, 0, 1);
    my %mode = (
        '&' => 'learn_reply',
        '%' => 'reply_only',
        '~' => 'learn_only',
        '$' => 'neither',
    );
    return ('normal', $text) unless exists $mode{$prefix};
    my $stripped = substr($text, 1);
    $stripped =~ s/^\s+//;
    return ($mode{$prefix}, $stripped);
}

sub _prune_replies {
    my ($self, $state) = @_;
    return unless $state;
    my $cutoff = $self->_now - $self->{flood_window};
    $state->{replies} = [ grep { defined($_) && $_ > $cutoff }
        @{ $state->{replies} || [] } ];
}

sub decide {
    my ($self, %args) = @_;
    croak 'policy object is required' unless ref($self);

    my $channel_state = $self->_channel_state($args{channel});
    my $user_state = $self->_user_state($channel_state, $args{speaker});
    return { reply => 0, learn => 0, reason => 'invalid_identity' }
        unless $channel_state && $user_state;

    my ($force, $text) = _force_mode($args{text}, $args{force_authorized});
    return { reply => 0, learn => 0, reason => 'empty_text', force => $force }
        unless _plain($text) && length($text);

    return {
        reply => 0, learn => 0, reason => 'master_disabled',
        force => $force, text => $text,
    } unless $args{master_enabled};

    return {
        reply => 0, learn => 0, reason => 'excluded',
        force => $force, text => $text,
    } if $args{excluded};

    my $forced_learn = $force eq 'learn_reply' || $force eq 'learn_only';
    my $forced_reply = $force eq 'learn_reply' || $force eq 'reply_only';
    my $forced_none  = $force eq 'neither';

    my $words = _word_count($text);
    my $length_ok = $words >= $self->{min_words}
        && (!$self->{max_words} || $words <= $self->{max_words});
    my $now = $self->_now;

    my $learn = 0;
    my $learn_reason = 'learn_disabled';
    if ($forced_none || $force eq 'reply_only') {
        $learn_reason = 'force_no_learn';
    }
    elsif ($args{is_command} && !$forced_learn) {
        $learn_reason = 'command';
    }
    elsif (!$length_ok && !$forced_learn) {
        $learn_reason = 'word_count';
    }
    elsif (!$args{learn_enabled} && !$forced_learn) {
        $learn_reason = 'learn_disabled';
    }
    elsif (defined($user_state->{last_learn})
        && ($now - $user_state->{last_learn}) < $self->{learn_interval}
        && !$forced_learn) {
        $learn_reason = 'learn_cooldown';
    }
    else {
        $learn = 1;
        $learn_reason = $forced_learn ? 'forced' : 'allowed';
    }

    my $mode = _plain($args{mode}) ? lc "$args{mode}" : 'ambient';
    my $reply_requested = $forced_reply
        || ($mode eq 'mention' && $args{respond_enabled})
        || ($mode eq 'chatter' && $args{chatter_enabled});
    my $reply = 0;
    my $reply_reason = 'not_requested';

    $self->_prune_replies($channel_state);
    if ($forced_none || $force eq 'learn_only') {
        $reply_reason = 'force_no_reply';
    }
    elsif ($args{is_command} && !$forced_reply) {
        $reply_reason = 'command';
    }
    elsif (!$reply_requested) {
        $reply_reason = $mode eq 'mention' ? 'respond_disabled'
            : $mode eq 'chatter' ? 'chatter_disabled' : 'not_requested';
    }
    elsif (defined($user_state->{last_reply})
        && ($now - $user_state->{last_reply}) < $self->{reply_interval}
        && !$forced_reply) {
        $reply_reason = 'reply_cooldown';
    }
    elsif (@{ $channel_state->{replies} } >= $self->{flood_max}
        && !$forced_reply) {
        $reply_reason = 'channel_flood';
    }
    elsif ($mode eq 'mention' && !$forced_reply
        && $self->_roll >= $self->{key_reply_rate}) {
        $reply_reason = 'key_reply_rate';
    }
    else {
        $reply = 1;
        $reply_reason = $forced_reply ? 'forced' : 'allowed';
    }

    return {
        reply       => $reply,
        learn       => $learn,
        text        => $text,
        force       => $force,
        words       => $words,
        reply_reason => $reply_reason,
        learn_reason => $learn_reason,
    };
}

sub record_learn {
    my ($self, %args) = @_;
    my $channel_state = $self->_channel_state($args{channel});
    my $user_state = $self->_user_state($channel_state, $args{speaker});
    return 0 unless $user_state;
    $user_state->{last_learn} = $self->_now;
    return 1;
}

sub record_reply {
    my ($self, %args) = @_;
    my $channel_state = $self->_channel_state($args{channel});
    my $user_state = $self->_user_state($channel_state, $args{speaker});
    return 0 unless $channel_state && $user_state;
    my $now = $self->_now;
    $user_state->{last_reply} = $now;
    push @{ $channel_state->{replies} }, $now;
    $self->_prune_replies($channel_state);
    return 1;
}

sub stats {
    my ($self) = @_;
    croak 'policy object is required' unless ref($self);
    my $users = 0;
    $users += scalar keys %{ $_->{users} || {} }
        for values %{ $self->{channel_states} };
    return {
        channels => scalar(keys %{ $self->{channel_states} }),
        users    => $users,
    };
}

1;
