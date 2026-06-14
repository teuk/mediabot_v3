#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use JSON::PP qw(decode_json);

use lib '.';
use Mediabot::ScriptActionRunner;

my $runner = Mediabot::ScriptActionRunner->new();
my $ctx = { channel => '#teuk' };

sub plan_for {
    my ($script_result) = @_;
    return $runner->apply_actions_dry($script_result, $ctx);
}

my $valid_response = {
    ok      => 1,
    actions => [ { type => 'reply', text => 'hello' } ],
};

my $legacy = plan_for({ response => { actions => [ { type => 'reply', text => 'legacy' } ] } });
ok($legacy->{ok}, 'legacy response without ok still plans actions');
is(scalar @{ $legacy->{planned} || [] }, 1, 'legacy response without ok plans one action');

my $top_ok = plan_for({ ok => 1, response => $valid_response });
ok($top_ok->{ok}, 'top-level numeric ok=1 still plans actions');
is(scalar @{ $top_ok->{planned} || [] }, 1, 'top-level numeric ok=1 plans one action');

my $json_bool_ok = plan_for({ ok => decode_json('true'), response => { ok => decode_json('true'), actions => [ { type => 'reply', text => 'json bool' } ] } });
ok($json_bool_ok->{ok}, 'JSON boolean ok=true is accepted');
is(scalar @{ $json_bool_ok->{planned} || [] }, 1, 'JSON boolean ok=true plans one action');

my $top_false = plan_for({ ok => 0, response => $valid_response });
ok(!$top_false->{ok}, 'top-level ok=0 closes the action layer');
is(scalar @{ $top_false->{planned} || [] }, 0, 'top-level ok=0 plans no actions');
like($top_false->{errors}[0]{error}, qr/script result is not ok|not ok/, 'top-level ok=0 reports not ok');

my $response_false = plan_for({ ok => 1, response => { ok => 0, actions => [ { type => 'reply', text => 'nope' } ] } });
ok(!$response_false->{ok}, 'response ok=0 closes the action layer');
is(scalar @{ $response_false->{planned} || [] }, 0, 'response ok=0 plans no actions');
like($response_false->{errors}[0]{error}, qr/script response is not ok|not ok/, 'response ok=0 reports not ok');

my $top_array = plan_for({ ok => [1], response => $valid_response });
ok(!$top_array->{ok}, 'top-level ok ARRAY is rejected');
is(scalar @{ $top_array->{planned} || [] }, 0, 'top-level ok ARRAY plans no actions');
like($top_array->{errors}[0]{error}, qr/top-level ok must be a JSON boolean or 0\/1 scalar/, 'top-level ok ARRAY reports scalar contract');

my $top_string_true = plan_for({ ok => 'true', response => $valid_response });
ok(!$top_string_true->{ok}, 'top-level ok string true is rejected');
is(scalar @{ $top_string_true->{planned} || [] }, 0, 'top-level ok string true plans no actions');
like($top_string_true->{errors}[0]{error}, qr/top-level ok must be a JSON boolean or 0\/1 scalar/, 'top-level ok string true reports scalar contract');

my $response_hash = plan_for({ ok => 1, response => { ok => { bad => 1 }, actions => [ { type => 'reply', text => 'bad' } ] } });
ok(!$response_hash->{ok}, 'response ok HASH is rejected');
is(scalar @{ $response_hash->{planned} || [] }, 0, 'response ok HASH plans no actions');
like($response_hash->{errors}[0]{error}, qr/response ok must be a JSON boolean or 0\/1 scalar/, 'response ok HASH reports scalar contract');

my $src = do { local (@ARGV, $/) = ('Mediabot/ScriptActionRunner.pm'); <> };
like($src, qr/mb259-B1/, 'ScriptActionRunner source contains mb259 ok flag contract marker');
unlike($src, qr/\b(system|qx)\s*(?:\(|\/|\{)/, 'mb259 ok flag contract does not introduce shell execution');

done_testing();
