#!/usr/bin/env perl
use strict;
use warnings;
use lib '.';
use Test::More;

use Mediabot::ScriptActionRunner;

my $runner = Mediabot::ScriptActionRunner->new(max_text_length => 400);
my $ctx = { channel => '#teuk', nick => 'TeuK' };

sub first_error_text {
    my ($plan) = @_;
    my $err = $plan->{errors}[0];
    return ref($err) eq 'HASH' ? ($err->{error} || '') : ($err || '');
}

my $level_array = $runner->plan_actions([
    { type => 'log', level => [ 'error' ], text => 'hello' },
], $ctx);
ok(!$level_array->{ok}, 'structured log level array is rejected');
like(first_error_text($level_array), qr/log level must be scalar/, 'structured log level array reports scalar contract');

my $level_hash = $runner->plan_actions([
    { type => 'log', level => { bad => 1 }, text => 'hello' },
], $ctx);
ok(!$level_hash->{ok}, 'structured log level hash is rejected');
like(first_error_text($level_hash), qr/log level must be scalar/, 'structured log level hash reports scalar contract');

my $level_missing = $runner->plan_actions([
    { type => 'log', text => 'hello' },
], $ctx);
ok($level_missing->{ok}, 'missing log level still defaults safely');
is($level_missing->{planned}[0]{level}, 'info', 'missing log level defaults to info');

my $level_invalid_scalar = $runner->plan_actions([
    { type => 'log', level => 'verbose', text => 'hello' },
], $ctx);
ok($level_invalid_scalar->{ok}, 'invalid scalar log level keeps legacy fallback behavior');
is($level_invalid_scalar->{planned}[0]{level}, 'info', 'invalid scalar log level falls back to info');

my $level_valid = $runner->plan_actions([
    { type => 'log', level => 'WARN', text => 'hello' },
], $ctx);
ok($level_valid->{ok}, 'valid scalar log level is accepted');
is($level_valid->{planned}[0]{level}, 'warn', 'valid scalar log level is normalized');

my $source = do { local $/; open my $fh, '<', 'Mediabot/ScriptActionRunner.pm' or die $!; <$fh> };
like($source, qr/mb251-B1/, 'ScriptActionRunner source contains mb251 log level scalar marker');
unlike($source, qr/`[^`]+`|\bqx\s*(?:\/|\(|\{)|\bsystem\s*(?:\(| )/, 'mb251 log level scalar guard does not introduce shell execution');

done_testing();
