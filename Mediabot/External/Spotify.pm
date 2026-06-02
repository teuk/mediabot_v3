package Mediabot::External::Spotify;
# =============================================================================
# Mediabot::External::Spotify — gestion des URLs open.spotify.com
# =============================================================================
# mb94-R1: extrait de Mediabot::External pour le découpage en sous-modules.
# External.pm reste la façade (@EXPORT inchangé) — il charge ce module et
# réexporte _handle_spotify via l'import implicite dans le même package.
#
# Dépendances internes (helpers restant dans External.pm) :
#   _decode_html, _make_http, _decode_http_content_utf8,
#   _fetch_url_chromium_dumpdom, botPrivmsg
# Ces fonctions sont appelées sans qualification de package car ce fichier
# est chargé depuis External.pm avec 'require' et injecté dans son namespace.
# =============================================================================

use strict;
use warnings;
use Exporter 'import';
use JSON::MaybeXS;
use URI::Escape qw(uri_escape_utf8);
use String::IRC;

our $VERSION = '1.00';

our @EXPORT_OK = qw(
    _spotify_is_bad
    _spotify_clean
    _spotify_duration_from_ms
    _spotify_duration_from_iso
    _spotify_extract_meta
    _spotify_extract_jsonish
    _handle_spotify
);

# ---------------------------------------------------------------------------
# _spotify_is_bad($v)
# Retourne 1 si la valeur est inutilisable (vide, générique Spotify).
# ---------------------------------------------------------------------------
sub _spotify_is_bad {
    my ($v) = @_;
    return 1 unless defined $v;
    $v = Mediabot::External::_decode_html($v);
    $v =~ s/[\r\n\t]/ /g; $v =~ s/\s+/ /g; $v =~ s/^\s+|\s+$//g;
    return 1 if $v eq '';
    return 1 if $v =~ /^Spotify$/i;
    return 1 if $v =~ /^Spotify\s*[–-]\s*Web Player$/i;
    return 1 if $v =~ /^Spotify Web Player$/i;
    return 1 if $v =~ /listening is everything/i;
    return 0;
}

# ---------------------------------------------------------------------------
# _spotify_clean($v)
# Nettoie une valeur Spotify (HTML entities, backslash-escapes, suffixes).
# ---------------------------------------------------------------------------
sub _spotify_clean {
    my ($v) = @_;
    return undef unless defined $v;
    $v = Mediabot::External::_decode_html($v);
    $v =~ s/\\u0026/&/g; $v =~ s/\\\//\//g; $v =~ s/\\"/"/g;
    $v =~ s/[\r\n\t]/ /g; $v =~ s/\s{2,}/ /g; $v =~ s/^\s+|\s+$//g;
    $v =~ s/\s*\|\s*Spotify\s*$//i;
    $v =~ s/\s*[–-]\s*Spotify\s*$//i;
    $v =~ s/\s*[–-]\s*song and lyrics by\s*/ - /i;
    return undef if _spotify_is_bad($v);
    return $v;
}

# ---------------------------------------------------------------------------
# _spotify_duration_from_ms($ms)  → "Xm Ys"
# ---------------------------------------------------------------------------
sub _spotify_duration_from_ms {
    my ($ms) = @_;
    return undef unless defined $ms && $ms =~ /^\d+$/;
    my $total = int($ms / 1000); return undef if $total <= 0;
    my $h = int($total / 3600); my $m = int(($total % 3600) / 60); my $s = $total % 60;
    return sprintf("%dh%02dm%02ds", $h, $m, $s) if $h;
    return sprintf("%dm %02ds", $m, $s);
}

