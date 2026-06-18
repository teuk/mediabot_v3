# t/cases/514_mb291_plugin_bridge_docs_contract.t
# Keep the public plugin examples/documentation aligned with the current bridge:
# dry-run + apply modes, conflict-safe aliases, and dynamic usage text.

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../..";
use File::Spec;
use Test::More;

my $root = File::Spec->rel2abs("$Bin/../..");
sub slurp {
    my ($rel) = @_;
    my $path = File::Spec->catfile($root, split m{/}, $rel);
    open my $fh, '<', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

my $bridge = slurp('Mediabot/Plugin/ScriptDryRun.pm');
my $runner = slurp('Mediabot/ScriptRunner.pm');
my $actions = slurp('Mediabot/ScriptActionRunner.pm');
my $partyline = slurp('Mediabot/Partyline.pm');
my $manager = slurp('Mediabot/PluginManager.pm');
my $sample = slurp('mediabot.sample.conf');
my $readme = slurp('plugins/scripts/README.md');
my $hello_perl = slurp('plugins/scripts/examples/hello_perl.pl');
my $hello_python = slurp('plugins/scripts/examples/hello_python.py');
my $hello_tcl = slurp('plugins/scripts/examples/hello_tcl.tcl');
my $roll = slurp('plugins/scripts/examples/roll.py');
my $calc = slurp('plugins/scripts/examples/calc.py');

unlike($bridge, qr/deliberately never applies actions|not an IRC feature yet/,
    'ScriptDryRun header no longer describes the obsolete dry-run-only bridge');
like($bridge, qr/supports two explicit modes.*dry-run.*apply/s,
    'ScriptDryRun header documents dry-run and apply modes');
unlike($runner, qr/does not execute external scripts yet/,
    'ScriptRunner header describes the active execution runtime');
unlike($actions, qr/performs dry-run planning only|not wired to ScriptDryRun automatically/,
    'ScriptActionRunner comments describe gated application');
like($partyline, qr/show external script bridge status and last run/,
    'partyline help is mode-neutral');
like($manager, qr/plugin register failed'\) \. "\\n"/,
    'PluginManager register failure uses a clean escaped newline');

for my $pair (
    [ 'Perl',   $hello_perl ],
    [ 'Python', $hello_python ],
    [ 'Tcl',    $hello_tcl ],
) {
    unlike($pair->[1], qr/produced a dry-run action plan/,
        "$pair->[0] hello example uses mode-neutral log text");
    like($pair->[1], qr/produced an action plan/,
        "$pair->[0] hello example documents the current action plan");
}

unlike($roll, qr/tools\/mb_plugin_dev\.pl/,
    'roll example no longer references a missing development tool');
like($sample, qr/AUTOLOAD=0/, 'sample config keeps plugin autoload disabled by default');
like($sample, qr/COMMANDS=hello,pyhello,tclhello,proll,p8ball,pchoose,pcalc/,
    'sample config documents all conflict-safe routes');
like($sample, qr/ACTION_MODE=apply.*ALLOW_IRC=yes.*APPLY_REQUIRE_SCOPE=yes/s,
    'sample config documents the guarded live mode');
like($readme, qr/Mediabot external script plugins/,
    'external plugin README exists');
like($readme, qr/`proll`.*`p8ball`.*`pchoose`.*`pcalc`/s,
    'README explains conflict-safe aliases');

require Mediabot::ScriptRunner;
require Mediabot::ScriptActionRunner;
my $examples = File::Spec->catdir($root, 'plugins', 'scripts', 'examples');
my $sr = Mediabot::ScriptRunner->new(script_dir => $examples, timeout => 5);
my $ar = Mediabot::ScriptActionRunner->new;

{
    my $r = $sr->run_script('roll.py', 'public_command',
        channel => '#teuk', nick => 'teuk', command => 'proll', args => [ 'bad' ]);
    my $plan = $ar->apply_actions_dry($r, { channel => '#teuk' });
    like($plan->{planned}[0]{text}, qr/\bproll\b/, 'roll usage reflects routed alias');
    unlike($plan->{planned}[0]{text}, qr/!roll\b/, 'roll usage does not advertise the internal command');
}

{
    my $r = $sr->run_script('choose.pl', 'public_command',
        channel => '#teuk', nick => 'teuk', command => 'pchoose', args => [ 'solo' ]);
    my $plan = $ar->apply_actions_dry($r, { channel => '#teuk' });
    like($plan->{planned}[0]{text}, qr/\bpchoose\b/, 'choose usage reflects routed alias');
    unlike($plan->{planned}[0]{text}, qr/!choose\b/, 'choose usage does not advertise the internal command');
}


{
    my $r = $sr->run_script('calc.py', 'public_command',
        channel => '#teuk', nick => 'teuk', command => 'pcalc', args => []);
    my $plan = $ar->apply_actions_dry($r, { channel => '#teuk' });
    like($plan->{planned}[0]{text}, qr/\bpcalc\b/, 'calculator usage reflects routed alias');
    unlike($plan->{planned}[0]{text}, qr/!calc\b/, 'calculator usage does not advertise the internal command');
}

SKIP: {
    my $tclsh;
    for my $dir (split /:/, $ENV{PATH} || '') {
        my $candidate = File::Spec->catfile($dir, 'tclsh');
        if (-x $candidate) { $tclsh = $candidate; last; }
    }
    skip 'tclsh not available', 2 unless $tclsh;

    my $r = $sr->run_script('eightball.tcl', 'public_command',
        channel => '#teuk', nick => 'teuk', command => 'p8ball', args => []);
    my $plan = $ar->apply_actions_dry($r, { channel => '#teuk' });
    like($plan->{planned}[0]{text}, qr/\bp8ball\b/, '8-ball usage reflects routed alias');
    unlike($plan->{planned}[0]{text}, qr/!8ball\b/, '8-ball usage does not advertise the internal command');
}

done_testing();
