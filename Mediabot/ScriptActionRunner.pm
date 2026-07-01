package Mediabot::ScriptActionRunner;

use strict;
use warnings;
use utf8;

use Scalar::Util qw(looks_like_number);
use Encode qw(encode);

# ---------------------------------------------------------------------------
# Mediabot::ScriptActionRunner
# ---------------------------------------------------------------------------
# Validator, planner and explicitly gated applier for ScriptRunner results.
#
# apply_actions_dry() validates script-returned actions and builds a structured
# plan without side effects. apply_actions() can apply log/reply/notice actions
# only when apply => 1; IRC output also requires allow_irc => 1. Timer actions are
# still rejected as not implemented, and this module never writes to the DB.
# ---------------------------------------------------------------------------

sub _constructor_positive_int {
    my ($value, $default, $min, $max) = @_;

    # mb286-B2: action-runner constructor limits control the application side of
    # external script output.  Keep them scalar numeric only; malformed refs
    # should fall back to safe defaults instead of being stringified/numified by
    # int() and producing warnings or surprising clamps.
    my $number = $default;
    if (defined $value && !ref($value)) {
        my $raw = "$value";
        $raw =~ s/^\s+|\s+$//g;
        $number = int($raw) if length($raw) && looks_like_number($raw);
    }

    $number = int($number);
    $number = $min if $number < $min;
    $number = $max if $number > $max;

    return $number;
}

