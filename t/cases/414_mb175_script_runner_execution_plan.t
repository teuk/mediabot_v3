# t/cases/414_mb175_script_runner_execution_plan.t
use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;
use JSON::PP qw(decode_json);

my $case = sub {
    my ($assert) = @_;

    my $root = File::Spec->catdir($Bin, '..', '..');
    unshift @INC, $root;

    eval { require Mediabot::ScriptRunner; 1 }
        or do { $assert->(0, "cannot load Mediabot::ScriptRunner: $@"); return; };

    my $runner = Mediabot::ScriptRunner->new(
        script_dir       => 'plugins/scripts',
        timeout          => 5,
        max_stdout_bytes => 8192,
    );

    my $perl_interp = $runner->interpreter_for_language('perl');
    my $py_interp   = $runner->interpreter_for_language('python');
    my $tcl_interp  = $runner->interpreter_for_language('tcl');

    $assert->(ref($perl_interp) eq 'ARRAY' && @$perl_interp >= 1,
        'interpreter_for_language returns argv array for Perl');
    $assert->(ref($py_interp) eq 'ARRAY' && $py_interp->[0] eq 'python3',
        'interpreter_for_language returns python3 for Python');
    $assert->(ref($tcl_interp) eq 'ARRAY' && $tcl_interp->[0] eq 'tclsh',
        'interpreter_for_language returns tclsh for Tcl');
    $assert->(!defined $runner->interpreter_for_language('shell'),
        'interpreter_for_language rejects unsupported language');

    my $payload = $runner->build_event_payload(
        'public_command',
        channel => '#test',
        nick    => 'Te[u]K',
        command => 'hello',
        args    => [ 'world' ],
    );

    my $plan = $runner->build_execution_plan('demo/hello.py', $payload);

    $assert->($plan->{ok} && $plan->{dry_run},
        'build_execution_plan returns OK dry-run plan');
    $assert->($plan->{language} eq 'python',
        'execution plan records language');
    $assert->($plan->{script} eq 'demo/hello.py',
        'execution plan records original relative script');
    $assert->($plan->{full_path} eq 'plugins/scripts/demo/hello.py',
        'execution plan resolves full path under script_dir');
    $assert->(ref($plan->{command}) eq 'ARRAY' && join(' ', @{ $plan->{command} }) eq 'python3 plugins/scripts/demo/hello.py',
        'execution plan builds argv command without shell');
    $assert->($plan->{timeout} == 5 && $plan->{max_stdout_bytes} == 8192,
        'execution plan carries timeout and stdout limit');

    my $stdin = decode_json($plan->{stdin});
    $assert->($stdin->{protocol} eq 'mediabot-script-v1' && $stdin->{event} eq 'public_command',
        'execution plan stdin contains JSON protocol envelope');
    $assert->($stdin->{data}{channel} eq '#test' && $stdin->{data}{args}[0] eq 'world',
        'execution plan stdin contains event data');

    my $bad = $runner->build_execution_plan('../evil.py', $payload);
    $assert->(!$bad->{ok} && $bad->{error} =~ /parent directory/,
        'build_execution_plan refuses unsafe script path');

    my $bad_ext = $runner->build_execution_plan('demo/hello.sh', $payload);
    $assert->(!$bad_ext->{ok} && $bad_ext->{error} =~ /unsupported/,
        'build_execution_plan refuses unsupported extension');

    my $dry = $runner->run_dry(
        'games/duckhunt.tcl',
        'public_command',
        channel => '#boulets',
        nick    => 'Georgette',
        command => 'duckhunt',
    );

    $assert->($dry->{ok} && $dry->{language} eq 'tcl',
        'run_dry builds a Tcl execution plan');
    $assert->(join(' ', @{ $dry->{command} }) eq 'tclsh plugins/scripts/games/duckhunt.tcl',
        'run_dry Tcl command uses argv without shell');

    my $sr_file = File::Spec->catfile($root, 'Mediabot', 'ScriptRunner.pm');
    open my $sfh, '<', $sr_file
        or do { $assert->(0, "cannot open ScriptRunner.pm: $!"); return; };
    my $src = do { local $/; <$sfh> };
    close $sfh;

    $assert->($src =~ /mb175-B1: execution plan only/,
        'ScriptRunner source contains mb175 marker');
    $assert->($src =~ /does not spawn/,
        'ScriptRunner source documents no spawn yet');
    $assert->($src !~ /\bsystem\s*\(|\bexec\s*\(|open3|IPC::Open3|qx\//,
        'ScriptRunner still does not execute external commands');
};

if (caller) { return $case; }

my $tests = 0;
my $fail  = 0;

my $assert = sub {
    my ($ok, $name) = @_;
    $tests++;
    $name = 'unnamed assertion' unless defined $name && $name ne '';

    if ($ok) {
        print "ok $tests - $name\n";
    }
    else {
        print "not ok $tests - $name\n";
        $fail++;
    }
};

$case->($assert);
print "1..$tests\n";
exit($fail ? 1 : 0);
