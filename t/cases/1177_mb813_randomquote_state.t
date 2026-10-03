use strict;
use warnings;
use File::Temp qw(tempdir);
use Fcntl qw(:DEFAULT :flock);
use Mediabot::RandomQuote::State;
return sub {
    my ($a)=@_;my $dir=tempdir(CLEANUP=>1);my $path="$dir/state.json";my $now=1000000;
    my $new=sub{Mediabot::RandomQuote::State->new(path=>$path,now=>sub{$now})};my $p=$new->();
    $a->is($p->status('#test',10800)->{interval},10800,'mb813: unconfigured frequency defaults to three hours');
    $a->ok(!-e $path && !-e "$path.lock",'mb813: status does not create state');
    $a->ok(!defined $p->claim('#test',10800),'mb813: first observation waits a full interval');
    $a->is($new->()->status('#TEST',10800)->{wait},10800,'mb813: persisted schedule is case insensitive');
    $a->is((stat($path))[2]&0777,0600,'mb813: state is private');
    $a->is((stat("$path.lock"))[2]&0777,0600,'mb813: lock is private');
    $p->configure('#other',900,10800);
    $now+=899;$a->ok(!defined $p->claim('#other',10800),'mb813: not due one second early');
    $now++;my $ticket=$new->()->claim('#other',10800);
    $a->ok($ticket && $ticket->{interval}==900,'mb813: independent channel due at exact frequency');
    $a->ok(!defined $p->claim('#other',10800),'mb813: duplicate tick cannot claim twice');
    $a->ok($p->consume('#other',$ticket->{revision}),'mb813: accepted ticket consumes once');
    $a->ok(!$p->consume('#other',$ticket->{revision}),'mb813: callback replay consumes nothing');
    $p->note_sent('#other',$ticket->{revision},42);
    $a->is($new->()->status('#other',10800)->{last_id},42,'mb813: last accepted id survives restart');
    $a->is($p->status('#test',10800)->{wait},9900,'mb813: other channel does not change first schedule');
    my $deadline=$p->status('#other',10800)->{next_at};$now+=10;
    $p->configure('#other',900,10800);
    $a->is($p->status('#other',10800)->{next_at},$deadline,'mb813: repeated configuration does not postpone schedule');
    $now+=100000;my $late=$p->claim('#other',10800);
    $a->is($late->{next_at},$now+900,'mb813: overdue schedule resumes from now');
    $a->ok(!defined $new->()->claim('#other',10800),'mb813: missed intervals never catch up in a burst');
    $p->configure('#other',3600,10800);
    $a->ok(!$p->consume('#other',$late->{revision}),'mb813: reconfiguration invalidates in-flight ticket');
    $a->is($p->status('#other',10800)->{last_id},42,'mb813: frequency changes retain last accepted id');
    $a->is($p->status('#other',10800)->{wait},3600,'mb813: changed frequency starts a complete new interval');
    $p->configure('#other',0,10800);
    $a->ok(!$p->status('#other',10800)->{custom},'mb813: default removes channel override');
    $a->is($p->status('#other',1800)->{interval},1800,'mb813: default follows current configured interval');
    my $read=sub{open my $fh,'<',$path or die $!;local $/;<$fh>};my $before=$read->();
    for my $value (899,604801,-1,'1m',undef) {
        $a->ok(!eval{$p->configure('#test',$value,10800);1},'mb813: out-of-range settings rejected');
    }
    for my $channel ('test','#bad channel','#bad:channel','#bad,channel',undef) {
        $a->ok(!eval{$p->configure($channel,900,10800);1},'mb813: invalid channel rejected');
    }
    $a->is($read->(),$before,'mb813: malformed settings preserve stored state');
    sysopen(my $lock,"$path.lock",O_RDWR) or die $!;flock($lock,LOCK_EX) or die $!;
    $a->ok(!eval{$new->()->claim('#test',10800);1},'mb813: busy state fails closed without blocking loop');close $lock;
    open my $fh,'>',$path or die $!;print {$fh} '{broken';close $fh;
    $a->ok(!eval{$new->()->claim('#test',10800);1},'mb813: corrupt schedule cannot send');
    unlink $path;$a->ok(!eval{$new->()->status('#test',10800);1},'mb813: missing initialized state fails closed');
    symlink "$dir/outside",$path or die $!;
    $a->ok(!eval{$new->()->status('#test',10800);1},'mb813: symlink state refused');
    unlink $path;unlink "$path.lock";symlink "$dir/outside","$path.lock" or die $!;
    $a->ok(!eval{$new->()->configure('#test',900,10800);1},'mb813: symlink lock refused');
};
