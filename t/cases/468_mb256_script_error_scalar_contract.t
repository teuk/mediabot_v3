#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use Test::More;
use JSON::PP qw(encode_json);

use lib '.';
use Mediabot::ScriptRunner;
use Mediabot::ScriptActionRunner;

my $runner = Mediabot::ScriptRunner->new(max_actions => 20);

my $decoded = $runner->decode_script_response(encode_json({
    ok     => JSON::PP::false,
    errors => [ { bad => 1 }, [ 'nested' ], 'clean error' ],
    actions => [ { type => 'reply', target => '#teuk', text => 'must not leak' } ],
}));

ok(!$decoded->{ok}, 'script response with mixed scalar/non-scalar errors remains failed');
is_deeply($decoded->{actions}, [], 'failed response with non-scalar errors exposes no actions');
is_deeply($decoded->{errors}, [ 'clean error' ], 'ScriptRunner keeps scalar errors and drops nested JSON diagnostics');
ok(!scalar(grep { /HASH\(|ARRAY\(/ } @{ $decoded->{errors} || [] }), 'ScriptRunner never stringifies nested errors');

my $nested_only = $runner->decode_script_response(encode_json({
    ok     => JSON::PP::false,
    errors => [ { bad => 1 }, [ 'nested' ] ],
}));

ok(!$nested_only->{ok}, 'nested-only error list remains failed');
is_deeply($nested_only->{errors}, [ 'script response reported failure' ], 'ScriptRunner falls back when all error entries are non-scalar');

my $empty_with_nested_errors = $runner->decode_script_response(encode_json({
    errors => [ { bad => 1 } ],
}));

ok(!$empty_with_nested_errors->{ok}, 'legacy response with non-empty nested errors remains failed');
is_deeply($empty_with_nested_errors->{errors}, [ 'script response reported errors' ], 'legacy error response also falls back for nested-only errors');

my $action_runner = Mediabot::ScriptActionRunner->new(max_actions => 20);
my $plan = $action_runner->apply_actions_dry({
    ok       => 0,
    response => {
        ok     => 0,
        errors => [ { bad => 1 }, [ 'nested' ], 'action layer scalar error' ],
    },
}, { channel => '#teuk' });

ok(!$plan->{ok}, 'ScriptActionRunner keeps failed result closed');
is_deeply($plan->{planned}, [], 'ScriptActionRunner plans no actions for failed nested diagnostics');
ok(ref($plan->{errors}) eq 'ARRAY', 'ScriptActionRunner returns structured errors');
is_deeply([ map { $_->{error} } @{ $plan->{errors} } ], [ 'action layer scalar error' ], 'ScriptActionRunner keeps only scalar propagated diagnostics');
ok(!scalar(grep { $_->{error} =~ /HASH\(|ARRAY\(/ } @{ $plan->{errors} || [] }), 'ScriptActionRunner never stringifies nested propagated errors');

my $plan_nested_only = $action_runner->apply_actions_dry({
    ok       => 0,
    response => {
        ok     => 0,
        errors => [ { bad => 1 }, [ 'nested' ] ],
    },
}, { channel => '#teuk' });

ok(!$plan_nested_only->{ok}, 'ScriptActionRunner nested-only diagnostics remain failed');
is_deeply([ map { $_->{error} } @{ $plan_nested_only->{errors} } ], [ 'script result is not ok' ], 'ScriptActionRunner falls back when all propagated diagnostics are non-scalar');

my $source_runner = do { local $/; open my $fh, '<', 'Mediabot/ScriptRunner.pm' or die $!; <$fh> };
my $source_action = do { local $/; open my $fh, '<', 'Mediabot/ScriptActionRunner.pm' or die $!; <$fh> };

like($source_runner, qr/mb256-B1/, 'ScriptRunner source contains mb256 scalar error marker');
like($source_action, qr/mb256-B2/, 'ScriptActionRunner source contains mb256 scalar error marker');
unlike($source_runner . $source_action, qr/`[^`]+`|\bqx\s*(?:\/|\(|\{)|\bsystem\s*(?:\(| )/, 'mb256 scalar error guard does not introduce shell execution');

done_testing();
