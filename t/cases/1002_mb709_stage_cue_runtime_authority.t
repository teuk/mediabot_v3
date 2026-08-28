use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

return sub {
    my ($assert) = @_;
    my $read = sub {
        my ($rel) = @_;
        open my $fh, '<:encoding(UTF-8)', "$Bin/../../$rel" or die "open $rel: $!";
        local $/;
        return <$fh>;
    };
    my $main = $read->('mediabot.pl');
    my $sender = $read->('Mediabot/Spark/Sender.pm');
    my $generator = $read->('Mediabot/Spark/Generator.pm');
    my $orch = $read->('Mediabot/Spark/Orchestrator.pm');
    my $conf = $read->('mediabot.sample.conf');

    $assert->like($main, qr/get_int\(\s*'main\.SPARK_ACTION_SEND_ARMED'/s,
        'mb709-1002: runtime consumes the separate default-off action arm');
    $assert->like(
        $main,
        qr/\$inflight_kind ne 'stage_cue'.*?\$action_enabled.*?_spark_action_arm_enabled/s,
        'mb709-1002: late in-flight gate rechecks action opt-in and process arm');
    $assert->like(
        $main,
        qr/\$kind eq 'stage_cue' && !\$pre->\{action_enabled\}.*?\$kind eq 'stage_cue' && !\$pre->\{action_armed\}/s,
        'mb709-1002: pre-delivery boundary rechecks both action authorities');
    $assert->like($main, qr/next if \$action_started/,
        'mb709-1002: one channel cannot start two Spark generations in one tick');
    $assert->like($main, qr/mark_action_delivered\(\$channel\)/,
        'mb709-1002: successful action installs dedicated pacing');

    $assert->like($sender, qr/"\\x01ACTION \\x\{2728\} \$line\\x01"/,
        'mb709-1002: only guarded sender code constructs the CTCP ACTION frame');
    $assert->unlike($generator . $orch, qr/\\x01ACTION|botPrivmsg|botNotice/,
        'mb709-1002: generator and orchestration own no IRC transport primitive');
    $assert->is(scalar(() = $conf =~ /^SPARK_ACTION_SEND_ARMED=0$/mg), 1,
        'mb709-1002: sample action arm is present exactly once and defaults off');
    $assert->is(scalar(() = $conf =~ /^SPARK_ACTION_COOLDOWN_SECONDS=1200$/mg), 1,
        'mb709-1002: sample action pacing is explicit and bounded');
};
