use strict;
use warnings;
use Test::More;
use Scalar::Util qw(refaddr);
use Mediabot::CommandRegistry;

my $registry = Mediabot::CommandRegistry->new;
my $first = $registry->register_command(
    name => 'forecast', aliases => ['weather', 'meteo'],
    description => 'Original help', level => 'User', plugin => 'original',
    handler => sub { 'original handler' },
);
my @before = $registry->list('public');
for my $replace (0, 1) {
    my $ok = eval {
        $registry->register_command(
            name => ' WEATHER ', source => ' PUBLIC ', replace => $replace,
            aliases => ['newalias'], handler => sub { 'unreachable handler' },
        );
        1;
    };
    ok(!$ok, "canonical registration cannot take another command's alias (replace=$replace)");
    like($@, qr/alias.*forecast/i, 'collision reports the existing alias owner');
    is($registry->count('public'), scalar @before, 'refusal creates no unreachable command');
    is(refaddr($registry->command_for('weather')), refaddr($first), 'original alias keeps its exact entry');
    is($registry->handler_for('forecast')->(), 'original handler', 'original handler is retained');
    is_deeply([$registry->aliases_for('forecast')], ['weather', 'meteo'], 'existing aliases remain intact');
    ok(!$registry->has_command('newalias'), 'failed registration leaves no new alias');
    is($registry->command_for('forecast')->{description}, 'Original help', 'refusal preserves help metadata');
    ok(!$registry->unregister_command('weather'), 'failed registration leaves no canonical entry to unregister');
}
is($registry->handler_for('meteo')->(), 'original handler', 'all original entry points still dispatch');

my $private = $registry->register_command(name => 'weather', source => 'private',
    handler => sub { 'private handler' });
is($registry->handler_for('weather', 'private')->(), 'private handler', 'ownership is scoped by source');
is($registry->handler_for('weather', 'public')->(), 'original handler', 'private command cannot affect public alias');

# Removing an alias explicitly through its owner releases the name normally.
$registry->register_command(name => 'forecast', aliases => ['meteo'], replace => 1,
    handler => sub { 'updated handler' });
ok(!$registry->has_command('weather', 'public'), 'owner replacement releases the removed alias');
my $new = $registry->register_command(name => 'weather', aliases => ['w'],
    handler => sub { 'new handler' });
is($registry->handler_for('weather')->(), 'new handler', 'released name can become a canonical command');
is($registry->handler_for('w')->(), 'new handler', 'new canonical command owns its aliases');
is($registry->handler_for('meteo')->(), 'updated handler', 'old owner keeps its remaining alias');
$registry->register_command(name => 'weather', aliases => ['neww'], replace => 1,
    handler => sub { 'replacement handler' });
is($registry->handler_for('weather')->(), 'replacement handler', 'legitimate canonical replacement still works');
ok(!$registry->has_command('w'), 'legitimate replacement removes obsolete aliases');
ok($registry->unregister_command('weather'), 'new canonical command unregisters normally');
ok(!$registry->has_command('neww'), 'unregister removes the new command aliases');
is($registry->handler_for('meteo')->(), 'updated handler', 'unregister cannot affect unrelated command ownership');
is($registry->handler_for('weather', 'private')->(), 'private handler', 'unregister preserves the other source');
done_testing;
