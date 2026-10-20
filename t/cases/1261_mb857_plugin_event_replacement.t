use strict;
use warnings;
use lib '.';
use Test::More;
use Scalar::Util qw(refaddr);
use Mediabot::EventBus;
use Mediabot::PluginManager;
use Mediabot::Plugin::ScriptDryRun;

{
    package MB857::Bot;
    sub new { bless { conf => {}, events => Mediabot::EventBus->new }, shift }
    sub events { $_[0]{events} }
}

for my $method (qw(emit emit_report)) {
    {
        note "$method replacement within public command observation";
        my $bot = MB857::Bot->new;
        my $bus = $bot->events;
        my $manager = Mediabot::PluginManager->new(bot => $bot);
        my $first = $manager->load_perl_module('Mediabot::Plugin::ScriptDryRun');
        ok($first && ref($first->{object}), 'real ScriptDryRun plugin loads through PluginManager');
        my $old = $first->{object};
        my $new;
        $bus->once(public_command_observed => sub {
            my $entry = $manager->load_perl_module('Mediabot::Plugin::ScriptDryRun', replace => 1);
            $new = $entry->{object};
        }, priority => 100);
        my $ctx = { command => 'fixture', channel => '#test', nick => 'alice' };
        my $first_result = $bus->$method('public_command_observed', $ctx);
        my $ran = ref($first_result) ? $first_result->{ran} : $first_result;
        ok($new && refaddr($new) != refaddr($old), 'replacement installs a different real plugin object');
        ok(!defined $old->{listener_entry}, 'normal unregister removes the old observer handle');
        is($old->observed_public, 0, 'replaced observer cannot process the in-progress command');
        is($new->observed_public, 0, 'new observer waits for a subsequent event');
        is($ran, 1, 'first event counts only its replacement callback');
        is($bus->listener_count('public_command_observed'), 1, 'exactly the replacement subscription survives');
        if (ref($first_result)) {
            is_deeply($first_result->{errors}, [], 'replacement completes without a callback failure');
        }
        my $second_result = $bus->$method('public_command_observed', $ctx);
        is(ref($second_result) ? $second_result->{ran} : $second_result, 1,
            'subsequent event runs one live observer');
        is($new->observed_public, 1, 'real replacement observer receives the subsequent command');
        is($old->observed_public, 0, 'retained old object stays inactive');
        is($new->unregister, 1, 'replacement unregister retains exact removal semantics');
        is($bus->listener_count('public_command_observed'), 0, 'final unsubscribe leaves no phantom observer');
    }
}
done_testing;
