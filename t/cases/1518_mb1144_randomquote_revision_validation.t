use strict;
use warnings;
use utf8;
use Test::More;
use File::Temp qw(tempdir);
use Mediabot::RandomQuote::State;

sub bytes {
    open my $fh, '<:raw', $_[0] or die $!;
    local $/; return <$fh>;
}
for my $bad (undef, '', '2garbage', '2.0', '2e0', '+2', ' 2', "2\n", '2١', [], {}, -1, '10000000000') {
    my $dir = tempdir(CLEANUP=>1);
    my $path = "$dir/state.json";
    my $now = 1000000;
    my $state = Mediabot::RandomQuote::State->new(path=>$path,now=>sub{$now});
    $state->configure('#test',900,10800);
    $now += 900;
    my $ticket = $state->claim('#test',10800);
    is($ticket->{revision},2,'fixture has an active revision two ticket');
    my $before = bytes($path);
    my (@warnings,$consumed,$sent);
    {
        local $SIG{__WARN__}=sub{push @warnings,@_};
        $consumed=$state->consume('#test',$bad);
        $sent=$state->note_sent('#test',$bad,99);
    }
    is($consumed,0,'malformed revision cannot consume a ticket');
    is($sent,0,'malformed revision cannot overwrite last sent quote');
    is_deeply(\@warnings,[],'malformed revisions are rejected without conversion warnings');
    is(bytes($path),$before,'rejected callbacks preserve persisted state exactly');
    ok($state->consume('#test',$ticket->{revision}),'valid owner still consumes its pending ticket');
    ok($state->note_sent('#test',$ticket->{revision},42),'valid owner records its quote');
    is($state->status('#test',10800)->{last_id},42,'valid sent quote is persisted');
}
{
    my $dir=tempdir(CLEANUP=>1);my $path="$dir/state.json";
    my $state=Mediabot::RandomQuote::State->new(path=>$path);
    is($state->consume('#test','bogus'),0,'invalid ticket rejected on unconfigured state');
    is($state->note_sent('#test','bogus',42),0,'invalid sent ticket rejected on unconfigured state');
    ok(!-e $path && !-e "$path.lock",'invalid callbacks create no state or lock');
}

# A FIFO at either persistent path must never stall the IRC event loop.
for my $which ('state', 'lock') {
    my $dir = tempdir(CLEANUP=>1);
    my $path = "$dir/state.json";
    my $state = Mediabot::RandomQuote::State->new(path=>$path,now=>sub{1000000});
    $state->configure('#test',900,10800);
    my $before = bytes($path);
    my $fifo = $which eq 'state' ? $path : "$path.lock";
    unlink($fifo) or die $!;
    require POSIX;
    POSIX::mkfifo($fifo,0600) == 0 or die $!;
    my $error;
    {
        local $SIG{ALRM}=sub{die "FIFO watchdog expired\n"};
        alarm 2;
        eval {$state->configure('#test',1800,10800)};
        $error=$@;
        alarm 0;
    }
    like($error,qr/RandomQuote (?:state|lock) is not a regular file/,
        "$which FIFO is rejected before any blocking read");
    ok(-p $fifo,"$which FIFO is left untouched");
    is(bytes($path),$before,'bad lock preserves existing schedule') if $which eq 'lock';
    unlink($fifo) or die $!;
    if ($which eq 'state') {
        open my $out,'>:raw',$path or die $!;
        print {$out} $before or die $!; close($out) or die $!;
    }
    is($state->status('#test',10800)->{interval},900,
        'rejected operation releases its lock and leaves policy unchanged');
}
{
    my $dir=tempdir(CLEANUP=>1);my $path="$dir/state.json";
    my $state=Mediabot::RandomQuote::State->new(path=>$path,now=>sub{1000000});
    $state->configure('#test',900,10800);
    my $raw=bytes($path);
    my $write=sub{open my $fh,'>:raw',$path or die $!;print {$fh} $_[0] or die $!;close($fh) or die $!};
    my $limit=$raw.(' ' x (262144-length($raw)));
    $write->($limit);
    is($state->status('#test',10800)->{interval},900,'document at byte limit is readable');
    is(bytes($path),$limit,'read leaves boundary document unchanged');
    $write->($limit.' ');
    eval {$state->configure('#test',1800,10800)};
    like($@,qr/RandomQuote state too large/,'oversize document is rejected');
    is(bytes($path),$limit.' ','oversize rejection preserves bytes');
    $write->($raw);
    chmod(0644,"$path.lock") or die $!;
    is($state->status('#test',10800)->{interval},900,'state remains usable after read rejection');
    is((stat("$path.lock"))[2]&0777,0600,'opened lock descriptor receives private permissions');
}
done_testing;
