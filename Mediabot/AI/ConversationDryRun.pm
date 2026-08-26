package Mediabot::AI::ConversationDryRun;

use strict;
use warnings;

use Carp qw(croak);
use Exporter 'import';

use Mediabot::AI::ConversationExecutor qw(execution_summary);
use Mediabot::AI::ConversationObserver qw(observe_public_line);

our $VERSION = '1.0';
our @EXPORT_OK = qw(format_ai_dryrun_log);

sub _plain_scalar {
    my ($value) = @_;
    return defined($value) && !ref($value);
}

sub _safe_short {
    my ($value, $max) = @_;
    return undef unless _plain_scalar($value);

    my $text = "$value";
    $text =~ s/^\s+|\s+$//g;
    return undef unless length($text) && length($text) <= $max;
    return undef if $text =~ /[\x00-\x1f\x7f]/;
    return $text;
}

sub new {
    my ($class, %args) = @_;

    my $executor = $args{executor};
    if (defined $executor) {
        croak 'executor must provide submit_dryrun()'
            unless ref($executor) && eval { $executor->can('submit_dryrun') };
    }
    else {
        my $conf = $args{conf};
        croak 'conf is required when executor is not injected'
            unless $conf && ref($conf) && eval { $conf->can('get') };

        $executor = Mediabot::AI::ConversationExecutor->new(
            conf       => $conf,
            loop_owner => $args{loop_owner},
        );
    }

    my $clock = $args{clock};
    croak 'clock must be a code reference'
        if defined($clock) && ref($clock) ne 'CODE';

    return bless {
        executor       => $executor,
        clock          => $clock || sub { time() },
        inflight       => {},
        last_submit_at => {},
    }, $class;
}

sub _runtime_no_reply {
    my ($reason, %extra) = @_;
    my %out = (
        ok     => 1,
        action => 'no_reply',
        reason => $reason,
    );
    $out{$_} = $extra{$_} for keys %extra;
    return \%out;
}

sub handle_public_line {
    my ($self, %args) = @_;
    croak 'dry-run object is required' unless ref($self);

    my $on_observation = delete $args{on_observation};
    my $on_candidate   = delete $args{on_candidate};
    my $on_result      = delete $args{on_result};
    croak 'on_observation must be a code reference'
        if defined($on_observation) && ref($on_observation) ne 'CODE';
    croak 'on_candidate must be a code reference'
        if defined($on_candidate) && ref($on_candidate) ne 'CODE';
    croak 'on_result must be a code reference'
        unless ref($on_result) eq 'CODE';

    my $channel = $args{channel};
    croak 'channel must be a public IRC channel'
        unless _plain_scalar($channel) && "$channel" =~ /^#/;

    my $channel_key = lc "$channel";
    my $now = $self->{clock}->();

    if ($self->{inflight}{$channel_key}) {
        my $language = _plain_scalar($args{language}) ? lc("$args{language}") : 'en';
        $language = 'en' unless $language eq 'en' || $language eq 'fr' || $language eq 'es';
        my $summary = _runtime_no_reply(
            'inflight',
            language => $language,
            provider => 'auto',
        );
        $on_observation->($summary) if $on_observation;
        return 0;
    }

    my $observation = observe_public_line(
        %args,
        now           => $now,
        last_reply_at => $self->{last_submit_at}{$channel_key},
    );

    $on_observation->($observation) if $on_observation;
    return 0 unless ref($observation) eq 'HASH'
        && ($observation->{action} // '') eq 'consider';

    $self->{inflight}{$channel_key} = 1;

    my $completed = 0;
    my $finish = sub {
        my ($result) = @_;
        return if $completed++;

        delete $self->{inflight}{$channel_key};

        # MB701-C: the normalized reply text may cross exactly one private
        # in-memory boundary into the late emission gate. Public/result logging
        # still receives execution_summary(), which never contains that text.
        if ($on_candidate
            && ref($result) eq 'HASH'
            && ($result->{action} // '') eq 'reply'
            && _plain_scalar($result->{text})) {
            my $candidate_ok = eval {
                $on_candidate->($result);
                1;
            };
            unless ($candidate_ok) {
                my %failed = (
                    ok     => 0,
                    action => 'no_reply',
                    reason => 'runtime_guard_error',
                    error  => 'candidate_callback_exception',
                );
                for my $key (qw(provider model provider_fallback model_fallback)) {
                    $failed{$key} = $result->{$key} if exists $result->{$key};
                }
                $on_result->(execution_summary(\%failed));
                return;
            }
        }

        my $summary = execution_summary($result);
        $summary ||= {
            ok     => 0,
            action => 'no_reply',
            reason => 'provider_error',
            error  => 'invalid_executor_result',
        };
        $on_result->($summary);
    };

    my $started;
    my $ok = eval {
        $started = $self->{executor}->submit_dryrun(
            provider => $observation->{provider},
            language => $observation->{language},
            message  => $args{message},
            on_done  => $finish,
        );
        1;
    };

    unless ($ok) {
        delete $self->{inflight}{$channel_key};
        $finish->({
            ok     => 0,
            action => 'no_reply',
            reason => 'provider_error',
            error  => 'executor_exception',
        });
        return 0;
    }

    if ($started) {
        $self->{last_submit_at}{$channel_key} = $now;
        return 1;
    }

    # ConversationExecutor/AI::Client may complete synchronously with an async
    # availability error before returning false. If it did not, fail closed.
    $finish->({
        ok     => 0,
        action => 'no_reply',
        reason => 'provider_error',
        error  => 'async_unavailable',
    }) unless $completed;

    return 0;
}

sub format_ai_dryrun_log {
    my ($channel, $summary) = @_;
    return undef unless _plain_scalar($channel) && "$channel" =~ /^#/;
    return undef unless ref($summary) eq 'HASH';

    my $action = _safe_short($summary->{action}, 32);
    my $reason = _safe_short($summary->{reason}, 64);
    return undef unless defined($action) && defined($reason);
    return undef unless $action eq 'reply' || $action eq 'no_reply';

    my @parts = (
        '[WIT_AI_DRYRUN]',
        'channel=' . $channel,
        'action=' . $action,
        'reason=' . $reason,
    );

    for my $key (qw(provider model error)) {
        my $value = _safe_short($summary->{$key}, 160);
        push @parts, "$key=$value" if defined $value;
    }

    push @parts, 'provider_fallback=' . ($summary->{provider_fallback} ? 1 : 0)
        if exists $summary->{provider_fallback};
    push @parts, 'model_fallback=' . ($summary->{model_fallback} ? 1 : 0)
        if exists $summary->{model_fallback};

    if (defined($summary->{reply_chars}) && !ref($summary->{reply_chars})
        && "$summary->{reply_chars}" =~ /^\d+\z/) {
        push @parts, 'reply_chars=' . int($summary->{reply_chars});
    }

    return join ' ', @parts;
}

1;
