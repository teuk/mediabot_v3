# t/cases/702_mb492_url_rich_badges.t
# =============================================================================
# mb492 — Une URL collée dans le chat => badge + DÉTAILS riches.
#
#   Apple Music : og:title brut -> ligne façon Spotify
#                 "Title - by Artist - album - 1969 - 3:33 - 17 tracks"
#                 (JSON-LD + og:description "Album · 1969 · 17 Songs")
#   X           : titre + TEXTE DU TWEET : jack on X: "just setting up my twttr"
#   Facebook    : titre + og:description courte.
#
# Handlers RÉELS exécutés sur fixtures HTML (HTTP et chromium mockés
# localement), botPrivmsg intercepté -> on vérifie la ligne IRC exacte.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

use Mediabot::External;
use Mediabot::External::URL;

{
    package L702; sub new { bless {}, shift } sub log { }
    package C702; sub new { bless {}, shift } sub get { undef }
    package H702; sub new { my ($c,$html)=@_; bless { html=>$html }, $c }
    sub get { return { success => 1, status => 200, content => $_[0]->{html} } }
}

sub _strip_irc { my ($s)=@_; $s =~ s/\x03\d{0,2}(?:,\d{1,2})?|\x0f|\x02//g; return $s; }
sub _mkself { return { logger => L702->new, conf => C702->new }; }

my @SENT;

return sub {
    my ($assert) = @_;

    no warnings 'redefine';
    no warnings 'once';
    local *Mediabot::Helpers::botPrivmsg = sub { push @SENT, $_[2]; 1 };

    # =========================================================================
    # 1. Apple Music : ligne riche complète (JSON-LD album)
    # =========================================================================
    {
        my $html = q{<html><head>
<meta property="og:title" content="Abbey Road (2019 Mix)"/>
<meta property="og:description" content="Album &#183; 1969 &#183; 17 Songs"/>
<script type="application/ld+json">{"@type":"MusicAlbum","name":"Abbey Road (2019 Mix)","byArtist":{"name":"The Beatles"},"datePublished":"1969-09-26","numTracks":17}</script>
</head></html>};
        local *Mediabot::External::_make_http = sub { H702->new($html) };
        local *Mediabot::External::URL::_fetch_url_chromium_dumpdom = sub { undef };
        @SENT = ();
        Mediabot::External::URL::_handle_applemusic(_mkself(), 'u', 'nick', '#c',
            'https://music.apple.com/us/album/abbey-road-2019-mix/1474815798');
        my $line = _strip_irc($SENT[0] // '');
        $assert->like($line, qr/\[AppleMusic\]/, 'AM: badge présent');
        $assert->like($line, qr/Abbey Road \(2019 Mix\)/, 'AM: titre');
        $assert->like($line, qr/by The Beatles/, 'AM: artiste (JSON-LD)');
        $assert->like($line, qr/album/, 'AM: type');
        $assert->like($line, qr/1969/, 'AM: année');
        $assert->like($line, qr/17 tracks/, 'AM: nombre de pistes');
    }

    # =========================================================================
    # 2. Apple Music : morceau avec durée ISO + artiste déjà dans le titre
    # =========================================================================
    {
        my $html = q{<html><head>
<meta property="og:title" content="Never Gonna Give You Up by Rick Astley"/>
<script type="application/ld+json">{"@type":"MusicRecording","name":"Never Gonna Give You Up","byArtist":{"name":"Rick Astley"},"duration":"PT3M33S","datePublished":"1987-07-27"}</script>
</head></html>};
        local *Mediabot::External::_make_http = sub { H702->new($html) };
        local *Mediabot::External::URL::_fetch_url_chromium_dumpdom = sub { undef };
        @SENT = ();
        Mediabot::External::URL::_handle_applemusic(_mkself(), 'u', 'nick', '#c',
            'https://music.apple.com/fr/album/x?i=1');
        my $line = _strip_irc($SENT[0] // '');
        $assert->like($line, qr/3:33/, 'AM: durée ISO convertie (PT3M33S -> 3:33)');
        $assert->like($line, qr/1987/, 'AM: année du morceau');
        my $artist_count = () = $line =~ /Rick Astley/g;
        $assert->is($artist_count, 1, 'AM: pas de doublon artiste (déjà dans le titre)');
        $assert->unlike($line, qr/\bsong\b/, 'AM: le type "song" implicite n\'est pas affiché');
    }

    # =========================================================================
    # 3. Apple Music : aucune métadonnée riche -> titre seul (comportement inchangé)
    # =========================================================================
    {
        my $html = q{<html><head><meta property="og:title" content="Some Mix"/></head></html>};
        local *Mediabot::External::_make_http = sub { H702->new($html) };
        local *Mediabot::External::URL::_fetch_url_chromium_dumpdom = sub { undef };
        @SENT = ();
        Mediabot::External::URL::_handle_applemusic(_mkself(), 'u', 'nick', '#c',
            'https://music.apple.com/us/playlist/p');
        my $line = _strip_irc($SENT[0] // '');
        $assert->like($line, qr/\[AppleMusic\] Some Mix\s*$/, 'AM: fallback titre seul intact');
    }

    # =========================================================================
    # 4. X : titre + texte du tweet
    # =========================================================================
    {
        my $self = _mkself();
        $self->{_x_twitter_cache} = {};
        local *Mediabot::External::URL::_fetch_url_chromium_dumpdom = sub {
            q{<meta property="og:title" content="jack on X"/>}
          . q{<meta property="og:description" content="just setting up my twttr"/>};
        };
        @SENT = ();
        Mediabot::External::URL::_handle_x_twitter($self, 'u', 'nick', '#c',
            'https://x.com/jack/status/20');
        my $line = _strip_irc($SENT[0] // '');
        $assert->like($line, qr/\[X\]/, 'X: badge présent');
        $assert->like($line, qr/jack on X: "just setting up my twttr"/, 'X: texte du tweet ajouté');
    }

    # =========================================================================
    # 5. X : pas de doublon quand le titre contient déjà le texte
    # =========================================================================
    {
        my $self = _mkself();
        $self->{_x_twitter_cache} = {};
        local *Mediabot::External::URL::_fetch_url_chromium_dumpdom = sub {
            q{<meta property="og:title" content="jack on X: just setting up my twttr"/>}
          . q{<meta property="og:description" content="just setting up my twttr"/>};
        };
        @SENT = ();
        Mediabot::External::URL::_handle_x_twitter($self, 'u', 'nick', '#c',
            'https://x.com/jack/status/21');
        my $line = _strip_irc($SENT[0] // '');
        my $count = () = $line =~ /just setting up my twttr/g;
        $assert->is($count, 1, 'X: anti-doublon (texte une seule fois)');
    }

    # =========================================================================
    # 6. X : description "login shell" ignorée
    # =========================================================================
    {
        my $self = _mkself();
        $self->{_x_twitter_cache} = {};
        local *Mediabot::External::URL::_fetch_url_chromium_dumpdom = sub {
            q{<meta property="og:title" content="Snowden (@Snowden) on X"/>}
          . q{<meta property="og:description" content="Log in to X to see posts"/>};
        };
        @SENT = ();
        Mediabot::External::URL::_handle_x_twitter($self, 'u', 'nick', '#c',
            'https://x.com/Snowden');
        my $line = _strip_irc($SENT[0] // '');
        $assert->unlike($line, qr/Log in/i, 'X: desc de login ignorée');
        $assert->like($line, qr/Snowden/, 'X: titre conservé');
    }

    # =========================================================================
    # 7. Facebook : titre + description
    # =========================================================================
    {
        my $html = q{<html><head><title>Le Gorafi</title>}
                 . q{<meta property="og:title" content="Le Gorafi"/>}
                 . q{<meta property="og:description" content="Toute l'actualite selon des sources contradictoires"/></head></html>};
        local *Mediabot::External::_make_http = sub { H702->new($html) };
        local *Mediabot::External::URL::_fetch_url_chromium_dumpdom = sub { undef };
        @SENT = ();
        my $self = _mkself();
        $self->{_facebook_cache} = {};
        Mediabot::External::URL::_handle_facebook($self, 'u', 'nick', '#c',
            'https://www.facebook.com/legorafi');
        my $line = _strip_irc($SENT[0] // '');
        $assert->like($line, qr/\[Facebook\]/, 'FB: badge présent');
        $assert->like($line, qr/Le Gorafi - Toute l'actualite/, 'FB: description ajoutée');
    }

    # =========================================================================
    # 8. Helpers unitaires
    # =========================================================================
    {
        $assert->is(Mediabot::External::URL::_am_duration_from_iso('PT3M33S'), '3:33',
            'iso PT3M33S -> 3:33');
        $assert->is(Mediabot::External::URL::_am_duration_from_iso('PT1H2M3S'), '1:02:03',
            'iso PT1H2M3S -> 1:02:03');
        $assert->ok(!defined Mediabot::External::URL::_am_duration_from_iso('garbage'),
            'iso invalide -> undef');
    }
};
