use strict;
use warnings;
use utf8;
use Test::More;
use Storable qw(dclone);
use Mediabot::Mediabot;
use Mediabot::Context;
use Mediabot::IRC::TextBudget qw(_irc_wire_bytes);
binmode Test::More->builder->output, ':encoding(UTF-8)';
binmode Test::More->builder->failure_output, ':encoding(UTF-8)';

{
    package MB1350::DB;
    sub prepare {
        my ($self)=@_; $self->{prepares}++;
        return bless {db=>$self,index=>0},'MB1350::Statement';
    }
    package MB1350::Statement;
    sub execute { 1 }
    sub fetchrow_hashref {
        my ($self)=@_;
        my $row=$self->{db}{rows}[$self->{index}++];
        return $row ? {%$row} : undef;
    }
    sub finish { $_[0]{db}{finished}++; 1 }
    package MB1350::User;
    sub is_authenticated { $_[0]{allowed} }
    sub has_level { $_[0]{allowed} && $_[1] eq 'Master' }
}
my (@wire,@audit,@warnings);
local $SIG{__WARN__}=sub {push @warnings,@_};
no warnings qw(redefine once);
local *Mediabot::ChannelCommands::botNotice=sub {push @wire,[@_[1,2]];1};
local *Mediabot::botNotice=sub {push @wire,[@_[1,2]];1};
local *Mediabot::ChannelCommands::logBot=sub {push @audit,[@_[2..$#_]];1};
sub run_chanlist_1350 {
    my ($rows,%opts)=@_;
    my $bot=Mediabot->new({});
    my $db=bless {rows=>dclone($rows)},'MB1350::DB'; $bot->{dbh}=$db;
    my $ctx=Mediabot::Context->new(bot=>$bot,nick=>'Caller',channel=>$opts{private}?undef:'#room',
        command=>$opts{command}//'chanlist',args=>[],message=>undef);
    $ctx->{user}=bless {allowed=>!$opts{denied}},'MB1350::User';$ctx->{_user_fetched}=1;
    @wire=();@audit=();
    my $result=$bot->command_registry->handler_for($ctx->command,$opts{private}?'private':'public')->($ctx);
    return {result=>$result,wire=>dclone(\@wire),audit=>dclone(\@audit),db=>$db};
}
sub entries_1350 {
    return [map {my $sets=$_->{chansets}//'';$sets =~ s/,/,+/g;
        $_->{name}.'('.($_->{nbUsers}//0).')'.(length($sets)?'[+'.$sets.']':'')} @{$_[0]}];
}
sub pages_1350 { [map {$_->[1]} grep {$_->[1]=~/\Achanlist\[/} @{$_[0]{wire}}] }
sub bodies_1350 { [map {my $s=$_;$s=~s/\Achanlist\[[0-9]+\/[0-9]+\]: //;$s} @{$_[0]}] }
sub valid_pages_1350 {
    my ($pages)=@_;
    return 0 unless @$pages;
    for my $i (0..$#$pages) {
        my $label=sprintf('chanlist[%02d/%02d]: ',$i+1,scalar @$pages);
        return 0 unless index($pages->[$i],$label)==0 && _irc_wire_bytes($pages->[$i])<=360;
    }
    return 1;
}
for my $case (
    ['long ASCII','a'x40], ['Unicode','界'x15], ['raw UTF-8',"\xe7\x95\x8c"x15],
    ['Unicode byte boundary','界'x3],
) {
    my ($label,$suffix)=@$case;
    my $rows=[map {{name=>"#c$_$suffix",nbUsers=>$_,chansets=>'Games,RandomQuote,Trivia'}} 1..17];
    my $r=run_chanlist_1350($rows);my $pages=pages_1350($r);
    my @shown=map {split / /,$_} @{bodies_1350($pages)};
    is_deeply(\@shown,entries_1350($rows),"$label: every complete channel and its metadata appears once, in query order");
    ok(valid_pages_1350($pages) && !grep({scalar(split / /,$_)>8} @{bodies_1350($pages)}),
        "$label: page labels are accurate and notices fit 360 wire bytes with at most eight entries");
    is_deeply([$r->{result},$r->{wire}[0],$r->{audit},$r->{db}{rows},$r->{db}{finished},
        [grep {$_->[0] ne 'Caller'} @{$r->{wire}}]],
        [1,['Caller','Registered channels: 17 result(s)'],[[undef,'chanlist']],$rows,1,[]],
        "$label: summary, private destination, audit, query cleanup and source rows are preserved");
}
{
    my $rows=[map {{name=>"#room$_",nbUsers=>0}} 1..17];
    my @expected=map {my $page=$_;my $first=($page-1)*8;
        sprintf('chanlist[%02d/03]: ',$page).join(' ',@{entries_1350($rows)}[$first..($page==3?16:$first+7)])} 1..3;
    my @actual;
    for my $command (qw(chanlist channels channellist)) {
        for my $private (0,1) {push @actual,pages_1350(run_chanlist_1350($rows,command=>$command,private=>$private))}
    }
    is_deeply(\@actual,[map {[ @expected ]} 1..6],
        'short entries retain eight-per-page layout through all three public/private command names');
}
{
    my $rows=[map {{name=>sprintf('#c%04d',$_).('a'x45),nbUsers=>1,chansets=>'Games,RandomQuote,Trivia'}} 1..505];
    my $pages=pages_1350(run_chanlist_1350($rows));
    my @shown=map {split / /,$_} @{bodies_1350($pages)};
    is_deeply(\@shown,entries_1350($rows),'more than 99 pages retain every channel in order');
    ok(@$pages>99 && valid_pages_1350($pages),'three-digit page counters still respect the byte budget');
}
{
    # A single metadata-rich row must not lose its tail or the following row.
    # This also forces page numbers beyond two digits with only two DB rows.
    my $rows=[{name=>'#large',nbUsers=>3,chansets=>join(',',map {"Flag$_".('x'x25)} 1..1100)}];
    my $pages=pages_1350(run_chanlist_1350($rows));
    is(join('',@{bodies_1350($pages)}),entries_1350($rows)->[0],
        'an oversized entry retains all metadata across continuation pages');
    ok(@$pages>99 && valid_pages_1350($pages),'continuations reserve enough space for the final page count');
    push @$rows,{name=>'#after',nbUsers=>0};
    $pages=pages_1350(run_chanlist_1350($rows));
    my $bodies=bodies_1350($pages);my $last=pop @$bodies;
    is_deeply([join('',@$bodies),$last],entries_1350($rows),
        'an entry after long metadata is neither lost nor merged into that metadata');
}
{
    my $empty=run_chanlist_1350([]);my $denied=run_chanlist_1350([{name=>'#secret'}],denied=>1);
    is_deeply([$empty->{wire},$empty->{audit},$empty->{db}{finished}],
        [[['Caller','No channel registered.']],[[undef,'chanlist']],1],'empty list keeps its notice and audit');
    ok(!$denied->{db}{prepares} && !grep({$_->[1]=~/Registered channels|chanlist\[|#secret/} @{$denied->{wire}}),
        'unauthenticated requests never query or disclose registered channels');
}
is_deeply(\@warnings,[],'pagination emits no warnings');
done_testing;
