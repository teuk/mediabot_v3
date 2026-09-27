use strict;
use warnings;
use utf8;
use Test::More;
use FindBin qw($Bin);

BEGIN { unshift @INC, "$Bin/../.." }
use Mediabot::AI::ConversationAudit qw(audit_exclusions);

{
    package MB797::Config;
    sub new { bless { values => $_[1] }, $_[0] }
    sub get { $_[0]{values}{$_[1]} }
}

my $values = {
    'conversation.CHANNEL_BOTS' => 'i/o:Coin|other:Relay',
    'conversation.CHANNEL_COMMANDS' => 'i/o:!bang+!pan|other:!bread',
};
my $conf = MB797::Config->new($values);
my %base = (conf => $conf, channel => '#i/o', bot_nick => 'nbot');

my $audit = audit_exclusions(%base,
    commands => ['!bang', '!pan', '!bread', '!birdcall'], bots => ['Coin']);
ok($audit->{ok}, 'audit runs against the runtime exclusion classifier');
is_deeply($audit->{missing_commands}, ['!birdcall', '!bread'],
    'missing external commands are named without inventing coverage');
is_deeply($audit->{missing_bots}, [],
    'bot sender and direct address both have coverage');
ok($audit->{ordinary_visible}, 'ordinary user text remains in the pipeline');
is($audit->{command_total}, 4, 'comparison counts the requested command set');
ok(!exists $audit->{message} && !exists $audit->{config},
    'report does not retain message text or private configuration');

$values->{'conversation.CHANNEL_COMMANDS'} =
    'i/o:!bang+!pan+!bread+!birdcall|other:!bread';
$audit = audit_exclusions(%base,
    commands => ['!BANG', '!birdcall', '!bread'], bots => ['Coin']);
is_deeply($audit->{missing_commands}, [],
    'same audit observes newly configured exact commands');
is($audit->{command_total}, 3,
    'case-folded command inventory remains bounded and unique');

$audit = audit_exclusions(%base, commands => ['!bang'], bots => ['Relay']);
is_deeply($audit->{missing_bots}, ['Relay'],
    'a bot declared for another channel cannot pass the channel audit');

$audit = audit_exclusions(%base, commands => ['!bang'], bots => ['nbot']);
ok(!$audit->{ok}, 'self-bot immunity cannot masquerade as external coverage');
$audit = audit_exclusions(%base, bot_nick => 'n[bot]',
    commands => ['!bang'], bots => ['n{bot}']);
ok(!$audit->{ok}, 'RFC1459 nick aliases cannot masquerade as external coverage');
$audit = audit_exclusions(%base, commands => ['!bang;cat'], bots => []);
ok(!$audit->{ok}, 'operator command input must be one exact safe word');
$audit = audit_exclusions(%base, commands => [], bots => []);
ok(!$audit->{ok}, 'empty inventory cannot produce a false passing audit');

done_testing;
