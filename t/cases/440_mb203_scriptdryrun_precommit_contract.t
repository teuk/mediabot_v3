#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use File::Spec;
use FindBin qw($Bin);

my @fail;
my $tests = 0;

sub ok {
    my ($cond, $msg) = @_;
    $tests++;
    if ($cond) {
        print "ok $tests - $msg\n";
    }
    else {
        print "not ok $tests - $msg\n";
        push @fail, $msg;
    }
}

sub slurp {
    my ($path) = @_;
    open my $fh, '<', $path or die "cannot open $path: $!";
    local $/;
    my $s = <$fh>;
    close $fh;
    return $s;
}

sub has_no_shell_danger {
    my ($src) = @_;
    return ($src !~ /\bsystem\s*\(/ && $src !~ /qx\s*[\/`]/ && $src !~ /`[^`]+`/);
}

my $root = File::Spec->rel2abs(File::Spec->catdir($Bin, '..', '..'));
unshift @INC, $root;

my @required_files = qw(
    Mediabot/Plugin/ScriptDryRun.pm
    Mediabot/ScriptRunner.pm
    Mediabot/ScriptActionRunner.pm
    plugins/scripts/examples/hello_perl.pl
    plugins/scripts/examples/hello_python.py
    plugins/scripts/examples/hello_tcl.tcl
    mediabot.sample.conf
);

for my $rel (@required_files) {
    my $path = File::Spec->catfile($root, split m{/}, $rel);
    ok(-f $path, "required file exists: $rel");
    ok(-s $path, "required file is not empty: $rel") if -f $path;
}

eval { require Mediabot::Plugin::ScriptDryRun; 1 };
ok(!$@, 'ScriptDryRun loads');
eval { require Mediabot::ScriptRunner; 1 };
ok(!$@, 'ScriptRunner loads');
eval { require Mediabot::ScriptActionRunner; 1 };
ok(!$@, 'ScriptActionRunner loads');

my $scriptdryrun_src = slurp(File::Spec->catfile($root, 'Mediabot', 'Plugin', 'ScriptDryRun.pm'));
my $runner_src       = slurp(File::Spec->catfile($root, 'Mediabot', 'ScriptRunner.pm'));
my $action_src       = slurp(File::Spec->catfile($root, 'Mediabot', 'ScriptActionRunner.pm'));
my $sample_conf      = slurp(File::Spec->catfile($root, 'mediabot.sample.conf'));

for my $marker (
    'mb194-B1: Config::Simple can return ARRAY refs',
    'mb195-B1: Config::Simple can return ARRAY refs for boolean plugin',
    'mb196-B1: lightweight ScriptDryRun runtime logging',
    'mb202-B1: centralize runtime logging with elapsed_ms',
) {
    ok(index($scriptdryrun_src, $marker) >= 0, "ScriptDryRun keeps marker: $marker");
}

for my $marker (
    'mb176-B1: real subprocess execution',
) {
    ok(index($runner_src, $marker) >= 0, "ScriptRunner keeps marker: $marker");
}

for my $marker (
    'mb186-B1: real action application is behind an explicit gate',
    'mb199-B1:',
    'mb200-B1:',
) {
    ok(index($action_src, $marker) >= 0, "ScriptActionRunner keeps marker: $marker");
}

ok($runner_src =~ /use\s+IPC::Open3\s+qw\(open3\)/, 'ScriptRunner uses IPC::Open3 open3');
ok($runner_src =~ /open3\s*\([^\n]*\@cmd/s, 'ScriptRunner calls open3 with argv array');
ok(has_no_shell_danger($scriptdryrun_src), 'ScriptDryRun has no shell execution');
ok(has_no_shell_danger($action_src), 'ScriptActionRunner has no shell execution');
ok($runner_src !~ /\bsystem\s*\(/ && $runner_src !~ /qx\s*[\/`]/, 'ScriptRunner has no system/qx shell execution');

ok($sample_conf =~ /^#?\[plugins\]/m, 'sample conf documents [plugins] section');
ok($sample_conf =~ /^#?AUTOLOAD=0/m, 'sample conf keeps plugin autoload disabled by default');
ok($sample_conf =~ /^#?ENABLED=Mediabot::Plugin::ScriptDryRun/m, 'sample conf documents ScriptDryRun plugin enable line');
ok($sample_conf =~ /^#?\[plugins\.ScriptDryRun\]/m, 'sample conf documents [plugins.ScriptDryRun] section');
ok($sample_conf =~ /^#?ACTION_MODE=dry-run/m, 'sample conf documents dry-run default');
ok($sample_conf =~ /^#?ALLOW_IRC=no/m, 'sample conf documents IRC disabled default');
ok($sample_conf =~ /^#?APPLY_REQUIRE_SCOPE=yes/m, 'sample conf documents apply scope guard');
ok($sample_conf =~ /ROUTES=.*hello=.*hello_perl\.pl.*pyhello=.*hello_python\.py.*tclhello=.*hello_tcl\.tcl/s, 'sample conf documents Perl/Python/Tcl routes');

{
    package MB203::ArrayConf;
    sub new { my ($class, %data) = @_; return bless \%data, $class; }
    sub get { my ($self, $key) = @_; return $self->{$key}; }

    package MB203::FakeBot;
    sub new { my ($class, $conf) = @_; return bless { conf => $conf }, $class; }
}

my $array_conf = MB203::ArrayConf->new(
    'plugins.ScriptDryRun.ROUTES' => [
        'hello=examples/hello_perl.pl',
        'pyhello=examples/hello_python.py, tclhello=examples/hello_tcl.tcl',
    ],
    'plugins.ScriptDryRun.ACTION_MODE'         => [ 'apply' ],
    'plugins.ScriptDryRun.ALLOW_IRC'           => [ 'yes' ],
    'plugins.ScriptDryRun.APPLY_REQUIRE_SCOPE' => [ 'yes' ],
);

my $plugin = Mediabot::Plugin::ScriptDryRun->register(MB203::FakeBot->new($array_conf));
ok($plugin->command_routes_enabled, 'array config enables route map');
ok($plugin->script_for_command('hello') eq 'examples/hello_perl.pl', 'array config routes hello to Perl');
ok($plugin->script_for_command('pyhello') eq 'examples/hello_python.py', 'array config routes pyhello to Python');
ok($plugin->script_for_command('tclhello') eq 'examples/hello_tcl.tcl', 'array config routes tclhello to Tcl');
ok($plugin->action_mode eq 'apply', 'array config parses ACTION_MODE=apply');
ok($plugin->allow_irc, 'array config parses ALLOW_IRC=yes');
ok($plugin->apply_require_scope, 'array config parses APPLY_REQUIRE_SCOPE=yes');
ok($plugin->apply_scope_is_restricted, 'routes satisfy apply scope guard');
ok(!$plugin->command_allowed('check'), 'routes-only config does not swallow unrelated command');

{
    package MB203::FakeIRC;
    sub new { bless { messages => [] }, shift }
    sub send_message { my ($self, @args) = @_; push @{ $self->{messages} }, \@args; return 1; }
    sub messages { @{ $_[0]->{messages} } }

    package MB203::FakeLogger;
    sub new { bless { logs => [] }, shift }
    sub log { my ($self, @args) = @_; push @{ $self->{logs} }, \@args; return 1; }
    sub info { my ($self, @args) = @_; push @{ $self->{logs} }, [ 'info', @args ]; return 1; }
    sub logs { @{ $_[0]->{logs} } }

    package MB203::FakeRuntimeBot;
    sub new { bless { irc => MB203::FakeIRC->new, logger => MB203::FakeLogger->new }, shift }
}

my $runtime_bot = MB203::FakeRuntimeBot->new;
my $runner = Mediabot::ScriptRunner->new(
    bot              => $runtime_bot,
    script_dir       => File::Spec->catdir($root, 'plugins', 'scripts'),
    timeout          => 5,
    max_stdout_bytes => 65536,
);
my $applier = Mediabot::ScriptActionRunner->new(bot => $runtime_bot);

my @cases = (
    [ hello    => 'examples/hello_perl.pl',   'Perl script bridge OK for command: hello' ],
    [ pyhello  => 'examples/hello_python.py', 'Python script bridge OK for command: pyhello' ],
    [ tclhello => 'examples/hello_tcl.tcl',   'Tcl script bridge OK for command: tclhello' ],
);

my $expected_messages = 0;
for my $case (@cases) {
    my ($command, $script, $expected_text) = @$case;
    my $script_result = $runner->run_script(
        $script,
        'public_command',
        channel => '#mb203',
        target  => '#mb203',
        nick    => 'Te[u]K',
        command => $command,
        args    => [],
    );

    ok(ref($script_result) eq 'HASH' && $script_result->{ok}, "$command script result is OK");
    ok(($script_result->{exit_code} // -1) == 0, "$command exits cleanly");
    ok(ref($script_result->{response}{actions}) eq 'ARRAY' && @{ $script_result->{response}{actions} } == 2, "$command returns two actions");

    my $plan = $applier->apply_actions(
        $script_result,
        { event => 'public_command', channel => '#mb203', target => '#mb203', nick => 'Te[u]K', command => $command, args => [] },
        apply     => 1,
        allow_irc => 1,
    );

    ok(ref($plan) eq 'HASH' && $plan->{applied_ok}, "$command action plan applies cleanly");
    my @messages = $runtime_bot->{irc}->messages;
    $expected_messages++;
    ok(@messages == $expected_messages, "$command sends one IRC message");
    ok($messages[-1][0] eq 'PRIVMSG', "$command sends PRIVMSG");
    ok($messages[-1][2] eq '#mb203', "$command target is default channel");
    ok($messages[-1][3] eq $expected_text, "$command visible text matches contract");
}

my @logs = $runtime_bot->{logger}->logs;
ok(@logs == 3, 'three log actions applied across Perl/Python/Tcl smoke');

print "1..$tests\n";
if (@fail) {
    print "FAILED: @fail\n";
    exit 1;
}
exit 0;
