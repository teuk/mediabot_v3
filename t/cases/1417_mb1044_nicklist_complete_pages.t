use strict;
use warnings;
use utf8;
use Test::More;
use Storable qw(dclone);
use Mediabot::ChannelCommands ();
use Mediabot::IRC::TextBudget qw(_irc_wire_bytes);

{
    package MB1044::Context;
    sub bot {$_[0]{bot}}
    sub nick {'Caller'}
    sub args {$_[0]{args}}
    sub channel {$_[0]{channel}}
    sub user {$_[0]{user}}
    sub message {undef}
    package MB1044::User;
    sub is_authenticated {$_[0]{auth}}
    sub has_level {$_[0]{admin}}
    sub nickname {'Caller'}
    sub level_description {'User'}
    package MB1044::Logger;
    sub log {push @{$_[0]{rows}},[@_[1,2]];1}
    package MB1044::IRC;
    sub nick_folded {'mediabot'}
}
my (@wire,@warnings);
local $SIG{__WARN__}=sub {push @warnings,@_};
no warnings qw(redefine once);
local *Mediabot::ChannelCommands::botNotice=sub {push @wire,[@_[1,2]];1};
local *Mediabot::ChannelCommands::noticeConsoleChan=sub {1};
local *Mediabot::ChannelCommands::logBot=sub {1};
sub run_1417 {
    my ($nicks,%opts)=@_;
    my $logger=bless {rows=>[]},'MB1044::Logger';
    my $bot={hChannelsNicks=>{defined($opts{key})?$opts{key}:'#room'=>$nicks},
        logger=>$logger,irc=>bless({},'MB1044::IRC')};
    my $before=dclone($bot->{hChannelsNicks});
    my $ctx=bless {bot=>$bot,args=>$opts{args}//[],channel=>$opts{channel}//'#room',
        user=>bless({auth=>exists($opts{auth})?$opts{auth}:1,
            admin=>exists($opts{admin})?$opts{admin}:1},'MB1044::User')},'MB1044::Context';
    @wire=();
    my $ok=eval {Mediabot::ChannelCommands::channelNickList_ctx($ctx);1};
    return {ok=>$ok?1:0,wire=>[map {[@$_]} @wire],logs=>$logger->{rows},
        cache=>$bot->{hChannelsNicks},before=>$before};
}
for my $case (
    ['long ASCII',[map {sprintf('n%02d',$_).('a'x61)} 1..10]],
    ['Unicode',[map {sprintf('n%02d',$_).("界"x25)} 1..19]],
    ['raw UTF-8',[map {sprintf('n%02d',$_).("\xe7\x95\x8c"x25)} 1..19]],
) {
    my ($label,$nicks)=@$case;
    my $r=run_1417($nicks);
    my @pages=map {$_->[1]} grep {$_->[1]=~/\Anicklist\[/} @{$r->{wire}};
    my @shown=map {my $s=$_;$s=~s/\Anicklist\[[0-9]+\/[0-9]+\]: //;split / /,$s} @pages;
    is_deeply([$r->{ok},\@shown],[1,$nicks],"$label: actual handler reports every nickname whole and in cache order");
    my $valid=@pages>1;
    for my $i (0..$#pages) {
        my $prefix=sprintf('nicklist[%02d/%02d]: ',$i+1,scalar @pages);
        $valid&&=index($pages[$i],$prefix)==0 && _irc_wire_bytes($pages[$i])<=360
            && scalar(split / /,substr($pages[$i],length($prefix)))<=10;
    }
    ok($valid,"$label: numbered pages fit 360 wire bytes and contain at most ten complete nicknames");
    is_deeply([$r->{cache},$r->{wire}[0],$r->{logs}[-1]],
        [$r->{before},['Caller','Users on #room: '.scalar(@$nicks).' result(s)'],
            [4,'nicklist #room => '.scalar(@$nicks).' users']],
        "$label: cache is untouched and summary/debug counts agree with the full list");
}
{
    my @nicks=map {"nick$_"} 1..23;
    my $r=run_1417(\@nicks,key=>'#room',args=>['#ROOM'],channel=>'#else');
    my @pages=map {$_->[1]} grep {$_->[1]=~/\Anicklist\[/} @{$r->{wire}};
    is_deeply(\@pages,[map {my $page=$_;my $first=($page-1)*10;
        sprintf('nicklist[%02d/03]: ',$page).join(' ',@nicks[$first..($page==3?22:$first+9)])} 1..3],
        'ordinary short nicknames keep the existing ten-per-page format and case-insensitive fallback');
}
{
    my @nicks=map {sprintf('n%04d',$_).('a'x59)} 1..505;
    my $r=run_1417(\@nicks);
    my @pages=map {$_->[1]} grep {$_->[1]=~/\Anicklist\[/} @{$r->{wire}};
    my @shown=map {my $s=$_;$s=~s/\Anicklist\[[0-9]+\/[0-9]+\]: //;split / /,$s} @pages;
    is_deeply(\@shown,\@nicks,'more than 99 pages retain the complete list in order');
    ok(@pages>99 && !grep({_irc_wire_bytes($_)>360} @pages)
        && index($pages[-1],sprintf('nicklist[%02d/%02d]: ',scalar(@pages),scalar(@pages)))==0,
        'expanded page counters remain accurate and inside the wire-byte budget');
}
{
    my $r=run_1417([undef,'','Alice']);
    is_deeply($r->{wire},[['Caller','Users on #room: 1 result(s)'],['Caller','nicklist[01/01]: Alice']],
        'empty cache entries remain filtered before counting and pagination');
}
{
    my $empty=run_1417([]);my $missing=run_1417(['Alice'],key=>'#other');
    is_deeply([$empty->{wire},$missing->{wire}],
        [[['Caller','Nicklist for #room is empty.']],[['Caller','No nicklist known for #room.']]],
        'empty and unknown channel replies preserve the established contract');
}
{
    my $guest=run_1417(['Alice'],auth=>0);my $regular=run_1417(['Alice'],admin=>0);
    ok(!grep({$_->[1]=~/\A(?:Users on |nicklist\[)/} (@{$guest->{wire}},@{$regular->{wire}})),
        'unauthenticated and non-administrator callers never receive nicklist contents');
}
is_deeply(\@warnings,[],'ASCII, Unicode, raw UTF-8 and rejected requests remain warning-free');
done_testing;
