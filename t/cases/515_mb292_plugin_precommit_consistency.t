#!/usr/bin/env perl
use strict;
use warnings;
use FindBin qw($Bin);
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

my $mediabot = slurp('Mediabot/Mediabot.pm');
my $runner = slurp('Mediabot/ScriptRunner.pm');
my $actions = slurp('Mediabot/ScriptActionRunner.pm');
my $bridge = slurp('Mediabot/Plugin/ScriptDryRun.pm');
my $partyline_test = slurp('t/cases/419_mb180_partyline_scriptdryrun_status.t');
my $runner_test = slurp('t/cases/413_mb174_script_runner_foundation.t');
my $actions_test = slurp('t/cases/416_mb177_script_action_runner_dryrun.t');
my $bridge_test = slurp('t/cases/418_mb179_script_dryrun_plugin_bridge.t');
my $routes_test = slurp('t/cases/423_mb184_scriptdryrun_command_routes.t');
my $apply_test = slurp('t/cases/425_mb186_script_action_runner_apply_gate.t');
my $test_runner = slurp('t/test_commands.pl');

unlike($mediabot, qr/foundation used by future plugin|minimal event bus foundation|future plugin\/dispatch work/,
    'Mediabot accessors no longer describe active components as future foundations');
like($mediabot, qr/active external Perl\/Python\/Tcl script runtime/,
    'Mediabot accessor documents the active multilingual script runtime');
like($mediabot, qr/active plugin manager/,
    'Mediabot accessor documents the active plugin manager');
like($mediabot, qr/active internal event bus/,
    'Mediabot accessor documents the active EventBus');
like($mediabot, qr/active command registry/,
    'Mediabot accessor documents the active command registry');

like($runner, qr/executes scripts out-of-process without a shell/,
    'ScriptRunner current execution comment remains present');
like($actions, qr/explicitly gated applier/,
    'ScriptActionRunner current apply comment remains present');
like($bridge, qr/supports two explicit modes/,
    'ScriptDryRun current dual-mode comment remains present');

unlike($runner_test, qr/deliberately does not execute external scripts yet/,
    'MB174 test no longer expects the obsolete non-executing runner');
unlike($actions_test, qr/dry-run planning only|documents dry-run only/,
    'MB177 test no longer expects a dry-run-only action layer');
unlike($bridge_test, qr/mb179-B1: trusted in-process Perl bridge/,
    'MB179 test no longer expects the obsolete Perl-only header');
unlike($partyline_test, qr/action mode: dry-run only/,
    'MB180 test no longer expects obsolete partyline config text');
unlike($routes_test, qr/mb184-B1: optional command-to-script route map/,
    'MB184 test no longer expects the removed historical route marker');
unlike($apply_test, qr/real action application is behind an explicit gate/,
    'MB186 test follows the current explicit-gates marker');

like($test_runner, qr/use overload.*?'&\{\}'/s,
    'static test runner supports callable legacy assertion objects');
like($test_runner, qr/local \$FindBin::Bin = dirname\(\$file\)/,
    'static test runner localizes FindBin for loaded legacy cases');
like($test_runner, qr/failed regex evaluated in list context/s,
    'static test runner detects collapsed failed-regex assertions');

done_testing();
