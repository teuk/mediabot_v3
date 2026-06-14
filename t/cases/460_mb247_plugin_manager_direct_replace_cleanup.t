#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../..";

use Mediabot::EventBus;
use Mediabot::PluginManager;

{
    package Local::MB247::ListenerPlugin;

    sub new {
        my ($class, %args) = @_;
        my $self = bless {
            bus              => $args{bus},
            tag              => $args{tag},
            calls            => 0,
            unregister_calls => 0,
        }, $class;

        $self->{entry} = $self->{bus}->on(
            mb247_event => sub { $self->{calls}++ },
            name   => 'mb247-' . ($self->{tag} || 'plugin'),
            plugin => 'Local::MB247::ListenerPlugin',
        );

        return $self;
    }

    sub unregister {
        my ($self, %opts) = @_;
        $self->{unregister_calls}++;
        return $self->{bus}->off(mb247_event => $self->{entry});
    }

    sub calls            { return $_[0]->{calls}; }
    sub unregister_calls { return $_[0]->{unregister_calls}; }
}

my $bus = Mediabot::EventBus->new;
my $pm  = Mediabot::PluginManager->new(bot => { event_bus => $bus });

my $old = Local::MB247::ListenerPlugin->new(bus => $bus, tag => 'old');
my $new = Local::MB247::ListenerPlugin->new(bus => $bus, tag => 'new');

is($bus->listener_count('mb247_event'), 2, 'two listeners exist before direct replace cleanup');

my $entry1 = $pm->register_plugin(
    name   => 'spellbridge',
    module => 'Local::MB247::ListenerPlugin',
    object => $old,
);
ok($entry1, 'initial direct plugin registration succeeds');

my $entry2 = $pm->register_plugin(
    name    => 'spellbridge',
    module  => 'Local::MB247::ListenerPlugin',
    object  => $new,
    replace => 1,
);
ok($entry2, 'direct register_plugin replace succeeds');

is($old->unregister_calls, 1, 'direct replace calls old plugin unregister exactly once');
is($new->unregister_calls, 0, 'direct replace does not unregister new plugin');
is($bus->listener_count('mb247_event'), 1, 'direct replace removed old EventBus listener');

$bus->emit('mb247_event');
is($old->calls, 0, 'old listener no longer runs after direct replace');
is($new->calls, 1, 'new listener remains active after direct replace');

is($pm->object_for('spellbridge'), $new, 'plugin manager points to replacement object');

my $plain_old = bless { unregister_calls => 0 }, 'Local::MB247::PlainPlugin';
my $plain_new = bless { unregister_calls => 0 }, 'Local::MB247::PlainPlugin';
$pm->register_plugin(name => 'plain', object => $plain_old);
$pm->register_plugin(name => 'plain', object => $plain_new, replace => 1);
is($pm->object_for('plain'), $plain_new, 'direct replace still works for object without unregister');

my $source = do {
    open my $fh, '<', "$Bin/../../Mediabot/PluginManager.pm" or die $!;
    local $/;
    <$fh>;
};

like($source, qr/mb247-B1: direct register_plugin/, 'PluginManager source contains mb247 direct replace marker');
unlike($source, qr/`[^`]+`|\bqx\s*(?:\/|\(|\{)|\bsystem\s*(?:\(|\s)/, 'PluginManager direct replace cleanup does not introduce shell execution');

# Package without unregister, intentionally empty.
package Local::MB247::PlainPlugin;

package main;
done_testing();
