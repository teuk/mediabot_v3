# MB744 — runtime enforcement for off/observe/on commands, events and jobs.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

{
    package T1075::Log;
    sub new { bless { lines => [] }, shift }
    sub log { push @{ $_[0]{lines} }, $_[2]; 1 }
}

{
    package T1075::Loop;
    sub new { bless { later => [] }, shift }
    sub later { push @{ $_[0]{later} }, $_[1]; 1 }
    sub run_all {
        my ($self) = @_;
        while (my $cb = shift @{ $self->{later} }) { $cb->() }
    }
}

{
    package T1075::Scheduler;
    sub new { bless { tasks => {} }, shift }
    sub add {
        my ($self, %args) = @_;
        $self->{tasks}{ $args{name} } = { %args, started => 0 };
        return $self;
    }
    sub start { $_[0]{tasks}{$_[1]}{started} = 1; 1 }
    sub stop { $_[0]{tasks}{$_[1]}{started} = 0; 1 }
    sub remove { delete($_[0]{tasks}{$_[1]}) ? 1 : 0 }
    sub fire {
        my ($self, $name) = @_;
        my $task = $self->{tasks}{$name} or return 0;
        return 0 unless $task->{started};
        $task->{cb}->();
        return 1;
    }
}

{
    package T1075::Bot;
    sub new {
        require Mediabot::CommandRegistry;
        require Mediabot::EventBus;
        return bless {
            registry  => Mediabot::CommandRegistry->new,
            event_bus => Mediabot::EventBus->new,
            loop      => T1075::Loop->new,
            scheduler => T1075::Scheduler->new,
            logger    => T1075::Log->new,
        }, shift;
    }
    sub command_registry { $_[0]{registry} }
    sub registry { $_[0]{registry} }
    sub events { $_[0]{event_bus} }
    sub getLoop { $_[0]{loop} }
}

{
    package T1075::Context;
    sub new { my ($class, %args) = @_; bless { %args, replies => [], notices => [] }, $class }
    sub nick { $_[0]{nick} }
    sub channel { $_[0]{channel} }
    sub command { 'v3hello' }
    sub args { [] }
    sub is_private { 0 }
    sub reply { push @{ $_[0]{replies} }, $_[1]; 1 }
    sub reply_private { push @{ $_[0]{notices} }, $_[1]; 1 }
}

return sub {
    my ($assert) = @_;

    require Mediabot::PluginManager;
    my $bot = T1075::Bot->new;
    my $manager = Mediabot::PluginManager->new(
        bot => $bot, plugin_dir => 'plugins');
    my $entry = $manager->load_package_v3('hello-v3',
        grants => [qw(events.subscribe irc.reply scheduler.jobs)]);
    $manager->enable('hello-v3');

    my $handler = $bot->{registry}->handler_for('v3hello', 'public');
    my $ctx = T1075::Context->new(nick => 'Tangy', channel => '#i/o');
    $handler->($ctx);
    $assert->is($entry->{object}{commands_observed}, 0,
        'global enable leaves an unconfigured channel completely off');

    $manager->set_v3_channel_policy('hello-v3', '#i/o',
        mode => 'observe', config => {
            greeting => 'Lumos', enthusiasm => 2, mention_nick => 1,
        });
    $handler->($ctx);
    $assert->is($entry->{object}{commands_observed}, 1,
        'observe runs the bounded command handler');
    $assert->is(scalar @{ $ctx->{replies} }, 0,
        'observe suppresses IRC output at the core sink');

    $bot->{event_bus}->emit('plugin_cron_observed', {
        minute => 1, hour => 2, dow => 3, mday => 4, month => 5, year => 2026,
    });
    $manager->set_v3_channel_policy('hello-v3', '#i/o', mode => 'off');
    $bot->{loop}->run_all;
    $assert->is($entry->{object}{minutes_observed}, 0,
        'late off revocation cancels an already queued event');

    $manager->set_v3_channel_policy('hello-v3', '#i/o', mode => 'observe');
    $bot->{event_bus}->emit('plugin_cron_observed', {
        minute => 2, hour => 2, dow => 3, mday => 4, month => 5, year => 2026,
    });
    $bot->{loop}->run_all;
    $assert->is($entry->{object}{minutes_observed}, 1,
        'observe receives a scoped deferred event');
    $assert->is($entry->{object}{observed_channels}[-1], '#i/o',
        'unscoped scheduler event is fanned out to its policy channel');
    $assert->is($entry->{object}{observed_modes}[-1], 'observe',
        'event sees the current activation mode');

    my $task = 'plugin.v3.hello-v3.heartbeat';
    $assert->ok($bot->{scheduler}->fire($task),
        'owned job fires while the package lifecycle is enabled');
    $assert->is($entry->{object}{heartbeats}, 1,
        'observe policy receives one channel-scoped job invocation');

    $manager->set_v3_channel_policy('hello-v3', '#I/O', mode => 'on',
        config => { greeting => 'Lumos', enthusiasm => 2, mention_nick => 1 });
    $handler->($ctx);
    $assert->is($ctx->{replies}[0], 'Tangy: Lumos!!',
        'on emits through the sink with typed channel configuration');

    my $other = T1075::Context->new(nick => 'Tangy', channel => '#elsewhere');
    $handler->($other);
    $assert->is(scalar @{ $other->{replies} }, 0,
        'another channel remains independently off');

    my $snapshot = $manager->v3_channel_policy('hello-v3', '#i/o');
    $assert->is($snapshot->{mode}, 'on',
        'manager exposes a detached operator policy snapshot');
    $manager->disable('hello-v3');
    $manager->unregister_plugin('hello-v3');
};
