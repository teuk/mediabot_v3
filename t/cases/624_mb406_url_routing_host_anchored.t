# t/cases/624_mb406_url_routing_host_anchored.t
# =============================================================================
# mb406 — Le routage des URLs matche le DÉBUT de l'URL (host), pas une
# sous-chaîne quelconque.
#
# Avant : Instagram/Spotify/Apple Music étaient routés par simple sous-chaîne
# (`$url =~ /instagram\.com/i`) et les motifs YouTube n'étaient pas ancrés :
#   - "https://example.org/?ref=instagram.com" partait sur le handler
#     Instagram (qui lance CHROMIUM) au lieu du titre générique ;
#   - "https://evil.example/?u=https://youtube.com/watch?v=XXXXXXXXXXX"
#     affichait les détails de la vidéo imbriquée au lieu du titre du site.
# mb406 : les 3 routes sont ancrées \Ahttps?://<host>(?:[/:?#]|\z) et
# les 5 motifs _is_youtube_url reçoivent \A. mb416 ferme le même défaut
# resté dans les deux routes Facebook et X/Twitter du dispatcher.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_624 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

return sub {
    my ($assert) = @_;

    # --- 1. Sémantique des routes ancrées (reproduction) -------------------
    my %route = (
        instagram => qr{\Ahttps?://(?:www\.)?instagram\.com(?:[/:?#]|\z)}i,
        spotify   => qr{\Ahttps?://open\.spotify\.com(?:[/:?#]|\z)}i,
        apple     => qr{\Ahttps?://music\.apple\.com(?:[/:?#]|\z)}i,
        facebook  => qr{\Ahttps?://(?:www\.)?facebook\.com(?:/|\z)}i,
        twitter   => qr{\Ahttps?://(?:www\.)?(?:x|twitter)\.com(?:/|\z)}i,
    );
    my @yes = (
        [ instagram => 'https://www.instagram.com/p/ABC123/' ],
        [ instagram => 'https://instagram.com/reel/XYZ/' ],
        [ spotify   => 'https://open.spotify.com/track/123' ],
        [ apple     => 'https://music.apple.com/fr/album/x/1' ],
        [ facebook  => 'https://www.facebook.com/example/posts/1' ],
        [ twitter   => 'https://x.com/example/status/1' ],
    );
    my @no = (
        [ instagram => 'https://example.org/?ref=instagram.com' ],
        [ instagram => 'https://notinstagram.com/p/x' ],
        [ spotify   => 'https://example.org/open.spotify.com/x' ],
        [ apple     => 'https://example.org/?u=music.apple.com' ],
        [ facebook  => 'https://example.org/?u=https://facebook.com/example' ],
        [ twitter   => 'https://example.org/?u=https://x.com/example/status/1' ],
    );
    for my $c (@yes) { $assert->ok($c->[1] =~ $route{$c->[0]}, "route $c->[0]: $c->[1]"); }
    for my $c (@no)  { $assert->ok($c->[1] !~ $route{$c->[0]}, "PAS route $c->[0]: $c->[1]"); }

    # --- 2. Scan source : dispatcher + YouTube ancrés ----------------------
    my $url_src = _slurp_624(File::Spec->catfile('.', 'Mediabot', 'External', 'URL.pm'));
    (my $url_code = $url_src) =~ s/^\s*#.*$//mg;
    $assert->unlike($url_code, qr{=~ /instagram\\\.com/i},     'plus de route Instagram en sous-chaîne');
    $assert->unlike($url_code, qr{=~ /open\\\.spotify\\\.com/i}, 'plus de route Spotify en sous-chaîne');
    $assert->unlike($url_code, qr{=~ /music\\\.apple\\\.com/i},  'plus de route Apple Music en sous-chaîne');
    $assert->like($url_code,
        qr/if \(\$url =~ m\{\\Ahttps\?\:\/\/(?:\(\?:www\\\.\)\?)?facebook\\\.com/,
        'route Facebook du dispatcher ancrée en début d URL (mb416)');
    $assert->like($url_code,
        qr/if \(\$url =~ m\{\\Ahttps\?\:\/\/(?:\(\?:www\\\.\)\?)?\(\?:x\|twitter\)\\\.com/,
        'route X/Twitter du dispatcher ancrée en début d URL (mb416)');
    $assert->like($url_src, qr/mb416-B1/, 'tag mb416-B1 (URL.pm)');
    $assert->like($url_src, qr/mb406-B1/, 'tag mb406-B1 (URL.pm)');

    my $yt_src = _slurp_624(File::Spec->catfile('.', 'Mediabot', 'External', 'YouTube.pm'));
    my ($is_yt) = $yt_src =~ /(sub _is_youtube_url \{.*?\n\}\n)/s; $is_yt //= '';
    my $anchored   = () = $is_yt =~ /m\{\\Ahttps\?:\/\//g;
    my $unanchored = () = $is_yt =~ /m\{https\?:\/\//g;
    $assert->ok($anchored >= 5,   'les motifs YouTube sont ancrés (\A)');
    $assert->is($unanchored, 0,   'aucun motif YouTube non ancré restant');
    $assert->like($yt_src, qr/mb406-B1/, 'tag mb406-B1 (YouTube.pm)');
};
