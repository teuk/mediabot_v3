# MB743 — API v3 event and shared-job ownership across plugin lifecycle.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

{
    package T1072::Log;
    sub new { bless { lines => [] }, shift }
    sub log { push @{ $_[0]{lines} }, $_[2]; 1 }
}

{
    package T1072::Loop;
    sub new { bless { later => [] }, shift }
    sub later { push @{ $_[0]{later} }, $_[1]; 1 }
    sub run_all {
        my ($self) = @_;
        while (my $cb = shift @{ $self->{later} }) { $cb->() }
    }
}

{
    package T1072::Scheduler;
    sub new { bless { tasks => {} }, shift }
    sub add {
        my ($self, %args) = @_;
        die "duplicate task\n" if $self->{tasks}{ $args{name} };
        $self->{tasks}{ $args{name} } = { %args, started => 0 };
        return $self;
    }
    sub start {
        my ($self, $name) = @_;
        return 0 unless $self->{tasks}{$name};
        return 0 if $self->{fail_start};
        $self->{tasks}{$name}{started} = 1;
        return 1;
    }
    sub stop {
        my ($self, $name) = @_;
        return 0 unless $self->{tasks}{$name};
        $self->{tasks}{$name}{started} = 0;
        return 1;
    }
    sub remove {
        my ($self, $name) = @_;
        return delete($self->{tasks}{$name}) ? 1 : 0;
    }
    sub fire {
        my ($self, $name) = @_;
        my $task = $self->{tasks}{$name} or return 0;
        return 0 unless $task->{started};
        $task->{cb}->();
        return 1;
    }
}

{
    package T1072::Bot;
    sub new {
        require Mediabot::CommandRegistry;
        require Mediabot::EventBus;
        return bless {
            registry  => Mediabot::CommandRegistry->new,
            event_bus => Mediabot::EventBus->new,
            loop      => T1072::Loop->new,
            scheduler => T1072::Scheduler->new,
            logger    => T1072::Log->new,
        }, shift;
    }
    sub command_registry { $_[0]{registry} }
    sub registry { $_[0]{registry} }
    sub events { $_[0]{event_bus} }
    sub getLoop { $_[0]{loop} }
}

