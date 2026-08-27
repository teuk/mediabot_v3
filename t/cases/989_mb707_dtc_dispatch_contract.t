use strict;
use warnings;
use utf8;

sub slurp_989 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

return sub {
    my ($assert) = @_;
    my $cmd = slurp_989('Mediabot/DTC/Commands.pm');
    my $src = slurp_989('Mediabot/DTC/Source.pm');

    $assert->like($cmd, qr/chanset_enabled\(\$bot, \$channel, CHANSET_NAME, default => 0\)/,
        'mb707-989: +DansTonChat is fail-closed before worker start');
    $assert->like($cmd, qr/CommandAsync::run_ctx_async\(\s*\$bot, \$ctx, 'dtc'/s,
        'mb707-989: network command runs outside the IRC event loop');
    $assert->like($cmd, qr/if \(\$arg eq ''\).*?fetch_random\(\)/s,
        'mb707-989: no argument means random quote');
    $assert->like($cmd, qr/\(\[0-9\]\+\).*?fetch_by_id\(\$id\)/s,
        'mb707-989: numeric argument means direct quote lookup');
    $assert->like($cmd, qr/search_ids\(\$arg\).*?fetch_by_id\(\$id\)/s,
        'mb707-989: text argument searches IDs and displays first result');
    $assert->like($src, qr/Mediabot::RSS::Fetcher::fetch_feed_once/,
        'mb707-989: DTC reuses the bounded peer-pinned HTTP transport');
    $assert->unlike($src, qr/`|system\s*\(|qx\s*\//,
        'mb707-989: source never shells out for HTTP');
};
