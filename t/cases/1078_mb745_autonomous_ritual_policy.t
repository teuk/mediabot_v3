# MB745 — autonomous output stays capability-, policy- and lifecycle-scoped.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

{
    package T1078::Logger;
    sub new { bless {}, shift }
    sub log { 1 }
}

{
    package T1078::Scheduler;
    sub new { bless { tasks => {} }, shift }
    sub add { my ($s, %a) = @_; $s->{tasks}{$a{name}} = { %a, started => 0 }; $s }
    sub start { $_[0]{tasks}{$_[1]}{started} = 1; 1 }
    sub stop { $_[0]{tasks}{$_[1]}{started} = 0; 1 }
    sub remove { delete($_[0]{tasks}{$_[1]}) ? 1 : 0 }
    sub fire {
        my ($s, $name) = @_;
        return 0 unless $s->{tasks}{$name}{started};
        $s->{tasks}{$name}{cb}->(); 1;
    }
}

{
    package T1078::Bot;
    sub new {
        require Mediabot::CommandRegistry;
        bless {
            registry => Mediabot::CommandRegistry->new,
            scheduler => T1078::Scheduler->new,
            logger => T1078::Logger->new,
            messages => [],
        }, shift;
    }
    sub command_registry { $_[0]{registry} }
    sub registry { $_[0]{registry} }
    sub plugin_channel_message { push @{ $_[0]{messages} }, [$_[1], $_[2]]; 1 }
}

return sub {
    my ($assert) = @_;
    require Mediabot::PluginManager;
    my $bot = T1078::Bot->new;
    for my $name (qw(8ball abbrev choose flip morse roll)) {
        $bot->{registry}->register_command(
            name => $name, source => 'public', handler => sub { 1 },
            metadata => { builtin => 1, dispatch => 'legacy-public' });
    }
    my $manager = Mediabot::PluginManager->new(
        bot => $bot, plugin_dir => 'plugins');
    $manager->load_package_v3('playful-v3', grants => [
        qw(irc.reply irc.notice irc.channel_message scheduler.jobs)
    ]);
    $manager->enable('playful-v3');
    my $task = 'plugin.v3.playful-v3.quiet_magic';

    $manager->set_v3_channel_policy('playful-v3', '#development',
        mode => 'observe', config => {
            language => 'fr', ritual_enabled => 1,
            ritual_every => 1, ritual_style => 'subtle',
        });
    $assert->ok($bot->{scheduler}->fire($task),
        'the owned ritual job fires in observe');
    $assert->is(scalar @{ $bot->{messages} }, 0,
        'observe suppresses autonomous channel output');

    $manager->set_v3_channel_policy('playful-v3', '#development',
        mode => 'on');
    $assert->ok($bot->{scheduler}->fire($task),
        'the owned ritual job fires in on mode');
    $assert->is(scalar @{ $bot->{messages} }, 1,
        'on permits exactly one bounded autonomous line');
    $assert->is($bot->{messages}[0][0], '#development',
        'the plugin cannot choose a target outside its policy channel');
    $assert->ok(length($bot->{messages}[0][1]) <= 400,
        'the autonomous line remains below the facade byte budget');

    $manager->set_v3_channel_policy('playful-v3', '#development', mode => 'off');
    $bot->{scheduler}->fire($task);
    $assert->is(scalar @{ $bot->{messages} }, 1,
        'off removes the channel from job fan-out immediately');

    $manager->disable('playful-v3');
    $assert->ok(!$bot->{scheduler}->fire($task),
        'disable stops the centrally owned job');
    $manager->unregister_plugin('playful-v3');
    $assert->ok(!exists $bot->{scheduler}{tasks}{$task},
        'unload removes the ritual timer completely');
};
