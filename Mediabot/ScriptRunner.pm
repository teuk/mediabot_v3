package Mediabot::ScriptRunner;

use strict;
use warnings;
use utf8;

use JSON::PP qw(encode_json decode_json);
use IPC::Open3 qw(open3);
use IO::Select ();
use Symbol qw(gensym);
use POSIX qw(WNOHANG);
use Time::HiRes qw(time sleep);
use Scalar::Util qw(looks_like_number);
use Cwd ();
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
use Errno ();

# ---------------------------------------------------------------------------
# Mediabot::ScriptRunner
# ---------------------------------------------------------------------------
# External Perl/Python/Tcl execution boundary for the mediabot-script-v1 protocol.
#
# ScriptRunner validates script paths and interpreters, builds the JSON envelope,
# executes scripts out-of-process without a shell, enforces timeout/I/O limits and
# validates the JSON response. It does not itself send IRC messages or apply the
# returned actions; that responsibility belongs to ScriptActionRunner.
# ---------------------------------------------------------------------------

sub _constructor_script_dir {
    my ($value) = @_;

    # mb283-B1: script_dir is the root of the external Perl/Python/Tcl
    # execution boundary.  Keep it as plain scalar path text at construction
    # time; do not let ARRAY/HASH/blessed refs stringify into fake directories
    # such as ARRAY(0x...) or overloaded paths before containment checks run.
    return 'plugins/scripts' unless defined $value;
    return 'plugins/scripts' if ref($value);

    my $dir = "$value";
    $dir =~ s/^\s+|\s+$//g;

    return length($dir) ? $dir : 'plugins/scripts';
}

