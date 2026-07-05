# t/cases/654_mb439_ytsearch_accent_query.t
# =============================================================================
# mb439 — La recherche YouTube encode la requête en byte-safe (accents).
#
# Suite de mb438. Les requêtes de recherche viennent d'IRC en OCTETS UTF-8 ;
# uri_escape_utf8() les double-encodait (café -> %C3%83%C2%A9) -> mauvaise
# requête à l'API YouTube. mb439 route _youtube_search_fetch_sync (worker
# bloquant) et ytSearch_ctx par le helper _uri_escape_bytes (mb438). Les URLs
# ASCII (oembed) et les IDs vidéo restent inchangés.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;
use Encode ();

sub _slurp_654 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

return sub {
    my ($assert) = @_;

    # --- 1. Sémantique -----------------------------------------------------
    my $esc = sub {
        my ($s) = @_;
        my $b = utf8::is_utf8($s) ? Encode::encode('UTF-8', $s) : $s;
        (my $e = $b) =~ s/([^A-Za-z0-9\-\._~])/sprintf("%%%02X",ord($1))/ge;
        return $e;
    };
    my $q = "caf" . chr(0xC3) . chr(0xA9) . " concert";   # "café concert"
    $assert->is($esc->($q), 'caf%C3%A9%20concert', 'café concert -> byte-safe');
    $assert->unlike($esc->($q), qr/%C3%83/, 'pas de double-encodage');

    # --- 2. Câblage réel ---------------------------------------------------
    my $src = _slurp_654(File::Spec->catfile('.', 'Mediabot', 'External', 'YouTube.pm'));

    my ($sync) = $src =~ /(sub _youtube_search_fetch_sync \{.*?\n\}\n)/s; $sync //= '';
    $assert->like($sync, qr/my \$q_enc = _uri_escape_bytes\(\$query_txt\)/,
        'worker: requête byte-safe');
    $assert->unlike($sync, qr/uri_escape_utf8\(\$query_txt\)/, 'plus de uri_escape_utf8 sur query_txt');

    my ($yt) = $src =~ /(sub ytSearch_ctx \{.*?\n\}\n)/s; $yt //= '';
    $assert->like($yt, qr/my \$encoded = _uri_escape_bytes\(\$query\)/,
        'ytSearch_ctx: requête byte-safe');
    $assert->unlike($yt, qr/uri_escape_utf8\(\$query\)/, 'plus de uri_escape_utf8 sur query');

    # Les IDs vidéo (ASCII) restent en uri_escape_utf8 — non concernés.
    $assert->like($yt, qr/uri_escape_utf8\(\$_\) \} \@vid_ids/,
        'IDs vidéo ASCII inchangés (hors périmètre)');

    $assert->like($src, qr/mb439-B1/, 'tag mb439-B1');
};
