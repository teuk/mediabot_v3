use strict;
use warnings;
use Scalar::Util qw(weaken);
use IO::Async::Loop;
use Time::HiRes ();
use Mediabot::VDM::AsyncFetcher;

{
    package MB848::VDMWorker;
    our (@workers, $launch);
    sub start {
        my ($class, %args) = @_;
        my $worker = bless {args => \%args, cancelled => 0}, $class;
        push @workers, $worker;
        return $launch ? $launch->($worker) : $worker;
    }
    sub finish { $_[0]{args}{on_done}->($_[1]) }
    sub cancel { $_[0]{cancelled}++; return 1 }
}
sub mb848_vdm_result {
    return {ok => 1, value => {ok => 1, items => [{id => $_[0], story => 'Offline VDM fixture'}]}};
}
sub mb848_vdm_waiter {
    my ($context, $sink) = @_;
    return sub {push @$sink, [$context->{name}, $_[0]]};
}
return sub {
    my ($a) = @_;
    local @MB848::VDMWorker::workers;
    local $MB848::VDMWorker::launch;
    my $make = sub {Mediabot::VDM::AsyncFetcher->new(
        loop => bless({}, 'MB848::UnusedLoop'), worker_class => 'MB848::VDMWorker',
        fetch_cb => sub {die 'external fetch forbidden'}, @_)};

    # The worker can finish inside start(). Its caller can request the same
    # article immediately; cancellation must still reach the new worker.
    for my $ending (qw(handle refuse throw)) {
        my $fetcher = $make->(); my (@out, $successor);
        $MB848::VDMWorker::launch = sub {
            my ($worker) = @_;
            $MB848::VDMWorker::launch = undef;
            $worker->finish(mb848_vdm_result(42));
            die "synthetic private launch error\n" if $ending eq 'throw';
            return $ending eq 'refuse' ? undef : $worker;
        };
        my $accepted = $fetcher->fetch(id => 42, on_done => sub {
            push @out, $_[0]{items}[0]{id};
            $successor = $fetcher->fetch(id => 42, on_done => sub {push @out, $_[0]{items}[0]{id}});
        });
        my ($old, $current) = @MB848::VDMWorker::workers[-2,-1];
        $a->is($accepted ? 1 : 0, $ending eq 'handle' ? 1 : 0, "mb848: $ending preserves launch return contract");
        $a->ok($successor && $fetcher->inflight, "mb848: $ending preserves same-source successor");
        $a->is($fetcher->waiter_count, 1, "mb848: $ending retains only current waiter");
        $a->ok($fetcher->cancel('offline cancellation'), "mb848: $ending current job is cancellable");
        $a->is($current->{cancelled}, 1, "mb848: $ending cancellation reaches successor handle");
        $a->is($old->{cancelled}, 0, "mb848: $ending completed handle is never cancelled");
        $old->finish(mb848_vdm_result(999));
        $a->is(join(',', @out), '42', "mb848: $ending old completion cannot emit or consume successor");
        $current->finish(mb848_vdm_result(43));
        $a->is(join(',', @out), '42,43', "mb848: $ending successor owns its terminal delivery");
        $a->ok(!$fetcher->inflight && !$fetcher->waiter_count, "mb848: $ending frees capacity after completion");
    }

    # Retaining a completed worker (diagnostics, a test double, or a delayed
    # callback) must not retain former request contexts or the handle itself.
    my $fetcher = $make->(); my @done;
    my $context = {name => 'first'}; my $weak_context = $context; weaken($weak_context);
    $fetcher->fetch(on_done => mb848_vdm_waiter($context, \@done));
    undef $context;
    my $worker = $MB848::VDMWorker::workers[-1];
    $a->ok(defined($weak_context), 'mb848: pending waiter retains its required context');
    $worker->finish(mb848_vdm_result(1));
    $a->is(scalar @done, 1, 'mb848: first waiter receives one terminal result');
    $a->ok(!defined($weak_context), 'mb848: completed retained callback releases former waiter context');
    my $weak_worker = $worker; weaken($weak_worker);
    my $retained_callback = $worker->{args}{on_done};
    pop @MB848::VDMWorker::workers; undef $worker;
    $a->ok(!defined($weak_worker), 'mb848: retained completion has no cycle through completed worker');
    $retained_callback->(mb848_vdm_result(2));
    $a->is(scalar @done, 1, 'mb848: retained terminal callback remains inert');

    my $inline = $make->(); my @inline;
    $MB848::VDMWorker::launch = sub {
        my ($worker) = @_; $MB848::VDMWorker::launch = undef;
        $worker->finish(mb848_vdm_result(60)); return $worker;
    };
    $inline->fetch(id => 60, on_done => sub {
        push @inline, $_[0]{items}[0]{id};
        $inline->fetch(id => 60, on_done => sub {push @inline, $_[0]{items}[0]{id}});
    });
    my $inline_old = splice @MB848::VDMWorker::workers, -2, 1;
    my $weak_inline = $inline_old; weaken($weak_inline);
    my $inline_callback = $inline_old->{args}{on_done}; undef $inline_old;
    $a->ok(!defined($weak_inline), 'mb848: returning inline handle cannot recreate completed worker cycle');
    $inline_callback->(mb848_vdm_result(61));
    $a->is(join(',', @inline), '60', 'mb848: retained inline callback cannot deliver successor');
    $MB848::VDMWorker::workers[-1]->finish(mb848_vdm_result(62));
    $a->is(join(',', @inline), '60,62', 'mb848: inline successor still owns completion after old handle release');

    # Cleanup must happen before fan-out: one failing consumer cannot strand
    # the others, and they can already see the released worker capacity.
    my $shared = $make->(); my @shared;
    $shared->fetch(id => 77, on_done => sub {push @shared, $shared->waiter_count; die 'consumer failure'});
    $shared->fetch(id => 77, on_done => sub {push @shared, $_[0]{items}[0]{id}});
    my $shared_worker = $MB848::VDMWorker::workers[-1];
    $shared_worker->finish(mb848_vdm_result(77));
    $shared_worker->finish(mb848_vdm_result(78));
    $a->is(join(',', @shared), '0,77', 'mb848: cleanup precedes isolated one-shot waiter fan-out');

    for my $ending (qw(refuse throw callback_refuse callback_throw)) {
        my $failed = $make->(); my @failed;
        $MB848::VDMWorker::launch = sub {
            my ($worker) = @_;
            $worker->finish({ok => 0, error => 'worker_setup'}) if $ending =~ /^callback/;
            die 'private setup failure' if $ending =~ /throw/;
            return undef;
        };
        my $accepted = $failed->fetch(on_done => sub {push @failed, $_[0]});
        $a->ok(!$accepted, "mb848: $ending reports failed worker launch");
        $a->is(scalar @failed, 1, "mb848: $ending completes the caller once");
        $a->is($failed[0]{error}, 'worker_error', "mb848: $ending preserves bounded normalized failure");
        $a->ok(!$failed->inflight && !$failed->waiter_count, "mb848: $ending releases all reserved capacity");
        $MB848::VDMWorker::launch = undef;
        $a->ok($failed->fetch(on_done => sub {}), "mb848: $ending accepts a later request");
        $MB848::VDMWorker::workers[-1]->finish(mb848_vdm_result(8));
    }

    my $bounded = $make->(max_waiters => 4);
    $a->ok(!$bounded->fetch(id => 'bad', on_done => sub {}), 'mb848: invalid article still fails before launch');
    for my $id (1..4) {$a->ok($bounded->fetch(id => $id, on_done => sub {}), 'mb848: independent source occupies one bounded worker slot')}
    $a->ok(!$bounded->fetch(id => 5, on_done => sub {}), 'mb848: total waiter/concurrency limit remains enforced');
    $_->finish(mb848_vdm_result(9)) for @MB848::VDMWorker::workers[-4..-1];
    $a->ok(!$bounded->inflight, 'mb848: bounded requests all complete normally');
    my $worker_bound = $make->(max_waiters => 16);
    $worker_bound->fetch(id => $_, on_done => sub {}) for 1..4;
    $a->ok(!$worker_bound->fetch(id => 5, on_done => sub {}), 'mb848: four-worker ceiling holds below waiter ceiling');
    $a->ok($worker_bound->fetch(id => 4, on_done => sub {}), 'mb848: coalescing remains allowed when four workers are active');
    $a->is($worker_bound->waiter_count, 5, 'mb848: coalesced waiter does not allocate a fifth worker');
    $_->finish(mb848_vdm_result(9)) for @MB848::VDMWorker::workers[-4..-1];

    # Real fork/pipe/watchers, with a local child value only. No source HTTP.
    require Mediabot::AsyncWorker;
    my $loop = IO::Async::Loop->new;
    my $real = Mediabot::VDM::AsyncFetcher->new(loop => $loop,
        fetch_cb => sub {my (%args) = @_; return {ok => 1, items => [{id => $args{id}, story => 'Offline child'}]}});
    my @real;
    $a->ok($real->fetch(id => 55, on_done => sub {push @real, $_[0]}), 'mb848: real article worker starts');
    $a->ok($real->fetch(id => 55, on_done => sub {push @real, $_[0]}), 'mb848: real matching article coalesces');
    my $deadline = Time::HiRes::time() + 5;
    $loop->loop_once(0.02) while $real->inflight && Time::HiRes::time() < $deadline;
    $a->is(scalar @real, 2, 'mb848: actual child completion reaches both waiters');
    $a->is(join(',', map {$_->{items}[0]{id}} @real), '55,55', 'mb848: exact requested ID survives process transport');
    $a->ok(!$real->inflight && !$real->waiter_count, 'mb848: real completion releases capacity');
};
