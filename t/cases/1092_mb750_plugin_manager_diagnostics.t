# MB750 — PluginManager exposes read-only operational truth for API v3.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

{
    package T1092::Logger;
    sub new { bless {}, shift }
    sub log { 1 }
}

{
    package T1092::Bot;
    sub new {
        require Mediabot::CommandRegistry;
        return bless {
            registry => Mediabot::CommandRegistry->new,
            logger => T1092::Logger->new,
        }, shift;
    }
    sub command_registry { $_[0]{registry} }
    sub registry { $_[0]{registry} }
}

return sub {
    my ($assert) = @_;
    require Mediabot::PluginManager;

    my $bot = T1092::Bot->new;
    my $manager = Mediabot::PluginManager->new(
        bot => $bot, plugin_dir => 'plugins');
    $manager->load_package_v3('hello-v3', grants => ['irc.reply']);
    $manager->set_v3_channel_policy('hello-v3', '#i/o',
        mode => 'observe', config => {
            greeting => 'Lumos', enthusiasm => 1, mention_nick => 0,
        });
    $manager->enable('hello-v3');

    my $permissions = $manager->v3_permissions_report('hello-v3');
    $assert->is(join(',', @{ $permissions->{effective} }), 'irc.reply',
        'manager reports the effective runtime intersection');
    $assert->is(join(',', @{ $permissions->{missing} }),
        'events.subscribe,scheduler.jobs',
        'manager names every requested but ungranted capability');

    my $report = $manager->v3_diagnostic_report('hello-v3');
    $assert->is($report->{status}, 'limited',
        'doctor reports an enabled partial-grant package as limited');
    $assert->is($report->{policies}{observe}, 1,
        'doctor sees the configured observe channel');
    $assert->is($report->{runtime}{mounted}{commands}, 1,
        'doctor counts the mounted command');
    $assert->is($report->{runtime}{mounted}{events}, 0,
        'ungranted event subscription is not mounted');
    $assert->is($report->{runtime}{mounted}{jobs}, 0,
        'ungranted scheduler job is not mounted');
    $assert->is($report->{failures}{total}, 0,
        'doctor starts with an empty instance-scoped failure summary');

    my $failures = $manager->v3_failure_report('hello-v3');
    $assert->is($failures->{max_recent}, 16,
        'manager publishes the fixed recent-history bound');
    $assert->is($failures->{total_failures}, 0,
        'manager failure view is initially empty');

    my $why = $manager->v3_channel_explanation(
        'hello-v3', '#I/O');
    $assert->is($why->{decision}, 'shadow',
        'manager explains current observe execution');
    $assert->is($why->{configured}, 1,
        'manager explanation follows policy casemapping');
    $assert->is($why->{output_allowed}, 0,
        'manager explanation reflects late output suppression');

    $why = $manager->v3_channel_explanation('hello-v3', '#elsewhere');
    $assert->is($why->{reason}, 'channel_off',
        'manager explains an unconfigured channel as default-off');

    my $ok = eval { $manager->v3_channel_explanation('hello-v3', 'bad'); 1 };
    $assert->like($@ // '', qr/invalid diagnostic channel/,
        'invalid diagnostic channel fails closed');
    $ok = eval { $manager->v3_diagnostic_report('missing'); 1 };
    $assert->like($@ // '', qr/not registered/,
        'unknown plugin diagnosis is explicit');
};
