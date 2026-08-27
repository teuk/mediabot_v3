use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use Mediabot::VDM::AsyncFetcher;

{
    package MB704B::Worker;
    our @STARTS;
    sub start {
        my ($class, %args) = @_;
        my $self = bless { args => { %args }, cancelled => 0 }, $class;
        push @STARTS, $self;
        return $self;
    }
    sub complete {
        my ($self, $result) = @_;
        $self->{args}{on_done}->($result);
    }
    sub run_child { $_[0]{args}{child}->() }
    sub cancel { $_[0]{cancelled} = 1; return 1 }
}

return sub {
    my ($assert) = @_;
    @MB704B::Worker::STARTS = ();

    my $fetch_calls = 0;
    my $async = Mediabot::VDM::AsyncFetcher->new(
        loop => bless({}, 'MB704B::Loop'),
        worker_class => 'MB704B::Worker',
        fetch_cb => sub {
            $fetch_calls++;
            return { ok => 1, items => [ { id => '42', story => 'Aujourd\'hui, test. VDM' } ] };
        },
    );

    my @done;
    $assert->ok($async->fetch(on_done => sub { push @done, shift }),
        'mb704-972: first request starts asynchronously');
    $assert->ok($async->inflight,
        'mb704-972: worker is marked inflight');
    $assert->is(scalar(@MB704B::Worker::STARTS), 1,
        'mb704-972: one worker starts for first request');

    $assert->ok($async->fetch(on_done => sub { push @done, shift }),
        'mb704-972: simultaneous caller is accepted for coalescing');
    $assert->is(scalar(@MB704B::Worker::STARTS), 1,
        'mb704-972: simultaneous callers share one worker');
    $assert->is($async->waiter_count, 2,
        'mb704-972: coalesced callers are bounded waiters');

    my $child_value = $MB704B::Worker::STARTS[0]->run_child;
    $assert->is($fetch_calls, 1,
        'mb704-972: feed fetch callback runs in the worker child boundary once');

    $MB704B::Worker::STARTS[0]->complete({ ok => 1, value => $child_value });
    $assert->ok(!$async->inflight,
        'mb704-972: completion clears inflight state');
    $assert->is(scalar(@done), 2,
        'mb704-972: all coalesced callers receive completion');
    $assert->ok($done[0]{ok} && $done[1]{ok},
        'mb704-972: successful child result is normalized for all waiters');

    $assert->ok($async->fetch(on_done => sub { push @done, shift }),
        'mb704-972: another request may start after completion');
    $assert->ok($async->cancel('test cancellation'),
        'mb704-972: active worker may be cancelled through shared worker API');

    my $bounded = Mediabot::VDM::AsyncFetcher->new(
        loop => bless({}, 'MB704B::Loop2'),
        worker_class => 'MB704B::Worker',
        max_waiters => 1,
        fetch_cb => sub { return { ok => 1, items => [] } },
    );
    $assert->ok($bounded->fetch(on_done => sub {}),
        'mb704-972: bounded fetcher accepts first waiter');
    $assert->ok(!$bounded->fetch(on_done => sub {}),
        'mb704-972: waiter cap fails closed under request pressure');
    $assert->ok(!$bounded->fetch(on_done => 'not-a-callback'),
        'mb704-972: invalid completion callback fails closed');
};
