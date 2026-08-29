use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

return sub {
    my ($assert) = @_;

    my $read = sub {
        my ($path) = @_;
        open my $fh, '<:encoding(UTF-8)', "$Bin/../../$path"
            or die "open $path: $!";
        local $/;
        return <$fh>;
    };

    my $adaptive = $read->('Mediabot/Spark/AdaptivePolicy.pm');
    my $orchestrator = $read->('Mediabot/Spark/Orchestrator.pm');
    my $selector = $read->('Mediabot/Spark/Selector.pm');
    my $main = $read->('mediabot.pl');
    my $doc = $read->('docs/SPARK_ACTION.md');

    $assert->like($orchestrator,
        qr/use Mediabot::Spark::AdaptivePolicy qw\(/,
        'mb710-1010: both lanes consume the centralized audience policy');
    $assert->like($orchestrator,
        qr/base_revival_silence_seconds\s*=>\s*\$self->\{min_silence_seconds\}/,
        'mb710-1010: configured revival silence remains the operator baseline');
    $assert->like($orchestrator,
        qr/base_shared_cooldown_seconds\s*=>\s*\$self->\{action_cooldown_seconds\}/,
        'mb710-1010: configured action cooldown remains the budget baseline');
    $assert->like($orchestrator,
        qr/shared_cooldown_until.*?reason\s*=>\s*'shared_budget'/s,
        'mb710-1010: a single channel budget joins momentum and revival');
    $assert->like($main,
        qr/action_cooldown_seconds\(\$channel\)/,
        'mb710-1010: event State receives the same adaptive action cooldown');
    $assert->like($orchestrator,
        qr/select_spark_event\(.*?audience_regime\s*=>\s*\$adaptive->\{audience_regime\}/s,
        'mb710-1010: regime reaches event selection');
    $assert->like($selector,
        qr/\$audience_regime eq 'solo'.*?\$kind ne 'reaction'.*?\$kind ne 'callback'/s,
        'mb710-1010: solo selection is limited to contextual ambient families');
    $assert->unlike($adaptive . $orchestrator,
        qr/\b(?:botPrivmsg|botNotice|do_PRIVMSG|Net::Async::IRC)\b/,
        'mb710-1010: audience policy and orchestration own no IRC transport');
    $assert->like($doc, qr/Audience-proportional pacing/,
        'mb710-1010: operator guide explains proportional pacing');
    $assert->like($doc, qr/The budget is channel-wide/,
        'mb710-1010: operator guide explains cross-lane pacing');
    $assert->like($doc, qr/No new configuration key is required/,
        'mb710-1010: operator guide makes the migration-free contract explicit');
};
