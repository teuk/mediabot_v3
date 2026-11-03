use strict;
use warnings;
use utf8;
use Test::More;
use Storable qw(dclone);
BEGIN {$MB1090::Clock::now=1000;*CORE::GLOBAL::time=sub () {$MB1090::Clock::now}}
use Mediabot::CommunityState ();
use Mediabot::UserCommands ();
use Mediabot::Context;

{
    package MB1090::Principal;
    sub is_authenticated {1}
    sub has_level {$_[0]{allow}}
    package MB1090::Bot;sub botNotice {1}
    package MB1090::Metrics;
    sub inc {$_[0]{counters}{$_[1]}++;1}
    sub set {$_[0]{gauges}{$_[1]}=$_[2];1}
    package MB1090::Ballots;
    sub TIEHASH {bless {data=>$_[1],reads=>0},$_[0]}
    sub FETCH {$_[0]{reads}++;$_[0]{data}{$_[1]}}
    sub STORE {$_[0]{data}{$_[1]}=$_[2]}
    sub FIRSTKEY {keys %{$_[0]{data}};each %{$_[0]{data}}}
    sub NEXTKEY {each %{$_[0]{data}}}
    sub SCALAR {scalar %{$_[0]{data}}}
    sub EXISTS {exists $_[0]{data}{$_[1]}}
}
no warnings qw(redefine once);
sub poll1090 {
    my (%a)=@_;
    return {question=>'Dinner?',options=>['Pizza','Sushi'],weights=>$a{weights}//[3,1],weighted=>$a{weighted}//0,
        votes=>$a{votes}//{alice=>0,bob=>0,charlie=>1,dave=>1,eve=>1},started=>900,deadline=>$a{deadline}//1010,active=>1};
}
sub run1090 {
    my ($entry,$method,$poll,%a)=@_;
    my $bot=$a{bot}//bless({_polls=>{'#test'=>$poll,'#other'=>{sentinel=>1}},metrics=>bless({counters=>{},gauges=>{}},'MB1090::Metrics')},'MB1090::Bot');
    my (@wire,@warnings,@audit);
    my $send=sub {push @wire,[$_[1],$_[2]];1};
    local *Mediabot::UserCommands::botPrivmsg=$send;
    local *Mediabot::Helpers::botPrivmsg=$send;
    local *Mediabot::UserCommands::botNotice=sub {push @wire,[$_[1],$_[2]];1};
    local *Mediabot::UserCommands::logBot=sub {push @audit,[@_[2..$#_]];1};
    local $SIG{__WARN__}=sub {push @warnings,@_};
    my $ctx=Mediabot::Context->new(bot=>$bot,nick=>$a{nick}//'Alice',channel=>$a{channel}//'#test',command=>$method,args=>$a{args}//[1]);
    $ctx->{user}=bless {allow=>$a{allow}//1},'MB1090::Principal';$ctx->{_user_fetched}=1;
    my $prefix=$entry eq 'facade'?'Mediabot::UserCommands::':'Mediabot::CommunityState::';
    {no strict 'refs';&{$prefix.$method}($ctx)}
    return {wire=>\@wire,warnings=>\@warnings,audit=>\@audit,bot=>$bot,poll=>$bot->{_polls}{'#test'}};
}
sub texts1090 {return [map {$_->[1]} @{$_[0]{wire}}]}
my @methods=qw(mbVote_ctx mbPollStatus_ctx mbPollResult_ctx mbPollStop_ctx);
{
    my @got;
    for my $entry (qw(module facade)) {
        my @views=map {run1090($entry,$_,poll1090())} @methods;
        push @got,[[map {texts1090($_)} @views],$views[3]{bot}{metrics}{gauges}{mediabot_poll_duration_seconds},
            $views[3]{bot}{metrics}{counters}{mediabot_poll_closed_total},[map {scalar @{$_->{warnings}}} @views]];
    }
    my $wanted=[
        ['Alice voted for "Pizza" (5 vote(s) cast)','Live tally: [1] Pizza: 2 (40%)  [2] Sushi: 3 (60%)'],
        ['"Dinner?" -- 5 vote(s) so far:','  [1] Pizza: 2 (40%)','  [2] Sushi: 3 (60%)'],
        ['Active poll: "Dinner?" (5 vote(s))  Winner: Sushi (60%)',sprintf('  [1] %-20s 2 vote(s) (40%%)','Pizza'),sprintf('  [2] %-20s 3 vote(s) (60%%)','Sushi')],
        ['Poll closed (5 vote(s)). Winner: Sushi (3/5, 60%). Use !pollresult for details.']
    ];
    is_deeply(\@got,[map {[$wanted,100,1,[0,0,0,0]]} 1..2],
        'all four real views retain ordinary counts, winning label, formatting and closure metrics through module and facade');
}
{
    my @got;
    for my $entry (qw(module facade)) {
        my @views=map {run1090($entry,$_,poll1090(weighted=>1))} @methods;
        push @got,[map {texts1090($_)} @views];
    }
    my $wanted=[
        ['Alice voted for "Pizza" (5 vote(s) cast)','Live tally: [1] Pizza (x3): 2=6 (66%)  [2] Sushi (x1): 3=3 (33%)'],
        ['"Dinner?" [weighted] -- 5 vote(s) so far:','  [1] Pizza (x3): 2=6 (66%)','  [2] Sushi (x1): 3=3 (33%)'],
        ['Active poll [weighted]: "Dinner?" (5 vote(s))  Winner: Pizza (67% weighted)',sprintf('  [1] %-20s (x3) 2 vote(s) = 6 (67%%)','Pizza'),sprintf('  [2] %-20s (x1) 3 vote(s) = 3 (33%%)','Sushi')],
        ['Poll closed (5 vote(s)). Winner: Pizza (2 vote(s), weighted score 6/9, 66%). Use !pollresult for details.']
    ];
    is_deeply(\@got,[$wanted,$wanted],
        'weighted views distinguish voters from scores and preserve their existing integer/rounded percentages');
}
{
    my @got;
    for my $entry (qw(module facade)) {
        my $tie=poll1090(weighted=>1,weights=>[3,2]);
        my $result=run1090($entry,'mbPollResult_ctx',dclone($tie));
        my $stop=run1090($entry,'mbPollStop_ctx',dclone($tie));
        my $missing=run1090($entry,'mbPollStop_ctx',poll1090(weighted=>1,weights=>[]));
        push @got,[$result->{wire}[0][1],$stop->{wire}[0][1],$missing->{wire}[0][1]];
    }
    is_deeply(\@got,[map {[
        'Active poll [weighted]: "Dinner?" (5 vote(s))  Tie: Pizza, Sushi',
        'Poll closed (5 vote(s)). Tie on weighted score: Pizza, Sushi. Use !pollresult for details.',
        'Poll closed (5 vote(s)). Winner: Sushi (3 vote(s), weighted score 3/5, 60%). Use !pollresult for details.'
    ]} 1..2], 'ties keep every winning label in option order and absent weights retain x1');
}
{
    my @got;
    for my $weighted (0,1) {
        my @views=map {run1090('module',$_,poll1090(weighted=>$weighted,votes=>{}))} @methods[1..3];
        push @got,[$views[0]{wire}[1][1],$views[1]{wire}[0][1],$views[2]{wire}[0][1],
            [map {scalar @{$_->{warnings}}} @views]];
    }
    is_deeply(\@got,[
        ['  [1] Pizza: 0 (0%)','Active poll: "Dinner?" (0 vote(s))','Poll closed. No votes cast.',[0,0,0]],
        ['  [1] Pizza (x3): 0=0 (0%)','Active poll [weighted]: "Dinner?" (0 vote(s))','Poll closed. No votes cast.',[0,0,0]]
    ], 'empty ordinary and weighted polls have zero percentages and no invented winner or division warning');
}
{
    local $MB1090::Clock::now=1011;
    my @got;
    for my $entry (qw(module facade)) {
        for my $method (qw(mbPollStatus_ctx mbPollResult_ctx)) {
            my $poll=poll1090();my $x=run1090($entry,$method,$poll);
            my $again=run1090($entry,'mbPollStatus_ctx',$poll,bot=>$x->{bot});
            push @got,[$x->{poll}{active},$x->{poll}{votes},$x->{bot}{_polls}{'#other'},texts1090($x),texts1090($again),
                $x->{bot}{metrics}{counters},scalar @{$x->{warnings}}];
        }
    }
    my $closed=['Closed poll: "Dinner?" (5 vote(s))  Winner: Sushi (60%)',
        sprintf('  [1] %-20s 2 vote(s) (40%%)','Pizza'),sprintf('  [2] %-20s 3 vote(s) (60%%)','Sushi')];
    my $votes=poll1090()->{votes};
    is_deeply(\@got,[map {
        [0,$votes,{sentinel=>1},['Poll expired. Use !pollresult to see results.'],['No active poll.'],{},0],
        [0,$votes,{sentinel=>1},$closed,['No active poll.'],{},0]
    } 1..2], 'status and results close overdue polls once without changing ballots, other channels or existing expiry metrics');
}
{
    my @got;
    for my $entry (qw(module facade)) {
        local $MB1090::Clock::now=1010;
        my $poll=poll1090();my $x=run1090($entry,'mbPollResult_ctx',$poll);
        my $at=$poll->{active};
        $MB1090::Clock::now=1011;
        my $closed=run1090($entry,'mbPollResult_ctx',$poll,bot=>$x->{bot});
        my $extend=run1090($entry,'mbPollExtend_ctx',$poll,bot=>$x->{bot},args=>[10]);
        my $unseen=poll1090();my $reopen=run1090($entry,'mbPollExtend_ctx',$unseen,args=>[10]);
        push @got,[$at,$poll->{active},$poll->{deadline},texts1090($extend),$unseen->{deadline},texts1090($reopen)];
    }
    is_deeply(\@got,[map {[1,0,1010,['No active poll.'],1021,['Poll extended by 10s (10s remaining).']]} 1..2],
        'exact deadline remains inclusive; observing closure prevents reopening while explicit extension of an unobserved late poll remains compatible');
}
{
    my @got;
    for my $method (@methods) {
        my %rows=map {('voter'.$_)=>($_%12)} 0..119;
        tie my %ballots,'MB1090::Ballots',\%rows;
        my $counter=tied %ballots;
        my $poll=poll1090(weighted=>1,votes=>\%ballots);$poll->{options}=[map {'Choice '.$_} 1..12];$poll->{weights}=[(1)x12];
        my $x=run1090('module',$method,$poll,nick=>'voter0');
        push @got,[$counter->{reads}<=125?1:0,scalar @{$x->{warnings}}];
    }
    is_deeply(\@got,[[1,0],[1,0],[1,0],[1,0]],
        'each view reads ballots once instead of rescanning all voters for every option; deterministic work bound without wall-clock timing');
}
{
    my $poll=poll1090();my $x=run1090('facade','mbVote_ctx',$poll,args=>[2]);
    my $status=run1090('module','mbPollStatus_ctx',$poll,bot=>$x->{bot});
    my $undo=run1090('facade','mbUnvote_ctx',$poll,bot=>$x->{bot});
    my $deny=run1090('module','mbPollStop_ctx',$poll,bot=>$x->{bot},allow=>0);
    my $stop=run1090('facade','mbPollStop_ctx',$poll,bot=>$x->{bot});
    is_deeply([$x->{wire}[1][1],$status->{wire}[0][1],$undo->{wire}[0][1],
        $x->{bot}{metrics}{counters}{mediabot_poll_votes_total},$stop->{wire}[0][1],scalar @{$deny->{audit}}],
        ['Live tally: [1] Pizza: 1 (20%)  [2] Sushi: 4 (80%)','"Dinner?" -- 5 vote(s) so far:',
         'Alice cancelled their vote (4 vote(s) remaining).',1,
         'Poll closed (4 vote(s)). Winner: Sushi (3/4, 75%). Use !pollresult for details.',0],
        'revoting and withdrawing feed fresh shared totals; unauthorized stop has no audit or closure effect');
}
done_testing;
