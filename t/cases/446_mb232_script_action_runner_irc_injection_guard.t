#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use File::Spec;
use lib File::Spec->rel2abs(File::Spec->curdir());

use Mediabot::ScriptActionRunner;

{
    package MB232::FakeIRC;
    sub new { bless { messages => [] }, shift }
    sub send_message {
        my ($self, @args) = @_;
        push @{ $self->{messages} }, \@args;
        return 1;
    }
    sub messages { return $_[0]->{messages}; }
}

my @fail;
sub ok {
    my ($cond, $msg) = @_;
    if ($cond) { print "ok - $msg\n"; }
    else       { print "not ok - $msg\n"; push @fail, $msg; }
}

my $irc = MB232::FakeIRC->new;
my $runner = Mediabot::ScriptActionRunner->new(
    bot             => { irc => $irc },
    max_text_length => 400,
);

my $context = {
    event   => 'public_command',
    channel => '#teuk',
    target  => '#teuk',
    nick    => 'Te[u]K',
    command => 'pyhello',
    args    => [],
};

my ($ok_reply, $err_reply) = $runner->validate_action(
    { type => 'reply', target => '#teuk', text => "safe line\r\nPRIVMSG #ops :pwned" },
    $context,
);
ok(!$ok_reply && $err_reply =~ /forbidden control/, 'reply text with CRLF is rejected');

my ($ok_notice, $err_notice) = $runner->validate_action(
    { type => 'notice', target => "Te[u]K\n#ops", text => 'hello' },
    $context,
);
ok(!$ok_notice && $err_notice =~ /forbidden control/, 'notice target with newline is rejected');

my ($ok_space_target, $err_space_target) = $runner->validate_action(
    { type => 'reply', target => '#teuk #ops', text => 'hello' },
    $context,
);
ok(!$ok_space_target && $err_space_target =~ /whitespace/, 'reply target with whitespace is rejected');

my ($ok_nul, $err_nul) = $runner->validate_action(
    { type => 'reply', target => '#teuk', text => "hello\0there" },
    $context,
);
ok(!$ok_nul && $err_nul =~ /forbidden control/, 'reply text with NUL is rejected');

my ($ok_default_target, $err_default_target, $planned_default) = $runner->validate_action(
    { type => 'reply', text => 'default target remains safe' },
    $context,
);
ok($ok_default_target && $planned_default->{target} eq '#teuk', 'default channel target still works');

my ($ok_good, $err_good, $planned_good) = $runner->validate_action(
    { type => 'notice', target => 'Te[u]K', text => 'single safe line' },
    $context,
);
ok($ok_good && $planned_good->{type} eq 'notice' && $planned_good->{target} eq 'Te[u]K', 'normal notice action still validates');

my $bad_result = {
    ok       => 1,
    response => {
        ok      => 1,
        errors  => [],
        actions => [
            { type => 'reply', target => '#teuk', text => "first\nsecond" },
            { type => 'notice', target => 'Te[u]K', text => 'this must not be applied' },
        ],
    },
};

my $plan = $runner->apply_actions($bad_result, $context, apply => 1, allow_irc => 1);
ok(!$plan->{ok}, 'mixed action plan is invalid when one IRC text contains newline');
ok(!$plan->{applied_ok}, 'invalid mixed action plan is not applied');
ok(ref($plan->{applied}) eq 'ARRAY' && @{ $plan->{applied} } == 0, 'invalid mixed action applies no IRC actions');
ok(@{ $irc->messages } == 0, 'invalid mixed action sends no IRC messages');

my $good_result = {
    ok       => 1,
    response => {
        ok      => 1,
        errors  => [],
        actions => [ { type => 'reply', target => '#teuk', text => 'one safe line' } ],
    },
};

my $good_apply = $runner->apply_actions($good_result, $context, apply => 1, allow_irc => 1);
ok($good_apply->{applied_ok}, 'safe single-line reply still applies');
ok(@{ $irc->messages } == 1, 'safe single-line reply sends one IRC message');
ok($irc->messages->[0][0] eq 'PRIVMSG' && $irc->messages->[0][2] eq '#teuk' && $irc->messages->[0][3] eq 'one safe line',
   'safe single-line reply keeps argv-style IRC payload');

my $src_file = File::Spec->catfile('Mediabot', 'ScriptActionRunner.pm');
open my $fh, '<', $src_file or die "cannot open $src_file: $!";
my $src = do { local $/; <$fh> };
close $fh;

ok($src =~ /mb232-B1: script-generated actions must remain single IRC\/log lines/, 'ScriptActionRunner source contains mb232 text guard marker');
ok($src =~ /mb232-B2: keep IRC destinations as a single target token/, 'ScriptActionRunner source contains mb232 target guard marker');
ok($src !~ /dbh->|prepare\(|INSERT|UPDATE|DELETE|system\s*\(|qx\//, 'mb232 guard does not introduce DB writes or shell execution');

if (@fail) {
    print "FAILED: @fail\n";
    exit 1;
}

exit 0;