return sub {
    my ($assert) = @_;

    require Mediabot::PluginManager;
    my $bot = T1072::Bot->new;
    my $manager = Mediabot::PluginManager->new(
        bot => $bot, plugin_dir => 'plugins');
    my $entry = $manager->load_package_v3(
        'hello-v3',
        grants => ['events.subscribe', 'irc.reply', 'scheduler.jobs'],
        channel_policies => {
            '#i/o' => { mode => 'on', config => {} },
        },
    );

    my $task = 'plugin.v3.hello-v3.heartbeat';
    $assert->is($manager->is_enabled('hello-v3'), 0,
        'load keeps the event/job witness disabled');
    $assert->is($bot->{event_bus}->listener_count('plugin_cron_observed'), 1,
        'load mounts one owned EventBus bridge');
    $assert->ok(exists($bot->{scheduler}{tasks}{$task}),
        'load reserves one namespaced scheduler task');
    $assert->is($bot->{scheduler}{tasks}{$task}{started}, 0,
        'reserved job is not started by load');

    $bot->{event_bus}->emit('plugin_cron_observed', {
        minute => 1, hour => 2, dow => 3, mday => 4, month => 5, year => 2026,
    });
    $bot->{loop}->run_all;
    $assert->is($entry->{object}{minutes_observed}, 0,
        'disabled plugin receives no event');

    $manager->enable('hello-v3');
    $assert->is($entry->{object}{started}, 1,
        'enable starts the plugin object');
    $assert->is($bot->{scheduler}{tasks}{$task}{started}, 1,
        'enable starts the owned shared job');

    $bot->{event_bus}->emit('plugin_cron_observed', {
        minute => 6, hour => 7, dow => 4, mday => 18, month => 9, year => 2026,
    });
    $assert->is($entry->{object}{minutes_observed}, 0,
        'event delivery is deferred outside the EventBus stack');
    $bot->{loop}->run_all;
    $assert->is($entry->{object}{minutes_observed}, 1,
        'deferred versioned event reaches its declared handler');

    $assert->ok($bot->{scheduler}->fire($task),
        'central scheduler can fire the owned job');
    $assert->is($entry->{object}{heartbeats}, 1,
        'job handler receives one bounded invocation');

    for my $minute (0 .. 39) {
        $bot->{event_bus}->emit('plugin_cron_observed', {
            minute => $minute, hour => 7, dow => 4,
            mday => 18, month => 9, year => 2026,
        });
    }
    $assert->is($entry->{event_queue}->pending_count, 32,
        'plugin event burst is capped at 32 pending envelopes');
    $assert->is($entry->{event_queue}->dropped_count, 8,
        'overflow is accounted without growing the queue');
    $bot->{loop}->run_all;
    $assert->is($entry->{object}{minutes_observed}, 33,
        'accepted burst drains in bounded batches');

    $bot->{event_bus}->emit('plugin_cron_observed', {
        minute => 50, hour => 7, dow => 4, mday => 18, month => 9, year => 2026,
    });
    $manager->disable('hello-v3');
    $bot->{loop}->run_all;
    $assert->is($entry->{object}{minutes_observed}, 33,
        'disable clears pending event delivery');
    $assert->is($bot->{scheduler}{tasks}{$task}{started}, 0,
        'disable stops the owned job');
    $assert->is($bot->{scheduler}->fire($task), 0,
        'disabled job cannot fire');

    $entry->{mounted_jobs}[0]{clock}{next_expected} = 1;
    $manager->enable('hello-v3');
    $assert->ok($entry->{mounted_jobs}[0]{clock}{next_expected} > time(),
        're-enable resets the expected first run instead of retaining stale time');
    $manager->disable('hello-v3');

    $manager->unregister_plugin('hello-v3');
    $assert->is($bot->{event_bus}->listener_count('plugin_cron_observed'), 0,
        'unload removes the exact EventBus listener');
    $assert->ok(!exists($bot->{scheduler}{tasks}{$task}),
        'unload removes the namespaced scheduler task');
    $assert->is($bot->{registry}->has_command('v3hello', 'public'), 0,
        'unload also removes the command surface');

    my $rollback_bot = T1072::Bot->new;
    $rollback_bot->{scheduler}{fail_start} = 1;
    my $rollback_manager = Mediabot::PluginManager->new(
        bot => $rollback_bot, plugin_dir => 'plugins');
    my $rollback_entry = $rollback_manager->load_package_v3(
        'hello-v3',
        grants => ['events.subscribe', 'irc.reply', 'scheduler.jobs'],
        channel_policies => {
            '#i/o' => { mode => 'on', config => {} },
        },
    );
    my $ok = eval { $rollback_manager->enable('hello-v3'); 1 };
    $assert->like($@ // '', qr/failed to start API v3 job 'heartbeat'/,
        'job start failure aborts plugin activation');
    $assert->is($rollback_manager->is_enabled('hello-v3'), 0,
        'failed activation leaves the plugin disabled');
    $assert->is($rollback_entry->{object}{started}, 0,
        'failed activation rolls back the plugin start hook');
    $rollback_manager->unregister_plugin('hello-v3');

    my $atomic_bot = T1072::Bot->new;
    delete $atomic_bot->{scheduler};
    my $atomic_manager = Mediabot::PluginManager->new(
        bot => $atomic_bot, plugin_dir => 'plugins');
    $ok = eval {
        $atomic_manager->load_package_v3(
            'hello-v3',
            grants => ['events.subscribe', 'irc.reply', 'scheduler.jobs'],
        );
        1;
    };
    $assert->like($@ // '', qr/scheduler unavailable/,
        'missing shared scheduler fails package load closed');
    $assert->is($atomic_manager->count, 0,
        'failed resource transaction leaves no registered plugin');
    $assert->is($atomic_bot->{registry}->has_command('v3hello', 'public'), 0,
        'failed resource transaction rolls back mounted commands');
    $assert->is($atomic_bot->{event_bus}->listener_count('plugin_cron_observed'), 0,
        'failed resource transaction rolls back event listeners');
};
