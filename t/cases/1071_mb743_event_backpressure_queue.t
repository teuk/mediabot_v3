# MB743 — bounded deferred event delivery and overflow isolation.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

return sub {
    my ($assert) = @_;

    require Mediabot::Plugin::EventQueueV3;

    my (@later, @seen, @errors, @drops);
    my $queue = Mediabot::Plugin::EventQueueV3->new(
        max_pending => 3,
        batch_size  => 2,
        defer       => sub { push @later, $_[0] },
        dispatch    => sub {
            my ($event) = @_;
            die "broken event\n" if $event->{id} eq 'bad';
            push @seen, $event->{id};
        },
        on_error => sub { push @errors, $_[1] },
        on_drop  => sub { push @drops, $_[0]{id} },
    );

    $assert->ok($queue->enqueue({ id => 'one' }), 'first event is accepted');
    $assert->ok($queue->enqueue({ id => 'bad' }), 'failing event is queued');
    $assert->ok($queue->enqueue({ id => 'three' }), 'queue accepts its bound');
    $assert->is($queue->enqueue({ id => 'four' }), 0,
        'overflow drops the newest event');
    $assert->is($queue->pending_count, 3,
        'pending queue never exceeds its bound');
    $assert->is(scalar @later, 1,
        'a burst schedules only one deferred drain');
    $assert->is(join(',', @drops), 'four',
        'drop callback identifies the rejected event');

    shift(@later)->();
    $assert->is(join(',', @seen), 'one',
        'first batch continues around a contained handler failure');
    $assert->is(scalar @errors, 1,
        'handler failure is reported exactly once');
    $assert->is($queue->pending_count, 1,
        'batch size leaves excess work queued');
    $assert->is(scalar @later, 1,
        'remaining work receives one later drain');

    shift(@later)->();
    $assert->is(join(',', @seen), 'one,three',
        'next batch drains the remaining event');
    $assert->is($queue->processed_count, 3,
        'processed count includes contained failures');
    $assert->is($queue->dropped_count, 1,
        'drop count is monotonic');

    $queue->enqueue({ id => 'stale' });
    my $stale = shift @later;
    $assert->is($queue->clear, 1,
        'clear reports cancelled pending work');
    $stale->();
    $assert->is(join(',', @seen), 'one,three',
        'a pre-clear deferred callback cannot revive stale work');
};
