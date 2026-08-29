use strict;
use warnings;
use utf8;

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
    my $mosaic = $read->('Mediabot/Spark/Mosaic.pm');

    $assert->like($main, qr/use Mediabot::Spark::Mosaic qw\(/,
        'mb710-1014: Mosaic runtime is an explicit Spark component');
    $assert->like(
        $main,
        qr/\$mosaic->begin\(.*?generation\s*=>\s*\$generation,.*?target\s*=>\s*\$candidate->\{target\}/s,
        'mb710-1014: collector is bound to generation and audience-sized target');
    $assert->like(
        $main,
        qr/if \(\$kind eq 'mosaic'\).*?\$mosaic->collect\(.*?nick\s*=>\s*\$nick.*?message\s*=>\s*\$line/s,
        'mb710-1014: active Mosaic sees explicit public responses');
    $assert->like(
        $main,
        qr/return 0 unless \(\$collected->\{action\}.*?'collect'.*?\$collected->\{ready\}.*?_spark_submit_mosaic_close/s,
        'mb710-1014: only accepted +words can trigger synthesis');
    $assert->like(
        $main,
        qr/mosaic_target_for_regime\(.*?audience_regime.*?mosaic_opening_generation/s,
        'mb710-1014: runtime turns measured audience into the visible target');
    $assert->like(
        $main,
        qr/kind\s*=>\s*'mosaic'.*?generation\s*=>\s*\$generation.*?continuation\s*=>\s*1/s,
        'mb710-1014: payoff keeps the event generation and one continuation');
    $assert->like(
        $main,
        qr/mosaic_closing.*?invalidate_channel\(\$channel\)/s,
        'mb710-1014: ordinary activity cannot revoke synthesis already closing');
    $assert->like(
        $main,
        qr/_spark_tick_mosaic_lifecycle.*?deadline_fallback/s,
        'mb710-1014: deadline fallback and timeout live in one bounded lifecycle');
    $assert->like(
        $main,
        qr/outcome\s*=>\s*'engaged'.*?spark_mosaic.*?forget_channel\(\$channel\)/s,
        'mb710-1014: delivered payoff closes State and destroys raw words');

    $assert->unlike($mosaic,
        qr/\b(?:DBI|CHANNEL_SET|CHANSET_LIST|botPrivmsg|Net::Async::IRC)\b/,
        'mb710-1014: collector owns neither persistence nor IRC transport');
    $assert->unlike($mosaic, qr/\b(?:logger|print|warn)\b/,
        'mb710-1014: collector cannot log raw word material');
    $assert->like(
        $mosaic,
        qr/return \[ \@\{ \$state->\{contributions\} \|\| \[\] \} \];/,
        'mb710-1014: provider receives a copy, never mutable collector storage');
};
