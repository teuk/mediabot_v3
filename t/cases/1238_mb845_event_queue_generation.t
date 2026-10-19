use strict;
use warnings;
use Test::More;
use lib '.';
use Mediabot::Plugin::EventQueueV3;
use IO::Async::Loop;
use Time::HiRes qw(time);
sub fire845 {my ($later)=@_;my $cb=shift @$later;$cb->() if $cb;}

for my $clear_from (qw(dispatch on_error)) {
    my (@later,@seen);my $queue;
    my $replace=sub {$queue->clear;$queue->enqueue({id=>'replacement'})};
    $queue=Mediabot::Plugin::EventQueueV3->new(batch_size=>2,max_pending=>3,
        defer=>sub {push @later,$_[0]},dispatch=>sub {
            push @seen,$_[0]{id};
            if ($_[0]{id} eq 'first') {
                die "fixture failure\n" if $clear_from eq 'on_error';
                $replace->();
            }
        },on_error=>sub {$replace->()});
    $queue->enqueue({id=>'first'});$queue->enqueue({id=>'obsolete'});
    my $old=shift @later;$old->();
    is(join(',',@seen),'first',"$clear_from: clear ends the old active batch");
    is($queue->pending_count,1,"$clear_from: replacement waits for its own deferred drain");
    is(scalar @later,1,"$clear_from: one replacement drain is scheduled");
    is($queue->processed_count,1,"$clear_from: only the dispatched old event is counted");
    $old->();
    is($queue->pending_count,1,"$clear_from: replaying old drain cannot consume new work");
    fire845(\@later);
    is(join(',',@seen),'first,replacement',"$clear_from: fresh generation drains normally");
    is($queue->pending_count,0,"$clear_from: replacement queue drains fully");
}
{
    my (@later,@seen);my $fail=1;
    my $q=Mediabot::Plugin::EventQueueV3->new(batch_size=>1,max_pending=>3,
        defer=>sub {push @later,$_[0];die "defer failed\n" if $fail},dispatch=>sub {push @seen,$_[0]{id}});
    ok(!eval {$q->enqueue({id=>'one'});1},'defer exception still reaches caller');
    is($q->pending_count,1,'failed scheduling does not discard pending work');
    my $old=shift @later;$old->();
    is(scalar @seen,0,'callback retained by a failed arm cannot dispatch');
    is($q->pending_count,1,'failed-arm callback cannot consume retained work');
    $fail=0;$q->enqueue({id=>'two'});is(scalar @later,1,'a later enqueue can schedule recovery');
    $old->();is(scalar @seen,0,'failed-arm replay cannot preempt recovery');
    fire845(\@later);is(join(',',@seen),'one','recovery still respects the batch bound');
    fire845(\@later);is(join(',',@seen),'one,two','remaining work gets a distinct later batch');
}
{
    my (@later,@seen);my $q;my $first=1;
    $q=Mediabot::Plugin::EventQueueV3->new(batch_size=>1,max_pending=>3,
        defer=>sub {
            if ($first) {$first=0;$_[0]->();die "old arm threw after completion\n"}
            push @later,$_[0];
        },dispatch=>sub {
            push @seen,$_[0]{id};
            if ($_[0]{id} eq 'first') {$q->clear;$q->enqueue({id=>'second'})}
        });
    ok(!eval {$q->enqueue({id=>'first'});1},'old defer failure remains visible after inline completion');
    is(join(',',@seen),'first','inline dispatch consumes only its old generation');
    ok($q->{scheduled},'old arm exception cannot reset the replacement scheduled flag');
    $q->enqueue({id=>'third'});
    is(scalar @later,1,'enqueue after old exception does not duplicate the replacement drain');
    fire845(\@later);is(join(',',@seen),'first,second','the original replacement arm remains usable');
    fire845(\@later);is(join(',',@seen),'first,second,third','subsequent event runs in another bounded batch');
}
{
    my $loop=IO::Async::Loop->really_new;my (@seen,@errors);my $q;
    $q=Mediabot::Plugin::EventQueueV3->new(batch_size=>1,max_pending=>4,
        defer=>sub {$loop->later($_[0])},dispatch=>sub {
            push @seen,$_[0]{id};
            if ($_[0]{id} eq 'reset') {$q->clear;$q->enqueue({id=>'fresh'});die "fixture dispatch failure\n"}
        },on_error=>sub {push @errors,$_[0]{id}});
    $q->enqueue({id=>'reset'});$q->enqueue({id=>'obsolete'});
    is(scalar @seen,0,'real IO::Async deferred delivery does not run inline');
    my $deadline=time()+3;$loop->loop_once(.01) while $q->pending_count && time()<$deadline;
    is(join(',',@seen),'reset,fresh','real loop drops cleared backlog and delivers fresh work once');
    is(join(',',@errors),'reset','real loop keeps handler failure isolation');
    is($q->processed_count,2,'real loop counts the two actually dispatched events');
    is($q->pending_count,0,'real loop leaves no blocked work');
}
{
    # Use the real manager's disable/re-enable path from a declared event
    # handler. Reuse only the existing offline bot/loop/scheduler fixture.
    my $fixture=do './t/cases/1072_mb743_v3_events_jobs_lifecycle.t';
    ok(ref($fixture) eq 'CODE','existing offline lifecycle fixture loads');
    require Mediabot::PluginManager;
    my $bot=T1072::Bot->new;
    my $manager=Mediabot::PluginManager->new(bot=>$bot,plugin_dir=>'plugins');
    my $entry=$manager->load_package_v3('hello-v3',
        grants=>['events.subscribe','irc.reply','scheduler.jobs'],
        channel_policies=>{'#i/o'=>{mode=>'on',config=>{}}});
    $manager->enable('hello-v3');my $seen=0;
    no warnings qw(redefine once);
    local *Mediabot::Plugin::V3::Hello::event_minute=sub {
        $seen++;
        if ($seen==1) {
            $manager->disable('hello-v3');$manager->enable('hello-v3');
            $bot->events->emit('plugin_cron_observed',{
                minute=>50,hour=>7,dow=>4,mday=>19,month=>10,year=>2026});
        }
        return 1;
    };
    for my $minute (1,2) {$bot->events->emit('plugin_cron_observed',{
        minute=>$minute,hour=>7,dow=>4,mday=>19,month=>10,year=>2026})}
    my $old=shift @{$bot->{loop}{later}};$old->();
    is($seen,1,'manager restart inside a handler ends the old batch');
    is($entry->{event_queue}->pending_count,1,'manager restart defers its newly accepted event');
    is(scalar @{$bot->{loop}{later}},1,'manager restart schedules exactly one fresh drain');
    ok($manager->is_enabled('hello-v3'),'new plugin activation remains enabled');
    ok($bot->{scheduler}{tasks}{'plugin.v3.hello-v3.heartbeat'}{started},'new activation keeps its owned job running');
    $old->();is($seen,1,'retained manager callback cannot process fresh activation work');
    $bot->{loop}->run_all;is($seen,2,'fresh activation event is delivered once');
    is($entry->{event_queue}->pending_count,0,'fresh activation drains completely');
    $manager->unregister_plugin('hello-v3');
    is($bot->events->listener_count('plugin_cron_observed'),0,'manager still tears down the exact event listener');
}
done_testing;
