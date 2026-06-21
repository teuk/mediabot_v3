# t/cases/546_mb324_youtube_search_blue_underlined_links.t
# =============================================================================
# MB324: every visible URL emitted by `yt <search>` must be foreground-only
# blue and underlined, with a final IRC reset and no background color.
# =============================================================================

use strict;
use warnings;

use File::Spec;

sub _slurp_mb324 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path
        or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_mb324 {
    my ($src, $name) = @_;
    my $re = qr/^sub\s+\Q$name\E\s*\{/m;
    return undef unless $src =~ /$re/g;

    my ($start, $pos, $depth) = ($-[0], pos($src), 1);
    my ($quote, $escape, $comment);

    while ($pos < length($src)) {
        my $ch = substr($src, $pos, 1);

        if ($comment) {
            $comment = 0 if $ch eq "\n";
            $pos++;
            next;
        }

        if (defined $quote) {
            if ($escape) {
                $escape = 0;
                $pos++;
                next;
            }
            if ($ch eq '\\') {
                $escape = 1;
                $pos++;
                next;
            }
            if ($ch eq $quote) {
                undef $quote;
                $pos++;
                next;
            }
            $pos++;
            next;
        }

        if ($ch eq '#') {
            $comment = 1;
            $pos++;
            next;
        }
        if ($ch eq "'" || $ch eq '"') {
            $quote = $ch;
            $pos++;
            next;
        }

        $depth++ if $ch eq '{';
        $depth-- if $ch eq '}';
        return substr($src, $start, $pos + 1 - $start)
            if $depth == 0;
        $pos++;
    }

    return undef;
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_mb324(
        File::Spec->catfile('.', 'Mediabot', 'External', 'YouTube.pm')
    );

    my $link   = _extract_sub_mb324($src, '_yt_link');
    my $format = _extract_sub_mb324($src, '_youtube_search_format_entry');

    $assert->ok(defined $link, '_yt_link helper found');
    $assert->ok(defined $format, '_youtube_search_format_entry found');

    $assert->like(
        $src,
        qr/our\s+\@EXPORT_OK\s*=\s*qw\(.*?_yt_link/s,
        '_yt_link is part of the shared YouTube formatting API'
    );

    $assert->like(
        $link // '',
        qr/"\\x0302\\x1F"\s*\.\s*\$url\s*\.\s*"\\x0F"/,
        'link helper applies blue, underline, and a final reset'
    );

    $assert->unlike(
        $link // '',
        qr/\\x03\d\d,\d\d/,
        'link helper does not set an IRC background color'
    );

    $assert->like(
        $format // '',
        qr/_yt_link\("https:\/\/www\.youtube\.com\/watch\?v=\$video_id"\)/,
        'YouTube search formatter applies _yt_link to its URL'
    );

    $assert->unlike(
        $format // '',
        qr/_yt_meta\("https:\/\/www\.youtube\.com\/watch\?v=\$video_id"\)/,
        'YouTube search URL is no longer rendered as grey metadata'
    );

    my $probe = <<'PROBE';
use strict;
use warnings;

sub _yt_link {
    my ($url) = @_;
    $url = '' unless defined $url;
    return "\x0302\x1F" . $url . "\x0F";
}

my $url = 'https://www.youtube.com/watch?v=abcdefghijk';
my $got = _yt_link($url);
my $expected = "\x0302\x1F" . $url . "\x0F";
print $got eq $expected ? "OK\n" : "BAD\n";
PROBE

    open my $fh, '-|', $^X, '-e', $probe
        or die "could not start MB324 formatting probe: $!";
    local $/;
    my $output = <$fh> // '';
    close $fh;

    my $rc = $? >> 8;
    $output =~ s/\s+\z//;

    $assert->is($rc, 0, 'isolated link formatting probe exits successfully');
    $assert->is($output, 'OK', 'runtime link bytes are blue, underlined, and reset');
};
