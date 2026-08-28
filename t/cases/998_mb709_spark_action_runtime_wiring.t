# t/cases/998_mb709_spark_action_runtime_wiring.t
use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

return sub {
    my ($assert) = @_;

    my $read = sub {
        my ($rel) = @_;
        open my $fh, '<:encoding(UTF-8)', "$Bin/../../$rel"
            or die "open $rel: $!";
        local $/;
        return <$fh>;
    };
    my $main = $read->('mediabot.pl');
    my $conf = $read->('mediabot.sample.conf');
    my $doc = $read->('docs/SPARK_ACTION.md');
    my $orch = $read->('Mediabot/Spark/Orchestrator.pm');
    my $policy = $read->('Mediabot/Spark/ActionPolicy.pm');

    $assert->like(
        $main,
        qr/chanset_enabled\(\s*\$bot,\s*\$channel,\s*'SparkAction',\s*default\s*=>\s*0/s,
        'mb709-998: runtime reads +SparkAction default-off');
    $assert->like(
        $main,
        qr/if \(\$enabled && \$action_enabled\).*?evaluate_action_channel\(/s,
        'mb709-998: momentum evaluation requires both Spark opt-ins');
    $assert->like(
        $main,
        qr/format_action_candidate_log\(\s*\$channel,\s*\$action_summary/s,
        'mb709-998: runtime emits a dedicated candidate metadata marker');
    $assert->like($orch, qr/action\s*=>\s*'action_candidate'/,
        'mb709-998: orchestrator exposes a distinct momentum candidate');
    $assert->like($orch, qr/kind\s*=>\s*\$profile->\{kind\}/,
        'mb709-998: momentum candidate selects an explicit action family');
    $assert->like($main, qr/main\.SPARK_ACTION_SEND_ARMED/,
        'mb709-998: action provider path has a separate default-off process arm');
    $assert->like($main, qr/submit_candidate\(.*?\$action_summary->\{kind\}/s,
        'mb709-998: authorized action candidates reach provider-neutral generation');
    $assert->unlike(
        $orch . $policy,
        qr/\b(?:botPrivmsg|botNotice|send_message|do_PRIVMSG|Net::Async::IRC)\b/,
        'mb709-998: action policy and orchestrator own no IRC transport');
    my ($action_method) = $orch =~
        /(sub evaluate_action_channel \{.*?\n\})\n\nsub observe_public_line/s;
    $assert->ok(defined $action_method,
        'mb709-998: momentum evaluator remains structurally auditable');
    $assert->unlike($action_method // '', qr/\bbegin_event\b/,
        'mb709-998: momentum evaluation creates no visible State event');

    for my $row (
        [ SPARK_ACTION_ACTIVITY_WINDOW_SECONDS => 600 ],
        [ SPARK_ACTION_MIN_HUMANS => 3 ],
        [ SPARK_ACTION_MIN_LINES => 6 ],
        [ SPARK_ACTION_MIN_PAUSE_SECONDS => 45 ],
        [ SPARK_ACTION_MAX_PAUSE_SECONDS => 180 ],
        [ SPARK_ACTION_PROBE_SECONDS => 30 ],
        [ SPARK_ACTION_COOLDOWN_SECONDS => 1200 ],
        [ SPARK_ACTION_SEND_ARMED => 0 ],
    ) {
        my ($key, $default) = @$row;
        $assert->is(
            scalar(() = $conf =~ /^\Q$key\E=\Q$default\E$/mg),
            1,
            "mb709-998: sample configuration exposes $key=$default once",
        );
        $assert->is(
            scalar(() = $doc =~ /^\Q$key\E=\Q$default\E$/mg),
            1,
            "mb709-998: tracked action guide documents $key=$default once",
        );
        $assert->like($main, qr/\Q$key\E/,
            "mb709-998: runtime consumes $key");
    }
};
