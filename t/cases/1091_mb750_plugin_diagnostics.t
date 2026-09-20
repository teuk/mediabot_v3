# MB750 — detached, read-only API v3 operational diagnostics.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

return sub {
    my ($assert) = @_;
    require Mediabot::Plugin::DiagnosticsV3;

    my $entry = {
        name => 'witness-v3', version => '1.0.0', enabled => 0,
        metadata => {
            requested_capabilities => [qw(events.subscribe irc.reply)],
            granted_capabilities => ['irc.reply'],
            effective_capabilities => ['irc.reply'],
        },
        manifest => {
            api => 3,
            commands => { hello => {} },
            events => [{ name => 'scheduler.minute' }],
            jobs => {},
        },
        mounted_commands => [{ name => 'hello', restore => { name => 'hello' } }],
        event_listeners => [],
        mounted_jobs => [],
    };
    my @policies = (
        { channel => '#Room[One]', mode => 'observe', config => { secret => 'hidden' } },
        { channel => '#off', mode => 'off', config => {} },
    );

    my $permissions = Mediabot::Plugin::DiagnosticsV3->permissions(
        entry => $entry);
    $assert->is($permissions->{status}, 'partial',
        'missing requested capability makes the grant partial');
    $assert->is(join(',', @{ $permissions->{missing} }), 'events.subscribe',
        'missing capability is computed from the effective intersection');
    $permissions->{effective}[0] = 'mutated';
    $assert->is($entry->{metadata}{effective_capabilities}[0], 'irc.reply',
        'permission report is detached from manager state');

    my $report = Mediabot::Plugin::DiagnosticsV3->report(
        entry => $entry, policies => \@policies);
    $assert->is($report->{status}, 'inactive',
        'disabled lifecycle wins over channel readiness');
    $assert->is($report->{reason}, 'plugin_disabled',
        'disabled diagnosis has a stable machine reason');
    $assert->is($report->{policies}{active}, 1,
        'active policy count excludes explicit off channels');
    $assert->is($report->{runtime}{saved_handlers}, 1,
        'diagnosis counts captured rollback handlers');
    $assert->ok(!exists($report->{policies}{config}),
        'diagnosis does not expose channel configuration values');

    $entry->{enabled} = 1;
    $report = Mediabot::Plugin::DiagnosticsV3->report(
        entry => $entry, policies => \@policies);
    $assert->is($report->{status}, 'limited',
        'enabled package with an active channel reports missing grants');
    $assert->is($report->{reason}, 'missing_capabilities',
        'limited diagnosis explains its capability boundary');

    $entry->{metadata}{granted_capabilities} =
        [qw(events.subscribe irc.reply)];
    $entry->{metadata}{effective_capabilities} =
        [qw(events.subscribe irc.reply)];
    $report = Mediabot::Plugin::DiagnosticsV3->report(
        entry => $entry, policies => \@policies);
    $assert->is($report->{status}, 'ready',
        'complete grants plus active policy are operationally ready');

    my $why = Mediabot::Plugin::DiagnosticsV3->explain_channel(
        entry => $entry, channel => '#room{one}',
        policy => $policies[0], policies => \@policies);
    $assert->is($why->{decision}, 'shadow',
        'observe mode is described as a shadow execution');
    $assert->is($why->{configured}, 1,
        'configured detection follows IRC RFC1459 casemapping');
    $assert->is($why->{plugin_runs}, 1,
        'observe mode executes plugin code');
    $assert->is($why->{output_allowed}, 0,
        'observe mode suppresses plugin output');
    $assert->is($why->{fallback_visible}, 1,
        'observe keeps a captured historical handler visible');

    $why = Mediabot::Plugin::DiagnosticsV3->explain_channel(
        entry => $entry, channel => '#new',
        policy => { channel => '#new', mode => 'off', config => {} },
        policies => \@policies);
    $assert->is($why->{decision}, 'blocked',
        'default-off channel is described as blocked');
    $assert->is($why->{configured}, 0,
        'unconfigured channel is distinguished from explicit off');
};
