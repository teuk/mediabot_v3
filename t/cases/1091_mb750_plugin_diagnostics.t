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
        entry => $entry, policies => \@policies, failures => {
            total_failures => 2,
            affected_resources => 1,
            active_streaks => [{ consecutive_failures => 2 }],
            recent => [{ occurred_at => 123 }, { occurred_at => 456 }],
        }, quarantine => {
            total => 1,
            max_entries => 64,
            entries => [{ resource => 'must-not-leak' }],
        });
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
    $assert->is($report->{failures}{total}, 2,
        'doctor carries only the detached aggregate failure total');
    $assert->is($report->{failures}{last_failure_at}, 456,
        'doctor exposes the latest timestamp without an error message');
    $assert->ok(!exists($report->{failures}{recent_records}),
        'doctor does not duplicate detailed failure records');
    $assert->is($report->{quarantine}{total}, 1,
        'doctor carries only the detached quarantine aggregate');
    $assert->is($report->{quarantine}{max_entries}, 64,
        'doctor publishes the quarantine bound');
    $assert->ok(!exists($report->{quarantine}{entries}),
        'doctor does not duplicate quarantine entry details');

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

    $report = Mediabot::Plugin::DiagnosticsV3->report(
        entry => $entry, policies => \@policies,
        quarantine => { total => 1, max_entries => 64 });
    $assert->is($report->{status}, 'limited',
        'manual quarantine limits an otherwise ready plugin');
    $assert->is($report->{reason}, 'quarantined_resources',
        'limited diagnosis names the exact operator boundary');

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
