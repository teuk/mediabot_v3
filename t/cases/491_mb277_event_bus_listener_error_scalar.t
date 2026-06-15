#!/usr/bin/env perl
use strict;
use warnings;
use lib '.';
use Test::More;

use Mediabot::EventBus;

my $bus = Mediabot::EventBus->new;

$bus->on('errors', sub { die { bad => 1 }; }, name => 'hash-die', plugin => 'P');
$bus->on('errors', sub { die [ 'bad' ]; }, name => 'array-die', plugin => 'P');
$bus->on('errors', sub { die "boom\r\nsecond\0line\n"; }, name => 'scalar-die', plugin => 'P');
$bus->on('errors', sub { die ('x' x 500); }, name => 'long-die', plugin => 'P');

my $report = $bus->emit_report('errors');

is($report->{ran}, 4, 'emit_report runs all listeners even when they die');
is(scalar @{ $report->{errors} }, 4, 'emit_report records one error per failed listener');

my ($hash_error, $array_error, $scalar_error, $long_error) = @{ $report->{errors} };

is(ref($hash_error->{error}), '', 'hash exception is converted to scalar fallback');
is($hash_error->{error}, 'unknown listener error', 'hash exception uses stable fallback');

is(ref($array_error->{error}), '', 'array exception is converted to scalar fallback');
is($array_error->{error}, 'unknown listener error', 'array exception uses stable fallback');

is(ref($scalar_error->{error}), '', 'scalar exception remains scalar');
unlike($scalar_error->{error}, qr/[\r\n\0]/, 'scalar exception is single-line and control-free');
like($scalar_error->{error}, qr/boom second line/, 'scalar exception keeps useful text');

is(ref($long_error->{error}), '', 'long scalar exception remains scalar');
ok(length($long_error->{error}) <= 240, 'long scalar exception is capped');
unlike($long_error->{error}, qr/HASH\(|ARRAY\(/, 'listener diagnostics do not expose stringified refs');

my $source = do { local (@ARGV, $/) = ('Mediabot/EventBus.pm'); <> };
like($source, qr/mb277-B1/, 'EventBus source contains mb277 listener error scalar marker');
unlike($source, qr/`[^`]+`|\bqx\s*(?:\/|\(|\{)|\bsystem\s*(?:\(| )/, 'mb277 EventBus listener error guard does not introduce shell execution');

done_testing();
