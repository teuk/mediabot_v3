#!/usr/bin/env perl
use strict;
use warnings;
use lib '.';
use Test::More;

use Mediabot::EventBus;
use Mediabot::PluginManager;
use Mediabot::Plugin::ScriptDryRun;

{
    package MB242::FakeBot;
    sub new {
        my ($class) = @_;
        return bless {
            conf   => {},
            events => Mediabot::EventBus->new,
        }, $class;
    }
    sub events { return $_[0]->{events}; }
}

my $bus = Mediabot::EventBus->new;
my @seen;
my $first = $bus->on(example_event => sub { push @seen, 'first' }, name => 'first');
my $second = $bus->on(example_event => sub { push @seen, 'second' }, name => 'second');

is($bus->listener_count('example_event'), 2, 'EventBus starts with two listeners');
is($bus->off(example_event => $first), 1, 'EventBus off removes exact listener entry');
is($bus->listener_count('example_event'), 1, 'EventBus off leaves other listener in place');
is($bus->emit('example_event'), 1, 'emit runs remaining listener only');
is_deeply(\@seen, ['second'], 'remaining listener is the expected one');
is($bus->off(example_event => $first), 0, 'EventBus off is idempotent for removed listener');

my $bot = MB242::FakeBot->new;
my $pm  = Mediabot::PluginManager->new(bot => $bot);

my $entry1 = $pm->load_perl_module('Mediabot::Plugin::ScriptDryRun');
ok($entry1 && ref($entry1) eq 'HASH', 'first ScriptDryRun plugin load succeeds');
is($bot->events->listener_count('public_command_observed'), 1, 'first load registers one public command listener');

my $old_object = $entry1->{object};
ok($old_object && $old_object->can('unregister'), 'ScriptDryRun object exposes unregister');

my $entry2 = $pm->load_perl_module('Mediabot::Plugin::ScriptDryRun', replace => 1);
ok($entry2 && ref($entry2) eq 'HASH', 'replace load succeeds');
is($bot->events->listener_count('public_command_observed'), 1, 'replace keeps exactly one public command listener');
isnt($entry2->{object}, $old_object, 'replace creates a new plugin object');
ok(!defined $old_object->{listener_entry}, 'old ScriptDryRun object cleared its listener entry');
ok(defined $entry2->{object}->{listener_entry}, 'new ScriptDryRun object keeps its listener entry');

my $ran = $bot->events->emit('public_command_observed', { command => 'nope' });
is($ran, 1, 'event dispatch runs one ScriptDryRun observer after replace');

my $source_eventbus = do { local (@ARGV, $/) = ('Mediabot/EventBus.pm'); <> };
my $source_plugin   = do { local (@ARGV, $/) = ('Mediabot/Plugin/ScriptDryRun.pm'); <> };
my $source_manager  = do { local (@ARGV, $/) = ('Mediabot/PluginManager.pm'); <> };

like($source_eventbus, qr/mb242-B1/, 'EventBus source contains mb242 off marker');
like($source_plugin, qr/mb242-B2/, 'ScriptDryRun source contains mb242 unregister marker');
like($source_manager, qr/mb242-B3/, 'PluginManager source contains mb242 replace cleanup marker');
unlike($source_eventbus . $source_plugin . $source_manager, qr/`[^`]+`|\bqx\s*(?:\/|\(|\{)|\bsystem\s*(?:\(| )/, 'mb242 cleanup does not introduce shell execution');

done_testing();
