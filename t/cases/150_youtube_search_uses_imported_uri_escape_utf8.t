# t/cases/150_youtube_search_uses_imported_uri_escape_utf8.t
# =============================================================================
# Regression checks for the synchronous worker used by youtubeSearch_ctx().
# The blocking worker must keep using URI::Escape::uri_escape_utf8 and must not
# reintroduce the removed URL::Encode dependency.
# =============================================================================

use strict;
use warnings;
use File::Spec;

sub _slurp_150 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _sub_150 {
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
    my $src = _slurp_150(File::Spec->catfile('.', 'Mediabot', 'External', 'YouTube.pm'));
    my $sync = _sub_150($src, '_youtube_search_fetch_sync');

    $assert->ok(defined $sync, '_youtube_search_fetch_sync found');
    $assert->like($src, qr/^use URI::Escape qw\(uri_escape_utf8\);$/m,
        'YouTube module imports uri_escape_utf8');
    $assert->like($sync // '', qr/my\s+\$q_enc\s*=\s*uri_escape_utf8\(\$query_txt\)/,
        'blocking worker encodes the query with uri_escape_utf8');
    $assert->like($sync // '', qr/"&q=\$q_enc"/,
        'encoded query is used in the search URL');
    $assert->unlike($src, qr/url_encode_utf8\(/,
        'undefined url_encode_utf8 is absent');
    $assert->unlike($src, qr/use URL::Encode/,
        'URL::Encode dependency is absent');
};
