# t/cases/960_mb703_spark_ai_boundary_no_delivery.t
# =============================================================================
# MB703-G — AI generation remains structurally separated from guarded IRC delivery.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

return sub {
    my ($assert) = @_;

    for my $rel (qw(
        Mediabot/Spark/Generator.pm
        Mediabot/Spark/DryRun.pm
        Mediabot/Spark/Orchestrator.pm
    )) {
        open my $fh, '<:encoding(UTF-8)', "$Bin/../../$rel"
            or die "open $rel: $!";
        local $/;
        my $src = <$fh>;
        $assert->unlike($src,
            qr/\b(?:botPrivmsg|botNotice|send_message|do_PRIVMSG|Net::Async::IRC)\b/,
            "mb703-960: $rel has no IRC delivery primitive");
        $assert->unlike($src, qr/SPARK_SEND_ARMED/,
            "mb703-960: $rel cannot consume the delivery arm switch");
    }

    my $main = do {
        open my $fh, '<:encoding(UTF-8)', "$Bin/../../mediabot.pl"
            or die "open mediabot.pl: $!";
        local $/;
        <$fh>;
    };

    my ($spark_tick) = $main =~ /(sub _spark_tick_all \{.*?\n\})\n\n# \+---/s;
    $assert->ok(defined $spark_tick,
        'mb703-960: Spark tick implementation is locatable for structural audit');
    $assert->unlike($spark_tick // '', qr/\b(?:botPrivmsg|botNotice|send_message|do_PRIVMSG)\b/,
        'mb703-960: Spark tick contains no IRC delivery call');
    $assert->unlike($spark_tick // '', qr/\b(?:botPrivmsg|botNotice|send_message|do_PRIVMSG)\b/,
        'mb703-960: timer itself owns no direct IRC transport call');
    $assert->like($main, qr/_spark_handle_candidate\(/,
        'mb703-960: provider completion crosses a private guarded delivery callback');
};
