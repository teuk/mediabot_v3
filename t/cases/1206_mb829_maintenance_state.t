use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use Mediabot::EventBus;
use Mediabot::AI::MetaMemory;

# One-shot subscriptions must stay one-shot across nested emissions, including
# a listener already consumed by an inner emission before the outer snapshot
# reaches it. Ordinary snapshot and error-isolation semantics remain unchanged.
for my $method (qw(emit emit_report)) {
    my $bus=Mediabot::EventBus->new;
    my $runs=0;
    $bus->once('nested',sub {
        ++$runs;
        $bus->$method('nested') if $runs<2;
    });
    $bus->$method('nested');
    is($runs,1,"$method: recursive callback runs once");
    is($bus->listener_count('nested'),0,"$method: consumed callback is removed");
    is_deeply([$bus->events],[],"$method: no phantom event remains");

    $bus=Mediabot::EventBus->new;
    my ($depth,$regular,$once)=(0,0,0);
    $bus->on('snapshot',sub {
        ++$regular;
        if (!$depth) {$depth=1; $bus->$method('snapshot'); $depth=0}
    });
    $bus->once('snapshot',sub {++$once});
    $bus->$method('snapshot');
    is($regular,2,"$method: regular listener can re-enter");
    is($once,1,"$method: outer snapshot cannot replay an inner one-shot");
    is($bus->listener_count('snapshot'),1,"$method: permanent subscription survives");

    $bus=Mediabot::EventBus->new;
    my ($old,$new)=(0,0);
    $bus->once('replace',sub {
        ++$old;
        $bus->once('replace',sub {++$new});
        $bus->$method('replace') if $old==1;
    });
    $bus->$method('replace');
    is($old,1,"$method: original one-shot remains consumed");
    is($new,1,"$method: newly registered one-shot can run in the nested event");
    is($bus->listener_count('replace'),0,"$method: nested replacement leaves no listener");
}

{
    my $bus=Mediabot::EventBus->new;my $runs=0;
    $bus->once('mixed',sub {++$runs;$bus->emit_report('mixed') if $runs<2});
    $bus->emit('mixed');
    is($runs,1,'one-shot claim is shared by emit and emit_report');
    my $failed=0;
    $bus->once('error',sub {++$failed;die "expected listener failure\n"});
    my $report=$bus->emit_report('error');
    is($report->{ran},1,'failed one-shot is counted as executed');
    is(scalar @{$report->{errors}},1,'failed one-shot keeps its error report');
    is($bus->emit_report('error')->{ran},0,'failed one-shot is not retried');
    is($failed,1,'exception does not restore a consumed callback');
}

for my $pair (['Alice!u@host','ALICE!u@host','Alice','ALICE'],
              ['Te[u]K!u@host','Te{u}K!u@host','Te[u]K','Te{u}K']) {
    my ($from,$to,$display,$renamed)=@$pair;
    my $dir=tempdir(CLEANUP=>1);
    my $memory=Mediabot::AI::MetaMemory->new(path=>"$dir/memory.json");
    my $ticket=$memory->begin_turn('network:#room',$from,'Remember the marker',100,$display);
    ok($memory->commit_turn($ticket,'The marker is owl'),'initial turn stored');
    my $inflight=$memory->begin_turn('network:#room',$from,'Continue',100,$display);
    ok($memory->rename_actor($from,$to),'equivalent IRC rename is accepted');
    ok($memory->current($inflight),'equivalent rename preserves an in-flight ticket');
    ok($memory->commit_turn($inflight,'Still owl'),'in-flight result remains associated with the actor');
    my $again=Mediabot::AI::MetaMemory->new(path=>"$dir/memory.json");
    my $next=$again->begin_turn('network:#room',$to,'What marker?',100);
    is($next->{speaker},$ticket->{speaker},'speaker identity survives rename and restart');
    is($next->{name},$renamed,'display name follows the observed nick');
    like(join(' ',map {$_->{content}} @{$next->{messages}}),qr/The marker is owl/,'conversation history remains available');
    my $other=$again->begin_turn('network:#room','Other!u@host','Hello',100,'Other');
    isnt($other->{speaker},$next->{speaker},'another participant remains distinct');
    ok($again->forget_actor('network:#room',$to),'renamed actor can erase their conversation');
    ok(!$again->current($next),'forget still invalidates the actor ticket');
    ok(!$again->commit_turn($next,'stale'),'late result cannot undo erasure');
    my $after=$again->begin_turn('network:#room',$to,'Fresh start',100,$renamed);
    unlike(join(' ',map {$_->{content}} @{$after->{messages}}),qr/owl|Remember the marker/,'erased content stays erased');
}

done_testing;
