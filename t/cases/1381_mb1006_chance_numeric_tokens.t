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
    my ($kind,$command,$args,$draws)=@_;
    my $bot=Mediabot->new({});
    my $plugin=Mediabot::Plugin::Playful->new(context=>$authority);
    @wire=(); @audit=(); @LIMITS=(); @DRAWS=@$draws;
    my (@warnings,$input,$call);
    if ($kind eq 'native') {
        $input=Mediabot::Context->new(bot=>$bot,nick=>'Alice',channel=>'#test',
            command=>$command,args=>[@$args]);
        $call=sub {$bot->command_registry->handler_for($command,'public')->($input)};
    } else {
        $input=Mediabot::Plugin::InvocationV3->new(nick=>'Alice',channel=>'#test',
            command=>$command,args=>$args,source=>'public',is_private=>0,
            authority=>$authority,activation=>'on',config=>{},
            reply_sink=>sub {push @wire,['public','#test',$_[0]];1},
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
    is_deeply(\@actual,\@expected,"$label: Unicode and mixed digits retain the existing default roll without partial conversion");
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
done_testing;
