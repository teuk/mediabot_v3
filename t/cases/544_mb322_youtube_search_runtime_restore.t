# t/cases/544_mb322_youtube_search_runtime_restore.t
# =============================================================================
# MB322: production hotfix after the MB320/MB321 forked worker timed out on
# teuk.org. The live command must use the proven synchronous transport while
# retaining MB320 parsers, size caps, formatting and Context reply routing.
# =============================================================================

use strict;
use warnings;
use File::Spec;

sub _slurp_mb322 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_mb322 {
    my ($src, $name) = @_;
    my $re = qr/^sub\s+\Q$name\E\s*\{/m;
    return undef unless $src =~ /$re/g;
    my ($start, $pos, $depth) = ($-[0], pos($src), 1);
    my ($quote, $escape, $comment);
    while ($pos < length($src)) {
        my $ch = substr($src, $pos, 1);
        if ($comment) { $comment = 0 if $ch eq "\n"; $pos++; next; }
        if (defined $quote) {
            if ($escape) { $escape = 0; $pos++; next; }
            if ($ch eq '\\') { $escape = 1; $pos++; next; }
            if ($ch eq $quote) { undef $quote; $pos++; next; }
            $pos++; next;
        }
        if ($ch eq '#') { $comment = 1; $pos++; next; }
        if ($ch eq "'" || $ch eq '"') { $quote = $ch; $pos++; next; }
        $depth++ if $ch eq '{';
        $depth-- if $ch eq '}';
        return substr($src, $start, $pos + 1 - $start) if $depth == 0;
        $pos++;
    }
    return undef;
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_mb322(
        File::Spec->catfile('.', 'Mediabot', 'External', 'YouTube.pm')
    );
    my $command = _extract_mb322($src, 'youtubeSearch_ctx');
    my $sync    = _extract_mb322($src, '_youtube_search_fetch_sync');
    my $format  = _extract_mb322($src, '_youtube_search_format_entry');

    $assert->ok(defined $command, 'YouTube command callback found');
    $assert->ok(defined $sync, 'hardened synchronous transport found');
    $assert->ok(defined $format, 'shared YouTube formatter found');

    $assert->like(
        $command // '',
        qr/MB32[23]: (?:emergency runtime restoration|restore the proven synchronous transport)/,
        'runtime restoration rationale is documented'
    );
    $assert->like(
        $command // '',
        qr/_youtube_search_fetch_sync\(\$api_key,\s*\$query_txt\)/,
        'live command uses the proven transport path'
    );
    $assert->unlike(
        $command // '',
        qr/_youtube_search_fetch_async\(/,
        'broken forked worker is not used by the live command'
    );
    $assert->like(
        $command // '',
        qr/_youtube_search_format_entry\(\$info\)/,
        'MB320 shared formatter is preserved'
    );
    $assert->like(
        $command // '',
        qr/\$ctx->reply\(/,
        'public and private output stays on Context routing'
    );
    $assert->like(
        $sync // '',
        qr/max_size\s*=>\s*256\s*\*\s*1024/,
        'search response size cap is preserved'
    );
    $assert->like(
        $sync // '',
        qr/max_size\s*=>\s*512\s*\*\s*1024/,
        'metadata response size cap is preserved'
    );
    $assert->like(
        $command // '',
        qr/search_exception/,
        'unexpected transport exceptions retain a diagnostic status'
    );
    $assert->like(
        $command // '',
        qr/youtubeSearch_ctx\(\): \$status: \$detail/,
        'runtime errors remain diagnostic in logs'
    );
    $assert->like(
        $src,
        qr/Mediabot::Helpers::logBot\(\s*\$self,\s*\$log_message,\s*\$log_channel,\s*'yt'/s,
        'successful searches keep historical command logging'
    );
};