sub _constructor_positive_int {
    my ($value, $default, $min, $max) = @_;

    # mb286-B1: constructor limits are execution-boundary knobs.  They must
    # stay plain numeric scalars; do not let ARRAY/HASH/blessed refs stringify
    # or numify through int(), which can emit warnings, invoke overloads, and
    # accidentally clamp to a different runtime limit.
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

    my $script_dir = _constructor_script_dir($args{script_dir});

    my $timeout = _constructor_positive_int($args{timeout}, 3, 1, 30);

    my $max_stdout = _constructor_positive_int($args{max_stdout_bytes}, 65536, 1024, 1048576);

    # mb280-B1: max_stderr_bytes is a first-class runtime cap, like
    # max_stdout_bytes. Before this it was never read at construction time
    # (silently ignored) and run_plan() fell back to the stdout instance cap for
    # stderr, so stderr could not be capped independently. Default matches the
    # stdout cap (64 KiB) so existing behavior is unchanged.
    my $max_stderr = _constructor_positive_int($args{max_stderr_bytes}, 65536, 1024, 1048576);

    # mb246-B1: keep stdin bounded at the runner boundary too. Normal
    # ScriptDryRun payloads are tiny IRC event envelopes, but run_plan() is a
    # public internal execution boundary and can receive handcrafted plans from
    # tests or other trusted internal callers. Refuse oversized stdin before
    # spawning a child.
    # The upper bound stays above the historical mb221 stress payload so that
    # the deadline-bounded nonblocking stdin path remains covered by tests.
    my $max_stdin = _constructor_positive_int($args{max_stdin_bytes}, 4194304, 1024, 4194304);

    my $max_actions = _constructor_positive_int($args{max_actions}, 20, 1, 50);

    return bless {
        bot              => $args{bot},
        script_dir       => $script_dir,
        timeout          => $timeout,
        max_stdout_bytes => $max_stdout,
        max_stderr_bytes => $max_stderr,
        max_stdin_bytes  => $max_stdin,
        max_actions      => $max_actions,
        allowed_actions  => {
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

sub script_dir {
    my ($self) = @_;
    return $self->{script_dir};
}

sub timeout {
    my ($self) = @_;
    return $self->{timeout};
}

sub max_stdout_bytes {
    my ($self) = @_;
    return $self->{max_stdout_bytes};
}

sub max_stderr_bytes {
    my ($self) = @_;
    return $self->{max_stderr_bytes};
}

sub max_stdin_bytes {
    my ($self) = @_;
    return $self->{max_stdin_bytes} || 65536;
}

sub max_actions {
    my ($self) = @_;
    return $self->{max_actions} || 20;
}

sub language_for {
    my ($self, $path) = @_;

    return undef unless defined $path;

    # mb280-B1: language detection is part of the script execution boundary.
    # Accept only plain scalar path text here as well, not ARRAY/HASH/blessed
    # refs that happen to stringify to a supported extension. validate_script_path()
    # already enforces this for normal execution; this keeps the direct helper API
    # under the same Perl/Python/Tcl scalar contract.
    return undef if ref($path);

    return 'perl'   if $path =~ /\.pl\z/i;
    return 'python' if $path =~ /\.py\z/i;
    return 'tcl'    if $path =~ /\.tcl\z/i;

    return undef;
}

sub validate_script_path {
    my ($self, $path) = @_;

    return (0, 'missing script path') unless defined $path;

    # mb273-B1: script paths are execution-boundary identifiers and must be
    # plain scalar relative paths.  Do not allow ARRAY/HASH/blessed refs to
    # stringify into ARRAY(...), HASH(...), or overloaded path text before the
    # lexical and symlink containment checks run.
    return (0, 'script path must be scalar') if ref($path);
    return (0, 'missing script path') unless length "$path";

    my $p = "$path";
    $p =~ s/^\s+|\s+$//g;

    return (0, 'empty script path') unless length $p;
    return (0, 'absolute paths are not allowed') if $p =~ m{\A/};
    return (0, 'parent directory traversal is not allowed') if $p =~ m{(?:\A|/)\.\.(?:/|\z)};
    return (0, 'backslash paths are not allowed') if $p =~ m{\\};
    return (0, 'NUL byte is not allowed') if $p =~ /\0/;

    my $lang = $self->language_for($p);
    return (0, 'unsupported script extension') unless defined $lang;

    my $full_path = $self->{script_dir} . '/' . $p;

    # mb221-B1 + A4 (mb225): containment check against symlink escape, for both
    # existing and not-yet-created scripts. The lexical checks above stop
    # textual traversal ('..', absolute, backslash), but a symlink placed inside
    # script_dir (the script file itself, OR an intermediate directory) can
    # still point outside it. We resolve the deepest existing path along
    # full_path (the file if present, else its nearest existing ancestor
    # directory) and require it to remain within script_dir. Resolving the
    # ancestor closes the TOCTOU gap where a symlinked subdirectory is created
    # before the script file (mb221 only checked when the file existed).
    my ($contained, $cerr) = $self->_path_within_script_dir($full_path);
    return (0, $cerr) unless $contained;

    return (1, undef, $lang, $full_path);
}

# A4 (mb225): true when full_path resolves within script_dir, resolving
# symlinks. Works even if the script file does not exist yet by checking its
# deepest existing ancestor directory.
sub _path_within_script_dir {
    my ($self, $full_path) = @_;

    my $real_dir = Cwd::abs_path($self->{script_dir});
    return (0, 'unable to resolve script path') unless defined $real_dir;

    my $dir_prefix = $real_dir;
    $dir_prefix .= '/' unless $dir_prefix =~ m{/\z};

    # Walk up to the deepest existing OR symlink path component.
    # mb265-B1: a broken symlink is not true for -e, but it is still a path
    # component that can later be repointed outside script_dir.  Stop on -l as
    # well as -e so broken symlink ancestors cannot be skipped and accidentally
    # accepted as a safe not-yet-created child path.
    my $probe = $full_path;
    while (length $probe && !-e $probe && !-l $probe) {
        my $next = $probe;
        $next =~ s{/[^/]+/?\z}{};
        last if !length $next || $next eq $probe;
        $probe = $next;
    }

    # Nothing exists to resolve (beyond script_dir): lexical checks already
    # passed, let the later exec fail cleanly.  Broken symlinks do not reach
    # this branch because -l is true and are rejected below when abs_path fails.
    return (1, undef) unless length $probe && (-e $probe || -l $probe);

    my $real_probe = Cwd::abs_path($probe);
    return (0, 'unable to resolve script path') unless defined $real_probe;

    unless (index($real_probe . '/', $dir_prefix) == 0) {
        return (0, 'script path escapes script directory');
    }

    return (1, undef);
}

sub _normalize_event_name {
    my ($event) = @_;

    # mb271-B1: event is a JSON protocol field sent to external scripts. It
    # must be a scalar token, not a HASH/ARRAY/blessed object stringified or
    # encoded into the event slot. Keep invalid internal caller input harmless
    # by falling back to the stable legacy event name "unknown".
    return 'unknown' unless defined $event;
    return 'unknown' if ref($event);

    my $value = "$event";
    $value =~ s/^\s+|\s+$//g;

    return 'unknown' unless length $value;
    return 'unknown' if $value =~ /[\r\n\0]/;
    return 'unknown' if $value =~ /\s/;
    return 'unknown' unless $value =~ /\A[A-Za-z0-9_.:-]+\z/;

    return $value;
}

sub _normalize_event_data_value {
    my ($value) = @_;

    # mb289-B1: data fields inside the external Perl/Python/Tcl JSON envelope
    # must stay simple and predictable. Normal ScriptDryRun traffic already sends
    # scalar channel/target/nick/command fields plus an args ARRAY of scalars, but
    # direct run_script()/build_event_payload() callers can hand nested HASH refs,
    # objects, or arrays containing refs. Do not expose arbitrary Perl structures
    # to external scripts or let JSON::PP encode blessed internals by accident.
    return undef unless defined $value;

    if (ref($value) eq 'ARRAY') {
        my @clean;
        for my $item (@$value) {
            next unless defined $item;
            next if ref($item);
            push @clean, "$item";
        }
        return \@clean;
    }

    return undef if ref($value);
    return "$value";
}

sub _normalize_event_data {
    my (%data) = @_;

    my %clean;
    for my $key (keys %data) {
        next unless defined $key;
        next if ref($key);
        my $safe_key = "$key";
        next unless length $safe_key;
        next if $safe_key =~ /[\r\n\0]/;
        $clean{$safe_key} = _normalize_event_data_value($data{$key});
    }

    return %clean;
}

sub build_event_payload {
    my ($self, $event, %data) = @_;

    $event = _normalize_event_name($event);
    my %safe_data = _normalize_event_data(%data);

    return {
        protocol => 'mediabot-script-v1',
        event    => $event,
        data     => \%safe_data,
    };
}

sub encode_event_payload {
    my ($self, $payload) = @_;

    # mb287-B1: this helper is the last JSON encoder before data crosses the
    # external Perl/Python/Tcl stdin boundary.  build_execution_plan() already
    # rejects non-object payloads, but direct helper callers must not be able to
    # encode JSON arrays/scalars or stringify overloaded objects into the script
    # protocol. Keep undef as the historical empty-object fallback.
    my $payload_object = _execution_payload_object($payload);
    $payload_object = {} unless defined $payload_object;

    return encode_json($payload_object);
}


sub _decode_ok_field {
    my ($value) = @_;

    # mb252-B1: if a script chooses to declare an explicit top-level ok field,
    # keep that field to the JSON contract: a real JSON boolean, or the legacy
    # numeric 0/1 scalar.  Arrays/objects/strings such as "true" must not become
    # truthy by Perl accident and allow actions to pass as successful output.
    if (ref($value)) {
        return (1, $value ? 1 : 0) if eval { $value->isa('JSON::PP::Boolean') };
        return (0, undef);
    }

    return (1, 0) if defined $value && "$value" eq '0';
    return (1, 1) if defined $value && "$value" eq '1';

    return (0, undef);
}

sub _script_error_text {
    my ($err) = @_;

    return '' unless defined $err;


    # mb256-B1: script response diagnostics are part of the JSON contract.
    # Error entries must be scalar text values; arrays/objects must not be
    # stringified into HASH or ARRAY memory-address placeholders and then shown
    # in logs, partyline status, or action-layer diagnostics.
    return '' if ref($err);
    my $text = "$err";
    $text =~ s/[\r\n\0]+/ /g;
    $text =~ s/^\s+|\s+$//g;
    $text = substr($text, 0, 240) if length($text) > 240;

    return $text;
}

sub _normalized_response_errors {
    my ($errors, $fallback) = @_;

    # mb239-B1: keep script-declared failure details bounded. A compact JSON
    # response can contain a very large errors array even when stdout itself is
    # capped. Preserve useful diagnostics, but never expose an unbounded error
    # list to ScriptActionRunner, partyline rendering, or logs.
    my @out;
    my $max_errors = 20;

    if (ref($errors) eq 'ARRAY') {
        for my $err (@$errors) {
            last if @out >= $max_errors;
            my $text = _script_error_text($err);
            push @out, $text if length $text;
        }
    }
    elsif (defined $errors) {
        my $text = _script_error_text($errors);
        push @out, $text if length $text;
    }

    push @out, $fallback || 'script response reported failure' unless @out;
    return \@out;
}

sub decode_script_response {
    my ($self, $json) = @_;

    return {
        ok     => 0,
        errors => [ 'empty script response' ],
        actions => [],
    } unless defined $json && length $json;

    my $decoded = eval { decode_json($json) };
    if (!$decoded || ref($decoded) ne 'HASH') {
        my $err = $@ || 'decoded response is not an object';
        $err =~ s/\s+/ /g;
        return {
            ok      => 0,
            errors  => [ "invalid JSON response: $err" ],
            actions => [],
        };
    }

    # mb253-B1: optional response protocol guard. Legacy scripts may omit
    # protocol to stay compatible, but if a script declares a protocol it must
    # be the exact Mediabot script protocol. This prevents future protocol
    # variants or nested JSON values from being accepted accidentally.
    if (exists $decoded->{protocol}) {
        return {
            ok      => 0,
            errors  => [ 'protocol must be scalar' ],
            actions => [],
        } if ref($decoded->{protocol});

        my $protocol = "$decoded->{protocol}";
        $protocol =~ s/^\s+|\s+$//g;

        return {
            ok      => 0,
            errors  => [ 'unsupported script response protocol' ],
            actions => [],
        } unless $protocol eq 'mediabot-script-v1';
    }

    # mb226-B1: respect a script-declared failure before trusting actions.
    # Older demo scripts may omit ok/errors entirely, so absence of ok remains
    # the legacy success-by-valid-actions contract. But if a script explicitly
    # returns ok=false or returns errors, the response is failed and no actions
    # are exposed to the action layer.
    if (exists $decoded->{ok}) {
        my ($ok_field_valid, $ok_field_value) = _decode_ok_field($decoded->{ok});
        return {
            ok      => 0,
            errors  => [ 'ok must be a JSON boolean or 0/1 scalar' ],
            actions => [],
        } unless $ok_field_valid;

        if (!$ok_field_value) {
            return {
                ok      => 0,
                errors  => _normalized_response_errors($decoded->{errors}, 'script response reported failure'),
                actions => [],
            };
        }
    }

    if (defined $decoded->{errors}) {
        return {
            ok      => 0,
            errors  => [ 'errors must be an array' ],
            actions => [],
        } unless ref($decoded->{errors}) eq 'ARRAY';

        if (@{ $decoded->{errors} }) {
            return {
                ok      => 0,
                errors  => _normalized_response_errors($decoded->{errors}, 'script response reported errors'),
                actions => [],
            };
        }
    }

    my $actions = $decoded->{actions};
    if (!defined $actions) {
        $actions = [];
    }

    return {
        ok      => 0,
        errors  => [ 'actions must be an array' ],
        actions => [],
    } unless ref($actions) eq 'ARRAY';

    # mb237-B1: cap the number of actions accepted from one external script
    # response. The stdout byte cap limits raw data size, but a compact JSON
    # response could still ask Mediabot to plan/apply a large number of IRC/log
    # actions. Keep the protocol bounded: one script invocation may only return
    # a small, predictable action list.
    if (@$actions > $self->max_actions) {
        return {
            ok      => 0,
            errors  => [ 'too many actions in script response' ],
            actions => [],
        };
    }

    my @valid;
    my @errors;

    for my $idx (0 .. $#$actions) {
        my $action = $actions->[$idx];

        if (ref($action) ne 'HASH') {
            push @errors, "action[$idx] must be an object";
            next;
        }

        my $type = $action->{type};

        # mb254-B1: keep action type itself in the JSON scalar contract.
        # ScriptActionRunner also validates action fields later, but ScriptRunner
        # is the protocol boundary that decides which actions are exposed at all.
        # Do not stringify ARRAY/HASH/boolean objects into ARRAY(0x...) or HASH(0x...)
        # while classifying action types.
        if (ref($type)) {
            push @errors, "action[$idx] type must be scalar";
            next;
        }

        if (!defined $type || !length "$type") {
            push @errors, "action[$idx] missing type";
            next;
        }

        $type = lc "$type";
        $type =~ s/^\s+|\s+$//g;
        if (!$self->{allowed_actions}{$type}) {
            push @errors, "action[$idx] unsupported type '$type'";
            next;
        }

        $action->{type} = $type;
        push @valid, $action;
    }

    return {
        ok      => @errors ? 0 : 1,
        errors  => \@errors,
        actions => \@valid,
    };
}

sub interpreter_for_language {
    my ($self, $language) = @_;

    return undef unless defined $language;

    # mb280-B2: interpreter selection must be keyed by a plain scalar language
    # token. Do not accept overloaded objects or other refs that stringify to
    # "perl", "python" or "tcl". The argv handed to open3() must come from
    # trusted scalar protocol values only.
    return undef if ref($language);

    my $lang = lc "$language";
    $lang =~ s/^\s+|\s+$//g;

    return [ $^X ]       if $lang eq 'perl';
    return [ 'python3' ] if $lang eq 'python';
    return [ 'tclsh' ]   if $lang eq 'tcl';

    return undef;
}

sub _execution_payload_object {
    my ($payload) = @_;

    # mb285-B1: the external Perl/Python/Tcl protocol stdin is a JSON object
    # envelope.  build_event_payload() always creates a HASH ref, but direct
    # internal callers can hand build_execution_plan() scalars, ARRAY refs or
    # blessed objects.  Reject those before JSON::PP can encode a non-object
    # payload or stringify overloaded data into the script boundary.
    return {} unless defined $payload;
    return undef unless ref($payload) eq 'HASH';
    return $payload;
}

sub build_execution_plan {
    my ($self, $script_path, $payload, %opts) = @_;

    my ($ok, $err, $language, $full_path) = $self->validate_script_path($script_path);
    unless ($ok) {
        return {
            ok      => 0,
            error   => $err,
            actions => [],
            command => [],
        };
    }

    my $interp = $self->interpreter_for_language($language);
    unless ($interp && ref($interp) eq 'ARRAY' && @$interp) {
        return {
            ok       => 0,
            error    => "no interpreter configured for language '$language'",
            language => $language,
            actions  => [],
            command  => [],
        };
    }

    my $payload_object = _execution_payload_object($payload);
    unless ($payload_object) {
        return {
            ok      => 0,
            error   => 'payload must be object',
            actions => [],
            command => [],
        };
    }

    my $json = $self->encode_event_payload($payload_object);

    # mb175-B1: execution plan only. This is intentionally a dry-run contract:
    # it prepares the argv/stdin/limits we will use later, but does not spawn.
    my @command = (@$interp, $full_path);

    return {
        ok               => 1,
        dry_run          => 1,
        language         => $language,
        script           => $script_path,
        full_path        => $full_path,
        command          => \@command,
        stdin            => $json,
        timeout          => $self->{timeout},
        max_stdin_bytes  => $self->{max_stdin_bytes},
        max_stdout_bytes => $self->{max_stdout_bytes},
        max_stderr_bytes => $self->{max_stderr_bytes},
    };
}

sub run_dry {
    my ($self, $script_path, $event, %data) = @_;

    my $payload = $self->build_event_payload($event, %data);
    return $self->build_execution_plan($script_path, $payload);
}


sub _append_capped {
    my ($buffer_ref, $chunk, $max, $truncated_ref) = @_;

    return unless defined $chunk && length $chunk;
    $$buffer_ref //= '';

    my $remaining = $max - length($$buffer_ref);
    if ($remaining <= 0) {
        $$truncated_ref = 1;
        return;
    }

    if (length($chunk) > $remaining) {
        $$buffer_ref .= substr($chunk, 0, $remaining);
        $$truncated_ref = 1;
        return;
    }

    $$buffer_ref .= $chunk;
}

sub _run_plan_failure {
    my ($error) = @_;
    $error = 'invalid execution plan' unless defined $error && length "$error";

    return {
        ok       => 0,
        error    => $error,
        timeout  => 0,
        stdout   => '',
        stderr   => '',
        response => { ok => 0, errors => [ $error ], actions => [] },
    };
}


sub _validate_stdin_json_object {
    my ($stdin) = @_;

    # mb288-B1: run_plan() is the last boundary before open3() hands STDIN to
    # an external Perl/Python/Tcl script.  build_execution_plan() and
    # encode_event_payload() now produce object envelopes, but a handcrafted
    # internal execution plan could still provide scalar non-JSON, JSON arrays,
    # or JSON scalars.  Refuse those before spawning the child so every script
    # receives the same protocol shape: one JSON object.
    return 'stdin must be JSON object' unless defined $stdin && length $stdin;

    my $decoded = eval { decode_json($stdin) };
    return 'stdin must be JSON object' if $@ || ref($decoded) ne 'HASH';

    return undef;
}

sub _execution_plan_scalar {
    my ($value) = @_;

    # mb278-B1: execution plans are an internal but security-sensitive boundary.
    # Do not allow script identities, language names, full paths, or argv entries
    # to be Perl references that stringify into apparently valid values.  The
    # subprocess layer must only receive plain scalar argv components.
    return 0 unless defined $value;
    return 0 if ref($value);
    return 1;
}

sub _argv_same {
    my ($left, $right) = @_;

    return 0 unless ref($left) eq 'ARRAY' && ref($right) eq 'ARRAY';
    return 0 unless @$left == @$right;

    for my $idx (0 .. $#$left) {
        return 0 unless _execution_plan_scalar($left->[$idx]);
        return 0 unless _execution_plan_scalar($right->[$idx]);
        return 0 unless "$left->[$idx]" eq "$right->[$idx]";
    }

    return 1;
}

sub _validate_execution_plan_for_run {
    my ($self, $plan) = @_;

    return 'invalid execution plan'
        unless ref($plan) eq 'HASH' && $plan->{ok};

    # mb241-B1: run_plan is an execution boundary, not only a helper for plans
    # produced by build_execution_plan.  A future internal caller must not be
    # able to hand it an arbitrary argv such as a shell command.  Re-validate
    # the script path and require the argv to be exactly the interpreter plus
    # the validated script path.
    # mb278-B2: reject references before any stringification in the execution
    # identity fields.  validate_script_path() also rejects script refs, but this
    # keeps run_plan() diagnostics explicit and avoids length/string comparison
    # on ARRAY/HASH/blessed values.
    return 'script path must be scalar'
        if exists $plan->{script} && ref($plan->{script});
    return 'missing script in execution plan'
        unless defined $plan->{script} && length "$plan->{script}";

    my ($ok, $err, $language, $full_path) = $self->validate_script_path($plan->{script});
    return $err unless $ok;

    return 'execution plan language must be scalar'
        if exists $plan->{language} && ref($plan->{language});
    my $plan_language = defined $plan->{language} ? lc "$plan->{language}" : '';
    $plan_language =~ s/^\s+|\s+$//g;
    return 'execution plan language mismatch'
        unless length($plan_language) && $plan_language eq $language;

    return 'execution plan full path must be scalar'
        if exists $plan->{full_path} && ref($plan->{full_path});
    my $plan_full_path = defined $plan->{full_path} ? "$plan->{full_path}" : '';
    return 'execution plan full path mismatch'
        unless length($plan_full_path) && $plan_full_path eq $full_path;

    my $interp = $self->interpreter_for_language($language);
    return "no interpreter configured for language '$language'"
        unless $interp && ref($interp) eq 'ARRAY' && @$interp;

    my @expected = (@$interp, $full_path);
    return 'execution plan command must be an array'
        unless ref($plan->{command}) eq 'ARRAY';

    # mb278-B3: argv entries are passed to open3() and must be plain scalars.
    # Reject ARRAY/HASH/blessed refs even if they overload stringification to
    # the expected interpreter or script path.
    for my $arg (@{ $plan->{command} }) {
        return 'execution plan command arguments must be scalar'
            unless _execution_plan_scalar($arg);
    }

    return 'execution plan command does not match validated script path'
        unless _argv_same($plan->{command}, \@expected);

    return undef;
}

sub run_plan {
    my ($self, $plan) = @_;

    my $plan_error = $self->_validate_execution_plan_for_run($plan);
    return _run_plan_failure($plan_error) if defined $plan_error;

    # mb272-B1: runtime execution limits are part of the run_plan contract.
    # They may be overridden by a handcrafted internal plan, but they must stay
    # plain scalar values.  Do not let ARRAY/HASH refs stringify through int()
    # and emit warnings or silently clamp into a different runtime boundary.
    for my $limit_key (qw(timeout max_stdin_bytes max_stdout_bytes max_stderr_bytes)) {
        return _run_plan_failure("$limit_key must be scalar")
            if exists $plan->{$limit_key} && ref($plan->{$limit_key});
    }

    my @cmd = @{ $plan->{command} };

    # mb257-B1: stdin is part of the internal execution-plan contract and
    # must be scalar bytes/text.  Do not stringify ARRAY/HASH refs into
    # ARRAY(0x...) or HASH(0x...) and feed that to an external process.
    return _run_plan_failure('stdin must be scalar')
        if exists $plan->{stdin} && ref($plan->{stdin});

    my $stdin      = defined $plan->{stdin} ? $plan->{stdin} : '';
    my $timeout    = defined $plan->{timeout} ? int($plan->{timeout}) : $self->{timeout};
    my $max_stdin  = defined $plan->{max_stdin_bytes} ? int($plan->{max_stdin_bytes}) : $self->{max_stdin_bytes};
    my $max_stdout = defined $plan->{max_stdout_bytes} ? int($plan->{max_stdout_bytes}) : $self->{max_stdout_bytes};
    my $max_stderr = defined $plan->{max_stderr_bytes} ? int($plan->{max_stderr_bytes}) : $self->{max_stderr_bytes};

    $timeout    = 1       if $timeout < 1;
    $timeout    = 30      if $timeout > 30;
    $max_stdin  = 1024    if $max_stdin < 1024;
    $max_stdin  = 4194304 if $max_stdin > 4194304;
    $max_stdout = 1024    if $max_stdout < 1024;
    $max_stdout = 1048576 if $max_stdout > 1048576;
    $max_stderr = 1024    if $max_stderr < 1024;
    $max_stderr = 1048576 if $max_stderr > 1048576;

    if (defined $stdin && length($stdin) > $max_stdin) {
        return _run_plan_failure('stdin too large');
    }

    if (my $stdin_error = _validate_stdin_json_object($stdin)) {
        return _run_plan_failure($stdin_error);
    }

    # mb236-B1: clamp runtime output caps even when run_plan() receives a
    # handcrafted execution plan. build_execution_plan() already creates sane
    # limits, but tests, plugins or future internal callers can pass a plan
    # directly. Never let max_stdout_bytes/max_stderr_bytes become unbounded.

    # mb176-B1: real subprocess execution, but still with the boundaries laid by
    # mb174/mb175: validated path, argv array only, no shell, JSON stdin,
    # timeout, stdout cap, stderr cap, and structured response parsing.
    my ($child_in, $child_out);
    my $child_err = gensym;

    my $pid = eval { open3($child_in, $child_out, $child_err, @cmd) };
    if (!$pid) {
        my $err = $@ || 'open3 failed';
        $err =~ s/\s+/ /g;
        return {
            ok       => 0,
            error    => $err,
            timeout  => 0,
            stdout   => '',
            stderr   => '',
            response => { ok => 0, errors => [ $err ], actions => [] },
        };
    }

    local $SIG{PIPE} = 'IGNORE';

    my $deadline = time() + $timeout;

    # mb221-B2: deadline-bounded, non-blocking stdin write. A blocking
    # print to the child's stdin can deadlock the whole bot if the child never
    # drains stdin while filling its own stdout (the parent blocks on print
    # before the read loop's deadline ever starts). Today the payload is a tiny
    # JSON envelope so this is not reachable, but we harden it now so a future
    # larger payload cannot reintroduce the unbounded-hang class we just closed
    # in mb220. If the child will not accept stdin before the deadline, treat it
    # as a timeout and kill it.
    my $stdin_timed_out = 0;
    if (defined $stdin && length $stdin) {
        my $wsel = IO::Select->new($child_in);
        my $offset = 0;
        my $len    = length $stdin;

        eval {
            my $flags = fcntl($child_in, F_GETFL, 0);
            fcntl($child_in, F_SETFL, $flags | O_NONBLOCK) if defined $flags;
            1;
        };

        while ($offset < $len) {
            if (time() > $deadline) { $stdin_timed_out = 1; last; }

            my @ready = $wsel->can_write(0.10);
            next unless @ready;

            my $wrote = syswrite($child_in, $stdin, $len - $offset, $offset);
            if (!defined $wrote) {
                # EAGAIN/EWOULDBLOCK -> retry; any other error -> stop writing.
                next if $!{EAGAIN} || $!{EWOULDBLOCK};
                last;
            }
            $offset += $wrote;
        }
    }
    eval { close $child_in; 1; };

    if ($stdin_timed_out) {
        kill 'TERM', $pid;
        sleep 0.2;
        if (waitpid($pid, WNOHANG) == 0) {
            kill 'KILL', $pid;
            waitpid($pid, 0);
        }
        eval { close $child_out; 1; };
        eval { close $child_err; 1; };
        return {
            ok       => 0,
            timeout  => 1,
            stdout   => '',
            stderr   => '',
            response => { ok => 0, errors => [ 'script timed out' ], actions => [] },
        };
    }

    my $selector = IO::Select->new();
    $selector->add($child_out);
    $selector->add($child_err);

    my $stdout = '';
    my $stderr = '';
    my $stdout_truncated = 0;
    my $stderr_truncated = 0;
    my $timed_out = 0;
    my $already_waited = 0;
    my $wait_status = undef;

    while ($selector->count) {
        if (time() > $deadline) {
            $timed_out = 1;
            kill 'TERM', $pid;
            sleep 0.2;
            my $w = waitpid($pid, WNOHANG);
            if ($w == 0) {
                kill 'KILL', $pid;
                waitpid($pid, 0);
                $wait_status = $?;
                $already_waited = 1;
            }
            elsif ($w == $pid) {
                $wait_status = $?;
                $already_waited = 1;
            }
            last;
        }

        my @ready = $selector->can_read(0.10);
        next unless @ready;

        for my $fh (@ready) {
            my $chunk = '';
            my $read = sysread($fh, $chunk, 4096);

            if (!defined $read) {
                next;
            }

            if ($read == 0) {
                $selector->remove($fh);
                close $fh;
                next;
            }

            if ($fh == $child_out) {
                _append_capped(\$stdout, $chunk, $max_stdout, \$stdout_truncated);
            }
            else {
                _append_capped(\$stderr, $chunk, $max_stderr, \$stderr_truncated);
            }
        }
    }

    if (!$already_waited) {
        # mb220-B1: bounded reap. A script can close stdout+stderr (which ends
        # the select loop immediately at EOF) yet keep running — e.g. a script
        # that does close STDOUT then close STDERR then sleeps for an hour. An
        # unconditional waitpid($pid, 0) here would block the entire bot until
        # that child exits on its own, completely defeating the timeout that is
        # the whole point of ScriptRunner. Reap against the same deadline and
        # escalate TERM -> KILL if it is exceeded.
        while (1) {
            my $w = waitpid($pid, WNOHANG);
            if ($w == $pid) { $wait_status = $?; last; }
            if ($w == -1)   { $wait_status = 0; last; }  # child already gone

            if (time() > $deadline) {
                $timed_out = 1;
                kill 'TERM', $pid;
                sleep 0.2;
                if (waitpid($pid, WNOHANG) == 0) {
                    kill 'KILL', $pid;
                    waitpid($pid, 0);
                }
                $wait_status = $?;
                last;
            }

            sleep 0.05;
        }
    }

    my $exit_code = $timed_out ? undef : (($wait_status >> 8) & 0xff);
    my $signal    = $timed_out ? undef : ($wait_status & 0x7f);

    my $response = $timed_out
        ? { ok => 0, errors => [ 'script timed out' ], actions => [] }
        : $self->decode_script_response($stdout);

    return {
        ok               => (!$timed_out && defined($exit_code) && $exit_code == 0 && $response->{ok}) ? 1 : 0,
        timeout          => $timed_out ? 1 : 0,
        exit_code        => $exit_code,
        signal           => $signal,
        stdout           => $stdout,
        stderr           => $stderr,
        stdout_truncated => $stdout_truncated ? 1 : 0,
        stderr_truncated => $stderr_truncated ? 1 : 0,
        response         => $response,
    };
}

sub run_script {
    my ($self, $script_path, $event, %data) = @_;

    my $plan = $self->run_dry($script_path, $event, %data);
    return $plan unless ref($plan) eq 'HASH' && $plan->{ok};

    my $result = $self->run_plan($plan);

    # A5 (mb225): expose the resolved language and validated absolute path in
    # the result for observability (.scriptdryrun last, logs). Additive fields;
    # callers that ignore them are unaffected.
    if (ref($result) eq 'HASH') {
        $result->{lang}          = $plan->{language}  if defined $plan->{language};
        $result->{resolved_path} = $plan->{full_path} if defined $plan->{full_path};
    }

    return $result;
}


sub allowed_action_types {
    my ($self) = @_;
    return sort keys %{ $self->{allowed_actions} };
}

1;
