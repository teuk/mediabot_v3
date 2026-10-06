use strict;
use warnings;
use utf8;
use File::Temp qw(tempdir);
use JSON::PP;
use IO::Async::Loop;
use IO::Async::Timer::Countdown;
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);
use Mediabot::RSS::Pacing;
use Mediabot::RSS::Runtime;
{
    package MB816::IRC;
    sub is_connected {$_[0]{connected}}
    package MB816::Repo;
    sub new {bless {due=>[], pending=>{}, enabled=>{}, marked=>[], errors=>[]}, shift}
    sub list_due_feeds {$_[0]{due}}
    sub is_feed_enabled {$_[0]{enabled}{$_[1]}}
    sub paced_pending_items {$_[0]{pending}{$_[1]} || []}
    sub record_poll_error {push @{$_[0]{errors}}, $_[1]; 1}
    sub mark_announced {
        my ($self,$id,$keys)=@_;
        push @{$self->{marked}}, $id;
        $self->{pending}{$id}=[];
        return 1;
    }
    package MB816::Worker;
    our @jobs;
    sub start {
        my ($class,%args)=@_;
        push @jobs, \%args;
        return bless {}, $class;
    }
}
return sub {
    my ($a)=@_;
    my $dir=tempdir(CLEANUP=>1);
    my $now=1000000;
    my $path="$dir/pacing.json";
    my $new_p=sub {Mediabot::RSS::Pacing->new(path=>$path,now=>sub{$now})};
    my $p=$new_p->();
    $p->configure('#35+ans',gap=>180,daily=>6);
    my $repo=MB816::Repo->new;
    my @feeds=map {{id_rss_feed=>$_,channel=>'#35+ans',label=>"Feed $_"}} 1..4;
    $repo->{due}=\@feeds;
    $repo->{enabled}{$_}=1 for 1..4;
    my $bot={_start_time=>1,irc=>bless({connected=>1},'MB816::IRC')};
    my $new_r=sub {Mediabot::RSS::Runtime->new(bot=>$bot,loop=>IO::Async::Loop->new,
        pacing=>$new_p->(),worker_class=>'MB816::Worker')};
    my $r=$new_r->();
    my (@sent,@opts); my $serial=0;
    no warnings 'redefine';
    local *Mediabot::RSS::Runtime::_parent_repo=sub{$repo};
    local *Mediabot::Helpers::botPrivmsg=sub {
        push @sent,$_[2]; push @opts,$_[3]; return 1;
    };
    my $complete=sub {
        my ($id,%opt)=@_;
        my ($job)=grep {$_->{label} eq "rss poll $id"} @MB816::Worker::jobs;
        die "missing RSS test job $id" unless $job;
        @MB816::Worker::jobs=grep {$_ != $job} @MB816::Worker::jobs;
        if ($opt{failed}) {$job->{on_done}->({ok=>0,error=>'timeout'}); return}
        my $key=sprintf('%064x',++$serial);
        my $items=$opt{empty} ? [] : [{item_key=>$key,line=>"Feed $id article $serial"}];
        $repo->{pending}{$id}=[map {{item_key=>$_->{item_key}}} @$items];
        $job->{on_done}->({ok=>1,value=>{ok=>1,announcements=>$items}});
    };
    $a->is($r->tick,4,'mb816: all four due feeds dispatched within existing worker limit');
    $a->is($r->tick,0,'mb816: another tick cannot duplicate in-flight polls');
    $complete->(1);
    $a->is(scalar @sent,0,'mb816: fastest feed cannot take slot while peers are still polling');
    $complete->(4);$complete->(3);
    $a->is(scalar @sent,0,'mb816: incomplete channel batch still holds publication');
    $complete->(2);
    $a->like($sent[-1],qr/^Feed 1 /,'mb816: initial rotation uses stable feed ids, not completion order');
    $a->is($r->queued_count,3,'mb816: only latest unused candidate for each other feed retained');
    $a->ok(!grep({$_->{timer}} values %{$r->{outq}}),'mb816: paced pool has no catch-up timer');
    $a->ok($opts[-1]{no_defer},'mb816: rotation keeps immediate-only AntiFlood policy');
    for my $expected (2,3,4,1,2) {
        $now+=10800;
        $r->tick;
        $complete->(1);$complete->(4);$complete->(3);$complete->(2);
        $a->like($sent[-1],qr/^Feed $expected /,"mb816: three-hour slot rotates to feed $expected despite feed 1 finishing first");
    }
    $a->is(scalar @sent,6,'mb816: six slots yield equal opportunities across the rotation');
    $now+=10800;
    $r->tick;$complete->(1);$complete->(2);$complete->(3);$complete->(4);
    $a->is(scalar @sent,6,'mb816: daily quota overrides rotation after six attempts');
    $a->is($p->status('#35+ans')->{used},6,'mb816: denied rotation does not reset or enlarge quota');
    $now=1086400;
    $r=$new_r->();
    $r->tick;$complete->(1);$complete->(2);$complete->(4);$complete->(3);
    $a->like($sent[-1],qr/^Feed 3 /,'mb816: restarted runtime resumes persisted cursor when first quota entry expires');
    $a->is($p->status('#35+ans')->{used},6,'mb816: rolling quota preserved with rotation after restart');
    $a->is(join(',',@{$p->rotation_order('#35+ANS',[4,1,3,2])}),'4,1,2,3','mb816: channel case and candidate order do not affect rotation');
    $p->configure('#35+ans',gap=>180,daily=>0);
    $now+=10800;
    $r->tick;$complete->(1);$complete->(2);$complete->(3);$complete->(4,failed=>1);
    $a->like($sent[-1],qr/^Feed 1 /,'mb816: failed next feed loses stale candidate and cannot block healthy feeds');
    $a->is(scalar @{$repo->{errors}},1,'mb816: worker failure keeps existing durable error path');
    $now+=10800;$repo->{enabled}{2}=0;
    $r->tick;$complete->(1);$complete->(2);$complete->(3,empty=>1);$complete->(4);
    $a->like($sent[-1],qr/^Feed 4 /,'mb816: disabled and empty feeds skipped without wasting their turns');
    $a->is($r->queued_count,1,'mb816: disabled and empty candidates removed from pool');
    $now+=10800;
    $repo->{due}=[];
    $r->tick;
    $a->like($sent[-1],qr/^Feed 1 /,'mb816: ready feed can publish when its next poll is not due');
    my $count=@sent;
    $r->tick;
    $a->is(scalar @sent,$count,'mb816: subsequent scheduler tick cannot catch up inside gap');
    $a->is($r->queued_count,0,'mb816: acknowledged final candidate leaves no memory backlog');
    $p->configure('#other',gap=>180,daily=>6);
    $a->is(join(',',@{$p->rotation_order('#other',[4,2,1])}),'1,2,4','mb816: another channel has its own rotation');
    $p->reserve('#other',feed_id=>2);
    $a->is(join(',',@{$p->rotation_order('#other',[4,2,1])}),'4,1,2','mb816: deleted id and added candidates fit circular ordering');
    $p->configure('#other',gap=>0,daily=>0);
    $p->configure('#other',gap=>180,daily=>6);
    $a->is(join(',',@{$new_p->()->rotation_order('#other',[1,2,4])}),'4,1,2','mb816: off/on and reconfiguration preserve cursor');
    $p->configure('#mixed',gap=>5,daily=>6);
    my @mixed=map {{id_rss_feed=>$_,channel=>'#mixed',label=>"Feed $_"}} (10,20);
    $repo->{enabled}{$_}=1 for 10,20;
    $repo->{due}=\@mixed;
    $r=$new_r->();$r->tick;$complete->(10);$complete->(20);
    $a->like($sent[-1],qr/^Feed 10 /,'mb816: staggered-poll scenario starts normally');
    $now+=300;$repo->{due}=[$mixed[0]];
    $r->tick;$complete->(10);
    $a->like($sent[-1],qr/^Feed 20 /,'mb816: ready feed gets next turn even while only faster peer is due');
    $now+=300;
    $repo->{pending}{10}=[{item_key=>'f'x64}];
    my $n=@sent;$repo->{due}=[];$r->tick;
    $a->is(scalar @sent,$n,'mb816: superseded cache cannot publish stale article or consume slot');
    $a->is($p->status('#mixed')->{used},2,'mb816: stale candidate rejection leaves quota unchanged');
    $p->configure('#daily-only',gap=>0,daily=>2);
    my @daily=map {{id_rss_feed=>$_,channel=>'#daily-only',label=>"Feed $_"}} (30,40);
    $repo->{enabled}{$_}=1 for 30,40;$repo->{due}=\@daily;
    $r=$new_r->();$n=@sent;$r->tick;$complete->(30);$complete->(40);
    $a->is(scalar @sent,$n+1,'mb816: worker completion drains only one candidate even without a gap');
    $repo->{due}=[];$r->tick;
    $a->is(scalar @sent,$n+2,'mb816: daily-only policy still permits its second eligible scheduler attempt');
    $p->configure('#mixed',gap=>0,daily=>0);
    $r->_enqueue_announcements(feed_id=>10,channel=>'#mixed',items=>[{item_key=>'e'x64,line=>'legacy fresh'}]);
    $a->is($sent[-1],'legacy fresh','mb816: disabling limits keeps normal fresh legacy delivery');
    my $legacy=Mediabot::RSS::Runtime->new(bot=>$bot,loop=>IO::Async::Loop->new,
        pacing=>$new_p->(),output_delay=>0.1);
    $n=@sent;$repo->{enabled}{50}=1;
    $legacy->_enqueue_announcements(feed_id=>50,channel=>'#legacy',items=>[
        {item_key=>'a'x64,line=>'legacy one'}, {item_key=>'b'x64,line=>'legacy two'}]);
    $a->is($sent[-1],'legacy one','mb816: unpaced first article remains immediate');
    $a->ok($legacy->{outq}{'#legacy'}{timer},'mb816: unpaced output keeps its existing inter-line timer');
    # loop_once may return for another event before the RSS timer expires.
    # Exercise that wakeup, then wait for delivery itself with a bounded deadline.
    my $early_wakeups=0;
    my $early=IO::Async::Timer::Countdown->new(delay=>0.005,
        on_expire=>sub {++$early_wakeups});
    $legacy->{loop}->add($early);$early->start;
    my $deadline=clock_gettime(CLOCK_MONOTONIC)+3;
    while (@sent < $n+2 && clock_gettime(CLOCK_MONOTONIC) < $deadline) {
        $legacy->{loop}->loop_once(0.05);
    }
    $legacy->{loop}->remove($early);
    $a->ok($early_wakeups>0,'mb816: unrelated event wakes the loop before legacy output');
    $a->is($sent[-1],'legacy two','mb816: ordinary output timer still delivers the next legacy article');
    $a->is(scalar @sent,$n+2,'mb816: legacy timer delivers exactly one additional article');
    $a->ok(!exists $legacy->{outq}{'#legacy'},'mb816: completed legacy timer leaves no queued output');
    my $before=do {open my $fh,'<',$path or die $!;local $/;<$fh>};
    $a->ok(!$p->reserve('#other',feed_id=>4)->{allowed},'mb816: cursor cannot advance while slot denied');
    my $after=do {open my $fh,'<',$path or die $!;local $/;<$fh>};
    $a->is($after,$before,'mb816: denied turn leaves quota and cursor byte-for-byte unchanged');
    $a->ok(!eval {$p->reserve('#other',feed_id=>0);1},'mb816: invalid feed id refused before reservation');
    my $old=decode_json($before);
    delete $_->{last_feed} for values %{$old->{channels}};
    open my $fh,'>',$path or die $!;print {$fh} encode_json($old);close $fh;
    $a->is($p->status('#35+ans')->{used},6,'mb816: old schema without cursor keeps complete existing quota history');
    $a->is(join(',',@{$p->rotation_order('#35+ans',[4,2,1])}),'1,2,4','mb816: old state starts rotation without resetting limits');
    $old->{channels}{'#35+ans'}{last_feed}='invalid';
    open $fh,'>',$path or die $!;print {$fh} encode_json($old);close $fh;
    $a->ok(!eval {$p->status('#35+ans');1},'mb816: corrupt cursor fails closed just like corrupt quota');
};
