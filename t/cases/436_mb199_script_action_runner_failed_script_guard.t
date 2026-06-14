#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use File::Spec;
use lib File::Spec->rel2abs(File::Spec->curdir());

use Mediabot::ScriptActionRunner;

{
    package MB199::FakeIRC;
    sub new { bless { messages => [] }, shift }
    sub send_message {
        my ($self, @args) = @_;
        push @{ $self->{messages} }, \@args;
        return 1;
    }
    sub messages { return $_[0]->{messages}; }
}

{
    package MB199::FakeLogger;
    sub new { bless { entries => [] }, shift }
    sub log {
        my ($self, @args) = @_;
        push @{ $self->{entries} }, \@args;
        return 1;
    }
    sub entries { return $_[0]->{entries}; }
}

my @fail;

sub ok {
    my ($cond, $msg) = @_;
    if ($cond) {
        print "ok - $msg\n";
    }
    else {
        print "not ok - $msg\n";
        push @fail, $msg;
    }
}

my $irc = MB199::FakeIRC->new;
my $logger = MB199::FakeLogger->new;
my $runner = Mediabot::ScriptActionRunner->new(
    bot => {
        irc    => $irc,
        logger => $logger,
    },
    max_text_length => 400,
);

my $context = {
    event   => 'public_command',
    channel => '#teuk',
    target  => '#teuk',
    nick    => 'Te[u]K',
    command => 'badscript',
    args    => [],
};

my $failed_path = {
    ok       => 0,
    error    => 'parent directory traversal is not allowed',
    timeout  => 0,
    response => {
        ok      => 0,
        errors  => [ 'script path rejected' ],
        actions => [ { type => 'reply', text => 'must not be planned' } ],
    },
};

my $dry = $runner->apply_actions_dry($failed_path, $context);
ok(ref($dry) eq 'HASH', 'failed script result returns a structured dry plan');
ok(!$dry->{ok}, 'failed script result keeps action plan closed');
ok($dry->{dry_run}, 'failed script result remains dry-run in planning path');
ok(ref($dry->{planned}) eq 'ARRAY' && @{ $dry->{planned} } == 0,
   'failed script result does not plan decoded actions');
ok(ref($dry->{errors}) eq 'ARRAY' && @{ $dry->{errors} } >= 1,
   'failed script result exposes errors to caller');
ok(join(' ', map { $_->{error} || '' } @{ $dry->{errors} }) =~ /parent directory|script path rejected/,
   'failed script result preserves useful failure reason');

my $apply = $runner->apply_actions($failed_path, $context, apply => 1, allow_irc => 1);
ok(!$apply->{ok}, 'apply mode also treats failed script result as invalid plan');
ok(!$apply->{applied_ok}, 'apply mode refuses to apply failed script result');
ok(ref($apply->{applied}) eq 'ARRAY' && @{ $apply->{applied} } == 0,
   'apply mode applies no actions from failed script result');
ok(ref($apply->{apply_errors}) eq 'ARRAY' && $apply->{apply_errors}[0]{error} =~ /action plan is invalid/,
   'apply mode reports explicit invalid action plan error');
ok(@{ $irc->messages } == 0, 'failed script result sends no IRC message');
ok(@{ $logger->entries } == 0, 'failed script result applies no log action');

my $timeout_result = {
    ok       => 0,
    timeout  => 1,
    response => {
        ok      => 0,
        errors  => [ 'script timed out' ],
        actions => [ { type => 'reply', text => 'late output must not be trusted' } ],
    },
};

my $timeout_plan = $runner->apply_actions_dry($timeout_result, $context);
ok(!$timeout_plan->{ok}, 'timeout result is rejected before action planning');
ok(@{ $timeout_plan->{planned} } == 0, 'timeout result plans zero actions');
ok(join(' ', map { $_->{error} || '' } @{ $timeout_plan->{errors} }) =~ /timed out/,
   'timeout error is preserved');

my $good_result = {
    ok       => 1,
    response => {
        ok      => 1,
        errors  => [],
        actions => [ { type => 'reply', text => 'good action' } ],
    },
};

my $good_plan = $runner->apply_actions_dry($good_result, $context);
ok($good_plan->{ok}, 'successful script result still plans actions normally');
ok(@{ $good_plan->{planned} } == 1 && $good_plan->{planned}[0]{text} eq 'good action',
   'successful script result preserves valid action planning');

my $src_file = File::Spec->catfile('Mediabot', 'ScriptActionRunner.pm');
open my $fh, '<', $src_file or die "cannot open $src_file: $!";
my $src = do { local $/; <$fh> };
close $fh;

ok($src =~ /mb199-B1: never plan or apply actions when ScriptRunner itself failed/,
   'ScriptActionRunner contains mb199 guard marker');
ok($src =~ /_failed_script_result_errors/,
   'ScriptActionRunner has helper to preserve failed script errors');
ok($src !~ /dbh->|prepare\(|INSERT|UPDATE|DELETE|system\s*\(|qx\//,
   'mb199 guard does not introduce DB writes or shell execution');

if (@fail) {
    print "FAILED: @fail\n";
    exit 1;
}

exit 0;
