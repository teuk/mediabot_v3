# t/cases/993_mb708_portal_runtime_wiring.t
use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

return sub {
    my ($assert) = @_;

    my $main = do {
        open my $fh, '<:encoding(UTF-8)', "$Bin/../../mediabot.pl"
            or die "open mediabot.pl: $!";
        local $/;
        <$fh>;
    };
    my $portal = do {
        open my $fh, '<:encoding(UTF-8)', "$Bin/../../Mediabot/Spark/Portal.pm"
            or die "open Portal.pm: $!";
        local $/;
        <$fh>;
    };

    $assert->like($main, qr/use Mediabot::Spark::Portal \(\);/,
        'mb708-993: Portal runtime is an explicit Spark component');
    $assert->like(
        $main,
        qr/\$portal->begin\(\s*channel\s*=>\s*\$channel,\s*generation\s*=>\s*\$generation/s,
        'mb708-993: collector is bound to the visible event generation');
    $assert->like(
        $main,
        qr/if \(\$kind eq 'portal'\).*?\$portal->collect\(.*?nick\s*=>\s*\$nick.*?message\s*=>\s*\$line/s,
        'mb708-993: active Portal observes bounded human contributions');
    $assert->like(
        $main,
        qr/\$collected->\{ready\}.*?_spark_submit_portal_close\(.*?'target_reached'/s,
        'mb708-993: third distinct contribution starts immediate synthesis');
    $assert->like(
        $main,
        qr/event_remaining_seconds.*?minimum.*?mark_closing.*?'deadline_fallback'/s,
        'mb708-993: deadline closes exactly two contributions before miss handling');
    $assert->like(
        $main,
        qr/contributions\s*=>\s*\$contributions/s,
        'mb708-993: private contribution copy crosses only the AI request boundary');
    $assert->like(
        $main,
        qr/kind\s*=>\s*'portal'.*?generation\s*=>\s*\$generation.*?continuation\s*=>\s*1/s,
        'mb708-993: payoff uses the same generation and one explicit continuation');
    $assert->like(
        $main,
        qr/outcome\s*=>\s*'engaged'.*?forget_channel\(\$channel\)/s,
        'mb708-993: delivered payoff finishes state and destroys contribution text');
    $assert->like(
        $main,
        qr/outcome\s*=>\s*'error'/s,
        'mb708-993: provider or continuation failure uses technical-error cooldown');
    $assert->like(
        $main,
        qr/portal_closing.*?invalidate_channel\(\$channel\)/s,
        'mb708-993: ordinary activity cannot revoke a Portal synthesis already closing');

    $assert->unlike($portal, qr/\b(?:DBI|CHANNEL_SET|CHANSET_LIST|botPrivmsg|Net::Async::IRC)\b/,
        'mb708-993: Portal collector owns neither persistence nor IRC delivery');
    $assert->unlike($portal, qr/\b(?:logger|print|warn)\b/,
        'mb708-993: raw Portal content cannot escape through collector logging');
    $assert->like($portal, qr/return \[ \@\{ \$state->\{contributions\} \|\| \[\] \} \];/,
        'mb708-993: AI receives a copy, never the mutable internal contribution array');
};
