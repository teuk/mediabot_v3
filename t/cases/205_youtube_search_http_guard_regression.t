# t/cases/205_youtube_search_http_guard_regression.t
# =============================================================================
# Both YouTube API calls remain protected and bounded, but they now live in the
# child worker rather than the live IRC callback.
# =============================================================================

use strict;
use warnings;
use File::Spec;

sub _slurp_205 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _sub_205 {
    my ($src, $name) = @_;
    my $re = qr/^[ \t]*sub[ \t]+\Q$name\E\b[^{]*\{/m;
    return undef unless $src =~ /$re/g;

    my $start = $-[0];
    my $pos   = pos($src);
    my $depth = 1;
    my ($quote, $escape, $comment);

    while ($pos < length($src)) {
        my $ch = substr($src, $pos, 1);
        if ($comment) { $comment = 0 if $ch eq "\n"; $pos++; next; }
        if (defined $quote) {
            if ($escape) { $escape = 0; $pos++; next; }
            if ($ch eq "\\") { $escape = 1; $pos++; next; }
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
    my $src = _slurp_205(File::Spec->catfile('.', 'Mediabot', 'External', 'YouTube.pm'));
    my $sync    = _sub_205($src, '_youtube_search_fetch_sync');
    my $command = _sub_205($src, 'youtubeSearch_ctx');

    $assert->ok(defined $sync, 'YouTube blocking worker found');
    $assert->ok(defined $command, 'youtubeSearch_ctx found');
    $assert->like($sync // '', qr/eval\s*\{\s*\$http_s->get\(\$search_url\)\s*\}/,
        'search endpoint is protected by eval');
    $assert->like($sync // '', qr/eval\s*\{\s*\$http_v->get\(\$videos_url\)\s*\}/,
        'metadata endpoint is protected by eval');
    $assert->like($sync // '', qr/reason\s*=>\s*\$\@/,
        'HTTP exception details are captured');
    $assert->like($sync // '', qr/max_size\s*=>\s*256 \* 1024/,
        'search response size is bounded');
    $assert->like($sync // '', qr/max_size\s*=>\s*512 \* 1024/,
        'metadata response size is bounded');
    $assert->like($sync // '', qr/status\s*=>\s*'metadata_unavailable'/,
        'metadata failure retains URL fallback behavior');
    $assert->unlike($command // '', qr/_make_http|\$http\w*->get\(/,
        'live IRC callback performs no HTTP request');
    $assert->like($command // '', qr/_youtube_search_fetch_sync\(\$api_key,\s*\$query_txt\)/,
        'MB322 live command delegates to the proven synchronous transport');
    $assert->unlike($command // '', qr/_youtube_search_fetch_async\(/,
        'MB322 quarantines the failing forked worker from the live command');
};
