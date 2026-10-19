use strict;
use warnings;
use Test::More;
use lib '.', 't/lib';
use IO::Async::Loop;
use Time::HiRes qw(time);
use Mediabot::RandomQuote::Runtime;
use MB813RandomQuoteFixture;

{
    package MB845QuoteWorker;
    our (@jobs,$mode);
    sub start {
        my ($class,%args)=@_;push @jobs,\%args;
        die "private constructor detail\n" if $mode eq 'throw';
        return undef if $mode eq 'refuse';
        $args{on_done}->({ok=>1,value=>{ok=>1,record=>undef}}) if $mode =~ /^inline/;
        die "private constructor detail after callback\n" if $mode eq 'inline_throw';
        return undef if $mode eq 'inline_refuse';
        return bless {},$class;
    }
    package MB845QuoteLogger;
    sub log {push @{$_[0]{lines}},$_[2];1}
    package MB845QuoteRuntime;
    our @ISA=('Mediabot::RandomQuote::Runtime');
    sub _done {
        my ($self,@args)=@_;push @{$self->{completed}},\@args;
        push @{$self->{busy_at_done}},scalar keys %{$self->{inflight}};
        $self->{hook}->($self) if $self->{hook};return 1;
    }
}
sub quote_runtime845 {
    @MB845QuoteWorker::jobs=();
    my $r=MB845QuoteRuntime->new(bot=>{logger=>bless({lines=>[]},'MB845QuoteLogger')},
        loop=>IO::Async::Loop->really_new,worker_class=>'MB845QuoteWorker');
    $r->{completed}=[];$r->{busy_at_done}=[];return $r;
}
for my $mode (qw(throw refuse inline inline_throw inline_refuse)) {
    my $r=quote_runtime845();$MB845QuoteWorker::mode=$mode;
    my $started;ok(eval {$started=$r->_start('#test',1,{revision=>1});1},"$mode: launch is contained");
    is($started,$mode eq 'inline'?1:0,"$mode: launch result retains its contract");
    is(scalar keys %{$r->{inflight}},0,"$mode: terminal attempt releases capacity");
    is(scalar keys %{$r->{workers}},0,"$mode: completed handle is not retained");
    is(scalar @{$r->{completed}},1,"$mode: terminal result is processed once");
    is($r->{busy_at_done}[0],0,"$mode: capacity is free before invoking consumer");
    unlike(join(' ',@{$r->{bot}{logger}{lines}}),qr/private constructor detail/,"$mode: raw constructor details stay private");
    $MB845QuoteWorker::mode='defer';
    is($r->_start('#test',2,{revision=>2}),1,"$mode: a replacement can start");
}
{
    my $r=quote_runtime845();$MB845QuoteWorker::mode='defer';
    $r->_start('#test',1,{revision=>1});my $old=$MB845QuoteWorker::jobs[-1];
    $old->{on_done}->({ok=>1});$r->_start('#test',2,{revision=>2});
    my $new=$MB845QuoteWorker::jobs[-1];my $handle=$r->{workers}{'#test'};
    $old->{on_done}->({ok=>1});
    is(scalar keys %{$r->{inflight}},1,'old completion cannot release a replacement reservation');
    is($r->{workers}{'#test'},$handle,'old completion cannot remove the replacement handle');
    is(scalar @{$r->{completed}},1,'duplicate terminal result is not consumed again');
    is($r->_start('#TEST',3,{revision=>3}),0,'direct overlapping launch is refused case-insensitively');
    is($r->{workers}{'#test'},$handle,'overlap refusal leaves the current handle intact');
    $new->{on_done}->({ok=>1});
    is(scalar keys %{$r->{inflight}},0,'replacement releases its own reservation');
}
for my $mode (qw(inline inline_throw inline_refuse)) {
    my $r=quote_runtime845();$MB845QuoteWorker::mode=$mode;my $replacement;
    $r->{hook}=sub {
        my ($self)=@_;delete $self->{hook};$MB845QuoteWorker::mode='defer';
        $self->_start('#test',2,{revision=>2});$replacement=$self->{workers}{'#test'};
    };
    $r->_start('#test',1,{revision=>1});
    is(scalar keys %{$r->{inflight}},1,"$mode: reentrant successor keeps capacity ownership");
    is($r->{workers}{'#test'},$replacement,"$mode: old launch cannot overwrite successor handle");
    is(scalar @{$r->{completed}},1,"$mode: no second failure after inline completion");
}
{
    my $r=quote_runtime845();$MB845QuoteWorker::mode='defer';
    $r->{hook}=sub {die "consumer error\n"};$r->_start('#test',1,{revision=>1});
    ok(eval {$MB845QuoteWorker::jobs[-1]{on_done}->({ok=>1});1},'consumer exception is contained');
    is(scalar keys %{$r->{inflight}},0,'consumer exception cannot retain capacity');
    delete $r->{hook};is($r->_start('#test',2,{revision=>2}),1,'later work can recover after consumer exception');
    my $invalid=quote_runtime845();$invalid->{worker_class}='Mediabot::AsyncWorker';$invalid->{loop}=bless({},'MB845NoLoop');
    is($invalid->_start('#test',1,{revision=>1}),0,'native setup refusal remains false');
    is(scalar @{$invalid->{completed}},1,'native inline setup failure is consumed once');
    is(scalar keys %{$invalid->{workers}},0,'native setup failure leaves no handle');
}
{
    # Keep the real schedule, SQL selection, final gates and actual fork/pipe.
    my $f=MB813RandomQuoteFixture->new;my $r=$f->{runtime};my $loop=IO::Async::Loop->really_new;
    $r->{loop}=$loop;$r->{worker_class}='Mediabot::AsyncWorker';
    $f->{bot}{conf}->set('main.RANDOM_QUOTE',900);
    my @sent;no warnings 'redefine';
    local *Mediabot::Helpers::botPrivmsg=sub {push @sent,[$_[1],$_[2],$_[3]];1};
    is($r->tick,0,'native schedule still waits one complete first interval');
    $f->{now}+=900;is($r->tick,1,'real asynchronous quote selection starts when due');
    my $deadline=time()+4;$loop->loop_once(.01) while keys(%{$r->{inflight}}) && time()<$deadline;
    is(scalar keys %{$r->{inflight}},0,'real child completion releases reservation');
    is(scalar keys %{$r->{workers}},0,'real child completion releases handle');
    is(scalar @sent,1,'real quote is delivered once');
    is($sent[0][0],'#test','native output stays on the selected channel');
    ok($sent[0][2]{no_defer},'native output retains no-catch-up transport policy');
    ok($f->{state}->status('#test',900)->{last_id},'only the accepted native quote id is recorded');
    is($r->tick,0,'completion does not retry before the next interval');
    is($f->{dbh}->selectrow_array('SELECT SUM(hits) FROM QUOTES'),0,'automatic selection preserves quote recall counters');
    is($f->{dbh}->selectrow_array('SELECT COUNT(*) FROM QUOTES'),3,'parent connection and quote rows remain intact');
}
done_testing;
