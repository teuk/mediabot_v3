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

my @many_errors = map { "error $_\nwith newline\0and nul " . ('x' x 300) } 1 .. 80;
my $decoded = $runner->decode_script_response(encode_json({
    ok      => JSON::PP::false,
    errors  => \@many_errors,
    actions => [ { type => 'reply', text => 'must not leak', target => '#teuk' } ],
}));

ok(!$decoded->{ok}, 'script-declared failure remains failed');
is_deeply($decoded->{actions}, [], 'script-declared failure exposes no actions');
ok(ref($decoded->{errors}) eq 'ARRAY', 'script-declared failure returns error array');
ok(@{ $decoded->{errors} } <= 20, 'ScriptRunner caps script-declared error count');
ok(!scalar(grep { /[\r\n\0]/ } @{ $decoded->{errors} }), 'ScriptRunner strips CR/LF/NUL from errors');
ok(!scalar(grep { length($_) > 240 } @{ $decoded->{errors} }), 'ScriptRunner caps individual error length');

my $empty_errors = $runner->decode_script_response(encode_json({
    ok     => JSON::PP::false,
    errors => [ "\n\r\0" ],
}));

ok(!$empty_errors->{ok}, 'empty-looking failure error remains failed');
is($empty_errors->{errors}[0], 'script response reported failure', 'ScriptRunner keeps fallback error when all details are empty');

my $action_runner = Mediabot::ScriptActionRunner->new(max_actions => 20);
my $plan = $action_runner->apply_actions_dry({
    ok       => 0,
    response => {
        ok     => 0,
        errors => \@many_errors,
    },
}, { channel => '#teuk' });

ok(!$plan->{ok}, 'ScriptActionRunner keeps failed script result closed');
is_deeply($plan->{planned}, [], 'ScriptActionRunner plans no actions for failed result');
ok(ref($plan->{errors}) eq 'ARRAY', 'ScriptActionRunner returns structured errors');
ok(@{ $plan->{errors} } <= 20, 'ScriptActionRunner caps propagated error count');
ok(!scalar(grep { $_->{error} =~ /[\r\n\0]/ } @{ $plan->{errors} }), 'ScriptActionRunner strips CR/LF/NUL from propagated errors');
ok(!scalar(grep { length($_->{error}) > 240 } @{ $plan->{errors} }), 'ScriptActionRunner caps propagated error length');

my $source_runner = do { local $/; open my $fh, '<', 'Mediabot/ScriptRunner.pm' or die $!; <$fh> };
my $source_action = do { local $/; open my $fh, '<', 'Mediabot/ScriptActionRunner.pm' or die $!; <$fh> };

like($source_runner, qr/mb239-B1/, 'ScriptRunner source contains mb239 bounded error marker');
like($source_action, qr/mb239-B2/, 'ScriptActionRunner source contains mb239 bounded error marker');
unlike($source_runner . $source_action, qr/`[^`]+`|\bqx\s*(?:\/|\(|\{)|\bsystem\s*(?:\(| )/, 'mb239 bounded error guard does not introduce shell execution');

done_testing();
