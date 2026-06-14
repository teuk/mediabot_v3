#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../..";

use Mediabot::ScriptActionRunner;

{
    package MB243::Logger;
    sub new { bless { info => [], log => [] }, shift }
    sub info { my ($self, $msg) = @_; push @{ $self->{info} }, $msg; return 1 }
    sub log  { my ($self, $level, $msg) = @_; push @{ $self->{log} }, [$level, $msg]; return 1 }
}

{
    package MB243::Bot;
    sub new {
        my ($class, $logger) = @_;
        return bless { logger => $logger }, $class;
    }
}

my $logger = MB243::Logger->new;
my $bot    = MB243::Bot->new($logger);
my $runner = Mediabot::ScriptActionRunner->new(bot => $bot);

my $script_result = {
    ok       => 1,
    response => {
        ok      => 1,
        actions => [
            { type => 'log', level => 'info', text => 'single logger lookup still applies log action' },
        ],
        errors => [],
    },
};

my $plan = $runner->apply_actions($script_result, { channel => '#teuk' }, apply => 1, allow_irc => 0);

ok($plan->{ok}, 'log action plan remains valid');
ok($plan->{applied_ok}, 'log action applies successfully');
is(scalar @{ $plan->{applied} || [] }, 1, 'one log action is applied');
is($logger->{info}[0], 'single logger lookup still applies log action', 'hash logger info method receives log text');

my $source = do {
    local $/;
    open my $fh, '<', "$Bin/../../Mediabot/ScriptActionRunner.pm" or die $!;
    <$fh>;
};

my $decl_count = () = $source =~ /my \$hash_logger = eval \{ \$bot->\{logger\} \};/g;
is($decl_count, 1, 'ScriptActionRunner has exactly one hash_logger lexical declaration');
like($source, qr/mb243-B1/, 'ScriptActionRunner source contains mb243 single logger lookup marker');
unlike($source, qr/`[^`]+`|\bqx\s*(?:\/|\(|\{)|\bsystem\s*(?:\(|\s)/, 'mb243 cleanup does not introduce shell execution');

done_testing();
