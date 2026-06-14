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
use Cwd ();
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
use Errno ();

# ---------------------------------------------------------------------------
# Mediabot::ScriptRunner
# ---------------------------------------------------------------------------
# mb174-B1: external script runner foundation.
#
# This module deliberately does not execute external scripts yet. It defines the
# safety boundary and JSON protocol helpers we will need before allowing Perl,
# Python or Tcl scripts to be run out-of-process.
# ---------------------------------------------------------------------------

sub new {
    my ($class, %args) = @_;

    my $script_dir = defined $args{script_dir} && length $args{script_dir}
        ? $args{script_dir}
        : 'plugins/scripts';

    my $timeout = defined $args{timeout} ? int($args{timeout}) : 3;
    $timeout = 1  if $timeout < 1;
    $timeout = 30 if $timeout > 30;

    my $max_stdout = defined $args{max_stdout_bytes} ? int($args{max_stdout_bytes}) : 65536;
    $max_stdout = 1024    if $max_stdout < 1024;
    $max_stdout = 1048576 if $max_stdout > 1048576;

    # mb246-B1: keep stdin bounded at the runner boundary too. Normal
    # ScriptDryRun payloads are tiny IRC event envelopes, but run_plan() is a
    # public internal execution boundary and can receive handcrafted plans in
    # tests or future plugins. Refuse oversized stdin before spawning a child.
    # The upper bound stays above the historical mb221 stress payload so that
    # the deadline-bounded nonblocking stdin path remains covered by tests.
    my $max_stdin = defined $args{max_stdin_bytes} ? int($args{max_stdin_bytes}) : 4194304;
    $max_stdin = 1024    if $max_stdin < 1024;
    $max_stdin = 4194304 if $max_stdin > 4194304;

    my $max_actions = defined $args{max_actions} ? int($args{max_actions}) : 20;
    $max_actions = 1  if $max_actions < 1;
    $max_actions = 50 if $max_actions > 50;

    return bless {
        bot              => $args{bot},
        script_dir       => $script_dir,
        timeout          => $timeout,
        max_stdout_bytes => $max_stdout,
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

    return 'perl'   if $path =~ /\.pl\z/i;
    return 'python' if $path =~ /\.py\z/i;
    return 'tcl'    if $path =~ /\.tcl\z/i;

    return undef;
}

sub validate_script_path {
    my ($self, $path) = @_;

    return (0, 'missing script path') unless defined $path && length $path;

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

    # Walk up to the deepest existing path component.
    my $probe = $full_path;
    while (length $probe && !-e $probe) {
        my $next = $probe;
        $next =~ s{/[^/]+/?\z}{};
        last if !length $next || $next eq $probe;
        $probe = $next;
    }

    # Nothing exists to resolve (script_dir itself missing): lexical checks
    # already passed, let the later exec fail cleanly.
    return (1, undef) unless length $probe && -e $probe;

    my $real_probe = Cwd::abs_path($probe);
    return (0, 'unable to resolve script path') unless defined $real_probe;

    unless (index($real_probe . '/', $dir_prefix) == 0) {
        return (0, 'script path escapes script directory');
    }

    return (1, undef);
}

sub build_event_payload {
    my ($self, $event, %data) = @_;

    $event = 'unknown' unless defined $event && length $event;

    return {
        protocol => 'mediabot-script-v1',
        event    => $event,
        data     => \%data,
    };
}

sub encode_event_payload {
    my ($self, $payload) = @_;

    return encode_json($payload || {});
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

    my $lang = lc "$language";

    return [ $^X ]       if $lang eq 'perl';
    return [ 'python3' ] if $lang eq 'python';
    return [ 'tclsh' ]   if $lang eq 'tcl';

    return undef;
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

    my $json = $self->encode_event_payload($payload || {});

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

sub _argv_same {
    my ($left, $right) = @_;

    return 0 unless ref($left) eq 'ARRAY' && ref($right) eq 'ARRAY';
    return 0 unless @$left == @$right;

    for my $idx (0 .. $#$left) {
        return 0 unless defined $left->[$idx] && defined $right->[$idx];
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
    return 'missing script in execution plan'
        unless defined $plan->{script} && length "$plan->{script}";

    my ($ok, $err, $language, $full_path) = $self->validate_script_path($plan->{script});
    return $err unless $ok;

    my $plan_language = defined $plan->{language} ? lc "$plan->{language}" : '';
    $plan_language =~ s/^\s+|\s+$//g;
    return 'execution plan language mismatch'
        unless length($plan_language) && $plan_language eq $language;

    my $plan_full_path = defined $plan->{full_path} ? "$plan->{full_path}" : '';
    return 'execution plan full path mismatch'
        unless length($plan_full_path) && $plan_full_path eq $full_path;

    my $interp = $self->interpreter_for_language($language);
    return "no interpreter configured for language '$language'"
        unless $interp && ref($interp) eq 'ARRAY' && @$interp;

    my @expected = (@$interp, $full_path);
    return 'execution plan command must be an array'
        unless ref($plan->{command}) eq 'ARRAY';

    return 'execution plan command does not match validated script path'
        unless _argv_same($plan->{command}, \@expected);

    return undef;
}

sub run_plan {
    my ($self, $plan) = @_;

    my $plan_error = $self->_validate_execution_plan_for_run($plan);
    return _run_plan_failure($plan_error) if defined $plan_error;

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
    my $max_stderr = defined $plan->{max_stderr_bytes} ? int($plan->{max_stderr_bytes}) : $self->{max_stdout_bytes};

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
