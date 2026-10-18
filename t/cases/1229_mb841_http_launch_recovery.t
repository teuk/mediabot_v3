use strict;
use warnings;
use IO::Async::Loop;
use Time::HiRes ();
use Mediabot::Plugin::HTTPServiceV3;
{
    package MB841::HTTPWorker;
    sub new {my ($class,%a)=@_;bless {args=>\%a,cancelled=>0},$class}
    sub finish {$_[0]{args}{on_done}->($_[1])}
    sub cancel {my ($s)=@_;$s->{cancelled}++;$s->finish({ok=>0,error=>'worker_cancelled'});1}
}
sub mb841_http_success {
    return {ok=>1,value=>{ok=>1,status=>200,url=>'https://example.net/item',body=>'local fixture',error=>''}};
}
return sub {
    my ($a)=@_;
    my $req=sub {{url=>'https://example.net/item',cache_ttl_seconds=>0}};
    for my $mode (qw(throw refuse callback_throw callback_refuse)) {
        my (@workers,@out); my $fail=1;
        my $s=Mediabot::Plugin::HTTPServiceV3->new(worker_factory=>sub {
            my %args=@_;my $w=MB841::HTTPWorker->new(%args);push @workers,$w;
            return $w unless $fail;
            $w->finish(mb841_http_success()) if $mode =~ /^callback/;
            die "synthetic private launcher detail\n" if $mode =~ /throw/;
            return undef;
        });
        my $res;
        my $ok=eval {$res=$s->fetch('fixture-v3',$req->(),sub {push @out,$_[0]});1};
        $a->ok($ok,"mb841: HTTP $mode is contained at service boundary");
        $a->ok($res && !$res->{accepted} && $res->{error} eq 'worker_setup',"mb841: HTTP $mode reports bounded setup refusal");
        $a->is($s->inflight_count('fixture-v3'),0,"mb841: HTTP $mode releases pending slot");
        $a->is(scalar @out,1,"mb841: HTTP $mode has exactly one terminal callback");
        if ($mode =~ /^callback/) {
            $a->ok($out[0] && $out[0]->ok,"mb841: HTTP $mode preserves already delivered result");
        } else {
            $a->is($out[0] ? $out[0]->error : '', 'worker_setup',"mb841: HTTP $mode hides private launcher exception");
        }
        $workers[0]->finish(mb841_http_success());
        $a->is(scalar @out,1,"mb841: HTTP $mode ignores retained late callback");
        $fail=0;
        my $r1=$s->fetch('fixture-v3',$req->(),sub {push @out,$_[0]});
        my $one=$workers[-1];
        my $r2=$s->fetch('fixture-v3',$req->(),sub {push @out,$_[0]});
        my $two=$workers[-1];
        $a->ok($r1->{accepted} && $r2->{accepted},"mb841: HTTP $mode leaves both permitted slots usable");
        my $busy=$s->fetch('fixture-v3',$req->(),sub {});
        $a->is($busy->{error},'busy',"mb841: HTTP $mode keeps original concurrency cap");
        $workers[0]->finish(mb841_http_success());
        $a->is($s->inflight_count('fixture-v3'),2,"mb841: HTTP $mode old callback cannot release successor slots");
        $one->finish(mb841_http_success());$two->finish(mb841_http_success());
        $a->is($s->inflight_count('fixture-v3'),0,"mb841: HTTP $mode recovers normal completion");
    }

    # No callback need ever arrive after a launcher throws. Repeated setup
    # faults must not accumulate two immortal Pending markers and force busy.
    my $failures=2;my @recovery;my @errors;
    my $recover=Mediabot::Plugin::HTTPServiceV3->new(worker_factory=>sub {
        my %args=@_;
        die "offline setup fault\n" if $failures-- > 0;
        my $w=MB841::HTTPWorker->new(%args);push @recovery,$w;return $w;
    });
    for (1..2) {
        eval {$recover->fetch('recovery-v3',$req->(),sub {push @errors,$_[0]})};
    }
    $a->is(scalar @errors,2,'mb841: repeated launcher exceptions each complete once');
    $a->is($recover->inflight_count('recovery-v3'),0,'mb841: repeated launcher faults leave no phantom busy slots');
    my $recovered=$recover->fetch('recovery-v3',$req->(),sub {});
    $a->ok($recovered->{accepted},'mb841: working launcher recovers without disabling the plugin');
    $_->finish(mb841_http_success()) for @recovery;

    # Plugin disable can happen during an injected launch. Its pending marker
    # is not yet cancellable, so the returned live handle must not be adopted.
    my ($s,$old,@workers,@out,$replace,$revoked_pending);
    $s=Mediabot::Plugin::HTTPServiceV3->new(worker_factory=>sub {
        my %args=@_;my $w=MB841::HTTPWorker->new(%args);push @workers,$w;
        if (!$old) {
            $old=$w;
            $revoked_pending=$s->cancel_plugin('fixture-v3');
            $replace=$s->fetch('fixture-v3',$req->(),sub {push @out,'replacement'});
        }
        return $w;
    });
    my $cancelled=$s->fetch('fixture-v3',$req->(),sub {push @out,'revoked'});
    $a->is($revoked_pending,0,'mb841: pending marker is not mistaken for a cancellable worker');
    $a->ok(!$cancelled->{accepted} && $cancelled->{error} eq 'cancelled','mb841: launch-time revocation is reported');
    $a->is($old->{cancelled},1,'mb841: worker returned after revocation is cancelled once');
    $a->ok($replace->{accepted},'mb841: new plugin generation can start during old launch');
    $a->is($s->inflight_count('fixture-v3'),1,'mb841: revoked launch cannot reinsert its old worker');
    $a->is(scalar @out,0,'mb841: cancellation completion is silent for revoked plugin');
    $old->finish(mb841_http_success());
    $a->is(scalar @out,0,'mb841: retained revoked callback stays silent');
    $a->is($s->inflight_count('fixture-v3'),1,'mb841: late old callback preserves new generation slot');
    $workers[-1]->finish(mb841_http_success());
    $a->is(join(',',@out),'replacement','mb841: only replacement generation receives HTTP result');
    $a->is($s->inflight_count('fixture-v3'),0,'mb841: replacement HTTP worker releases capacity');

    # Real fork/pipe/watch_process with an injected offline HTTP response.
    # Network policy and HTTPS verification remain enforced by production code.
    my $loop=IO::Async::Loop->new;my @real;
    my $real=Mediabot::Plugin::HTTPServiceV3->new(loop=>$loop,
        resolver=>sub {['93.184.216.34']},
        requester=>sub {{status=>200,headers=>{'content-type'=>'application/json'},content=>'{"offline":true}'}});
    my $r=$real->fetch('offline-v3',$req->(),sub {push @real,$_[0]});
    $a->ok($r->{accepted},'mb841: real HTTP worker starts with offline transport');
    my $deadline=Time::HiRes::time()+5;
    $loop->loop_once(0.02) while !@real && Time::HiRes::time()<$deadline;
    $a->ok($real[0] && $real[0]->ok,'mb841: real HTTP worker crosses shared response boundary');
    $a->is($real[0] ? $real[0]->body : '', '{"offline":true}','mb841: real worker preserves response body');
    $a->is($real->inflight_count('offline-v3'),0,'mb841: real HTTP worker releases slot');
};
