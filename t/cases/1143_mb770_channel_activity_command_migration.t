# MB770 — activity commands shadow, adopt and restore exact saved handlers.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

use Scalar::Util qw(refaddr);

{
    package T1143::Logger;
    sub new { bless { lines => [] }, shift }
    sub log { push @{ $_[0]{lines} }, $_[2]; 1 }
}

{
    package T1143::Activity;
    sub new { bless { calls => [] }, shift }
    sub compare {
        my ($self, %args) = @_;
        require Mediabot::Plugin::ActivityComparisonV3;
        push @{ $self->{calls} }, [compare => { %args }];
        return { ok => 1, comparison =>
            Mediabot::Plugin::ActivityComparisonV3->new(
                left => $args{left}, right => $args{right},
                left_count => 8, right_count => 2,
                period => $args{period}, period_label => 'all time') };
    }
    sub heatmap {
        my ($self, %args) = @_;
        require Mediabot::Plugin::ActivityHeatmapV3;
        push @{ $self->{calls} }, [heatmap => { %args }];
        return { ok => 1, heatmap =>
            Mediabot::Plugin::ActivityHeatmapV3->new(
                nick => $args{nick}, hours => [(0) x 24]) };
    }
}

{
    package T1143::Bot;
    sub new {
        require Mediabot::CommandRegistry;
        bless {
            registry => Mediabot::CommandRegistry->new,
            logger => T1143::Logger->new,
        }, shift;
    }
    sub command_registry { $_[0]{registry} }
    sub registry { $_[0]{registry} }
    sub getUserChannelLevel { 0 }
}

{
    package T1143::Context;
    sub new {
        my ($class, %args) = @_;
        bless {
            command => $args{command}, args => $args{args} || [],
            replies => [], notices => [],
        }, $class;
    }
    sub nick { 'Luna' }
    sub channel { '#test' }
    sub command { $_[0]{command} }
    sub args { $_[0]{args} }
    sub is_private { 0 }
    sub user { undef }
    sub reply { push @{ $_[0]{replies} }, $_[1]; 1 }
    sub reply_private { push @{ $_[0]{notices} }, $_[1]; 1 }
}

return sub {
    my ($assert) = @_;
    require Mediabot::PluginManager;

    my $bot = T1143::Bot->new;
    my (%original, %legacy_calls);
    for my $name (qw(compare heatmap)) {
        my $handler = sub { $legacy_calls{$name}++; 1 };
        $original{$name} = $handler;
        $bot->{registry}->register_command(
            name => $name, source => 'public', handler => $handler,
            category => 'core', metadata => {
                builtin => 1, dispatch => 'registry', syntax => $name,
                migration_fallback => 1,
            });
    }

    my $activity = T1143::Activity->new;
    my $manager = Mediabot::PluginManager->new(
        bot => $bot, plugin_dir => 'plugins',
        v3_channel_activity_service => $activity);
    $manager->load_package_v3('channel-activity-v3', grants => [
        qw(data.channel_activity.read irc.reply irc.notice)
    ]);

    my $compare = $bot->{registry}->handler_for('compare', 'public');
    my $compare_ctx = T1143::Context->new(
        command => 'compare', args => [qw(luna neville)]);
    $compare->($compare_ctx);
    $assert->is($legacy_calls{compare}, 1,
        'disabled package preserves historical compare');
    $assert->is(scalar @{ $activity->{calls} }, 0,
        'disabled package performs no activity read');

    $manager->set_v3_channel_policy(
        'channel-activity-v3', '#test', mode => 'observe');
    $manager->enable('channel-activity-v3');
    $compare->($compare_ctx);
    $assert->is($legacy_calls{compare}, 2,
        'observe invokes the saved compare handler exactly once');
    $assert->is(scalar @{ $activity->{calls} }, 1,
        'observe performs one side-effect-free comparison');
    $assert->is(scalar @{ $compare_ctx->{replies} }, 0,
        'observe suppresses every v3 comparison reply');

    $manager->set_v3_channel_policy(
        'channel-activity-v3', '#test', mode => 'on');
    $compare->($compare_ctx);
    $assert->is($legacy_calls{compare}, 2,
        'on suppresses the historical comparison path');
    $assert->is($activity->{calls}[-1][0], 'compare',
        'on uses the approved comparison service');
    $assert->is($compare_ctx->{replies}[-1],
        '[all time] luna: 8 msg(s) (80%) | neville: 2 msg(s) (20%) | luna leads by 6 msg(s)',
        'on emits one historical-format comparison');

    my $heatmap = $bot->{registry}->handler_for('heatmap', 'public');
    my $heatmap_ctx = T1143::Context->new(
        command => 'heatmap', args => ['luna']);
    $heatmap->($heatmap_ctx);
    $assert->is($activity->{calls}[-1][0], 'heatmap',
        'on uses the approved heatmap service');
    $assert->is(scalar @{ $heatmap_ctx->{replies} }, 5,
        'empty authoritative heatmap has one header and four blocks');
    $assert->is($legacy_calls{heatmap} // 0, 0,
        'on never duplicates the historical heatmap');

    $manager->set_v3_channel_policy(
        'channel-activity-v3', '#test', mode => 'off');
    $compare->($compare_ctx);
    $heatmap->($heatmap_ctx);
    $assert->is($legacy_calls{compare}, 3,
        'off immediately restores historical compare');
    $assert->is($legacy_calls{heatmap}, 1,
        'off immediately restores historical heatmap');

    $manager->unregister_plugin('channel-activity-v3');
    for my $name (qw(compare heatmap)) {
        my $restored = $bot->{registry}->command_for($name, 'public');
        $assert->is(refaddr($restored->{handler}), refaddr($original{$name}),
            "unload restores the exact $name handler reference");
    }
};
