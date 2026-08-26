package Mediabot::AI::ConversationDecision;

use strict;
use warnings;

use Exporter 'import';

our $VERSION = '1.0';
our @EXPORT_OK = qw(
    decision_defaults
    decision_contract
    parse_model_decision
    decision_summary
);

my %DEFAULT = (
    max_reply_chars => 280,
    max_raw_chars   => 4096,
);

sub decision_defaults {
    return { %DEFAULT };
}

sub decision_contract {
    return join "\n",
        'Return exactly one decision.',
        'If no reply should be sent: NO_REPLY',
        'If a reply should be sent: REPLY: <single-line reply>',
        'Do not use Markdown, JSON, code fences, labels or extra lines.';
}

sub _plain_scalar {
    my ($value) = @_;
    return defined($value) && !ref($value);
}

sub _bounded_int {
    my ($value, $default, $min, $max) = @_;
    return $default unless _plain_scalar($value) && "$value" =~ /^\d+\z/;

    my $n = int($value);
    return $default if $n < $min || $n > $max;
    return $n;
}

sub _no_reply {
    my ($reason) = @_;
    return {
        action => 'no_reply',
        reason => $reason,
    };
}

sub _strip_irc_formatting {
    my ($text) = @_;

    # Standard IRC formatting controls: bold/reset/reverse/italic/underline.
    $text =~ s/[\x02\x0f\x16\x1d\x1f]//g;
    # mIRC colour sequences, including optional background colour.
    $text =~ s/\x03\d{0,2}(?:,\d{1,2})?//g;
    # Any remaining C0/DEL control byte is not valid reply content.
    $text =~ s/[\x00-\x1f\x7f]//g;

    return $text;
}

sub _normalise_reply_text {
    my ($text) = @_;
    return undef unless _plain_scalar($text);

    $text = _strip_irc_formatting("$text");
    $text =~ s/^\s+|\s+$//g;
    $text =~ s/[ \t]+/ /g;

    return length($text) ? $text : undef;
}

sub parse_model_decision {
    my ($raw, %opts) = @_;

    return _no_reply('invalid_output') unless _plain_scalar($raw);

    my $max_raw = _bounded_int(
        $opts{max_raw_chars},
        $DEFAULT{max_raw_chars},
        64,
        16_384,
    );
    return _no_reply('invalid_output') if length("$raw") > $max_raw;

    my $wire = "$raw";
    $wire =~ s/^\s+|\s+$//g;

    return _no_reply('model_no_reply') if $wire eq 'NO_REPLY';

    # REPLY is deliberately one physical line. Newlines, Markdown wrappers,
    # JSON or any other response shape fail closed rather than being guessed.
    return _no_reply('invalid_output')
        unless $wire =~ /\AREPLY:[ \t]+([^\r\n]+)\z/;

    my $text = _normalise_reply_text($1);
    return _no_reply('invalid_output') unless defined $text;

    my $max_reply = _bounded_int(
        $opts{max_reply_chars},
        $DEFAULT{max_reply_chars},
        32,
        1000,
    );
    return _no_reply('reply_too_long') if length($text) > $max_reply;

    return {
        action => 'reply',
        reason => 'model_reply',
        text   => $text,
    };
}

sub decision_summary {
    my ($decision) = @_;
    return undef unless ref($decision) eq 'HASH';

    my $action = $decision->{action};
    my $reason = $decision->{reason};
    return undef unless _plain_scalar($action) && _plain_scalar($reason);
    return undef unless $action eq 'no_reply' || $action eq 'reply';

    my %out = (
        action => "$action",
        reason => "$reason",
    );

    if ($action eq 'reply') {
        my $text = _normalise_reply_text($decision->{text});
        return undef unless defined $text;
        return undef if length($text) > $DEFAULT{max_reply_chars};
        $out{text} = $text;
    }

    return \%out;
}

1;
