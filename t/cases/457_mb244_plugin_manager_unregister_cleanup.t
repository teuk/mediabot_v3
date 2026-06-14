#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../..";

use Mediabot::EventBus;
use Mediabot::PluginManager;

{
    package Local::MB244::Plugin;

    sub new {
        my ($class, $bus) = @_;
        return bless {
            bus              => $bus,
            listener_entry   => undef,
            unregister_calls => 0,
        }, $class;
    }

    sub install_listener {
        my ($self) = @_;
        $self->{listener_entry} = $self->{bus}->on(
            example_event => sub { return 1 },
            name   => 'mb244-test-listener',
            plugin => __PACKAGE__,
        );
        return $self->{listener_entry};
    }

    sub unregister {
        my ($self, %opts) = @_;
        $self->{unregister_calls}++;
        return $self->{bus}->off(example_event => $self->{listener_entry});
    }

    sub unregister_calls { return $_[0]->{unregister_calls}; }
}

my $bus = Mediabot::EventBus->new;
my $pm  = Mediabot::PluginManager->new(bot => bless({ event_bus => $bus }, 'Local::MB244::Bot'));

my $plugin = Local::MB244::Plugin->new($bus);
$plugin->install_listener;

is($bus->listener_count('example_event'), 1, 'plugin installed one EventBus listener');

$pm->register_plugin(
    name   => 'Local::MB244::Plugin',
    module => 'Local::MB244::Plugin',
    object => $plugin,
);

ok($pm->is_registered('Local::MB244::Plugin'), 'plugin is registered before explicit unregister');
is($pm->unregister_plugin('Local::MB244::Plugin'), 1, 'explicit unregister_plugin succeeds');
ok(!$pm->is_registered('Local::MB244::Plugin'), 'plugin is removed from PluginManager');
is($plugin->unregister_calls, 1, 'plugin object unregister hook was called exactly once');
is($bus->listener_count('example_event'), 0, 'explicit unregister removed plugin EventBus listener');

is($pm->unregister_plugin('Local::MB244::Plugin'), 0, 'second unregister is idempotent and returns 0');
is($plugin->unregister_calls, 1, 'second unregister does not call object hook again');

my $plain = bless({}, 'Local::MB244::PlainObject');
$pm->register_plugin(name => 'plain', module => 'Local::MB244::PlainObject', object => $plain);
is($pm->unregister_plugin('plain'), 1, 'object without unregister can still be removed');
ok(!$pm->is_registered('plain'), 'plain plugin is removed cleanly');

my $source = do {
    open my $fh, '<:encoding(UTF-8)', "$Bin/../../Mediabot/PluginManager.pm"
        or die "cannot read PluginManager.pm: $!";
    local $/;
    <$fh>;
};

like($source, qr/mb244-B1: explicit plugin unregister/, 'PluginManager source contains mb244 unregister cleanup marker');
unlike($source, qr/`[^`]+`|\bqx\s*(?:\/|\(|\{)|\bsystem\s*(?:\(|\s)/, 'PluginManager unregister cleanup does not introduce shell execution');

done_testing();
