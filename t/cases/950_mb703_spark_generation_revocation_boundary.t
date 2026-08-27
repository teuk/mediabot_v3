# t/cases/950_mb703_spark_generation_revocation_boundary.t
# =============================================================================
# MB703-C — Event generation tokens make future async AI completion revocable.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use Mediabot::Spark::State;
use Mediabot::Spark::Selector qw(select_spark_event);

return sub {
    my ($assert) = @_;

    my $now = 500_000;
    my $state = Mediabot::Spark::State->new(clock => sub { $now });
    $state->observe_human(channel => '#spark', nick => 'alice');
    $now += 5;
    $state->observe_human(channel => '#spark', nick => 'bob');
    $now += 5;
    $state->observe_human(channel => '#spark', nick => 'carol');

    my $choice = select_spark_event(
        recent_humans => 3,
        context_lines => 5,
        ai_available  => 1,
        cursor        => 2,
    );
    $assert->is($choice->{kind}, 'callback',
        'mb703-950: selector can choose a context-aware AI-enriched Callback');

    my $generation = $state->begin_event(
        channel          => '#spark',
        kind             => $choice->{kind},
        duration_seconds => $choice->{duration_seconds},
    );
    $assert->ok($state->generation_is_current('#spark', $generation),
        'mb703-950: async work can capture the active event generation');

    my $finished = $state->finish_event(channel => '#spark', outcome => 'superseded');
    $assert->is($finished->{outcome}, 'superseded',
        'mb703-950: organic conversation may supersede the event');
    $assert->ok(!$state->generation_is_current('#spark', $generation),
        'mb703-950: late provider completion is stale after event completion');

    my $main = do {
        open my $fh, '<:encoding(UTF-8)', "$Bin/../../mediabot.pl"
            or die "open mediabot.pl: $!";
        local $/;
        <$fh>;
    };
    $assert->like($main, qr/Mediabot::Spark::(?:State|Observer|Orchestrator|Generator|DryRun|Sender)/,
        'mb703-950: runtime keeps state, generation and guarded delivery boundaries explicit');
    $assert->like($main, qr/Mediabot::Spark::DryRun::format_ai_dryrun_log/,
        'mb703-950: provider completion is reduced to a metadata-only Spark dry-run log');
    $assert->like($main, qr/SPARK_SEND_ARMED/,
        'mb703-950: guarded delivery is controlled by the explicit Spark kill switch');
};
