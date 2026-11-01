use strict;
use warnings;
use utf8;
use Test::More;
use Storable qw(dclone);
BEGIN { our $now=1_900_000_000; *CORE::GLOBAL::time=sub {$main::now} }
use Mediabot::Partyline;
use Mediabot::Helpers ();
use Mediabot::IRC::CommandThrottle ();
{
    package MB1056::Conf;
    sub get {$_[1] eq 'antiflood.CHANFLOOD_MAX_COMMANDS' ? 1 : undef}
    package MB1056::Log;
    sub log {push @{$_[0]{rows}},[@_[1,2]];1}
    package MB1056::Metrics;
    sub inc {++$_[0]{$_[1]};1}
    package MB1056::Stream;
    sub write {$_[0]{text}.=$_[1];1}
    package MB1056::NoIO;
    our $AUTOLOAD;
    sub AUTOLOAD {die 'Unexpected database or IRC operation'}
    sub DESTROY {}
}
my (@console,@warnings,$bot,$party,$stream);
local $SIG{__WARN__}=sub {push @warnings,@_};
no warnings qw(redefine once);
local *Mediabot::Helpers::noticeConsoleChan=sub {push @console,$_[1];1};
sub setup_1429 {
    @console=();$main::now=1_900_000_000;
    $bot={conf=>bless({},'MB1056::Conf'),logger=>bless({rows=>[]},'MB1056::Log'),
        metrics=>bless({},'MB1056::Metrics'),dbh=>bless({},'MB1056::NoIO'),irc=>bless({},'MB1056::NoIO')};
    $stream=bless({text=>''},'MB1056::Stream');
    $party=bless({bot=>$bot,users=>{1=>{authenticated=>1,login=>'Owner',nick=>'Owner',level=>0}},
        streams=>{1=>$stream}},'Mediabot::Partyline');
}
sub guard_1429 { Mediabot::Helpers::checkChanFlood($bot,$_[0]) }
sub operator_1429 {
    $main::now+=6;$stream->{text}='';
    $party->_handle_line($stream,1,$_[0]);
    return $stream->{text};
}
setup_1429();
is_deeply([guard_1429('#MiXeD'),guard_1429('#mixed'),
    Mediabot::IRC::CommandThrottle::checkChanFlood($bot,'#MIXED')],[0,1,1],
    'native facade and owner share the threshold across channel letter casing');
is_deeply([sort keys %{$bot->{_chan_flood}}],['#mixed'],
    'one canonical channel owns the active state');
is(scalar(@{$bot->{_chan_flood}{'#mixed'}{hits}}),2,
    'a silenced spelling cannot append more hits through another spelling');
is($bot->{metrics}{mediabot_chanflood_blocks_total},1,
    'one threshold crossing records one block; already-silenced requests retain their policy');
is(scalar(@console),1,'a casing change cannot create another console notification');
$main::now+=29;
is(guard_1429('#mIxEd'),1,'every spelling stays silent through the final second');
++$main::now;
is(guard_1429('#MIXED'),0,'the exact shared deadline admits a new request');
is_deeply([$bot->{_chan_flood}{'#mixed'}{silenced_until},scalar(@{$bot->{_chan_flood}{'#mixed'}{hits}})],[0,1],
    'expiry resets the same channel window before recording its first new hit');
is(guard_1429('#mixed'),1,'the new window still applies the existing threshold');
is(scalar(@console),1,'notification cooldown also survives channel casing changes');

setup_1429();
guard_1429('#mixed');
$bot->{_chan_flood}{'#other'}={hits=>[123],silenced_until=>0,notified_at=>42};
$bot->{_chan_flood_conf}{'#other'}={window=>17,max=>9,silence=>33,warn_only=>1};
my $other=dclone([$bot->{_chan_flood}{'#other'},$bot->{_chan_flood_conf}{'#other'}]);
my $confirm=operator_1429('.floodset #MiXeD 10 2 7');
like($confirm,qr/CC2: floodset #MiXeD .*window=10 max=2 silence=7/s,
    'native partyline confirmation preserves the operator channel spelling');
