package Mediabot::AI::ConversationObserver;

use strict;
use warnings;

use Exporter 'import';

use Mediabot::AI::ConversationPolicy qw(evaluate_candidate decision_summary);

our $VERSION = '1.0';
our @EXPORT_OK = qw(
    is_command_like
    observe_public_line
    format_dryrun_log
);

sub _plain_scalar {
    my ($value) = @_;
    return defined($value) && !ref($value);
}

sub _trimmed {
    my ($value) = @_;
    return '' unless _plain_scalar($value);
    my $text = "$value";
    $text =~ s/^\s+|\s+$//g;
    return $text;
}

sub is_command_like {
    my (%args) = @_;

    my $line = _trimmed($args{message});
    return 0 unless length $line;

    my ($first, @rest) = split /\s+/, $line;
    return 0 unless defined $first && length $first;

    my $command_char = _plain_scalar($args{command_char})
        ? "$args{command_char}" : '!';
    return 1 if length($command_char)
        && index($first, $command_char) == 0;

    # Bare ?keyword is Mediabot's quick factoid command form.
    return 1 if !@rest && $first =~ /^\?[A-Za-z0-9_.\-]{1,64}$/;

    my $bot_nick = _trimmed($args{bot_nick});
    if (length $bot_nick) {
        my $first_fold = lc $first;
        my $nick_fold  = lc $bot_nick;
        return 1 if $first_fold eq $nick_fold
                 || $first_fold eq "$nick_fold:"
                 || $first_fold eq "$nick_fold,";

        if ($args{initial_trigger_enabled}) {
            my $initial = substr($nick_fold, 0, 1);
            return 1 if length($initial) && $first_fold eq $initial;
        }
    }

    return 0;
}

sub observe_public_line {
    my (%args) = @_;

    my $nick     = _trimmed($args{nick});
    my $bot_nick = _trimmed($args{bot_nick});
    my $from_self = length($nick) && length($bot_nick)
        && lc($nick) eq lc($bot_nick) ? 1 : 0;

    my $is_command = is_command_like(
        message                 => $args{message},
        command_char            => $args{command_char},
        bot_nick                => $bot_nick,
        initial_trigger_enabled => $args{initial_trigger_enabled},
    );

    my $decision = evaluate_candidate(
        enabled       => $args{enabled} ? 1 : 0,
        channel       => $args{channel},
        message       => $args{message},
        language      => $args{language},
        provider      => 'auto',
        from_self     => $from_self,
        # Reliable peer/bot identity classification belongs to a later Identity
        # round. MB700-C is dry-run only and cannot call a provider or emit IRC.
        from_bot      => $args{from_bot} ? 1 : 0,
        is_command    => $is_command,
        now           => $args{now},
        last_reply_at => $args{last_reply_at},
    );

    return decision_summary($decision);
}

sub format_dryrun_log {
    my ($channel, $summary) = @_;
    return undef unless _plain_scalar($channel) && $channel =~ /^#/;
    return undef unless ref($summary) eq 'HASH';

    my $action   = $summary->{action};
    my $reason   = $summary->{reason};
    my $language = $summary->{language};
    my $provider = $summary->{provider};

    return undef unless _plain_scalar($action) && _plain_scalar($reason);
    return undef unless _plain_scalar($language) && _plain_scalar($provider);

    my $line = sprintf(
        '[WIT_DRYRUN] channel=%s action=%s reason=%s language=%s provider=%s',
        $channel, $action, $reason, $language, $provider,
    );

    if (defined($summary->{retry_after_seconds})
        && !ref($summary->{retry_after_seconds})
        && "$summary->{retry_after_seconds}" =~ /^\d+\z/) {
        $line .= ' retry_after=' . int($summary->{retry_after_seconds});
    }

    return $line;
}

1;
