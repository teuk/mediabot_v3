package Mediabot::ScriptActionRunner;

use strict;
use warnings;
use utf8;

# ---------------------------------------------------------------------------
# Mediabot::ScriptActionRunner
# ---------------------------------------------------------------------------
# mb177-B1: safe action applier foundation for ScriptRunner results.
#
# This module deliberately performs dry-run planning only. It validates actions
# returned by external scripts and converts them into a structured plan. It does
# not send IRC messages, create timers, touch DB, or mutate runtime state yet.
# ---------------------------------------------------------------------------

sub new {
    my ($class, %args) = @_;

    my $max_text_length = defined $args{max_text_length} ? int($args{max_text_length}) : 400;
    $max_text_length = 32   if $max_text_length < 32;
    $max_text_length = 2000 if $max_text_length > 2000;

    return bless {
        bot             => $args{bot},
        max_text_length => $max_text_length,
        allowed_actions => {
            reply  => 1,
            notice => 1,
            log    => 1,
            timer  => 1,
        },
    }, $class;
}

sub bot {
    my ($self) = @_;
    return $self->{bot};
}

sub max_text_length {
    my ($self) = @_;
    return $self->{max_text_length};
}

sub allowed_action_types {
    my ($self) = @_;
    return sort keys %{ $self->{allowed_actions} };
}

sub _trim {
    my ($value) = @_;
    return '' unless defined $value;
    my $v = "$value";
    $v =~ s/^\s+|\s+$//g;
    return $v;
}

sub _context_default_target {
    my ($self, $context) = @_;

    return undef unless $context;

    if (ref($context) eq 'HASH') {
        return $context->{channel} if defined $context->{channel} && length $context->{channel};
        return $context->{target}  if defined $context->{target}  && length $context->{target};
    }

    for my $method (qw(channel target reply_target)) {
        next unless eval { $context->can($method) };
        my $value = eval { $context->$method() };
        return $value if defined $value && length "$value";
    }

    return undef;
}

sub _bounded_text {
    my ($self, $text) = @_;

    my $value = _trim($text);
    return (0, 'missing text') unless length $value;

    if (length($value) > $self->{max_text_length}) {
        return (0, 'text too long');
    }

    return (1, undef, $value);
}

sub validate_action {
    my ($self, $action, $context) = @_;

    return (0, 'action must be an object') unless ref($action) eq 'HASH';

    my $type = lc _trim($action->{type});
    return (0, 'missing action type') unless length $type;
    return (0, "unsupported action type '$type'") unless $self->{allowed_actions}{$type};

    if ($type eq 'reply' || $type eq 'notice') {
        my ($text_ok, $text_err, $text) = $self->_bounded_text($action->{text});
        return (0, $text_err) unless $text_ok;

        my $target = _trim($action->{target});
        $target = _trim($self->_context_default_target($context)) unless length $target;
        return (0, 'missing target') unless length $target;

        return (1, undef, {
            type   => $type,
            target => $target,
            text   => $text,
        });
    }

    if ($type eq 'log') {
        my ($text_ok, $text_err, $text) = $self->_bounded_text($action->{text});
        return (0, $text_err) unless $text_ok;

        my $level = lc _trim($action->{level} || 'info');
        $level = 'info' unless $level =~ /\A(?:debug|info|warn|error)\z/;

        return (1, undef, {
            type  => 'log',
            level => $level,
            text  => $text,
        });
    }

    if ($type eq 'timer') {
        my $name  = _trim($action->{name});
        my $delay = defined $action->{delay} ? int($action->{delay}) : 0;

        return (0, 'missing timer name') unless length $name;
        return (0, 'invalid timer delay') unless $delay >= 1 && $delay <= 3600;

        return (1, undef, {
            type  => 'timer',
            name  => $name,
            delay => $delay,
        });
    }

    return (0, "unsupported action type '$type'");
}

sub plan_actions {
    my ($self, $actions, $context) = @_;

    $actions ||= [];
    return {
        ok      => 0,
        planned => [],
        errors  => [ 'actions must be an array' ],
    } unless ref($actions) eq 'ARRAY';

    my @planned;
    my @errors;

    for my $idx (0 .. $#$actions) {
        my ($ok, $err, $planned) = $self->validate_action($actions->[$idx], $context);
        if ($ok) {
            push @planned, $planned;
        }
        else {
            push @errors, {
                index => $idx,
                error => $err,
            };
        }
    }

    return {
        ok      => @errors ? 0 : 1,
        planned => \@planned,
        errors  => \@errors,
    };
}

sub _bot_logger {
    my ($self) = @_;

    my $bot = $self->{bot};
    return undef unless $bot;

    # mb187-F1: Mediabot is a blessed hash, not a plain HASH ref.  Accessing
    # $bot->{logger} inside eval keeps fake HASH bots and real Mediabot objects
    # working without requiring a logger() accessor.
    my $hash_logger = eval { $bot->{logger} };
    return $hash_logger if $hash_logger;

    my $logger = eval { $bot->can('logger') ? $bot->logger : undef };
    return $logger if $logger;

    return undef;
}

sub _log_action {
    my ($self, $action) = @_;

    my $logger = $self->_bot_logger;
    my $level  = $action->{level} || 'info';
    my $text   = $action->{text}  || '';

    if ($logger) {
        if (eval { $logger->can($level) }) {
            eval { $logger->$level($text); 1 };
            return !$@;
        }

        if (eval { $logger->can('log') }) {
            eval { $logger->log($level, $text); 1 };
            return !$@;
        }
    }

    return 1;
}

