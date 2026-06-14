#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../..";

use Mediabot::EventBus;
use Mediabot::PluginManager;

{
    package Local::MB248::ListenerPlugin;

    sub new {
        my ($class, %args) = @_;
        my $self = bless {
            bus              => $args{bus},
            tag              => $args{tag} || 'plugin',
            calls            => 0,
            unregister_calls => 0,
        }, $class;

        $self->{entry} = $self->{bus}->on(
            mb248_event => sub { $self->{calls}++ },
            name   => 'mb248-' . $self->{tag},
            plugin => 'Local::MB248::ListenerPlugin',
        );

        return $self;
    }

    sub unregister {
        my ($self, %opts) = @_;
        $self->{unregister_calls}++;
        return $self->{bus}->off(mb248_event => $self->{entry});
    }

    sub calls            { return $_[0]->{calls}; }
    sub unregister_calls { return $_[0]->{unregister_calls}; }
}

my $bus = Mediabot::EventBus->new;
my $pm  = Mediabot::PluginManager->new(bot => { event_bus => $bus });

my $plugin = Local::MB248::ListenerPlugin->new(bus => $bus, tag => 'same');

$pm->register_plugin(
    name        => 'spellbridge',
    module      => 'Local::MB248::ListenerPlugin',
    object      => $plugin,
    description => 'first registration',
);

is($bus->listener_count('mb248_event'), 1, 'initial same-object fixture has one listener');

$pm->register_plugin(
    name        => 'spellbridge',
    module      => 'Local::MB248::ListenerPlugin',
    object      => $plugin,
    description => 'metadata refresh',
    replace     => 1,
);

is($plugin->unregister_calls, 0, 'same-object replace does not call unregister');
is($pm->object_for('spellbridge'), $plugin, 'same-object replace keeps the current plugin object');
is($bus->listener_count('mb248_event'), 1, 'same-object replace keeps EventBus listener registered');

$bus->emit('mb248_event');
is($plugin->calls, 1, 'listener still runs after same-object replace');

my $replacement = Local::MB248::ListenerPlugin->new(bus => $bus, tag => 'replacement');
is($bus->listener_count('mb248_event'), 2, 'replacement fixture adds a second listener before replace');

$pm->register_plugin(
    name    => 'spellbridge',
    module  => 'Local::MB248::ListenerPlugin',
    object  => $replacement,
    replace => 1,
);

is($plugin->unregister_calls, 1, 'different-object replace still unregisters old plugin exactly once');
is($replacement->unregister_calls, 0, 'different-object replace does not unregister replacement plugin');
is($bus->listener_count('mb248_event'), 1, 'different-object replace removes old listener and keeps replacement listener');

$bus->emit('mb248_event');
is($plugin->calls, 1, 'old listener no longer runs after different-object replace');
is($replacement->calls, 1, 'replacement listener runs after different-object replace');

my $source = do {
    open my $fh, '<', "$Bin/../../Mediabot/PluginManager.pm" or die $!;
    local $/;
    <$fh>;
};

like($source, qr/mb248-B1: a same-object replace is a metadata refresh/, 'PluginManager source contains mb248 same-object marker');
unlike($source, qr/`[^`]+`|\bqx\s*(?:\/|\(|\{)|\bsystem\s*(?:\(|\s)/, 'same-object replace guard does not introduce shell execution');

done_testing();
