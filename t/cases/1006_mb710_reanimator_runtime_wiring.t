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

    my $main = $read->('mediabot.pl');
    my $sample = $read->('mediabot.sample.conf');
    my $doc = $read->('docs/SPARK_ACTION.md');

    $assert->like($main, qr/use Mediabot::Spark::Identity \(\);/,
        'mb710-1006: production imports the generic bot identity boundary');
    $assert->like($main, qr/configured_bot_nicks\s*=>\s*\n?\s*\$mediabot->\{conf\}->get\('main\.BOT_NICKS'\)/s,
        'mb710-1006: runtime uses the existing generic configured bot list');
    $assert->ok(scalar(() = $main =~ /from_bot\s*=>\s*\$from_conversation_bot/g) >= 1,
        'mb710-1006: the shared bot decision reaches conversational lanes');
    $assert->like($main, qr/_spark_observe_public_line\(.*?\$from_conversation_bot/s,
        'mb710-1006: Spark receives the shared bot decision');
    $assert->like($main, qr/initial_trigger_enabled\s*=>.*?MAIN_PROG_INITIAL_TRIGGER/s,
        'mb710-1006: Spark receives the enabled initial command trigger');
    $assert->like($sample, qr/conversational audience.*BOT_NICKS/is,
        'mb710-1006: sample configuration explains generic audience filtering');
    $assert->like($doc, qr/recency-weighted effective audience/i,
        'mb710-1006: operator documentation describes the adaptive metric');
};
