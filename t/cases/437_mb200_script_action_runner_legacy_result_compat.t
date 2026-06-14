#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use File::Spec;
use lib File::Spec->rel2abs(File::Spec->curdir());

use Mediabot::ScriptActionRunner;

{
    package MB200::FakeIRC;
    sub new { bless { sent => [] }, shift }
    sub send_message {
        my ($self, @args) = @_;
        push @{ $self->{sent} }, \@args;
        return 1;
    }
    sub sent { return $_[0]->{sent}; }
}

{
    package MB200::FakeLogger;
    sub new { bless { entries => [] }, shift }
    sub log {
        my ($self, $level, $text) = @_;
        push @{ $self->{entries} }, [ $level, $text ];
        return 1;
    }
    sub info {
        my ($self, $text) = @_;
        push @{ $self->{entries} }, [ 'info', $text ];
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

my $irc    = MB200::FakeIRC->new;
my $logger = MB200::FakeLogger->new;
my $runner = Mediabot::ScriptActionRunner->new(
    bot => {
        irc    => $irc,
        logger => $logger,
    },
    max_text_length => 400,
);

my $context = { channel => '#teuk', nick => 'Te[u]K', command => 'legacy' };

my $legacy_result = {
    response => {
        actions => [
            { type => 'reply', target => '#teuk', text => 'legacy reply' },
            { type => 'log', level => 'info', text => 'legacy log' },
        ],
    },
};

my $dry = $runner->apply_actions($legacy_result, $context);
ok($dry->{dry_run}, 'legacy result without top-level ok remains dry-run by default');
ok($dry->{ok}, 'legacy result without top-level ok still validates');
ok(ref($dry->{planned}) eq 'ARRAY' && @{ $dry->{planned} } == 2,
   'legacy result without top-level ok still plans actions');

my $apply = $runner->apply_actions($legacy_result, $context, apply => 1, allow_irc => 1);
ok(!$apply->{dry_run}, 'legacy result can enter apply mode');
ok($apply->{applied_ok}, 'legacy result can apply successfully');
ok(ref($apply->{applied}) eq 'ARRAY' && @{ $apply->{applied} } == 2,
   'legacy result applies reply and log actions');
ok(@{ $irc->sent } == 1, 'legacy result sends one IRC message');
ok($irc->sent->[0][0] eq 'PRIVMSG' && $irc->sent->[0][2] eq '#teuk' && $irc->sent->[0][3] eq 'legacy reply',
   'legacy reply keeps argv-style IRC payload');
ok(@{ $logger->entries } == 1 && $logger->entries->[0][1] eq 'legacy log',
   'legacy log action is still applied');

my $failed_top = {
    ok       => 0,
    error    => 'subprocess failed',
    response => {
        actions => [ { type => 'reply', text => 'must not be planned' } ],
    },
};

my $failed_plan = $runner->apply_actions_dry($failed_top, $context);
ok(!$failed_plan->{ok}, 'explicit top-level ok=0 is still rejected');
ok(@{ $failed_plan->{planned} } == 0, 'explicit top-level failure plans zero actions');

my $failed_response = {
    response => {
        ok      => 0,
        errors  => [ 'script response failed' ],
        actions => [ { type => 'reply', text => 'must not be planned either' } ],
    },
};

my $failed_response_plan = $runner->apply_actions_dry($failed_response, $context);
ok(!$failed_response_plan->{ok}, 'explicit response ok=0 is rejected');
ok(@{ $failed_response_plan->{planned} } == 0, 'explicit response failure plans zero actions');
ok(join(' ', map { $_->{error} || '' } @{ $failed_response_plan->{errors} }) =~ /script response failed|script result is not ok/,
   'explicit response failure preserves a useful error');

my $src_file = File::Spec->catfile('Mediabot', 'ScriptActionRunner.pm');
open my $fh, '<', $src_file or die "cannot open $src_file: $!";
my $src = do { local $/; <$fh> };
close $fh;

ok($src =~ /mb200-B1: preserve legacy ScriptActionRunner callers/,
   'ScriptActionRunner contains mb200 compatibility marker');
ok($src =~ /exists \$script_result->\{ok\}/,
   'ScriptActionRunner rejects explicit top-level failure only');
ok($src =~ /exists \$response->\{ok\}/,
   'ScriptActionRunner rejects explicit response failure');
ok($src !~ /dbh->|prepare\(|INSERT|UPDATE|DELETE|system\s*\(|qx\//,
   'mb200 compatibility guard does not introduce DB writes or shell execution');

if (@fail) {
    print "FAILED: @fail\n";
    exit 1;
}

exit 0;