# ---------------------------------------------------------------------------
# _spotify_duration_from_iso($d)  → "Xm Ys"  (ISO 8601 PT…)
# ---------------------------------------------------------------------------
sub _spotify_duration_from_iso {
    my ($d) = @_;
    return undef unless defined $d;
    if ($d =~ /^PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?$/i) {
        my ($h, $m, $s) = ($1 // 0, $2 // 0, $3 // 0);
        return undef if !$h && !$m && !$s;
        return sprintf("%dh%02dm%02ds", $h, $m, $s) if $h;
        return sprintf("%dm %02ds", $m, $s);
    }
    return undef;
}

# ---------------------------------------------------------------------------
# _spotify_extract_meta($self, \%info, $html, $context)
# Parse les balises <meta> og:title / twitter:title / description.
# ---------------------------------------------------------------------------
sub _spotify_extract_meta {
    my ($self, $info, $html, $context) = @_;
    return unless defined $html && $html ne '';
    my ($og_title, $twitter_title, $title_tag, $description);
    while ($html =~ /<meta\b([^>]*?)>/sig) {
        my $attrs = $1;
        if ($attrs =~ /(?:property|name)=["']og:title["']/i && $attrs =~ /\bcontent=["']([^"']+)["']/i) {
            $og_title = $1;
        } elsif ($attrs =~ /(?:property|name)=["']twitter:title["']/i && $attrs =~ /\bcontent=["']([^"']+)["']/i) {
            $twitter_title = $1;
        } elsif ($attrs =~ /(?:property|name)=["'](?:og:description|description|twitter:description)["']/i
            && $attrs =~ /\bcontent=["']([^"']+)["']/i) {
            $description = $1;
        }
    }
    if ($html =~ /<title[^>]*>(.*?)<\/title>/si) { $title_tag = $1; }
    for my $candidate ($og_title, $twitter_title, $title_tag) {
        my $v = _spotify_clean($candidate); next unless defined $v && $v ne '';
        if (!defined $info->{title} && $v =~ /^(.+?)\s+-\s+(.+)$/) {
            $info->{title}  //= _spotify_clean($1);
            $info->{artist} //= _spotify_clean($2) unless ($2 // '') =~ /Spotify/i;
        } else { $info->{title} //= $v; }
        last if defined $info->{title};
    }
    my $desc = _spotify_clean($description);
    if (defined $desc && $desc ne '') {
        if ($desc =~ /\b(?:Song|Single|Album|EP|Playlist|Episode|Show)\s*[·-]\s*([^·|.-]+)\s*[·-]\s*(\d{4})/i) {
            $info->{artist} //= _spotify_clean($1); $info->{year} //= $2;
        } elsif ($desc =~ /\b(?:Song|Single|Album|EP)\s*[·-]\s*([^·|.-]+)/i) {
            $info->{artist} //= _spotify_clean($1);
        }
        if ($desc =~ /\bfrom\s+(?:the\s+)?(?:album|single)\s+([^.,|]+)(?:[.,|]|$)/i) {
            $info->{album} //= _spotify_clean($1);
        }
    }
    $self->{logger}->log(4, "_handle_spotify() parsed meta from $context");
}

# ---------------------------------------------------------------------------
# _spotify_extract_jsonish($self, \%info, $text, $context)
# Parse JSON-LD et regex conservateurs depuis le HTML Spotify.
# ---------------------------------------------------------------------------
sub _spotify_extract_jsonish {
    my ($self, $info, $text, $context) = @_;
    return unless defined $text && $text ne '';
    while ($text =~ m{<script[^>]+type=["']application/ld\+json["'][^>]*>(.*?)</script>}sig) {
        my $json = Mediabot::External::_decode_html($1);
        my $data = eval { decode_json($json) }; next unless defined $data;
        my @items = ref($data) eq 'ARRAY' ? @$data : ($data);
        for my $item (@items) {
            next unless ref($item) eq 'HASH';
            $info->{title} //= _spotify_clean($item->{name});
            if (ref($item->{byArtist}) eq 'HASH') {
                $info->{artist} //= _spotify_clean($item->{byArtist}{name});
            } elsif (ref($item->{byArtist}) eq 'ARRAY') {
                my @a = grep { defined && $_ ne '' }
                        map { ref $_ eq 'HASH' ? _spotify_clean($_->{name}) : _spotify_clean($_) }
                        @{ $item->{byArtist} };
                $info->{artist} //= join(', ', @a) if @a;
            }
            if (ref($item->{inAlbum}) eq 'HASH') { $info->{album} //= _spotify_clean($item->{inAlbum}{name}); }
            if (defined $item->{duration} && !defined $info->{duration}) {
                $info->{duration} = _spotify_duration_from_iso($item->{duration});
            }
            $info->{year} //= $1 if defined($item->{datePublished}) && $item->{datePublished} =~ /^(\d{4})/;
        }
    }
    if (!defined $info->{title}) {
        if ($text =~ /"track"\s*:\s*\{.{0,3000}?"name"\s*:\s*"([^"\\]*(?:\\.[^"\\]*)*)"/s) {
            (my $v = $1) =~ s/\\"/"/g; $info->{title} = _spotify_clean($v);
        } elsif ($text =~ /"type"\s*:\s*"track".{0,3000}?"name"\s*:\s*"([^"\\]*(?:\\.[^"\\]*)*)"/s) {
            (my $v = $1) =~ s/\\"/"/g; $info->{title} = _spotify_clean($v);
        }
    }
    if (!defined $info->{artist} && $text =~ /"artists"\s*:\s*\[(.{0,2000}?)\]/s) {
        my $blob = $1; my @a;
        while ($blob =~ /"name"\s*:\s*"([^"\\]*(?:\\.[^"\\]*)*)"/g) {
            (my $v = $1) =~ s/\\"/"/g; my $c = _spotify_clean($v); push @a, $c if defined $c && $c ne '';
        }
        $info->{artist} //= join(', ', @a) if @a;
    }
    if (!defined $info->{album} && $text =~ /"album"\s*:\s*\{.{0,2000}?"name"\s*:\s*"([^"\\]*(?:\\.[^"\\]*)*)"/s) {
        (my $v = $1) =~ s/\\"/"/g; $info->{album} = _spotify_clean($v);
    }
    $info->{year} //= $1 if !defined $info->{year} && $text =~ /"release_date"\s*:\s*"(\d{4})/;
    if (!defined $info->{duration} && $text =~ /"duration_ms"\s*:\s*(\d+)/) {
        $info->{duration} = _spotify_duration_from_ms($1);
    }
    $self->{logger}->log(4, "_handle_spotify() parsed JSON-ish metadata from $context");
}

# ---------------------------------------------------------------------------
# _handle_spotify($self, $message, $nick, $channel, $url)
# Point d'entrée principal — appelé depuis displayUrlTitle() dans External.pm.
# ---------------------------------------------------------------------------
sub _handle_spotify {
    my ($self, $message, $nick, $channel, $url) = @_;

    $self->{logger}->log(4, "_handle_spotify() start url=$url");

    (my $clean_url = $url) =~ s/\?.*$//;

    my ($spotify_type, $spotify_id) = $clean_url =~ m{
        open\.spotify\.com/
        (?:(?:intl-[a-z]{2})/)?
        (track|album|playlist|episode|show|artist)
        /([A-Za-z0-9]+)
    }ix;

    unless (defined $spotify_type && defined $spotify_id) {
        $self->{logger}->log(3, "_handle_spotify() could not extract Spotify type/id from $clean_url");
        return undef;
    }

    my %info = (type => $spotify_type);

    my $http = Mediabot::External::_make_http(timeout => 10, max_size => 2 * 1024 * 1024);

    # Step 1: Spotify oEmbed
    {
        my $oembed_url = "https://open.spotify.com/oembed?url=" . uri_escape_utf8($clean_url);
        my $res = eval { $http->get($oembed_url) } // { success => 0, status => 0, reason => $@ };
        if ($res->{success}) {
            my $json = Mediabot::External::_decode_http_content_utf8($self, $res->{content} // '', 'spotify-oembed');
            my $data = eval { decode_json($json) };
            if (ref($data) eq 'HASH') {
                $info{title}  //= _spotify_clean($data->{title});
                $info{artist} //= _spotify_clean($data->{author_name});
                _spotify_extract_jsonish($self, \%info, $json, 'oEmbed-json');
                $self->{logger}->log(4, "_handle_spotify() parsed oEmbed metadata");
            }
        } else {
            $self->{logger}->log(4, "_handle_spotify() oEmbed HTTP $res->{status} $res->{reason} for $oembed_url");
        }
    }

    # Step 2: Spotify embed page
    unless (defined $info{title} && defined $info{artist} && defined $info{album}
         && defined $info{duration} && defined $info{year}) {
        my $embed_url = "https://open.spotify.com/embed/$spotify_type/$spotify_id";
        my $res = eval { $http->get($embed_url) } // { success => 0, status => 0, reason => $@ };
        if ($res->{success}) {
            my $content = Mediabot::External::_decode_http_content_utf8($self, $res->{content} // '', 'spotify-embed');
            $self->{logger}->log(4, "_handle_spotify() embed fetched " . length($content) . " bytes");
            _spotify_extract_meta($self, \%info, $content, 'embed');
            _spotify_extract_jsonish($self, \%info, $content, 'embed');
        } else {
            $self->{logger}->log(4, "_handle_spotify() embed HTTP $res->{status} $res->{reason}");
        }
    }

    # Step 3: normal Spotify page
    unless (defined $info{title} && defined $info{artist} && defined $info{album}
         && defined $info{duration} && defined $info{year}) {
        my $res = eval { $http->get($clean_url) } // { success => 0, status => 0, reason => $@ };
        if ($res->{success}) {
            my $content = Mediabot::External::_decode_http_content_utf8($self, $res->{content} // '', 'spotify-http');
            $self->{logger}->log(4, "_handle_spotify() HTTP fetched " . length($content) . " bytes");
            _spotify_extract_meta($self, \%info, $content, 'HTTP');
            _spotify_extract_jsonish($self, \%info, $content, 'HTTP');
        } else {
            $self->{logger}->log(3, "_handle_spotify() HTTP $res->{status} $res->{reason} for $clean_url");
        }
    }

    # Step 4: Chromium fallback
    unless (defined $info{title} && defined $info{artist} && defined $info{album}
         && defined $info{duration} && defined $info{year}) {
        $self->{logger}->log(4, "_handle_spotify() falling back to Chromium for $clean_url");
        my $dom = Mediabot::External::_fetch_url_chromium_dumpdom($self, $clean_url,
            virtual_time_budget => 10000, alarm_timeout => 28, lang => 'fr-FR');
        if (defined $dom && $dom ne '') {
            $self->{logger}->log(4, "_handle_spotify() Chromium DOM fetched " . length($dom) . " bytes");
            _spotify_extract_meta($self, \%info, $dom, 'Chromium');
            _spotify_extract_jsonish($self, \%info, $dom, 'Chromium');
        }
    }

    unless (defined $info{title} && !_spotify_is_bad($info{title})) {
        $self->{logger}->log(3, "_handle_spotify() could not extract a usable Spotify title from $clean_url");
        return undef;
    }

    my @parts;
    push @parts, $info{title};
    push @parts, "by $info{artist}"   if defined $info{artist} && !_spotify_is_bad($info{artist}) && $info{artist} ne $info{title};
    push @parts, "album $info{album}" if defined $info{album}  && !_spotify_is_bad($info{album})  && $info{album}  ne $info{title};
    push @parts, $info{year}          if defined $info{year}    && $info{year}    =~ /^\d{4}$/;
    push @parts, $info{duration}      if defined $info{duration} && $info{duration} ne '';

    my $display = join(' - ', @parts);
    $display =~ s/\s+/ /g; $display =~ s/^\s+|\s+$//g;
    $display = substr($display, 0, 300);

    $self->{logger}->log(4, "_handle_spotify() final display='$display'");

    my $badge = String::IRC->new("[")->white('black');
    $badge   .= String::IRC->new("Spotify")->black('green');
    $badge   .= String::IRC->new("]")->white('black');
    my $msg = "$badge\x0f $display";

    Mediabot::Helpers::botPrivmsg($self, $channel, "($nick) $msg");
    return 1;
}

1;
