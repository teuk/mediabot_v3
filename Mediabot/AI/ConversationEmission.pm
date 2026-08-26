package Mediabot::AI::ConversationEmission;

use strict;
use warnings;

use Carp qw(croak);
use Encode qw(encode_utf8);
use Exporter 'import';

our $VERSION = '1.0';
our @EXPORT_OK = qw(
    emission_defaults
    evaluate_emission
    emission_summary
    format_emission_dryrun_log
);

my %DEFAULT = (
    max_reply_chars => 280,
    max_reply_bytes => 350,
);

my %ALLOWED_ARG = map { $_ => 1 } qw(
    enabled
    runtime_active
    irc_connected
    channel_joined
    request_generation
    current_generation
    channel
    text
);

sub emission_defaults {
    return { %DEFAULT };
}

sub _plain_scalar {
    my ($value) = @_;
    return defined($value) && !ref($value);
}

sub _positive_generation {
    my ($value) = @_;
    return undef unless _plain_scalar($value) && "$value" =~ /^[1-9]\d{0,14}\z/;
    my $n = int($value);
    return $n;
}

sub _no_emit {
    my ($reason, %extra) = @_;
    return {
        action => 'no_emit',
        reason => $reason,
        %extra,
    };
}

sub _normalise_reply_text {
    my ($raw) = @_;
    return (undef, 'invalid_reply') unless _plain_scalar($raw);

    my $text = "$raw";

    # CR/LF/NUL would change IRC framing. Never repair framing characters here;
    # a reply reaching the final emission gate with one is rejected outright.
    return (undef, 'unsafe_reply') if $text =~ /[\r\n\x00]/;

    # Defence in depth: ConversationDecision already strips ordinary IRC
    # presentation codes, but the emission boundary repeats that sanitation so
    # future callers cannot bypass it accidentally.
    $text =~ s/\x03\d{0,2}(?:,\d{1,2})?//g;
    $text =~ s/[\x02\x0f\x16\x1d\x1f]//g;

    # Reject every remaining C0/DEL control, including CTCP SOH. Wit may emit
    # plain text only and can never manufacture CTCP or another IRC command.
    return (undef, 'unsafe_reply') if $text =~ /[\x00-\x1f\x7f]/;

    $text =~ s/^\s+|\s+$//g;
    $text =~ s/[ \t]+/ /g;
    return (undef, 'empty_reply') unless length($text);

    return ($text, undef);
}

sub evaluate_emission {
    my (%args) = @_;

    for my $key (keys %args) {
        croak "unknown Wit emission field: $key" unless $ALLOWED_ARG{$key};
    }

    # Late authorization is intentionally evaluated before reply content. An
    # administrative opt-out or runtime loss must always win over an AI result
    # that was valid when the provider request was submitted.
    return _no_emit('disabled')
        unless $args{enabled};
    return _no_emit('runtime_inactive')
        unless $args{runtime_active};
    return _no_emit('irc_disconnected')
        unless $args{irc_connected};
    return _no_emit('not_joined')
        unless $args{channel_joined};

    my $request_generation = _positive_generation($args{request_generation});
    my $current_generation = _positive_generation($args{current_generation});
    return _no_emit('stale_generation')
        unless defined($request_generation)
            && defined($current_generation)
            && $request_generation == $current_generation;

    my $channel = $args{channel};
    return _no_emit('invalid_channel')
        unless _plain_scalar($channel)
            && "$channel" =~ /^#[^\s,:\x00-\x1f\x7f]{1,79}\z/;

    my ($text, $text_error) = _normalise_reply_text($args{text});
    return _no_emit($text_error) unless defined $text;

    my $reply_chars = length($text);
    return _no_emit('reply_too_long', reply_chars => $reply_chars)
        if $reply_chars > $DEFAULT{max_reply_chars};

    my $reply_bytes = length(encode_utf8($text));
    return _no_emit(
        'reply_too_large',
        reply_chars => $reply_chars,
        reply_bytes => $reply_bytes,
    ) if $reply_bytes > $DEFAULT{max_reply_bytes};

    return {
        action             => 'emit',
        reason             => 'authorized',
        text               => $text,
        reply_chars        => $reply_chars,
        reply_bytes        => $reply_bytes,
        request_generation => $request_generation,
    };
}

sub emission_summary {
    my ($decision) = @_;
    return undef unless ref($decision) eq 'HASH';

    my $action = $decision->{action};
    my $reason = $decision->{reason};
    return undef unless _plain_scalar($action) && _plain_scalar($reason);
    return undef unless $action eq 'emit' || $action eq 'no_emit';

    my %out = (
        action => "$action",
        reason => "$reason",
    );

    for my $key (qw(reply_chars reply_bytes request_generation)) {
        next unless _plain_scalar($decision->{$key});
        next unless "$decision->{$key}" =~ /^\d+\z/;
        $out{$key} = int($decision->{$key});
    }

    return \%out;
}


sub _safe_log_scalar {
    my ($value, $max) = @_;
    return undef unless _plain_scalar($value);

    my $text = "$value";
    $text =~ s/^\s+|\s+$//g;
    return undef unless length($text) && length($text) <= $max;
    return undef if $text =~ /[\x00-\x1f\x7f]/;
    return $text;
}

sub format_emission_dryrun_log {
    my ($channel, $summary) = @_;
    return undef unless _plain_scalar($channel)
        && "$channel" =~ /^#[^\s,:\x00-\x1f\x7f]{1,79}\z/;
    return undef unless ref($summary) eq 'HASH';

    my $action = _safe_log_scalar($summary->{action}, 32);
    my $reason = _safe_log_scalar($summary->{reason}, 64);
    return undef unless defined($action) && defined($reason);
    return undef unless $action eq 'emit' || $action eq 'no_emit';

    my @parts = (
        '[WIT_EMIT_DRYRUN]',
        'channel=' . $channel,
        'action=' . $action,
        'reason=' . $reason,
    );

    for my $key (qw(reply_chars reply_bytes request_generation)) {
        next unless _plain_scalar($summary->{$key});
        next unless "$summary->{$key}" =~ /^\d+\z/;
        push @parts, "$key=" . int($summary->{$key});
    }

    return join ' ', @parts;
}

1;
