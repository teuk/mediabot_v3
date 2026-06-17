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

my $pm       = slurp('Mediabot/PluginManager.pm');
my $bus      = slurp('Mediabot/EventBus.pm');
my $registry = slurp('Mediabot/CommandRegistry.pm');
my $party    = slurp('Mediabot/Partyline.pm');
my $runner   = slurp('Mediabot/ScriptRunner.pm');

like($pm, qr/Active manager for trusted in-process Perl plugins/,
    'PluginManager header describes the active manager');
like($pm, qr/plugins\.AUTOLOAD boot gate/,
    'PluginManager header documents the autoload gate');
like($pm, qr/ScriptRunner across the mediabot-script-v1 boundary/,
    'PluginManager header documents the external-script boundary');
unlike($pm, qr/minimal plugin manager foundation|before we add any external Perl\/Python\/Tcl|core later decides/,
    'PluginManager no longer describes the pre-runtime architecture');

like($bus, qr/Active internal event bus used by core hooks and trusted plugins/,
    'EventBus header describes the active bus');
like($bus, qr/public_command_observed event powers plugin observation/,
    'EventBus header documents its current plugin event');
unlike($bus, qr/does not change current Mediabot behavior yet|It will allow future core code/,
    'EventBus no longer describes an unused future foundation');

like($registry, qr/Active command registry used alongside Mediabot's legacy dispatch tables/,
    'CommandRegistry header describes current hybrid dispatch');
like($registry, qr/compatibility fallback for commands not registered here yet/,
    'CommandRegistry header documents the legacy fallback');
unlike($registry, qr/does not change the existing Mediabot dispatch yet|eventually to let internal plugins/,
    'CommandRegistry no longer describes a future-only component');

like($party, qr/Read-only Partyline visibility for the active PluginManager state/,
    'Partyline comment describes active plugin visibility');
unlike($party, qr/new plugin foundation/,
    'Partyline comment no longer calls PluginManager a new foundation');

like($runner, qr/tests or other trusted internal callers/,
    'ScriptRunner stdin comment describes current trusted callers');
unlike($runner, qr/tests or future plugins/,
    'ScriptRunner stdin comment no longer points only to future plugins');

done_testing();