is_deeply($bot->{_chan_flood_conf}{'#mixed'},{window=>10,max=>2,silence=>7,warn_only=>0},
    'the operator setting addresses the canonical admission key');
ok(!exists($bot->{_chan_flood_conf}{'#MiXeD'}), 'operator settings never create a casing alias');
ok(!exists($bot->{_chan_flood}{'#mixed'}),'operator configuration resets the existing canonical window');
is_deeply([guard_1429('#MIXED'),guard_1429('#mixed'),guard_1429('#MiXeD')],[0,0,1],
    'the configured threshold applies to all spellings immediately');
is($bot->{_chan_flood}{'#mixed'}{silenced_until},$main::now+7,
    'the configured silence duration is applied to the common window');
my $status=operator_1429('.floodstatus');
like($status,qr/Channel flood \(AF4.*?#mixed\s+SILENCED/s,
    'native floodstatus reports the same silenced channel');
is_deeply([$bot->{_chan_flood}{'#other'},$bot->{_chan_flood_conf}{'#other'}],$other,
    'changing one channel preserves another channel state and operator settings');
operator_1429('.floodset #MIXED 10 1 20');
is_deeply([sort keys %{$bot->{_chan_flood_conf}}],['#mixed','#other'],
    'reconfiguration through a different spelling replaces one setting');
ok(!exists($bot->{_chan_flood}{'#mixed'}),'reconfiguration through another spelling clears the active silence');
is_deeply([guard_1429('#mixed'),guard_1429('#MiXeD')],[0,1],
    'the replacement threshold takes effect without keeping the previous counter');

setup_1429();
operator_1429('.floodset #MiXeD 10 1 7 warn-only');
is_deeply([guard_1429('#MIXED'),guard_1429('#mixed'),guard_1429('#MiXeD')],[0,0,0],
    'warn-only configured with mixed casing never starts a real silence');
is($bot->{_chan_flood}{'#mixed'}{silenced_until},0,'warn-only retains an unsilenced canonical window');
is($bot->{metrics}{mediabot_chanflood_blocks_total},2,'warn-only keeps the existing count of threshold exceedances');
is(scalar(@console),1,'warn-only notification cooldown is shared as well');
like($console[0]//'',qr/warn-only/,'the console event reports the configured warn-only behavior');
operator_1429('.floodset #mIxEd');
is_deeply($bot->{_chan_flood_conf}{'#mixed'},
    {window=>undef,max=>undef,silence=>undef,warn_only=>0},
    'resetting to defaults uses the same setting and turns warn-only off');
is_deeply([guard_1429('#MiXeD'),guard_1429('#MIXED')],[0,1],
    'native defaults resume immediately for every spelling');

setup_1429();
operator_1429('.floodset #MiXeD 0 0 0');
is_deeply($bot->{_chan_flood_conf}{'#mixed'},
    {window=>1,max=>1,silence=>1,warn_only=>0},'minimum-value clamping is preserved');
is_deeply([guard_1429('#MIXED'),guard_1429('#mixed'),guard_1429('#other'),guard_1429('#OTHER')],[0,1,0,1],
    'distinct channels keep separate thresholds while their own spellings share state');
my $before=dclone([$bot->{_chan_flood},$bot->{_chan_flood_conf}]);
is_deeply([map {guard_1429($_)} (undef,'','Caller','&room')],[0,0,0,0],
    'the historical public #channel admission boundary remains unchanged');
is_deeply([$bot->{_chan_flood},$bot->{_chan_flood_conf}],$before,
    'non-channel input never creates or changes flood state');
is_deeply(\@warnings,[],'native dispatcher, configuration, expiry and admission paths remain warning-free');
done_testing;
