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

sub apply_actions_dry {
    my ($self, $script_result, $context) = @_;

    my $response = ref($script_result) eq 'HASH' ? $script_result->{response} : undef;
    my $actions  = ref($response) eq 'HASH' ? $response->{actions} : undef;

    my $plan = $self->plan_actions($actions || [], $context);
    $plan->{dry_run} = 1;

    return $plan;
}

1;
