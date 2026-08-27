# t/cases/962_mb703_spark_runtime_pacing_bounds.t
# =============================================================================
# MB703-F — pilot pacing cannot escape the Orchestrator's safe numeric bounds.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use Mediabot::Spark::Orchestrator;

{
    package Local::SparkState961;
    sub new { bless {}, shift }
    sub observe_human { return { recent_humans => 0 } }
    sub snapshot { return { recent_humans => 0, event_active => 0, cooldown_until => 0 } }
}

{
    package Local::SparkObserver961;
    sub new { bless {}, shift }
    sub observe_public_line { return { reason => 'observed', line_count => 0 } }
    sub context_lines { return [] }
}

return sub {
    my ($assert) = @_;

    my $state = Local::SparkState961->new();
    my $observer = Local::SparkObserver961->new();

    my $pilot = Mediabot::Spark::Orchestrator->new(
        state                   => $state,
        observer                => $observer,
        min_silence_seconds     => 60,
        candidate_probe_seconds => 30,
    );
    $assert->is($pilot->{min_silence_seconds}, 60,
        'mb703-962: 60s pilot silence value is accepted at the lower bound');
    $assert->is($pilot->{candidate_probe_seconds}, 30,
        'mb703-962: 30s pilot probe value is accepted at the lower bound');

    my $unsafe_low = Mediabot::Spark::Orchestrator->new(
        state                   => $state,
        observer                => $observer,
        min_silence_seconds     => 1,
        candidate_probe_seconds => 1,
    );
    $assert->is($unsafe_low->{min_silence_seconds}, 1200,
        'mb703-962: too-low silence value fails back to 20 minutes');
    $assert->is($unsafe_low->{candidate_probe_seconds}, 300,
        'mb703-962: too-low probe value fails back to five minutes');

    my $unsafe_high = Mediabot::Spark::Orchestrator->new(
        state                   => $state,
        observer                => $observer,
        min_silence_seconds     => 999_999,
        candidate_probe_seconds => 999_999,
    );
    $assert->is($unsafe_high->{min_silence_seconds}, 1200,
        'mb703-962: too-high silence value fails closed to the safe default');
    $assert->is($unsafe_high->{candidate_probe_seconds}, 300,
        'mb703-962: too-high probe value fails closed to the safe default');
};