sub _send_irc_action {
    my ($self, $action) = @_;

    my $bot = $self->{bot};
    return (0, 'bot is not available') unless $bot;

    my $irc = ref($bot) eq 'HASH' ? $bot->{irc} : eval { $bot->{irc} };
    return (0, 'irc object is not available') unless $irc && eval { $irc->can('send_message') };

    my $command = $action->{type} eq 'notice' ? 'NOTICE' : 'PRIVMSG';

    my $ok = eval {
        $irc->send_message($command, undef, $action->{target}, $action->{text});
        1;
    };

    return (1, undef) if $ok;
    my $err = $@ || 'send_message failed';
    $err =~ s/[\r\n]+/ /g;
    return (0, $err);
}

sub apply_actions {
    my ($self, $script_result, $context, %opts) = @_;

    my $apply     = $opts{apply}     ? 1 : 0;
    my $allow_irc = $opts{allow_irc} ? 1 : 0;

    my $plan = $self->apply_actions_dry($script_result, $context);

    # mb186-B1: real action application is behind an explicit gate.
    # Default remains dry-run. IRC output requires apply => 1 AND allow_irc => 1.
    # This method is not wired to ScriptDryRun automatically.
    return $plan unless $apply;

    my @applied;
    my @apply_errors;

    if (!$plan->{ok}) {
        $plan->{applied}      = [];
        $plan->{apply_errors} = [ { error => 'action plan is invalid' } ];
        $plan->{applied_ok}   = 0;
        return $plan;
    }

    for my $idx (0 .. $#{ $plan->{planned} || [] }) {
        my $action = $plan->{planned}[$idx];

        if ($action->{type} eq 'log') {
            if ($self->_log_action($action)) {
                push @applied, { index => $idx, type => 'log' };
            }
            else {
                push @apply_errors, { index => $idx, type => 'log', error => 'log action failed' };
            }
            next;
        }

        if ($action->{type} eq 'reply' || $action->{type} eq 'notice') {
            unless ($allow_irc) {
                push @apply_errors, {
                    index => $idx,
                    type  => $action->{type},
                    error => 'irc actions require allow_irc',
                };
                next;
            }

            my ($ok, $err) = $self->_send_irc_action($action);
            if ($ok) {
                push @applied, {
                    index  => $idx,
                    type   => $action->{type},
                    target => $action->{target},
                };
            }
            else {
                push @apply_errors, {
                    index => $idx,
                    type  => $action->{type},
                    error => $err,
                };
            }
            next;
        }

        if ($action->{type} eq 'timer') {
            push @apply_errors, {
                index => $idx,
                type  => 'timer',
                error => 'timer actions are not implemented yet',
            };
            next;
        }

        push @apply_errors, {
            index => $idx,
            type  => $action->{type} || '?',
            error => 'unsupported planned action',
        };
    }

    $plan->{dry_run}      = 0;
    $plan->{applied}      = \@applied;
    $plan->{apply_errors} = \@apply_errors;
    $plan->{applied_ok}   = @apply_errors ? 0 : 1;

    return $plan;
}


sub _failed_script_result_errors {
    my ($script_result) = @_;

    my @raw_errors;

    if (ref($script_result) ne 'HASH') {
        push @raw_errors, 'script result is not an object';
    }
    else {
        push @raw_errors, $script_result->{error}
            if defined $script_result->{error} && length "$script_result->{error}";

        push @raw_errors, 'script timed out'
            if $script_result->{timeout};

        my $response = ref($script_result->{response}) eq 'HASH'
            ? $script_result->{response}
            : undef;

        if ($response && ref($response->{errors}) eq 'ARRAY') {
            push @raw_errors, @{ $response->{errors} };
        }
    }

    push @raw_errors, 'script result is not ok' unless @raw_errors;

    my @errors;
    for my $err (@raw_errors) {
        next unless defined $err;
        my $text = "$err";
        $text =~ s/[\r\n]+/ /g;
        $text =~ s/^\s+|\s+$//g;
        next unless length $text;
        push @errors, { error => $text };
    }

    return @errors ? \@errors : [ { error => 'script result is not ok' } ];
}

sub _script_result_failed {
    my ($script_result) = @_;

    # mb200-B1: preserve legacy ScriptActionRunner callers that predate
    # ScriptRunner's top-level { ok => 1 } wrapper.  Absence of the top-level
    # ok flag is not a failure by itself when a response/actions payload exists.
    return 1 unless ref($script_result) eq 'HASH';
    return 1 if $script_result->{timeout};
    return 1 if defined $script_result->{error} && length "$script_result->{error}";
    return 1 if exists $script_result->{ok} && !$script_result->{ok};

    my $response = ref($script_result->{response}) eq 'HASH'
        ? $script_result->{response}
        : undef;

    return 1 if $response && exists $response->{ok} && !$response->{ok};

    return 0;
}

sub apply_actions_dry {
    my ($self, $script_result, $context) = @_;

    # mb199-B1: never plan or apply actions when ScriptRunner itself failed.
    # A failed script may have no response, invalid JSON, a timeout, a non-zero
    # exit code, or even a partially decoded action list.  Treat the subprocess
    # failure as authoritative and keep the action layer closed.
    if (_script_result_failed($script_result)) {
        return {
            ok      => 0,
            dry_run => 1,
            planned => [],
            errors  => _failed_script_result_errors($script_result),
        };
    }

    my $response = ref($script_result) eq 'HASH' ? $script_result->{response} : undef;
    my $actions  = ref($response) eq 'HASH' ? $response->{actions} : undef;

    my $plan = $self->plan_actions($actions || [], $context);
    $plan->{dry_run} = 1;

    return $plan;
}

1;
