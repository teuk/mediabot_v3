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
# MB1345: omitted seconds follow the fallback, rather than int(undef) -> 10.
for my $route ('native','facade','registry') {
    for my $deadline (1900,2100) {
        for my $case ([[],60], [['0'],10], [['30'],30], [['900'],600], [['bad'],60],
                         [['1٢'],60], [['٢'],60], [["30\n"],60], [['0060'],60]) {
            my ($args,$extra)=@$case;
            my $display = join(' ', @$args); $display =~ s/\n/\\n/g;
            my $state={active=>1,question=>'Keep ballots?',options=>['Yes','No'],
                votes=>{alice=>0,bob=>1},started=>1800,deadline=>$deadline};
            $bot->{_polls}{'#test'}=dclone($state);
            my $expected=dclone($bot->{_polls});
            $expected->{'#test'}{deadline}=($deadline>2000?$deadline:2000)+$extra;
            $bot->{wire}=[]; @warnings=();
            my $ctx=Mediabot::Context->new(bot=>$bot,nick=>'Creator',channel=>'#TeSt',
                command=>'pollextend',args=>$args);
            $ctx->{user}=$master;$ctx->{_user_fetched}=1;
            if ($route eq 'registry') { $bot->command_registry->handler_for('pollextend','public')->($ctx) }
            elsif ($route eq 'facade') { Mediabot::UserCommands::mbPollExtend_ctx($ctx) }
            else { Mediabot::CommunityState::mbPollExtend_ctx($ctx) }
            my $remaining=$expected->{'#test'}{deadline}-2000;
            is_deeply([$bot->{_polls},$bot->{wire},\@warnings],
                [$expected,[['public','#TeSt',"Poll extended by ${extra}s (${remaining}s remaining)."]],[]],
                "$route deadline=$deadline args='$display': correct extension without warnings or ballot changes");
        }
    }
}
# MB1370: Unicode digit tokens are text, never partially parsed durations or
# option weights. Exercise the public registry and real weighted result path.
for my $order ('plain', 'weighted-first', 'timeout-first') {
    my (@actual, @expected);
    for my $token ('1٢', '٢3', '３０', '00060') {
        my $weighted = $order ne 'plain';
        my $raw = $order eq 'weighted-first' ? "weighted $token Choice? | Yes | No"
                : $order eq 'timeout-first' ? "$token weighted Choice? | Yes | No"
                : "$token Choice? | Yes | No";
        @warnings = (); @audit = ();
        my $other = dclone($bot->{_polls}{'#other'});
        my $count = $bot->{metrics}{mediabot_poll_created_total};
        invoke_1407('poll', '#TeSt', $raw);
        my $ascii = $token eq '00060';
        my $question = $ascii ? 'Choice?' : "$token "
            . ($order eq 'timeout-first' ? 'weighted ' : '') . 'Choice?';
        my $is_weighted = $weighted && ($ascii || $order eq 'weighted-first') ? 1 : 0;
        push @actual, [$bot->{_polls}{'#test'}, $bot->{wire}, [@warnings], [@audit],
            $bot->{metrics}{mediabot_poll_created_total} - $count, $bot->{_polls}{'#other'}];
        push @expected, [{question=>$question,options=>['Yes','No'],weights=>[1,1],
            weighted=>$is_weighted,votes=>{},started=>2000,deadline=>2000+($ascii?60:300),active=>1},
            [['public','#TeSt',"Poll: \"$question\"  [1] Yes  [2] No  -- vote with !vote <n>"]],
            [], [['#TeSt','poll',$question]], 1, $other];
    }
    is_deeply(\@actual, \@expected, "$order: only a complete ASCII timeout is consumed; Unicode text, defaults and other channels survive");
}
{
    my (@actual, @expected);
    for my $case (['2١',1], ['١',1], ['２',1], ['003',3], ['10',10], ['11',1]) {
        my ($token, $weight) = @$case;
        @warnings = ();
        my $label = $weight == 1 ? "Yes:$token" : 'Yes';
        invoke_1407('poll', '#TeSt', "weighted 60 Choice? | Yes:$token | No");
        invoke_1407('vote', '#test', '1', 'Alice');
        invoke_1407('vote', '#TEST', '2', 'Bob');
        invoke_1407('pollstatus', '#tEsT');
        my $first_pct = int($weight * 100 / ($weight + 1));
        my $second_pct = int(100 / ($weight + 1));
        push @actual, [$bot->{_polls}{'#test'}{options}, $bot->{_polls}{'#test'}{weights},
            $bot->{_polls}{'#test'}{votes}, $bot->{wire}, [@warnings]];
        push @expected, [[$label,'No'], [$weight,1], {alice=>0,bob=>1},
            [['public','#tEsT','"Choice?" [weighted] -- 2 vote(s) so far:'],
             ['public','#tEsT',"  [1] $label (x$weight): 1=$weight ($first_pct%)"],
             ['public','#tEsT',"  [2] No (x1): 1=1 ($second_pct%)"]], []];
    }
    is_deeply(\@actual, \@expected,
        'weighted ballots use whole ASCII weights in 1..10; malformed suffixes remain labels with unit weight and no warnings');
}
done_testing;
