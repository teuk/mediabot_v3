use strict;
use warnings;
use utf8;
use Test::More;
use Protocol::IRC ();
use Protocol::IRC::Message ();
use Mediabot::Fullop;

{
    package MB1055::IRC;
    our @ISA = ('Protocol::IRC');
    sub encoder { undef }
    sub write { push @{$_[0]{wire}}, $_[1]; 1 }
    package MB1055::Logger;
    sub log { push @{$_[0]{rows}}, [@_[1,2]]; 1 }
}
sub guard_1428 {
    my (%opts)=@_;
    my $irc=bless {wire=>[]}, 'MB1055::IRC';
    my $logger=bless {rows=>[]}, 'MB1055::Logger';
    my $guard=Mediabot::Fullop->new(
        bot=>{irc=>$irc,logger=>$logger},
        enabled_cb=>sub { exists($opts{enabled}) ? $opts{enabled} : 1 },
        nicklist_cb=>sub { @{$opts{nicks}//[]} },
    );
    $guard->update_isupport('MODES='.($opts{modes}//20));
    return ($guard,$irc->{wire},$logger->{rows});
}
sub decoded_1428 {
    my ($wire)=@_;
    return [map {
        my $line=$_;
        $line=~s/\r\n\z//;
        my $m=Protocol::IRC::Message->new_from_line($line);
        [$m->command, $m->args]
    } @$wire];
}
my @warnings;
local $SIG{__WARN__}=sub {push @warnings,@_};
for my $case (
    ['long ASCII','#'.('c'x63),[map {sprintf('n%02d',$_).('a'x61)} 1..19]],
    ['ordinary nick limit','#room',[map {sprintf('n%02d',$_).('a'x27)} 1..20]],
    ['raw UTF-8','#'.("\xe7\x95\x8c"x20),[map {sprintf('n%02d',$_).("\xe7\x95\x8c"x15)} 1..23]],
) {
    my ($label,$channel,$nicks)=@$case;
    my ($g,$wire)=guard_1428(nicks=>$nicks);
    is($g->sweep_channel($channel),scalar(@$nicks),"$label: the native sweep accounts for every nickname");
    my $rows=decoded_1428($wire);
    is_deeply([map {@{$_}[3..$#$_]} @$rows],$nicks,"$label: the native transport preserves every whole nickname in order");
    ok(@$wire>1 && !grep({length($_)>512} @$wire),"$label: every serialized IRC line fits 512 octets including CRLF");
    ok(!grep({$_->[0] ne 'MODE' || $_->[1] ne $channel || $_->[2] ne '+'.('o'x(@$_-3)) || @$_-3>20} @$rows),
        "$label: one matching +o per target and the advertised mode limit are preserved");
}
{
    # Exactly 512 bytes: 9 framing + 47 channel + two (1 mode + 1 space + 226 nickname).
    my $channel='#'.('c'x46);
    my @nicks=('a'x226,'b'x226,'c'x226);
    my ($g,$wire)=guard_1428;
    is($g->sweep_channel($channel,@nicks),3,'an exact-boundary batch keeps all three targets');
    is_deeply([map {length($_)} @$wire],[512,284],'a 512-byte line is allowed and its successor starts a new batch');
    is_deeply([map {@{$_}[3..$#$_]} @{decoded_1428($wire)}],\@nicks,'boundary packing never duplicates or truncates targets');
    my ($h,$next)=guard_1428;
    $h->sweep_channel($channel.'x',@nicks);
    is_deeply([map {length($_)} @$next],[285,285,285],'one extra channel byte moves both targets out of the full batch');
    my ($j,$trailing)=guard_1428;
    $j->sweep_channel($channel,$nicks[0],':'.substr($nicks[1],1));
    is_deeply([map {length($_)} @$trailing],[284,285],
        'defensive packing also counts the native trailing-argument marker');
}
{
    my ($g,$wire)=guard_1428(modes=>3,nicks=>[qw(Alice Bob Carol Dave)]);
    is($g->sweep_channel('#open'),4,'ordinary op sweeps keep their target count');
    is_deeply($wire,["MODE #open +ooo Alice Bob Carol\r\n","MODE #open +o Dave\r\n"],
        'short-name batching stays byte-for-byte identical and still follows MODES=3');
    is($g->handle_join('#open','Eve'),1,'a normal join still emits one op');
    is($wire->[-1],"MODE #open +o Eve\r\n",'the native join command remains unchanged');
}
{
    my ($g,$wire)=guard_1428;
    $g->update_isupport('CASEMAPPING=rfc1459');
    is($g->sweep_channel('#open','[Alice','{Alice','Bob',undef,'','bad nick','bad,nick'),2,
        'RFC1459 deduplication and the existing target filter still apply before packing');
    is_deeply($wire,["MODE #open +oo [Alice Bob\r\n"],'deduplication retains the first server spelling');
    $g->update_isupport('CASEMAPPING=ascii');
    $g->sweep_channel('#open','[Alice','{Alice');
    is($wire->[-1],"MODE #open +oo [Alice {Alice\r\n",'ASCII case mapping still keeps distinct spellings');
}
{
    my ($g,$wire,$logs)=guard_1428;
    my $too_long='z'x600;
    is($g->sweep_channel('#open','Alice',$too_long,'Bob'),2,
        'an impossible singleton is excluded from the emitted-target count');
    is_deeply($wire,["MODE #open +oo Alice Bob\r\n"],
        'one oversized target does not block, rename or split its ordinary neighbors');
    ok(@$logs==1 && $logs->[0][0]==1 && index($logs->[0][1],$too_long)<0,
        'an impossible singleton has one bounded diagnostic without copying its payload');
    is($g->handle_join('#open',$too_long),0,'an impossible joined nickname produces no malformed MODE');
    is(scalar(@$wire),1,'the rejected join emits no IRC command');
}
{
    my ($g,$wire)=guard_1428(enabled=>0);
    is_deeply([$g->sweep_channel('#closed','Alice'),$g->handle_join('#closed','Bob'),$wire],[0,0,[]],
        'disabled Fullop remains silent');
    my ($h,$next)=guard_1428;
    is_deeply([$h->handle_join('#open','Alice',banned=>1),$next],[0,[]],
        'the existing banned-join guard still prevents an op');
    is($h->sweep_channel('#open'),0,'an empty native nicklist emits nothing');
}
is_deeply(\@warnings,[],'all packing and preserved policy paths remain warning-free');
done_testing;
