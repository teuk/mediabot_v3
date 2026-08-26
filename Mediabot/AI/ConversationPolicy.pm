package Mediabot::AI::ConversationPolicy;

use strict;
use warnings;

use Exporter 'import';
use Scalar::Util qw(looks_like_number);

use Mediabot::AI qw(normalize_provider);

our $VERSION = '1.0';
our @EXPORT_OK = qw(
    policy_defaults
    evaluate_candidate
    decision_summary
);

my %DEFAULT = (
    min_interval_seconds => 90,
    max_message_chars    => 800,
);

sub policy_defaults {
    return { %DEFAULT };
}

sub _plain_scalar {
    my ($value) = @_;
    return defined($value) && !ref($value);
}

sub _bool {
    my ($value) = @_;
    return 0 unless defined $value;
    return 0 if ref($value);
    return $value ? 1 : 0;
}

sub _bounded_int {
    my ($value, $default, $min, $max) = @_;
    return $default unless _plain_scalar($value) && "$value" =~ /^\d+\z/;

    my $n = int($value);
    return $default if $n < $min || $n > $max;
    return $n;
}

sub _time_value {
    my ($value) = @_;
    return undef unless _plain_scalar($value) && looks_like_number($value);
    return undef if $value < 0;
    return 0 + $value;
}

sub _language {
    my ($raw) = @_;
    return 'en' unless _plain_scalar($raw);

    my $lang = lc "$raw";
    $lang =~ s/^\s+|\s+$//g;
    return $lang if $lang eq 'en' || $lang eq 'fr' || $lang eq 'es';
    return 'en';
}

sub _decision {
    my (%args) = @_;

    my %out = (
        action   => $args{action},
        reason   => $args{reason},
        language => $args{language},
        provider => $args{provider},
    );

    $out{retry_after_seconds} = int($args{retry_after_seconds})
        if defined $args{retry_after_seconds};

    return \%out;
}

sub evaluate_candidate {
    my (%args) = @_;

    my $language = _language($args{language});
    my $provider = normalize_provider(
        exists($args{provider}) ? $args{provider} : 'auto'
    );

    return _decision(
        action   => 'no_reply',
        reason   => 'invalid_provider',
        language => $language,
        provider => undef,
    ) unless defined $provider;

    return _decision(
        action   => 'no_reply',
        reason   => 'disabled',
        language => $language,
        provider => $provider,
    ) unless _bool($args{enabled});

    my $channel = $args{channel};
    return _decision(
        action   => 'no_reply',
        reason   => 'private',
        language => $language,
        provider => $provider,
    ) unless _plain_scalar($channel) && "$channel" =~ /^#/;

    return _decision(
        action   => 'no_reply',
        reason   => 'self',
        language => $language,
        provider => $provider,
    ) if _bool($args{from_self});

    return _decision(
        action   => 'no_reply',
        reason   => 'bot',
        language => $language,
        provider => $provider,
    ) if _bool($args{from_bot});

    return _decision(
        action   => 'no_reply',
        reason   => 'command',
        language => $language,
        provider => $provider,
    ) if _bool($args{is_command});

    my $message = $args{message};
    return _decision(
        action   => 'no_reply',
        reason   => 'empty',
        language => $language,
        provider => $provider,
    ) unless _plain_scalar($message);

    $message = "$message";
    my $visible = $message;
    $visible =~ s/^\s+|\s+$//g;

    return _decision(
        action   => 'no_reply',
        reason   => 'empty',
        language => $language,
        provider => $provider,
    ) unless length $visible;

    my $max_chars = _bounded_int(
        $args{max_message_chars},
        $DEFAULT{max_message_chars},
        32,
        10_000,
    );

    return _decision(
        action   => 'no_reply',
        reason   => 'too_long',
        language => $language,
        provider => $provider,
    ) if length($message) > $max_chars;

    my $min_interval = _bounded_int(
        $args{min_interval_seconds},
        $DEFAULT{min_interval_seconds},
        0,
        3600,
    );

    if ($min_interval > 0) {
        my $now  = _time_value($args{now});
        my $last = _time_value($args{last_reply_at});

        if (defined($now) && defined($last) && $now >= $last) {
            my $elapsed = $now - $last;
            if ($elapsed < $min_interval) {
                my $retry = int($min_interval - $elapsed);
                $retry = 1 if $retry < 1;

                return _decision(
                    action              => 'no_reply',
                    reason              => 'cooldown',
                    language            => $language,
                    provider            => $provider,
                    retry_after_seconds => $retry,
                );
            }
        }
    }

    return _decision(
        action   => 'consider',
        reason   => 'eligible',
        language => $language,
        provider => $provider,
    );
}

sub decision_summary {
    my ($decision) = @_;
    return undef unless ref($decision) eq 'HASH';

    my $action = $decision->{action};
    my $reason = $decision->{reason};
    return undef unless _plain_scalar($action) && _plain_scalar($reason);
    return undef unless $action eq 'consider' || $action eq 'no_reply';

    my %summary = (
        action   => "$action",
        reason   => "$reason",
        language => _language($decision->{language}),
        provider => normalize_provider($decision->{provider}),
    );

    $summary{retry_after_seconds} = int($decision->{retry_after_seconds})
        if _plain_scalar($decision->{retry_after_seconds})
            && "$decision->{retry_after_seconds}" =~ /^\d+\z/;

    return \%summary;
}

1;
