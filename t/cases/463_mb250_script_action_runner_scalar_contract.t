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

my $type_ref = $runner->plan_actions([ { type => { bad => 1 }, text => 'hello', target => '#teuk' } ], $ctx);
ok(!$type_ref->{ok}, 'structured action type is rejected');
like(first_error_text($type_ref), qr/action type must be scalar/, 'structured action type reports scalar contract');

my $text_ref = $runner->plan_actions([ { type => 'reply', text => { bad => 1 }, target => '#teuk' } ], $ctx);
ok(!$text_ref->{ok}, 'structured reply text is rejected');
like(first_error_text($text_ref), qr/text must be scalar/, 'structured reply text reports scalar contract');

my $target_ref = $runner->plan_actions([ { type => 'notice', text => 'hello', target => [ '#teuk' ] } ], $ctx);
ok(!$target_ref->{ok}, 'structured IRC target is rejected');
like(first_error_text($target_ref), qr/target must be scalar/, 'structured IRC target reports scalar contract');

my $timer_name_ref = $runner->plan_actions([ { type => 'timer', name => { later => 1 }, delay => 5 } ], $ctx);
ok(!$timer_name_ref->{ok}, 'structured timer name is rejected');
like(first_error_text($timer_name_ref), qr/timer name must be scalar/, 'structured timer name reports scalar contract');

my $timer_delay_ref = $runner->plan_actions([ { type => 'timer', name => 'safe.timer', delay => [ 5 ] } ], $ctx);
ok(!$timer_delay_ref->{ok}, 'structured timer delay is rejected');
like(first_error_text($timer_delay_ref), qr/invalid timer delay/, 'structured timer delay reports invalid delay');

my $timer_delay_junk = $runner->plan_actions([ { type => 'timer', name => 'safe.timer', delay => '10seconds' } ], $ctx);
ok(!$timer_delay_junk->{ok}, 'mixed timer delay string is rejected');
like(first_error_text($timer_delay_junk), qr/invalid timer delay/, 'mixed timer delay reports invalid delay');

my $valid = $runner->plan_actions([
    { type => 'reply', text => 'hello from JSON', target => '#teuk' },
    { type => 'notice', text => 'private hello', target => 'TeuK' },
    { type => 'log', level => 'info', text => 'script bridge log' },
    { type => 'timer', name => 'safe.timer-1', delay => '30' },
], $ctx);
ok($valid->{ok}, 'valid scalar reply/notice/log/timer actions still plan successfully');
is(scalar @{ $valid->{planned} || [] }, 4, 'all valid scalar actions are preserved');
is($valid->{planned}[3]{delay}, 30, 'numeric timer delay string is normalized to integer');

my $source = do { local $/; open my $fh, '<', 'Mediabot/ScriptActionRunner.pm' or die $!; <$fh> };
like($source, qr/mb250-B1/, 'ScriptActionRunner source contains mb250 scalar contract marker');
unlike($source, qr/`[^`]+`|\bqx\s*(?:\/|\(|\{)|\bsystem\s*(?:\(| )/, 'mb250 scalar contract does not introduce shell execution');

done_testing();
