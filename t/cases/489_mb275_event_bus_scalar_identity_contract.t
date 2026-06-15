#!/usr/bin/env perl
use strict;
use warnings;
use lib '.';
use Test::More;

use Mediabot::EventBus;

{
    package MB275::SameStringEntry;
    use overload '""' => sub { 'same-listener-string' }, fallback => 1;
}

my $bus = Mediabot::EventBus->new;

my $died = eval { $bus->on([ 'bad_event' ], sub { 1 }); 1 } ? 0 : 1;
ok($died, 'EventBus rejects non-scalar event names on registration');

is($bus->emit([ 'bad_event' ]), 0, 'emit ignores non-scalar event names');
is($bus->listener_count({ bad => 'event' }), 0, 'listener_count ignores non-scalar event names');
is($bus->clear([ 'bad_event' ]), 0, 'clear ignores non-scalar event names');

my @order;
$bus->on('meta_event', sub { push @order, 'bad-priority'; die "boom\n"; },
    name     => { bad => 1 },
    plugin   => [ 'Plugin' ],
    priority => [ 99 ],
);
$bus->on('meta_event', sub { push @order, 'high-priority' },
    name     => " useful listener \n",
    plugin   => " Plugin::Name\0 ",
    priority => 10,
);

my $report = $bus->emit_report('meta event');
is_deeply(\@order, [ 'high-priority', 'bad-priority' ], 'non-scalar priority falls back to zero without ordering ahead');
is($report->{ran}, 2, 'emit_report still runs both listeners');
is(scalar @{ $report->{errors} }, 1, 'only failing listener reports an error');
ok(!defined $report->{errors}[0]{name}, 'non-scalar listener name is not stringified in diagnostics');
ok(!defined $report->{errors}[0]{plugin}, 'non-scalar listener plugin is not stringified in diagnostics');
unlike($report->{errors}[0]{error}, qr/[\r\n\0]/, 'listener error is single-line sanitized text');

my $entry_a = $bus->on('identity_event', sub { 1 }, name => 'a');
my $entry_b = $bus->on('identity_event', sub { 1 }, name => 'b');
bless $entry_a, 'MB275::SameStringEntry';
bless $entry_b, 'MB275::SameStringEntry';

is("$entry_a", "$entry_b", 'test setup: two distinct listener entries stringify the same');
is($bus->listener_count('identity_event'), 2, 'identity event starts with two listeners');
is($bus->off('identity_event', $entry_a), 1, 'off removes exact blessed listener entry by reference identity');
is($bus->listener_count('identity_event'), 1, 'off leaves different same-string listener in place');
is($bus->off('identity_event', $entry_a), 0, 'off remains idempotent for removed listener');

my $once_a = $bus->once('once_identity_event', sub { 1 }, name => 'once-a');
my $once_b = $bus->once('once_identity_event', sub { 1 }, name => 'once-b');
bless $once_a, 'MB275::SameStringEntry';
bless $once_b, 'MB275::SameStringEntry';
is($bus->emit('once_identity_event'), 2, 'once identity test emits both same-string entries first time');
is($bus->listener_count('once_identity_event'), 0, 'once cleanup removes all emitted once entries by refaddr identity');

my $source = do { local (@ARGV, $/) = ('Mediabot/EventBus.pm'); <> };
like($source, qr/mb275-B1/, 'EventBus source contains mb275 scalar event marker');
like($source, qr/refaddr/, 'EventBus source uses refaddr for listener identity');
unlike($source, qr/`[^`]+`|\bqx\s*(?:\/|\(|\{)|\bsystem\s*(?:\(| )/, 'mb275 EventBus hardening does not introduce shell execution');

done_testing();
