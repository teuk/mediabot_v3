#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../..";

use Mediabot::ScriptRunner;
use Mediabot::ScriptActionRunner;
use JSON::PP qw(encode_json);

my $runner = Mediabot::ScriptRunner->new(max_actions => 3);

is($runner->max_actions, 3, 'ScriptRunner exposes configured max_actions');

my @three = map { { type => 'log', text => "ok $_" } } 1 .. 3;
my $ok_response = $runner->decode_script_response(encode_json({ ok => 1, actions => \@three }));
ok($ok_response->{ok}, 'ScriptRunner accepts action count at the configured limit');
is(scalar @{ $ok_response->{actions} }, 3, 'ScriptRunner preserves actions at the limit');

my @four = map { { type => 'log', text => "too many $_" } } 1 .. 4;
my $too_many = $runner->decode_script_response(encode_json({ ok => 1, actions => \@four }));
ok(!$too_many->{ok}, 'ScriptRunner rejects action count above the configured limit');
is_deeply($too_many->{actions}, [], 'ScriptRunner exposes no actions after action-count rejection');
like(join(' ', @{ $too_many->{errors} || [] }), qr/too many actions/i, 'ScriptRunner reports action-count rejection clearly');

my $low_runner = Mediabot::ScriptRunner->new(max_actions => -10);
is($low_runner->max_actions, 1, 'ScriptRunner clamps max_actions lower bound');

my $high_runner = Mediabot::ScriptRunner->new(max_actions => 5000);
is($high_runner->max_actions, 50, 'ScriptRunner clamps max_actions upper bound');

my $action_runner = Mediabot::ScriptActionRunner->new(max_actions => 3);
is($action_runner->max_actions, 3, 'ScriptActionRunner exposes configured max_actions');

my $plan_ok = $action_runner->plan_actions(\@three, { channel => '#teuk' });
ok($plan_ok->{ok}, 'ScriptActionRunner plans action count at the configured limit');
is(scalar @{ $plan_ok->{planned} }, 3, 'ScriptActionRunner keeps planned actions at the limit');

my $plan_bad = $action_runner->plan_actions(\@four, { channel => '#teuk' });
ok(!$plan_bad->{ok}, 'ScriptActionRunner rejects action count above the configured limit');
is_deeply($plan_bad->{planned}, [], 'ScriptActionRunner plans nothing after action-count rejection');
like(($plan_bad->{errors}[0]{error} || ''), qr/too many actions/i, 'ScriptActionRunner reports action-count rejection clearly');

my $legacy_script_result = {
    response => {
        ok      => 1,
        actions => \@four,
    },
};
my $dry_plan = $action_runner->apply_actions_dry($legacy_script_result, { channel => '#teuk' });
ok(!$dry_plan->{ok}, 'apply_actions_dry rejects too many legacy actions');
is_deeply($dry_plan->{planned}, [], 'apply_actions_dry keeps action layer closed for too many actions');

my $source_runner = do {
    open my $fh, '<', 'Mediabot/ScriptRunner.pm' or die $!;
    local $/;
    <$fh>;
};
like($source_runner, qr/mb237-B1/, 'ScriptRunner source contains mb237 marker');

my $source_action = do {
    open my $fh, '<', 'Mediabot/ScriptActionRunner.pm' or die $!;
    local $/;
    <$fh>;
};
like($source_action, qr/mb237-B2/, 'ScriptActionRunner source contains mb237 marker');

unlike($source_runner . $source_action, qr/\bsystem\s*(?:\(| )|\bqx\s*(?:\/|\(|\{)|`[^`]+`/, 'mb237 action-count guard does not introduce shell execution');

done_testing();
