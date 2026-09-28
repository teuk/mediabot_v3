# MB805: offline Spark replay must follow the instance's public prefix.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
BEGIN { unshift @INC, "$Bin/../.." }
use Mediabot::Spark::Replay qw(replay_events);

{
    package MB805::Conf;
    sub new { bless { prefix => $_[1] }, $_[0] }
    sub get {
        return $_[0]{prefix} if $_[1] eq 'main.MAIN_PROG_CMD_CHAR';
        return undef;
    }
}

my @chat = (
    { at => 0, type => 'line', nick => 'Alice', message => 'bonjour' },
    { at => 1, type => 'line', nick => 'Bob', message => 'un sujet' },
    { at => 2, type => 'line', nick => 'Alice', message => 'encore une idée' },
    { at => 3, type => 'line', nick => 'Bob', message => 'merci' },
);
my %base = (channel => '#room', bot_nick => 'Mediabot');
my $config = MB805::Conf->new('#');
my $with_command = replay_events(%base, conf => $config,
    events => [@chat,
        { at => 4, type => 'line', nick => 'Carol',
          message => '#rss probe https://example.org/feed' },
        { at => 50, type => 'probe' }]);
is($with_command->{probes}[0]{revival_reason}, 'bot_pressure',
    'configured # command becomes command pressure, not a human line');
is_deeply($with_command->{excluded}, {},
    'central conversation exclusions remain independent of own commands');

my $wrong_prefix = replay_events(%base, conf => MB805::Conf->new('!'),
    events => [@chat,
        { at => 4, type => 'line', nick => 'Carol', message => '#rss probe' },
        { at => 50, type => 'probe' }]);
isnt($wrong_prefix->{probes}[0]{revival_reason}, 'bot_pressure',
    'the old hard-coded prefix would misclassify a # command');

my $legacy = replay_events(%base, conf => MB805::Conf->new(undef),
    events => [@chat,
        { at => 4, type => 'line', nick => 'Carol', message => '!rss probe' },
        { at => 50, type => 'probe' }]);
is($legacy->{probes}[0]{revival_reason}, 'bot_pressure',
    'synthetic fixture without configured prefix keeps ! compatibility');

for my $invalid ("!\n", '!!', []) {
    my $accepted = eval {
        replay_events(%base, conf => MB805::Conf->new($invalid),
            events => [{ at => 0, type => 'probe' }]);
        1;
    };
    ok(!$accepted, 'invalid configured prefix is rejected before replay');
}

done_testing;
