# MB769 — capability and invocation-policy wiring for activity reads.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

use File::Path qw(make_path);
use File::Temp qw(tempdir);
use JSON::PP ();

{
    package T1140::ActivityService;
    sub new { bless { calls => [] }, shift }
    sub compare {
        my ($self, %args) = @_;
        push @{ $self->{calls} }, { operation => 'compare', %args };
        return { ok => 1, comparison => undef };
    }
    sub heatmap {
        my ($self, %args) = @_;
        push @{ $self->{calls} }, { operation => 'heatmap', %args };
        return { ok => 1, heatmap => undef };
    }
}

{
    package T1140::Log;
    sub new { bless { lines => [] }, shift }
    sub log { push @{ $_[0]{lines} }, $_[2]; 1 }
}

{
    package T1140::Bot;
    sub new {
        require Mediabot::CommandRegistry;
        bless {
            registry => Mediabot::CommandRegistry->new,
            logger => T1140::Log->new,
        }, shift;
    }
    sub command_registry { $_[0]{registry} }
    sub registry { $_[0]{registry} }
}

{
    package T1140::CommandContext;
    sub new { my ($class, %args) = @_; bless { %args }, $class }
    sub nick { 'Luna' }
    sub channel { $_[0]{channel} }
    sub args { [] }
    sub is_private { 0 }
    sub reply { 1 }
    sub reply_private { 1 }
}

return sub {
    my ($assert) = @_;
    require Mediabot::PluginManager;

    my $root = tempdir(CLEANUP => 1);
    my $package = "$root/activity-probe";
    make_path("$package/lib");
    open my $manifest_fh, '>:encoding(UTF-8)', "$package/plugin.json"
        or die $!;
    print {$manifest_fh} JSON::PP->new->canonical->encode({
        api => 3,
        name => 'activity-probe',
        version => '1.0.0',
        description => 'Channel activity facade probe.',
        runtime => {
            kind => 'perl', entrypoint => 'lib/ActivityProbe.pm',
            class => 'T1140::ActivityProbe',
        },
        compatibility => {}, activation => { default => 'off' },
        capabilities => ['data.channel_activity.read'],
        commands => {
            activityprobe => {
                source => 'public', help => 'Probe activity data.',
                level => 0, handler => 'probe', aliases => [],
            },
        },
        events => [], jobs => {}, config_schema => {},
    });
    close $manifest_fh;

    open my $plugin_fh, '>:encoding(UTF-8)',
        "$package/lib/ActivityProbe.pm" or die $!;
    print {$plugin_fh} <<'PLUGIN';
package T1140::ActivityProbe;
sub new { my ($class, %args) = @_; bless { %args }, $class }
sub probe {
    my ($self, $context, $invocation) = @_;
    $context->activity_compare(
        $invocation, 'Luna', 'Neville', period => '7d');
    return $context->activity_heatmap($invocation, 'Luna');
}
1;
PLUGIN
    close $plugin_fh;

    my $bot = T1140::Bot->new;
    my $activity = T1140::ActivityService->new;
    my $manager = Mediabot::PluginManager->new(
        bot => $bot, plugin_dir => $root,
        v3_channel_activity_service => $activity,
    );
    $manager->load_package_v3(
        'activity-probe', grants => ['data.channel_activity.read']);
    $manager->set_v3_channel_policy(
        'activity-probe', '#GreatHall', mode => 'observe', config => {});
    $manager->enable('activity-probe');

    my $handler = $bot->{registry}->handler_for('activityprobe', 'public');
    $handler->(T1140::CommandContext->new(channel => '#greathall'));
    $assert->is(scalar @{ $activity->{calls} }, 2,
        'observe may execute approved side-effect-free activity reads');
    $assert->is($activity->{calls}[0]{channel}, '#GreatHall',
        'core policy supplies the channel instead of plugin arguments');
    $assert->is($activity->{calls}[0]{period}, '7d',
        'only approved compare arguments cross the facade');
    $assert->is($activity->{calls}[1]{operation}, 'heatmap',
        'second approved operation reaches the service');

    $manager->set_v3_channel_policy(
        'activity-probe', '#greathall', mode => 'off', config => {});
    $handler->(T1140::CommandContext->new(channel => '#greathall'));
    $assert->is(scalar @{ $activity->{calls} }, 2,
        'off prevents plugin and activity service execution');

    my $context = $manager->plugin('activity-probe')
        ->{metadata}{plugin_context};
    $assert->ok(!$context->can('database') && !$context->can('sql'),
        'activity capability adds no database or SQL escape hatch');

    my $denied_bot = T1140::Bot->new;
    my $denied_activity = T1140::ActivityService->new;
    my $denied_manager = Mediabot::PluginManager->new(
        bot => $denied_bot, plugin_dir => $root,
        v3_channel_activity_service => $denied_activity,
    );
    $denied_manager->load_package_v3('activity-probe', grants => []);
    $denied_manager->set_v3_channel_policy(
        'activity-probe', '#greathall', mode => 'observe', config => {});
    $denied_manager->enable('activity-probe');
    my $denied_handler = $denied_bot->{registry}
        ->handler_for('activityprobe', 'public');
    my $ok = eval {
        $denied_handler->(T1140::CommandContext->new(channel => '#greathall'));
        1;
    };
    $assert->ok($ok && !$@,
        'ungranted activity capability failure is contained by the core');
    $assert->is(scalar @{ $denied_activity->{calls} }, 0,
        'ungranted activity capability never reaches the core service');
    $assert->like($denied_bot->{logger}{lines}[-1] // '',
        qr/capability 'data\.channel_activity\.read' was not granted/,
        'contained capability failure remains operator-visible');
};
