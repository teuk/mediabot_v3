package Mediabot::Spark::Config;
use strict;
use warnings;
use Exporter 'import';
our @EXPORT_OK = qw(orchestrator_options);

# Keep the live runtime and offline replay on one configuration boundary.
# Values remain raw here: Orchestrator owns validation, bounds and defaults.
my @OPTIONS = (
    ['min_silence_seconds', 'SPARK_MIN_SILENCE_SECONDS'],
    ['candidate_probe_seconds', 'SPARK_CANDIDATE_PROBE_SECONDS'],
    ['action_activity_window_seconds', 'SPARK_ACTION_ACTIVITY_WINDOW_SECONDS'],
    ['action_min_humans', 'SPARK_ACTION_MIN_HUMANS'],
    ['action_min_lines', 'SPARK_ACTION_MIN_LINES'],
    ['action_min_pause_seconds', 'SPARK_ACTION_MIN_PAUSE_SECONDS'],
    ['action_max_pause_seconds', 'SPARK_ACTION_MAX_PAUSE_SECONDS'],
    ['action_probe_seconds', 'SPARK_ACTION_PROBE_SECONDS'],
    ['action_cooldown_seconds', 'SPARK_ACTION_COOLDOWN_SECONDS'],
);
sub orchestrator_options {
    my ($conf) = @_;
    die "Spark configuration unavailable\n" unless $conf && eval {$conf->can('get')};
    return { map {$_->[0] => $conf->get('main.'.$_->[1])} @OPTIONS };
}
1;