sub new {
    my ($class, %args) = @_;

    my $max_text_length = _constructor_positive_int($args{max_text_length}, 400, 32, 2000);

    my $max_actions = _constructor_positive_int($args{max_actions}, 20, 1, 50);

    # A1 (mb225): plafond configurable des diagnostics d'erreur, par coherence
    # avec max_actions. Defaut 20 (comportement historique inchange).
    my $max_errors = _constructor_positive_int($args{max_errors}, 20, 1, 100);

    return bless {
        bot             => $args{bot},
        max_text_length => $max_text_length,
        max_actions     => $max_actions,
        max_errors      => $max_errors,
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

sub max_actions {
    my ($self) = @_;
    return $self->{max_actions} || 20;
}

sub max_errors {
    my ($self) = @_;
    return $self->{max_errors} || 20;
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

sub _is_plain_scalar {
    my ($value) = @_;

    # mb250-B1: JSON action fields that become IRC/log/timer protocol values
    # must be scalar strings/numbers, not nested arrays or objects stringified
    # into HASH(0x...) / ARRAY(0x...). Keep the multilingual script contract
    # explicit and predictable before applying actions.
    return 0 if ref($value);
    return 1;
}

sub _context_default_target {
    my ($self, $context) = @_;

    return undef unless $context;

    # mb270-B1: context default targets are part of the action-layer contract.
    # A malformed ARRAY/HASH value in channel must not mask a scalar target
    # fallback, and object methods returning refs must not be stringified into
    # ARRAY(...)/HASH(...) before _bounded_target() sees them.
    if (ref($context) eq 'HASH') {
        for my $key (qw(channel target)) {
            my $value = $context->{$key};
            next unless _is_plain_scalar($value);

            my $safe = _trim($value);
            return $safe if length $safe;
        }
    }

    for my $method (qw(channel target reply_target)) {
        next unless eval { $context->can($method) };
        my $value = eval { $context->$method() };
        next unless _is_plain_scalar($value);

        my $safe = _trim($value);
        return $safe if length $safe;
    }

    return undef;
}

sub _bounded_text {
    my ($self, $text) = @_;

    return (0, 'text must be scalar') unless _is_plain_scalar($text);

    my $value = _trim($text);
    return (0, 'missing text') unless length $value;

    # mb232-B1: script-generated actions must remain single IRC/log lines.
    # External Perl/Python/Tcl scripts talk JSON to Mediabot, but their text is
    # eventually handed to IRC or logs.  Reject CR/LF/NUL early so a script can
    # never smuggle a second IRC line or poison structured runtime logs.
    return (0, 'text contains forbidden control characters') if $value =~ /[\r\n\0]/;

    if (length($value) > $self->{max_text_length}) {
        return (0, 'text too long');
    }

    return (1, undef, $value);
}

sub _bounded_target {
    my ($self, $target) = @_;

    return (0, 'target must be scalar') unless _is_plain_scalar($target);

    my $value = _trim($target);
    return (0, 'missing target') unless length $value;

    # mb232-B2: keep IRC destinations as a single target token.  A script action
    # must not be able to inject spaces, CR/LF or NUL into the destination passed
    # to send_message().  Normal channel names and nicknames are unaffected.
    return (0, 'target contains forbidden control characters') if $value =~ /[\r\n\0]/;
    return (0, 'target contains whitespace') if $value =~ /\s/;

    # mb234-B1: keep the destination to one IRC recipient, not an IRC target
    # list or a malformed trailing parameter. IRC accepts comma-separated
    # target lists; external script JSON must not be able to fan out a single
    # action to several channels/users by smuggling commas into target.
    return (0, 'target contains multiple recipients') if $value =~ /,/;
    return (0, 'target starts with forbidden prefix') if $value =~ /\A:/;

    return (0, 'target too long') if length($value) > 200;

    return (1, undef, $value);
}

sub _bounded_timer_name {
    my ($self, $name) = @_;

    return (0, 'timer name must be scalar') unless _is_plain_scalar($name);

    my $value = _trim($name);
    return (0, 'missing timer name') unless length $value;

    # mb235-B1: timer action names are future runtime identifiers. Even though
    # timer actions are not implemented yet, validate the JSON contract now so
    # external Perl/Python/Tcl scripts cannot produce multiline, whitespace-rich
    # or shell-looking timer names that would become dangerous later.
    return (0, 'timer name contains forbidden control characters') if $value =~ /[\r\n\0]/;
    return (0, 'timer name contains whitespace') if $value =~ /\s/;
    return (0, 'timer name too long') if length($value) > 64;
    return (0, 'timer name contains unsupported characters') unless $value =~ /\A[A-Za-z0-9_.-]+\z/;

    return (1, undef, $value);
}

sub validate_action {
    my ($self, $action, $context) = @_;

    return (0, 'action must be an object') unless ref($action) eq 'HASH';
    return (0, 'action type must be scalar') unless _is_plain_scalar($action->{type});

    my $type = lc _trim($action->{type});
    return (0, 'missing action type') unless length $type;
    return (0, "unsupported action type '$type'") unless $self->{allowed_actions}{$type};

    if ($type eq 'reply' || $type eq 'notice') {
        my ($text_ok, $text_err, $text) = $self->_bounded_text($action->{text});
        return (0, $text_err) unless $text_ok;

        my $target = $action->{target};
        if (!defined $target || (!ref($target) && !length _trim($target))) {
            $target = $self->_context_default_target($context);
        }

        my ($target_ok, $target_err, $safe_target) = $self->_bounded_target($target);
        return (0, $target_err) unless $target_ok;

        return (1, undef, {
            type   => $type,
            target => $safe_target,
            text   => $text,
        });
    }

    if ($type eq 'log') {
        my ($text_ok, $text_err, $text) = $self->_bounded_text($action->{text});
        return (0, $text_err) unless $text_ok;

        # mb251-B1: keep the log action level in the same scalar JSON
        # contract as the other action fields.  A nested array/object level
        # must not silently stringify and fall back to info; it is invalid
        # script output and should be rejected before planning.
        my $level_raw = exists $action->{level} ? $action->{level} : 'info';
        return (0, 'log level must be scalar') unless _is_plain_scalar($level_raw);

        my $level = lc _trim($level_raw);
        $level = 'info' unless length $level && $level =~ /\A(?:debug|info|warn|error)\z/;

        return (1, undef, {
            type  => 'log',
            level => $level,
            text  => $text,
        });
    }

    if ($type eq 'timer') {
        my ($name_ok, $name_err, $name) = $self->_bounded_timer_name($action->{name});
        return (0, $name_err) unless $name_ok;

        my $delay_raw = $action->{delay};
        return (0, 'invalid timer delay')
            unless defined $delay_raw
                && _is_plain_scalar($delay_raw)
                && "$delay_raw" =~ /\A[0-9]+\z/;

        my $delay = int($delay_raw);
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

    # MB296: an omitted actions field remains compatible with an empty action
    # list, but false scalar values such as 0, "0" or "" are malformed JSON
    # contracts and must not be silently converted into [] by ||=.
    $actions = [] unless defined $actions;
    return {
        ok      => 0,
        planned => [],
        errors  => [ 'actions must be an array' ],
    } unless ref($actions) eq 'ARRAY';

    # mb237-B2: keep the action layer bounded even for legacy callers that
    # bypass ScriptRunner and call ScriptActionRunner directly. Planning or
    # applying hundreds of actions from one script result would be an accidental
    # fan-out/spam primitive; reject it as an invalid plan.
    if (@$actions > $self->max_actions) {
        return {
            ok      => 0,
            planned => [],
            errors  => [ { error => 'too many actions in action plan' } ],
        };
    }

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
    # mb243-B1: keep the hash-based logger lookup single. A duplicate
    # lexical declaration is harmless at runtime but noisy under warnings and
    # weakens the cleanliness of the plugin/script bridge commit.
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

    # mb359-B1: encode script-generated IRC text to UTF-8 bytes before it
    # reaches IO::Async::Stream. JSON decoders return Perl character strings;
    # handing a wide-character scalar directly to send_message() eventually
    # reaches syswrite() and can terminate the bot on non-ASCII output.
    # Already encoded byte strings remain unchanged.
    my $wire_text = $action->{text};
    $wire_text = encode('UTF-8', $wire_text) if utf8::is_utf8($wire_text);

    my $ok = eval {
        $irc->send_message($command, undef, $action->{target}, $wire_text);
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

    # mb186-B1: real action application remains behind explicit gates.
    # ScriptDryRun calls this method only in ACTION_MODE=apply; IRC output still requires both
    # apply => 1 and allow_irc => 1. Without apply, the validated plan is returned.
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


sub _safe_error_text {
    my ($err) = @_;

    return '' unless defined $err;


    # mb256-B2: keep propagated failed-script diagnostics scalar-only at the
    # action layer too. Legacy direct callers may bypass ScriptRunner and hand
    # response.errors entries directly to ScriptActionRunner; never stringify
    # nested JSON arrays or objects into Perl reference placeholders.
    return '' if ref($err);
    my $text = "$err";
    $text =~ s/[\r\n\0]+/ /g;
    $text =~ s/^\s+|\s+$//g;
    $text = substr($text, 0, 240) if length($text) > 240;

    return $text;
}

sub _failed_script_result_errors {
    my ($self, $script_result) = @_;

    # mb239-B2: bound failed-result diagnostics at the action layer too. This
    # protects legacy direct callers that may bypass ScriptRunner's bounded error
    # normalization and hand ScriptActionRunner a huge response.errors array.
    # A1 (mb225): le plafond est desormais configurable (max_errors), defaut 20.
    my $max_errors = (ref($self) && $self->can('max_errors')) ? $self->max_errors : 20;

    return [ { error => 'script result is not an object' } ]
        if ref($script_result) ne 'HASH';

    # mb224-B1: the generic "... is not ok" messages are a FALLBACK. They are
    # only surfaced when there is no more specific scalar diagnostic available.
    # Previously they were always prepended, which (a) crowded out the real
    # scalar errors propagated from response.errors (mb256 contract) and (b)
    # emitted both 'script result is not ok' AND 'script response is not ok'
    # when only a single fallback was expected. We now split diagnostics into
    # "specific" (validation errors, script-level error, timeout, scalar
    # response.errors) and a single generic fallback used only when specific is
    # empty.
    my @specific;

    # mb290-B1: a top-level script_result.error is an execution-boundary
    # diagnostic, not arbitrary Perl data. Direct/legacy callers may bypass
    # ScriptRunner and hand ScriptActionRunner a HASH/ARRAY/blessed object here.
    # Keep the error contract scalar-only and never stringify overloaded objects
    # while collecting diagnostics.
    if (exists $script_result->{error}) {
        if (ref($script_result->{error})) {
            push @specific, 'top-level error must be scalar';
        }
        elsif (defined $script_result->{error} && length "$script_result->{error}") {
            push @specific, $script_result->{error};
        }
    }

    push @specific, 'script timed out'
        if $script_result->{timeout};

    my $response = ref($script_result->{response}) eq 'HASH'
        ? $script_result->{response}
        : undef;

    # ok-flag validation errors are specific diagnostics (not generic fallbacks).
    my ($top_has_ok, $top_valid, $top_value) = (0, 1, 1);
    if (exists $script_result->{ok}) {
        $top_has_ok = 1;
        ($top_valid, $top_value) = _decode_ok_flag_for_action_layer($script_result->{ok});
        push @specific, 'top-level ok must be a JSON boolean or 0/1 scalar'
            unless $top_valid;
    }

    my ($resp_has_ok, $resp_valid, $resp_value) = (0, 1, 1);
    if ($response && exists $response->{ok}) {
        $resp_has_ok = 1;
        ($resp_valid, $resp_value) = _decode_ok_flag_for_action_layer($response->{ok});
        push @specific, 'response ok must be a JSON boolean or 0/1 scalar'
            unless $resp_valid;
    }

    # mb267-B1: response.errors is also a failure signal for legacy/direct
    # ScriptActionRunner callers, even when response.ok is absent.  ScriptRunner
    # already closes actions when errors is non-empty; keep the direct action
    # boundary consistent so a hand-built { response => { errors => [...],
    # actions => [...] } } cannot plan/apply actions by omission of ok.
    if ($response && exists $response->{errors} && ref($response->{errors}) ne 'ARRAY') {
        push @specific, 'response errors must be an array';
    }
    elsif ($response && ref($response->{errors}) eq 'ARRAY') {
        for my $err (@{ $response->{errors} }) {
            last if @specific >= $max_errors;
            my $text = _safe_error_text($err);
            push @specific, $text if length $text;
        }
    }

    # Build the specific error list (already scalar; re-clean defensively).
    my @errors;
    for my $err (@specific) {
        last if @errors >= $max_errors;
        my $text = _safe_error_text($err);
        next unless length $text;
        push @errors, { error => $text };
    }

    return \@errors if @errors;

    # No specific diagnostic: emit a SINGLE generic fallback, preferring the
    # top-level flag over the response-level flag.
    if ($top_has_ok && $top_valid && !$top_value) {
        return [ { error => 'script result is not ok' } ];
    }
    if ($resp_has_ok && $resp_valid && !$resp_value) {
        return [ { error => 'script response is not ok' } ];
    }

    return [ { error => 'script result is not ok' } ];
}

sub _decode_ok_flag_for_action_layer {
    my ($value) = @_;

    # mb259-B1: ScriptActionRunner also accepts legacy/direct callers that may
    # bypass ScriptRunner.  If such a caller provides an explicit ok flag, keep
    # it on the same JSON contract as ScriptRunner: JSON boolean or numeric 0/1
    # scalar only.  Do not let HASH/ARRAY refs or strings like true become
    # truthy by Perl accident and open the action planner.
    if (ref($value)) {
        return (1, $value ? 1 : 0) if eval { $value->isa('JSON::PP::Boolean') };
        return (0, undef);
    }

    return (1, 0) if defined $value && "$value" eq '0';
    return (1, 1) if defined $value && "$value" eq '1';

    return (0, undef);
}

sub _script_result_failed {
    my ($script_result) = @_;

    # mb200-B1: preserve legacy ScriptActionRunner callers that predate
    # ScriptRunner's top-level { ok => 1 } wrapper.  Absence of the top-level
    # ok flag is not a failure by itself when a response/actions payload exists.
    return 1 unless ref($script_result) eq 'HASH';
    return 1 if $script_result->{timeout};

    # mb290-B2: treat any non-scalar top-level error as a failed script result
    # without stringifying it. This keeps direct action-layer callers aligned with
    # the scalar JSON diagnostic contract enforced by ScriptRunner.
    if (exists $script_result->{error}) {
        return 1 if ref($script_result->{error});
        return 1 if defined $script_result->{error} && length "$script_result->{error}";
    }

    if (exists $script_result->{ok}) {
        my ($valid, $ok_value) = _decode_ok_flag_for_action_layer($script_result->{ok});
        return 1 unless $valid && $ok_value;
    }

    my $response = ref($script_result->{response}) eq 'HASH'
        ? $script_result->{response}
        : undef;

    if ($response && exists $response->{ok}) {
        my ($valid, $ok_value) = _decode_ok_flag_for_action_layer($response->{ok});
        return 1 unless $valid && $ok_value;
    }

    # mb267-B2: keep ScriptActionRunner aligned with ScriptRunner for legacy
    # direct callers. A response carrying errors is failed even if response.ok
    # is omitted. A non-array errors field is malformed and must also close the
    # action layer. Empty errors remains compatible and does not fail by itself.
    if ($response && exists $response->{errors}) {
        return 1 unless ref($response->{errors}) eq 'ARRAY';
        return 1 if @{ $response->{errors} };
    }

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
            errors  => $self->_failed_script_result_errors($script_result),
        };
    }

    my $response = ref($script_result) eq 'HASH' ? $script_result->{response} : undef;
    my $actions  = ref($response) eq 'HASH' ? $response->{actions} : undef;

    # Preserve the distinction between a missing actions field and a malformed
    # false scalar value. plan_actions() handles undef as the compatible empty
    # list and rejects every defined non-array value.
    my $plan = $self->plan_actions($actions, $context);
    $plan->{dry_run} = 1;

    return $plan;
}

1;
