use strict;
use warnings;
use utf8;
use Test::More;
use Storable qw(dclone);
BEGIN {*CORE::GLOBAL::time=sub () {2000}}
use Mediabot::Mediabot;
use Mediabot::Context;
use MockUser;
binmode Test::More->builder->output, ':encoding(UTF-8)';
binmode Test::More->builder->failure_output, ':encoding(UTF-8)';
{
    package MB1034::Metrics;
    sub inc {$_[0]{$_[1]}++;1}
    sub set {$_[0]{$_[1]}=$_[2];1}
    package MB1034::Bot;
    our @ISA=('Mediabot');
    sub botNotice {push @{$_[0]{wire}},['notice',$_[1],$_[2]];1}
}
my (@warnings,@audit);local $SIG{__WARN__}=sub {push @warnings,@_};
no warnings qw(redefine once);
local *Mediabot::UserCommands::botNotice=sub {push @{$_[0]{wire}},['notice',$_[1],$_[2]];1};
local *Mediabot::UserCommands::botPrivmsg=sub {push @{$_[0]{wire}},['public',$_[1],$_[2]];1};
local *Mediabot::Helpers::botPrivmsg=sub {push @{$_[0]{wire}},['public',$_[1],$_[2]];1};
local *Mediabot::UserCommands::logBot=sub {push @audit,[@_[2..$#_]];1};
my $master=MockUser->new(level=>'Master',auth=>1);
my $bot=Mediabot->new({});bless $bot,'MB1034::Bot';
$bot->{wire}=[];$bot->{metrics}=bless {},'MB1034::Metrics';
sub invoke_1407 {
    my ($command,$channel,$raw,$nick,$user)=@_;$bot->{wire}=[];
    my $ctx=Mediabot::Context->new(bot=>$bot,nick=>$nick//'Creator',channel=>$channel,
        command=>$command,args=>defined($raw)?[split / /,$raw]:[]);
    $ctx->{user}=$user//$master;$ctx->{_user_fetched}=1;
    return $bot->command_registry->handler_for($command,'public')->($ctx);
}
sub matching_1407 {my ($name)=@_;return grep {lc($_) eq lc($name)} keys %{$bot->{_polls}}}
sub text_1407 {join("\n",map {$_->[2]} @{$bot->{wire}})}
invoke_1407('poll','#Other','Other? | one | two');my $other=dclone($bot->{_polls}{'#Other'}//$bot->{_polls}{'#other'});
invoke_1407('poll','#TeSt','weighted 60 Thé ? | Oui:3 | Non:1');
my ($key)=matching_1407('#test');my $poll=$bot->{_polls}{$key};
invoke_1407('vote','#test','1','Alice');
is_deeply($poll->{votes},{alice=>0},'vote finds the poll despite another spelling of the same channel');
invoke_1407('pollstatus','#TEST');
like(text_1407(),qr/Thé.*Oui \(x3\): 1=3 \(100%\)/s,'live status finds the same weighted tally across channel case');
is($bot->{wire}[0][1],'#TEST','wire replies retain the caller channel spelling');
invoke_1407('pollresult','#tEsT');
like(text_1407(),qr/Winner: Oui \(100% weighted\)/,'result lookup shares the canonical in-memory poll');
invoke_1407('pollvoters','#test');
like(text_1407(),qr/\[1\] Oui \(1\): alice/,'authorized voter breakdown finds ballots through another channel spelling');
invoke_1407('unvote','#TEST',undef,'Alice');
ok(!keys(%{$poll->{votes}}) && text_1407()=~/cancelled their vote/,'withdrawal uses the same channel identity');
invoke_1407('pollextend','#test','30');
is($poll->{deadline},2090,'extension reaches the existing poll without inventing another slot');
invoke_1407('poll','#test','Replacement? | A | B');
my @keys=matching_1407('#test');
is(scalar(@keys),1,'creating via another case cannot leave two polls for one channel');
invoke_1407('pollstop','#TEST');
ok(text_1407()=~/Poll closed/ && !(grep {$bot->{_polls}{$_}{active}} matching_1407('#test')),
    'Master stop closes the current poll across channel case');
my $before=dclone([$bot->{_polls},{%{$bot->{metrics}}},\@audit]);
invoke_1407('poll','#tEsT','Forbidden? | A | B','Guest',MockUser->new(level=>'User',auth=>1));
is_deeply([$bot->{_polls},{%{$bot->{metrics}}},\@audit],$before,
    'case normalization never bypasses Master authorization or mutates denied creation');
my ($other_key)=matching_1407('#other');
is_deeply($bot->{_polls}{$other_key},$other,'other channels and their ballots remain independent');
invoke_1407('poll','#Room[one]','Square? | A | B');
invoke_1407('poll','#Room{one}','Brace? | A | B');
is(scalar(matching_1407('#room[one]'))+scalar(matching_1407('#room{one}')),2,
    'existing punctuation-distinct channel cache keys are not merged by an unnegotiated mapping');
is_deeply(\@warnings,[],'case-varying poll commands are warning-free');
done_testing;
