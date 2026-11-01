use strict;
use warnings;
use Test::More;
use Scalar::Util qw(refaddr);
use Mediabot::Plugin::EventQueueV3;

{
    package EventFixture::FalseError;
    use overload bool=>sub {$_[0]{coercions}++;0},
        '""'=>sub {$_[0]{coercions}++;die "private exception text\n"},fallback=>1;
    package EventFixture::ThrowingError;
    use overload bool=>sub {$_[0]{coercions}++;die "private exception bool\n"},
        '""'=>sub {$_[0]{coercions}++;die "private exception text\n"},fallback=>1;
}
sub fire_event {my ($later)=@_;my $cb=shift @$later;return unless $cb;$cb->()}
{
    my (@later,@seen,@errors,@drops);
    my $q=Mediabot::Plugin::EventQueueV3->new(max_pending=>3,batch_size=>2,
        defer=>sub {push @later,$_[0]},dispatch=>sub {
            die "broken event\n" if $_[0]{id} eq 'bad';push @seen,$_[0]{id};
        },on_error=>sub {push @errors,$_[1]},on_drop=>sub {push @drops,$_[0]{id}});
    my @accepted=map {$q->enqueue({id=>$_})} qw(one bad three four);
    is_deeply([\@accepted,$q->pending_count,scalar(@later),\@drops,$q->dropped_count],
        [[1,1,1,0],3,1,['four'],1],'burst stays bounded, drops the newest event and schedules one drain');
    fire_event(\@later);
    is_deeply([\@seen,\@errors,$q->pending_count,scalar(@later),$q->processed_count],
        [['one'],["broken event\n"],1,1,2],'a scalar handler error is observed once and the next batch waits');
    fire_event(\@later);
    is_deeply([\@seen,$q->pending_count,$q->processed_count,$q->dropped_count],
        [[qw(one three)],0,3,1],'remaining work drains once and counters include contained failures');
    $q->enqueue({id=>'stale'});my $stale=shift @later;my $cancelled=$q->clear;$stale->();
    is_deeply([$cancelled,\@seen,$q->pending_count,$q->processed_count],
        [1,[qw(one three)],0,3],'clear revokes pending work even when its old callback is retained');
}
for my $class(qw(EventFixture::FalseError EventFixture::ThrowingError)) {
    my $error=bless {coercions=>0},$class;
    my (@later,@seen,@errors);
    my $q=Mediabot::Plugin::EventQueueV3->new(max_pending=>4,batch_size=>1,
        defer=>sub {push @later,$_[0]},dispatch=>sub {
            die $error if $_[0]{id} eq 'bad';push @seen,$_[0]{id};
        },on_error=>sub {push @errors,$_[1];die "observer failed\n"});
    $q->enqueue({id=>'bad'});$q->enqueue({id=>'healthy'});
    my $ok=eval {fire_event(\@later);1};
    is_deeply([$ok?1:0,scalar(@errors),refaddr($errors[0]),$error->{coercions},
        $q->{draining},$q->pending_count,$q->processed_count,scalar(@later)],
        [1,1,refaddr($error),0,0,1,1,1],"$class dispatch preserves the exception object and retires the batch despite an observer failure");
    fire_event(\@later);$q->enqueue({id=>'later'});fire_event(\@later);
    is_deeply([\@seen,$q->pending_count,$q->processed_count,$q->{draining}],
        [[qw(healthy later)],0,3,0],"$class dispatch does not strand accepted or subsequently enqueued work");
}
for my $class(qw(EventFixture::FalseError EventFixture::ThrowingError)) {
    my $error=bless {coercions=>0},$class;
    my (@later,@seen);my $fail=1;
    my $q=Mediabot::Plugin::EventQueueV3->new(max_pending=>3,batch_size=>1,
        defer=>sub {push @later,$_[0];die $error if $fail},dispatch=>sub {push @seen,$_[0]{id}});
    my $ok=eval {$q->enqueue({id=>'one'});1};my $caught=$@;
    my $stale=shift @later;$stale->();
    is_deeply([$ok?1:0,refaddr($caught),$error->{coercions},$q->{scheduled},
        $q->pending_count,\@seen],[0,refaddr($error),0,0,1,[]],
        "$class defer propagates the exact exception after revoking only its failed arm");
    $fail=0;$q->enqueue({id=>'two'});$stale->();fire_event(\@later);fire_event(\@later);
    is_deeply([\@seen,$q->pending_count,$q->processed_count,$q->{scheduled}],
        [[qw(one two)],0,2,0],"$class defer recovers without a stale callback consuming fresh work");
}
{
    my (@later,@seen);my $fail=1;
    my $q=Mediabot::Plugin::EventQueueV3->new(max_pending=>2,batch_size=>1,
        defer=>sub {push @later,$_[0];die "loop unavailable\n" if $fail},
        dispatch=>sub {push @seen,$_[0]{id}});
    for my $id(qw(one two)) {eval {$q->enqueue({id=>$id});1}}
    my @stale=splice @later;$fail=0;
    my $accepted=$q->enqueue({id=>'rejected'});
    $_->() for @stale;
    is_deeply([$accepted,$q->pending_count,$q->dropped_count,scalar(@later),\@seen],
        [0,2,1,1,[]],'a full unarmed queue keeps its cap and rejected-newest policy while retrying its accepted backlog');
    fire_event(\@later);fire_event(\@later);$_->() for @stale;
    is_deeply([\@seen,$q->pending_count,$q->processed_count,$q->dropped_count],
        [[qw(one two)],0,2,1],'accepted work drains in FIFO batches after scheduling recovers, without reviving old failed arms');
}
{
    # Exercise the real PluginManager bridge, failure ledger and event envelope.
    # Reuse the existing offline transport/scheduler fixture only.
    my $fixture=do './t/cases/1072_mb743_v3_events_jobs_lifecycle.t';
    die 'lifecycle fixture missing' unless ref($fixture) eq 'CODE';
    require Mediabot::PluginManager;
    my $bot=T1072::Bot->new;
    my $manager=Mediabot::PluginManager->new(bot=>$bot,plugin_dir=>'plugins');
    my $entry=$manager->load_package_v3('hello-v3',
        grants=>['events.subscribe','irc.reply','scheduler.jobs'],
        channel_policies=>{'#i/o'=>{mode=>'on',config=>{}}});
    $manager->enable('hello-v3');my $seen=0;
    my $error=bless {coercions=>0},'EventFixture::ThrowingError';
    no warnings qw(redefine once);
    local *Mediabot::Plugin::V3::Hello::event_minute=sub {die $error if ++$seen==1;1};
    my $emit=sub {$bot->events->emit('plugin_cron_observed',{
        minute=>$_[0],hour=>7,dow=>4,mday=>1,month=>11,year=>2026})};
    $emit->(1);$emit->(2);
    my $ok=eval {$bot->{loop}->run_all;1};
    my $report=$manager->_v3_failure_ledger('hello-v3')->report;
    is_deeply([$ok?1:0,$seen,$entry->{event_queue}->processed_count,
        $entry->{event_queue}->pending_count,$report->{total_failures},
        $report->{total_successes},$error->{coercions}],
        [1,2,2,0,1,1,0],'native manager reports one plugin failure and delivers the following event without coercing the exception');
    $emit->(3);$bot->{loop}->run_all;
    $report=$manager->_v3_failure_ledger('hello-v3')->report;
    my $pending=$entry->{event_queue}->pending_count;
    $manager->unregister_plugin('hello-v3');
    is_deeply([$seen,$pending,$report->{total_failures},$report->{total_successes},
        $bot->events->listener_count('plugin_cron_observed')],[3,0,1,2,0],
        'native manager stays usable after the failure and still removes its owned listener');
}
done_testing;
