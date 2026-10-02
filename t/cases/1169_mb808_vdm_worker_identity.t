use strict;
use warnings;
use Mediabot::VDM::AsyncFetcher;
{
    package MB808::Worker;
    our @started;
    sub start { my ($class,%args)=@_;my $self=bless {args=>\%args},$class;push @started,$self;return $self }
    sub child { $_[0]{args}{child}->() }
    sub complete { $_[0]{args}{on_done}->({ok=>1,value=>$_[0]->child}) }
    sub cancel { $_[0]{cancelled}=1;return 1 }
}
return sub {
    my ($a)=@_;
    @MB808::Worker::started=();
    my (@seen,@answers);
    my $fetcher=Mediabot::VDM::AsyncFetcher->new(loop=>bless({},'MB808::Loop'),worker_class=>'MB808::Worker',fetch_cb=>sub {
        my (%opts)=@_;push @seen,$opts{id}//'feed';return {ok=>1,items=>[{id=>$opts{id}//517747}]};
    });
    $a->ok($fetcher->fetch(id=>304759,on_done=>sub {push @answers,['a',shift]}),'mb808: first numbered job accepted');
    $a->ok($fetcher->fetch(id=>304759,on_done=>sub {push @answers,['b',shift]}),'mb808: same ID shares its job');
    $a->ok($fetcher->fetch(id=>42,on_done=>sub {push @answers,['c',shift]}),'mb808: different ID has independent job');
    $a->ok($fetcher->fetch(on_done=>sub {push @answers,['d',shift]}),'mb808: recent feed is independent of numbered jobs');
    $a->is(scalar @MB808::Worker::started,3,'mb808: exactly three source identities produce three workers');
    $a->is($fetcher->waiter_count,4,'mb808: total waiters tracked across source identities');
    $MB808::Worker::started[1]->complete;
    $a->is($answers[0][0],'c','mb808: out-of-order completion goes to correct requester');
    $a->is($answers[0][1]{items}[0]{id},42,'mb808: different IDs cannot share returned story');
    $MB808::Worker::started[0]->complete;
    $a->is($answers[1][1]{items}[0]{id},304759,'mb808: first same-ID caller receives its article');
    $a->is($answers[2][1]{items}[0]{id},304759,'mb808: second same-ID caller receives its article');
    $MB808::Worker::started[2]->complete;
    $a->is($answers[3][1]{items}[0]{id},517747,'mb808: feed caller alone receives feed content');
    $a->is(join(',',@seen),'42,304759,feed','mb808: worker receives exact requested source options');
    $a->ok(!$fetcher->inflight && !$fetcher->waiter_count,'mb808: completed jobs release all capacity');
    my @late;
    $fetcher->fetch(id=>304759,on_done=>sub { push @late, shift });
    $MB808::Worker::started[0]->complete;
    $a->is(scalar @late,0,'mb808: duplicate old callback cannot complete a new same-ID job');
    $MB808::Worker::started[-1]->complete;
    $a->is(scalar @late,1,'mb808: only current worker may complete the new same-ID job');
    $a->ok(!$fetcher->fetch(id=>'x',on_done=>sub{}),'mb808: invalid ID starts no worker');
    for my $id (1..4){$a->ok($fetcher->fetch(id=>$id,on_done=>sub{}),'mb808: bounded worker slot accepts valid ID')}
    $a->ok(!$fetcher->fetch(id=>5,on_done=>sub{}),'mb808: worker concurrency is capped');
    $a->ok($fetcher->cancel('test'),'mb808: all active workers can be cancelled');
    $a->is(scalar(grep {$_->{cancelled}} @MB808::Worker::started),4,'mb808: cancellation reaches every current source job');
};
