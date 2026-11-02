use strict;
use warnings;
use utf8;
use Test::More;
use Storable qw(dclone);
our (@DRAWS,@LIMITS,$DRAWING);
BEGIN {
    *CORE::GLOBAL::rand = sub {
        return CORE::rand($_[0] // 1) unless $DRAWING;
        die "unexpected random draw\n" unless @DRAWS;
        my $bound=$_[0] // 1;
        push @LIMITS,$bound;
        return shift(@DRAWS)*$bound;
    };
}
use Mediabot::Mediabot;
use Mediabot::Context;
use Mediabot::PluginContext;
use Mediabot::Plugin::InvocationV3;
require './plugins/playful-v3/lib/Playful.pm';
binmode Test::More->builder->output, ':encoding(UTF-8)';
binmode Test::More->builder->failure_output, ':encoding(UTF-8)';
my (@wire,@audit);
no warnings qw(redefine once);
local *Mediabot::UserCommands::botPrivmsg=sub {push @wire,['public',$_[1],$_[2]];1};
local *Mediabot::UserCommands::botNotice=sub {push @wire,['notice',$_[1],$_[2]];1};
local *Mediabot::UserCommands::logBot=sub {push @audit,[@_[2..$#_]];1};
my $authority=Mediabot::PluginContext->new(plugin=>'playful-v3',
    requested=>[qw(irc.reply irc.notice)],granted=>[qw(irc.reply irc.notice)]);
sub run_1381 {
    my ($kind,$command,$args,$draws,$channel,$bot,$plugin)=@_;
    $channel //= '#test';
    $bot //= Mediabot->new({});
    $plugin //= Mediabot::Plugin::Playful->new(context=>$authority);
    @wire=(); @audit=(); @LIMITS=(); @DRAWS=@$draws;
    my (@warnings,$input,$call);
    if ($kind eq 'native') {
        $input=Mediabot::Context->new(bot=>$bot,nick=>'Alice',channel=>$channel,
            command=>$command,args=>[@$args]);
        $call=sub {$bot->command_registry->handler_for($command,'public')->($input)};
    } else {
        $input=Mediabot::Plugin::InvocationV3->new(nick=>'Alice',channel=>$channel,
            command=>$command,args=>$args,source=>'public',is_private=>0,
            authority=>$authority,activation=>'on',config=>{},
            reply_sink=>sub {push @wire,['public',$channel,$_[0]];1},
            notice_sink=>sub {push @wire,['notice','Alice',$_[0]];1});
        my $method='command_'.$command;
        $call=sub {$plugin->$method($authority,$input)};
    }
    my $error;
    {
        local $DRAWING=1;
        local $SIG{__WARN__}=sub {push @warnings,@_};
        $error=eval {$call->();1}?'':"$@";
    }
    my $record=$command eq 'roll'
        ? ($kind eq 'native'?$bot->{_roll_history}:$plugin->{roll_history})
        :$command eq 'flip'
        ? ($kind eq 'native'?$bot->{_flip_stats}:$plugin->{flip_stats})
        :[$kind eq 'native'?$bot->{_choose_last}:$plugin->{choose_last},
          $kind eq 'native'?$bot->{_choose_history}:$plugin->{choose_history}];
    return dclone({error=>$error,wire=>\@wire,limits=>\@LIMITS,remaining=>\@DRAWS,
        warnings=>\@warnings,args=>$input->args,audit=>\@audit,record=>$record});
}
sub expected_1381 {
    my ($kind,$command,$args,$limits,$text,$value,$record)=@_;
    return {error=>'',wire=>[['public','#test',$text]],limits=>$limits,remaining=>[],
        warnings=>[],args=>$args,audit=>$kind eq 'native'?[['#test',$command,$value]]:[],record=>$record};
}
my $default='Alice rolled 1d6: 4';
{
my (@all_actual,@all_expected);
for my $group (
    ['dice count',[['٢d8'],['1٢d8'],['２d8']]],
    ['dice sides',[['2d٨'],['2d8٢'],['2d８']]],
    ['single sides',[['٨'],['8٢'],['８']]],
) {
    my ($label,$inputs)=@$group;
    my (@actual,@expected);
    for my $args (@$inputs) {
        for my $kind (qw(native plugin)) {
            push @actual,run_1381($kind,'roll',$args,[.5]);
            push @expected,expected_1381($kind,'roll',$args,[6],$default,'1d6',{'#test'=>[$default]});
        }
    }
    push @all_actual,[$label,\@actual];push @all_expected,[$label,\@expected];
}
is_deeply(\@all_actual,\@all_expected,
    "Unicode dice counts, sides and shorthand remain whole-token defaults without partial conversion");
}

{
    my (@actual,@expected);
    my $text="Alice rolled 1d6 (adv): [5, \x1e1\x0f]  → 5";
    for my $args (['+٢','adv'],['+2٣','adv'],['-２','adv'],['1d6','-1٢','adv']) {
        for my $kind (qw(native plugin)) {
            push @actual,run_1381($kind,'roll',$args,[.1,.8]);
            push @expected,expected_1381($kind,'roll',$args,[6,6],$text,'1d6',{'#test'=>[$text]});
        }
    }
    is_deeply(\@actual,\@expected,'Unicode modifiers are ignored as whole tokens and cannot partly change the bonus; advantage remains active');
}
{
    my (@actual,@expected);
    for my $args (['٢'],['1٢'],['２']) {
        for my $kind (qw(native plugin)) {
            push @actual,run_1381($kind,'flip',$args,[.1]);
            push @expected,expected_1381($kind,'flip',$args,[$kind eq 'native'?1:2],
                'Alice flipped a coin: Heads!','H',{'#test'=>{h=>1,t=>0}});
        }
    }
    is_deeply(\@actual,\@expected,'Unicode flip counts retain one coin, one draw and correct channel counters without numeric warnings');
}
{
    my (@actual,@expected);
    for my $label ('café:٢','café:1٢','café:２') {
        my $args=[$label,'|','tea'];
        for my $kind (qw(native plugin)) {
            push @actual,run_1381($kind,'choose',$args,[0]);
            push @expected,expected_1381($kind,'choose',$args,[2],"Alice: I choose... $label!",$label,
                [{'#test'=>$label},{'#test'=>[$label]}]);
        }
    }
    is_deeply(\@actual,\@expected,'non-ASCII weight suffixes remain literal Unicode labels rather than partly parsed weights');
}
{
    my (@actual,@expected);
    for my $case (
        [['2d8','+3'],[0,.5],[8,8],'Alice rolled 2d8: [1, 5] +3 = 9','2d8'],
        [['20','-2','dis'],[.1,.8],[20,20],"Alice rolled 1d20 (dis): [3, \x1e17\x0f] -2 = 1  → 1",'1d20'],
        [['0d999','+999'],[0],[100],'Alice rolled 1d100: 1 +100 = 101','1d100'],
    ) {
        my ($args,$draws,$limits,$text,$value)=@$case;
        for my $kind (qw(native plugin)) {
            push @actual,run_1381($kind,'roll',$args,$draws);
            push @expected,expected_1381($kind,'roll',$args,$limits,$text,$value,{'#test'=>[$text]});
        }
    }
    is_deeply(\@actual,\@expected,'ASCII dice, shorthand, signed bonuses, advantage modes and clamps keep their established results');
}
{
    my $args=['99']; my $text='Alice flipped 10 coins: HHHHHHHHHH  (10 H, 0 T)';
    is_deeply([map {run_1381($_,'flip',$args,[(.1)x10])} qw(native plugin)],
        [map {expected_1381($_,'flip',$args,[($_ eq 'native'?1:2)x10],$text,'HHHHHHHHHH',{'#test'=>{h=>10,t=>0}})} qw(native plugin)],
        'ASCII flip counts still clamp at ten and record each actual coin');
}
{
    my $args=['café:2','|','tea'];
    is_deeply([map {run_1381($_,'choose',$args,[0])} qw(native plugin)],
        [map {expected_1381($_,'choose',$args,[3],'Alice: I choose... café! (1 of 3 options)','café',
            [{'#test'=>'café'},{'#test'=>['café']}])} qw(native plugin)],
        'ASCII weights retain their expanded pool, Unicode result text, choice recall state and native audit');
}
{
    my (@actual,@expected);
    for my $args (['nonsense'],['nonsense','+2']) {
        my $text=@$args>1?'Alice rolled 1d6: 4 +2 = 6':$default;
        for my $kind (qw(native plugin)) {
            push @actual,run_1381($kind,'roll',$args,[.5]);
            push @expected,expected_1381($kind,'roll',$args,[6],$text,'1d6',{'#test'=>[$text]});
        }
    }
    is_deeply(\@actual,\@expected,'existing unrecognized-token fallback and subsequent valid modifiers remain unchanged');
}
# Reuse each actual native/plugin instance across differently cased messages.
# Fixed draws check state identity/order without reseeding or random thresholds.
sub compact_1074 {
    my ($r)=@_;
    return {map {$_=>$r->{$_}} qw(error wire limits remaining warnings args audit)};
}
sub expected_step_1074 {
    my ($kind,$command,$channel,$args,$limits,$text,$value)=@_;
    return {error=>'',wire=>[['public',$channel,$text]],limits=>$limits,remaining=>[],
        warnings=>[],args=>$args,audit=>$kind eq 'native' && defined($value)
            ? [[$channel,$command,$value]] : []};
}
{
    my (@actual,@expected);
    for my $kind (qw(native plugin)) {
        my $bot=Mediabot->new({});my $plugin=Mediabot::Plugin::Playful->new(context=>$authority);
        my (@got,@want,@rolls,@choices);
        my @channels=('#MiXeD','#mixed','#MIXED');
        for my $n (1..6) {
            my $channel=$channels[($n-1)%3];my $text="Alice rolled 1d6: $n";
            my $r=run_1381($kind,'roll',[],[($n-.5)/6],$channel,$bot,$plugin);
            push @rolls,$text;push @got,compact_1074($r);
            push @want,expected_step_1074($kind,'roll',$channel,[],[6],$text,'1d6');
        }
        my @last_rolls=@rolls[1..5];
        for my $row (['#mIxEd','Last rolls: '.join('  |  ',reverse @last_rolls)],
                     ['#Other','Alice: no roll history on #Other.']) {
            my ($channel,$text)=@$row;
            push @got,compact_1074(run_1381($kind,'roll',['history'],[],$channel,$bot,$plugin));
            push @want,expected_step_1074($kind,'roll',$channel,['history'],[],$text,undef);
        }
        for my $n (0..5) {
            my $label=('0','café','alpha','beta','gamma','delta')[$n];
            my $channel=$channels[$n%3];
            my $args=$n==1?['café:2','|','water']:[$label,'|','water'];
            my $limits=$n==1?[3]:[2];
            my $text="Alice: I choose... $label!".($n==1?' (1 of 3 options)':'');
            push @choices,$label;
            push @got,compact_1074(run_1381($kind,'choose',$args,[0],$channel,$bot,$plugin));
            push @want,expected_step_1074($kind,'choose',$channel,$args,$limits,$text,$label);
            if ($n==0) {
                push @got,compact_1074(run_1381($kind,'choose',['last'],[],'#mixed',$bot,$plugin));
                push @want,expected_step_1074($kind,'choose','#mixed',['last'],[],
                    'Alice: last choice was: 0',undef);
            }
        }
        my @last_choices=@choices[1..5];
        for my $row (['last','#mIxEd','Alice: last choice was: delta'],
                     ['history','#MIXED','Last choices: '.join(' | ',reverse @last_choices)],
                     ['last','#Other','Alice: no previous choice on this channel.'],
                     ['history','#Other','Alice: no choice history on #Other.']) {
            my ($arg,$channel,$text)=@$row;
            push @got,compact_1074(run_1381($kind,'choose',[$arg],[],$channel,$bot,$plugin));
            push @want,expected_step_1074($kind,'choose',$channel,[$arg],[],$text,undef);
        }
        my $state=$kind eq 'native' ? [$bot->{_roll_history},$bot->{_choose_last},$bot->{_choose_history}]
            : [$plugin->{roll_history},$plugin->{choose_last},$plugin->{choose_history}];
        push @actual,[$kind,\@got,$state];push @expected,[$kind,\@want,
            [{'#mixed'=>\@last_rolls},{'#mixed'=>'delta'},{'#mixed'=>\@last_choices}]];
    }
    is_deeply(\@actual,\@expected,
        'native/plugin histories share channel case identity, keep five real results, preserve zero/Unicode/weights and never draw or audit on recall');
}
{
    my (@actual,@expected);
    for my $kind (qw(native plugin)) {
        my $bot=Mediabot->new({});my $plugin=Mediabot::Plugin::Playful->new(context=>$authority);
        my (@got,@want);
        for my $row (['#MiXeD',.1,'Heads!','H'],['#mixed',.9,'Tails!','T'],['#Other',.1,'Heads!','H']) {
            my ($channel,$draw,$word,$value)=@$row;
            push @got,compact_1074(run_1381($kind,'flip',[],[$draw],$channel,$bot,$plugin));
            push @want,expected_step_1074($kind,'flip',$channel,[],[$kind eq 'native'?1:2],
                "Alice flipped a coin: $word",$value);
        }
        for my $row (['#MIXED','1 Heads (50%)  1 Tails (50%)  — 2 total'],
                     ['#oThEr','1 Heads (100%)  0 Tails (0%)  — 1 total']) {
            my ($channel,$suffix)=@$row;
            push @got,compact_1074(run_1381($kind,'flip',['stats'],[],$channel,$bot,$plugin));
            push @want,expected_step_1074($kind,'flip',$channel,['stats'],[],
                "Alice flip stats on $channel: $suffix",undef);
        }
        my $stats=$kind eq 'native'?$bot->{_flip_stats}:$plugin->{flip_stats};
        push @actual,[$kind,\@got,$stats];push @expected,[$kind,\@want,
            {'#mixed'=>{h=>1,t=>1},'#other'=>{h=>1,t=>0}}];
    }
    is_deeply(\@actual,\@expected,
        'native/plugin flip stats accumulate across channel casing, isolate other channels and preserve reply/audit spelling without extra draws');
}
done_testing;
