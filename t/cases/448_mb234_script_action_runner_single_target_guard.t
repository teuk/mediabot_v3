#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../..";

use Mediabot::ScriptActionRunner;

{
    package MB234FakeIRC;
    sub new { bless { sent => [] }, shift }
    sub send_message {
        my ($self, @argv) = @_;
        push @{ $self->{sent} }, \@argv;
        return 1;
    }
}

my $irc = MB234FakeIRC->new;
my $bot = bless { irc => $irc }, 'MB234FakeBot';
my $runner = Mediabot::ScriptActionRunner->new(bot => $bot, max_text_length => 400);

sub result_for {
    my (@actions) = @_;
    return {
        ok       => 1,
        timeout  => 0,
        response => {
            ok      => 1,
            errors  => [],
            actions => \@actions,
        },
    };
}

my $comma_plan = $runner->apply_actions(
    result_for({ type => 'reply', target => '#safe,#other', text => 'fan-out attempt' }),
    { channel => '#safe' },
    apply     => 1,
    allow_irc => 1,
);

ok(!$comma_plan->{ok}, 'comma-separated IRC target is rejected during planning');
is(scalar @{ $comma_plan->{planned} || [] }, 0, 'comma target plans no action');
is(scalar @{ $irc->{sent} }, 0, 'comma target sends no IRC message');
like(($comma_plan->{errors}[0]{error} || ''), qr/multiple recipients/, 'comma target reports multiple recipients');

my $colon_plan = $runner->apply_actions(
    result_for({ type => 'notice', target => ':nick', text => 'bad prefix' }),
    { channel => '#safe' },
    apply     => 1,
    allow_irc => 1,
);

ok(!$colon_plan->{ok}, 'colon-prefixed target is rejected during planning');
is(scalar @{ $colon_plan->{planned} || [] }, 0, 'colon target plans no action');
like(($colon_plan->{errors}[0]{error} || ''), qr/forbidden prefix/, 'colon target reports forbidden prefix');

my $ctx_comma_plan = $runner->apply_actions(
    result_for({ type => 'reply', text => 'context target fan-out' }),
    { channel => '#safe,#other' },
    apply     => 1,
    allow_irc => 1,
);

ok(!$ctx_comma_plan->{ok}, 'comma-separated context default target is rejected');
is(scalar @{ $ctx_comma_plan->{planned} || [] }, 0, 'bad context target plans no action');

my $safe_channel_plan = $runner->apply_actions(
    result_for({ type => 'reply', target => '#safe', text => 'hello channel' }),
    { channel => '#fallback' },
    apply     => 1,
    allow_irc => 1,
);

ok($safe_channel_plan->{ok}, 'normal channel target remains valid');
ok($safe_channel_plan->{applied_ok}, 'normal channel target still applies');
is(scalar @{ $irc->{sent} }, 1, 'safe channel target sends one IRC message');
is_deeply($irc->{sent}[0], [ 'PRIVMSG', undef, '#safe', 'hello channel' ], 'safe channel uses argv-style PRIVMSG payload');

my $safe_nick_plan = $runner->apply_actions(
    result_for({ type => 'notice', target => 'TeuK', text => 'hello nick' }),
    { channel => '#fallback' },
    apply     => 1,
    allow_irc => 1,
);

ok($safe_nick_plan->{ok}, 'normal nick target remains valid');
ok($safe_nick_plan->{applied_ok}, 'normal nick target still applies');
is(scalar @{ $irc->{sent} }, 2, 'safe nick target sends one more IRC message');
is_deeply($irc->{sent}[1], [ 'NOTICE', undef, 'TeuK', 'hello nick' ], 'safe nick uses argv-style NOTICE payload');

open my $fh, '<', 'Mediabot/ScriptActionRunner.pm' or die "cannot read ScriptActionRunner.pm: $!";
my $src = do { local $/; <$fh> };
close $fh;

like($src, qr/mb234-B1: keep the destination to one IRC recipient/, 'ScriptActionRunner source contains mb234 single-target marker');
unlike($src, qr/dbh->|prepare\(|INSERT|UPDATE|DELETE|system\s*\(|qx\//, 'mb234 guard does not introduce DB writes or shell execution');

done_testing();
