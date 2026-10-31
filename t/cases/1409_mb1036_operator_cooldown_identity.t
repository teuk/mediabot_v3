use strict;
use warnings;
use utf8;
use Test::More;
use Storable qw(dclone);
BEGIN { our $now = 1_900_000_000; *CORE::GLOBAL::time = sub { $main::now } }
use Mediabot::Partyline;
use Mediabot::Helpers ();
{
    package MB1036::Log;
    sub log { 1 }
    package MB1036::Metrics;
    sub inc { ++$_[0]{$_[1]}; 1 }
    package MB1036::Stream;
    sub write { $_[0]{text} .= $_[1]; 1 }
    package MB1036::NoIO;
    our $AUTOLOAD;
    sub AUTOLOAD { die 'Unexpected database or IRC operation' }
    sub DESTROY {}
}
my @warnings; local $SIG{__WARN__} = sub {push @warnings, @_};
my ($bot, $party, $stream);
sub setup_1409 {
    $bot = {logger => bless({}, 'MB1036::Log'), metrics => bless({}, 'MB1036::Metrics'),
        dbh => bless({}, 'MB1036::NoIO'), irc => bless({}, 'MB1036::NoIO')};
    $stream = bless({text => ''}, 'MB1036::Stream');
    # Construct the native dispatcher state without opening a listener.
    $party = bless({bot => $bot, users => {1 => {authenticated => 1, login => 'Owner',
        nick => 'Owner', level => 0}}, streams => {1 => $stream}}, 'Mediabot::Partyline');
}
sub operator_1409 {
    $main::now += 6; $stream->{text} = '';
    $party->_handle_line($stream, 1, $_[0]);
    return $stream->{text};
}
sub guard_1409 { Mediabot::Helpers::checkCmdCooldown($bot, $_[0], $_[1], $_[2]) }
my @aliases = qw(actualites news actu actualite);
setup_1409();
is_deeply([map {guard_1409('#test', $_)} @aliases], [0,45,45,45],
    'all paid-news aliases still share the default parent-side 45 second guard');
my $confirmation = operator_1409('.cmdcooldown #TeSt NeWs 90');
like($confirmation, qr/Cooldown for !news on #TeSt set to 1m30s\./,
    'confirmation retains the operator spelling and duration');
is_deeply($bot->{_cmd_cooldown_conf}, {'#test' => {actualites => 90}},
    'operator configuration uses the same channel and command identity as admission');
is_deeply([map {guard_1409('#TEST', $_)} @aliases], [0,90,90,90],
    'setting an alias resets the actual active group and enforces its new duration');
$main::now += 89;
is(guard_1409('#tEsT', 'ACTU'), 1, 'the configured alias group blocks until its last second');
++$main::now;
is(guard_1409('#test', 'actualite'), 0, 'the exact configured deadline permits the next request');
my $listing = operator_1409('.cmdcooldown');
like($listing, qr/Active cooldowns:.*#test\s+!actualites\s+1m30s/s,
    'the existing no-argument listing is reachable through the real dispatcher');
operator_1409('.cmdcooldown #TEST AcTu 0');
is_deeply([map {guard_1409('#test', $_)} @aliases], [0,0,0,0],
    'zero through one alias really disables the entire shared default cooldown');
ok(!exists($bot->{_cmd_cooldown}{'actualites:#test'}),
    'disabling an alias also clears the canonical active timestamp');

my @disabled;
for my $alias (@aliases) {
    setup_1409(); guard_1409('#test', 'actualites');
    operator_1409(".cmdcooldown #TeSt $alias 0");
    push @disabled, [map {guard_1409('#TEST', $_)} @aliases];
}
is_deeply(\@disabled, [map {[0,0,0,0]} @aliases],
    'every accepted alias can configure the shared group without cycling around its policy');
setup_1409();
$bot->{_cmd_cooldown_conf} = {'#other' => {actualites => 100}, '#test' => {ai => 20}};
$bot->{_cmd_cooldown} = {'actualites:#other' => $main::now, 'ai:#test' => $main::now};
my $unrelated = dclone([$bot->{_cmd_cooldown_conf}, $bot->{_cmd_cooldown}]);
operator_1409('.cmdcooldown #TeSt news 90');
delete $bot->{_cmd_cooldown_conf}{'#test'}{actualites};
is_deeply([$bot->{_cmd_cooldown_conf}, $bot->{_cmd_cooldown}], $unrelated,
    'configuration and reset leave other commands and channels untouched');
operator_1409('.cmdcooldown #TeSt AI 99999');
is_deeply([guard_1409('#TEST', 'ai'), guard_1409('#test', 'AI')], [0,3600],
    'ordinary commands use the same channel identity and retain the one-hour upper bound');
$bot->{_cmd_cooldown} = {};
is_deeply([guard_1409('#test', 'ai', 7), guard_1409('#test', 'ai', 7)], [0,7],
    'an explicit caller override still takes precedence over the operator setting');
my $before = dclone([$bot->{_cmd_cooldown_conf}, $bot->{_cmd_cooldown}]);
my $bad = operator_1409('.cmdcooldown #test news nope');
is_deeply([$bot->{_cmd_cooldown_conf}, $bot->{_cmd_cooldown}], $before,
    'malformed settings never change live admission state');
like($bad, qr/Usage: \.cmdcooldown/, 'malformed settings retain the syntax response');
is_deeply(\@warnings, [], 'native operator and admission paths are warning-free without DB or network IO');
done_testing;
