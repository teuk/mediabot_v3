# t/cases/169_youtube_search_three_results_colored.t
# =============================================================================
# The YouTube search worker must request at most three IDs, preserve their
# search order, and the command must emit one visible line per formatted item.
# =============================================================================

use strict;
use warnings;
use File::Spec;

sub _slurp_169 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _sub_169 {
    my ($src, $name) = @_;
    my $re = qr/^sub\s+\Q$name\E\s*\{/m;
    return undef unless $src =~ /$re/g;
    my ($start, $pos, $depth) = ($-[0], pos($src), 1);
    while ($pos < length($src)) {
        my $ch = substr($src, $pos, 1);
        $depth++ if $ch eq '{';
        $depth-- if $ch eq '}';
        return substr($src, $start, $pos + 1 - $start) if $depth == 0;
        $pos++;
    }
    return undef;
}

return sub {
    my ($assert) = @_;
    my $src = _slurp_169(File::Spec->catfile('.', 'Mediabot', 'External', 'YouTube.pm'));
    my $parse   = _sub_169($src, '_youtube_search_parse_ids');
    my $sync    = _sub_169($src, '_youtube_search_fetch_sync');
    my $command = _sub_169($src, 'youtubeSearch_ctx');

    $assert->ok(defined $parse, 'search-ID parser found');
    $assert->ok(defined $sync, 'synchronous YouTube worker found');
    $assert->ok(defined $command, 'youtubeSearch_ctx found');
    $assert->like($sync // '', qr/&maxResults=3/,
        'search endpoint requests three results');
    $assert->like($parse // '', qr/last if \@ids >= 3/,
        'ID parser caps results at three');
    $assert->like($parse // '', qr/next if \$seen\{\$video_id\}\+\+/,
        'duplicate video IDs are ignored');
    $assert->like($sync // '', qr/my\s+\$ids_enc\s*=\s*join\(',',\s*\@\$video_ids\)/,
        'metadata endpoint receives ordered selected IDs');
    $assert->like($sync // '', qr/map \{ \$video_by_id->\{\$_\} \}.*\@\$video_ids/s,
        'metadata entries are restored in search order');
    $assert->like($command // '', qr/my\s+\$rank\s*=\s*\$i \+ 1/,
        'visible result rank is computed');
    $assert->like($command // '', qr/for my \$i \(0 \.\. \$#formatted\)/,
        'one IRC reply is emitted per formatted result');
    $assert->like($command // '', qr/\$ctx->reply\("\(\$nick\) \$msg"\)/,
        'output uses Context reply routing');
    $assert->like($command // '', qr/Mediabot::Helpers::logBot/s,
        'successful search usage is still logged');
    $assert->unlike($sync // '', qr/&maxResults=1/,
        'one-result search limit is not reintroduced');
};
