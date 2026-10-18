use strict;
use warnings;
use Mediabot::DTC::AsyncFetcher;
use IO::Async::Loop;
use Time::HiRes ();
{
    package MB841::DTCWorker;
    our (@workers, $launch);
    sub start {
        my ($class, %args) = @_;
        my $w = bless {args => \%args}, $class;
        push @workers, $w;
        return $launch ? $launch->($w) : $w;
    }
    sub finish { $_[0]{args}{on_done}->($_[1]) }
}
sub mb841_dtc_result {
    return {ok=>1,value=>{ok=>1,id=>$_[0],text=>'local fixture'}};
}
return sub {
    my ($a)=@_;
    local @MB841::DTCWorker::workers;
    local $MB841::DTCWorker::launch;
    my $make=sub { Mediabot::DTC::AsyncFetcher->new(
        loop=>bless({},'MB841::NoLoop'),worker_class=>'MB841::DTCWorker',
        fetch_cb=>sub {die 'no external fetch permitted'},
    ) };
    my $f=$make->(); my @first;
    $a->ok($f->fetch(on_done=>sub {push @first,$_[0]}),'mb841: first source request starts');
    my $old=$MB841::DTCWorker::workers[-1];
    $a->ok($f->inflight,'mb841: active request occupies the source slot');
    $a->ok(!$f->fetch(on_done=>sub {}),'mb841: second source fetch is refused while busy');
    $old->finish(mb841_dtc_result(1));
    $a->is(scalar @first,1,'mb841: first result is delivered once');
    $a->ok(!$f->inflight,'mb841: first request releases capacity');
    my @second;
    $a->ok($f->fetch(on_done=>sub {push @second,$_[0]}),'mb841: replacement request starts');
    my $current=$MB841::DTCWorker::workers[-1];
    $old->finish(mb841_dtc_result(99));
    $a->is(scalar @first,1,'mb841: duplicate old completion cannot repeat its caller');
    $a->ok($f->inflight,'mb841: old completion cannot clear replacement capacity');
    $a->is(scalar @second,0,'mb841: replacement receives no old result');
    $current->finish(mb841_dtc_result(2));
    $a->is($second[0]{id},2,'mb841: replacement receives its own result');
    $a->ok(!$f->inflight,'mb841: replacement releases capacity normally');

    # A launcher may report failure synchronously, as AsyncWorker does for
    # pipe/fork/loop setup errors. Reentrant callers must see the reserved slot.
    my $nested; my $g=$make->(); my @inline;
    $MB841::DTCWorker::launch=sub {
        my ($w)=@_;
        if (!defined $nested) {$nested=-1; $nested=$g->fetch(on_done=>sub {})}
        $w->finish(mb841_dtc_result(3));
        return $w;
    };
    $a->ok($g->fetch(on_done=>sub {push @inline,$_[0]}),'mb841: inline completion is accepted');
    $a->is($nested,0,'mb841: source slot is reserved throughout launcher entry');
    $a->is(scalar @inline,1,'mb841: inline result reaches its caller once');
    $a->ok(!$g->inflight,'mb841: returned completed handle cannot resurrect a source job');

    my $h=$make->(); my @h;
    $MB841::DTCWorker::launch=sub {
        my ($w)=@_;
        $MB841::DTCWorker::launch=undef;
        $w->finish(mb841_dtc_result(4));
        return $w;
    };
    $h->fetch(on_done=>sub {
        push @h,$_[0]{id};
        $h->fetch(on_done=>sub {push @h,$_[0]{id}});
    });
    my $new=$MB841::DTCWorker::workers[-1];
    $a->ok($h->inflight,'mb841: completion callback can start a successor');
    $a->ok($h->{worker} == $new,'mb841: outer launcher cannot overwrite successor handle');
    $new->finish(mb841_dtc_result(5));
    $a->is(join(',',@h),'4,5','mb841: reentrant successor has independent terminal delivery');
    $a->ok(!$h->inflight,'mb841: reentrant successor leaves no occupied slot');

    for my $kind (qw(throw refuse callback_refuse callback_throw)) {
        my $x=$make->(); my @out;
        $MB841::DTCWorker::launch=sub {
            my ($w)=@_;
            $w->finish({ok=>0,error=>'worker_setup'}) if $kind =~ /^callback/;
            die "synthetic private launch failure\n" if $kind =~ /throw/;
            return undef;
        };
        my $accepted;
        my $ok=eval {$accepted=$x->fetch(on_done=>sub {push @out,$_[0]});1};
        $a->ok($ok,"mb841: $kind is contained at source boundary");
        $a->ok(!$accepted,"mb841: $kind reports launcher refusal");
        $a->is(scalar @out,1,"mb841: $kind gives exactly one terminal result");
        $a->is($out[0]{error}//'', 'worker_error',"mb841: $kind retains bounded public error");
        $a->ok(!$x->inflight,"mb841: $kind releases capacity");
        $MB841::DTCWorker::launch=undef;
        $a->ok($x->fetch(on_done=>sub {}),"mb841: $kind permits later recovery");
        $MB841::DTCWorker::workers[-1]->finish(mb841_dtc_result(6));
    }
    $MB841::DTCWorker::launch=undef;
    my $bad=$make->();
    $bad->fetch(on_done=>sub {die 'caller failed'});
    my $worker=$MB841::DTCWorker::workers[-1];
    my $ok=eval {$worker->finish({ok=>0,error=>'worker_timeout'});1};
    $a->ok($ok && !$bad->inflight,'mb841: throwing caller cannot retain the source slot');

    # Real fork, pipe and watcher; no HTTP/IRC/database operation.
    my $loop=IO::Async::Loop->new;
    my $real=Mediabot::DTC::AsyncFetcher->new(loop=>$loop,
        fetch_cb=>sub {return {ok=>1,id=>7,text=>'offline child'}});
    my @real;
    $a->ok($real->fetch(on_done=>sub {push @real,$_[0]}),'mb841: real worker starts');
    my $deadline=Time::HiRes::time()+5;
    $loop->loop_once(0.02) while !@real && Time::HiRes::time()<$deadline;
    $a->is($real[0]{id}//0,7,'mb841: real worker result crosses pipe unchanged');
    $a->ok(!$real->inflight,'mb841: real process completion frees slot');
};
