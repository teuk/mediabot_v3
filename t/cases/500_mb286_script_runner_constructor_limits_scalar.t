#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use Test::More;

use lib '.';
use Mediabot::ScriptRunner;
use Mediabot::ScriptActionRunner;

{
    package Local::MB286::ExplodingNumber;
    use overload
        '""' => sub { die 'object stringified unexpectedly' },
        '0+' => sub { die 'object numified unexpectedly' },
        fallback => 1;
    sub new { bless {}, shift }
}

my @warnings;
{
    local $SIG{__WARN__} = sub { push @warnings, @_ };

    my $bad_limit = Local::MB286::ExplodingNumber->new;

    my $runner = Mediabot::ScriptRunner->new(
        timeout          => [ 30 ],
        max_stdout_bytes => { bad => 1 },
        max_stdin_bytes  => $bad_limit,
        max_actions      => sub { 99 },
    );

    is($runner->timeout, 3, 'ScriptRunner malformed timeout falls back to default');
    is($runner->max_stdout_bytes, 65536, 'ScriptRunner malformed stdout cap falls back to default');
    is($runner->max_stdin_bytes, 4194304, 'ScriptRunner malformed stdin cap falls back to default');
    is($runner->max_actions, 20, 'ScriptRunner malformed action cap falls back to default');

    my $good_runner = Mediabot::ScriptRunner->new(
        timeout          => ' 9 ',
        max_stdout_bytes => '2048',
        max_stdin_bytes  => '4096',
        max_actions      => '7',
    );

    is($good_runner->timeout, 9, 'ScriptRunner scalar timeout still applies');
    is($good_runner->max_stdout_bytes, 2048, 'ScriptRunner scalar stdout cap still applies');
    is($good_runner->max_stdin_bytes, 4096, 'ScriptRunner scalar stdin cap still applies');
    is($good_runner->max_actions, 7, 'ScriptRunner scalar action cap still applies');

    my $action_runner = Mediabot::ScriptActionRunner->new(
        max_text_length => [ 2000 ],
        max_actions     => { bad => 1 },
        max_errors      => $bad_limit,
    );

    is($action_runner->max_text_length, 400, 'ScriptActionRunner malformed text cap falls back to default');
    is($action_runner->max_actions, 20, 'ScriptActionRunner malformed action cap falls back to default');
    is($action_runner->max_errors, 20, 'ScriptActionRunner malformed error cap falls back to default');

    my $good_action_runner = Mediabot::ScriptActionRunner->new(
        max_text_length => '128',
        max_actions     => '6',
        max_errors      => '12',
    );

    is($good_action_runner->max_text_length, 128, 'ScriptActionRunner scalar text cap still applies');
    is($good_action_runner->max_actions, 6, 'ScriptActionRunner scalar action cap still applies');
    is($good_action_runner->max_errors, 12, 'ScriptActionRunner scalar error cap still applies');
}

is_deeply(\@warnings, [], 'malformed constructor limit refs emit no warnings or overload stringification');

done_testing();
