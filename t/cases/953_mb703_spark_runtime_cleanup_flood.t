# t/cases/953_mb703_spark_runtime_cleanup_flood.t
# =============================================================================
# MB703-D — Runtime cleanup and independent Spark flood suppression.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use Mediabot::AI::ConversationFloodGuard;
use Mediabot::Spark::Observer;
use Mediabot::Spark::Orchestrator;
use Mediabot::Spark::State;

return sub {
    my ($assert) = @_;

    my $now = 30_000;
    my $clock = sub { $now };
    my $state = Mediabot::Spark::State->new(clock => $clock);
    my $observer = Mediabot::Spark::Observer->new(clock => $clock);
    my $guard = Mediabot::AI::ConversationFloodGuard->new(
        clock => $clock,
        threshold_lines => 3,
        window_seconds => 10,
        suppression_seconds => 180,
    );
    my $rt = Mediabot::Spark::Orchestrator->new(
        state => $state,
        observer => $observer,
        flood_guard => $guard,
        clock => $clock,
    );

    my $last;
    for my $row (
        [Alice => 'un'],
        [Bob   => 'deux'],
        [Carol => 'trois'],
    ) {
        $last = $rt->observe_public_line(
            enabled => 1, channel => '#spark', nick => $row->[0],
            bot_nick => 'Mediabot', message => $row->[1], command_char => '!',
        );
        $now += 1;
    }

    $assert->is($last->{reason}, 'flood_suppression',
        'mb703-953: Spark has an independent flood guard before future AI/event work');
    $assert->is(scalar(@{ $rt->context_lines('#spark') }), 2,
        'mb703-953: the line that trips suppression is not retained as provider context');

    my $disc = $rt->evaluate_channel(
        enabled => 1, channel => '#spark', runtime_active => 1,
        irc_connected => 0, channel_joined => 0,
        game_active => 0, wit_pending => 0, ai_available => 1,
    );
    $assert->is($disc->{reason}, 'irc_disconnected',
        'mb703-953: IRC disconnect fails closed');
    $assert->is(scalar(@{ $rt->channels() }), 0,
        'mb703-953: disconnect/part truth discards ephemeral channel context');
    $assert->is($state->snapshot('#spark')->{recent_humans}, 0,
        'mb703-953: forgotten channel cannot reuse pre-disconnect human activity');

    $state->observe_human(channel => '#other', nick => 'Alice');
    $assert->is($state->forget_channel('#other'), 1,
        'mb703-953: State exposes explicit ephemeral channel cleanup');
    $assert->is($state->snapshot('#other')->{recent_humans}, 0,
        'mb703-953: State cleanup removes bounded human metadata too');
};
