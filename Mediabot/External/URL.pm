package Mediabot::External::URL;
# =============================================================================
# Mediabot::External::URL — URL routing, shared decoding and generic titles;
#                           external providers have dedicated owners
# =============================================================================
# mb99-R1: extrait de Mediabot::External.
# =============================================================================

use strict;
use warnings;
use utf8;   # mb621-B1: les litteraux de ce fichier sont des CARACTERES.
            # Sans cela ils sont des OCTETS, et interpoler une variable
            # venue d'IRC (mediabot.pl decode les messages entrants) fait
            # basculer toute la chaine : les octets sont relus en latin-1
            # puis re-encodes a l'envoi -> mojibake (« humeur Ã©lectrique »).

use Exporter 'import';
use JSON::MaybeXS;
use Mediabot::AsyncWorker;

# MB889: preserve the historical browser entry points through one owner.
use Mediabot::External::Chromium qw(
    _fetch_url_chromium_dumpdom
    _wait_chromium_child
    _decode_chromium_wait_status
);

# MB886: retain historical URL calls and optional handler export.
use Mediabot::External::AppleMusic qw(
    _am_duration_from_iso
    _am_duration_from_ms
    _applemusic_url_info
    _applemusic_extract_details
    _applemusic_lookup_track
    _applemusic_fetch_sync
    _handle_applemusic
);
# MB891: Instagram owns its metadata and worker lifecycle; keep URL aliases.
use Mediabot::External::Instagram qw(
    _instagram_url_info
    _instagram_clean_meta_value
    _instagram_meta_from_html
    _instagram_parse_social_description
    _instagram_fetch_sync
    _instagram_build_display
    _handle_instagram
);

# MB892: Facebook owns its metadata and fallback policy; retain URL aliases.
use Mediabot::External::Facebook qw(
    _facebook_url
    _facebook_title_from_html
    _facebook_fallback_title_from_url
    _handle_facebook
);

# MB893: X/Twitter owns its metadata and fallback policy; keep URL aliases.
use Mediabot::External::XTwitter qw(
    _x_url
    _x_title_from_html
    _x_desc_from_html
    _x_compact_count
    _x_fallback_title_from_url
    _handle_x_twitter
);

use URI::Escape qw(uri_escape_utf8 uri_escape);
use HTML::Entities qw(decode_entities);
use HTML::Entities '%entity2char';
use String::IRC;
use Encode qw(encode decode);

our $VERSION = '1.00';

our @EXPORT_OK = qw(
    _extract_url
    _decode_html
    _decode_http_content_utf8
    _fetch_url_chromium_dumpdom
    _handle_instagram
    _handle_applemusic
    _facebook_url
    _facebook_title_from_html
    _facebook_fallback_title_from_url
    _handle_facebook
    _x_url
    _x_title_from_html
    _x_fallback_title_from_url
    _handle_x_twitter
    _clean_generic_url_title
    _handle_generic_title
    displayUrlTitle
);

sub _extract_url {
    my ($text) = @_;
    return undef unless defined $text;

    # Keep the first HTTP(S) URL found in the message.
    # Then strip common punctuation that users often type just after a link.
    return undef unless $text =~ m{(https?://\S+)}i;

    my $url = $1;

    # Remove terminal punctuation that is almost never part of the URL in IRC
    # messages. This fixes cases like:
    #   https://example.org/foo).
    #   https://example.org/foo,
    #   https://example.org/foo]
    #
    # mb405-B1: MAIS ne retirer une ')' ou ']' finale que si elle est NON
    # APPARIÉE dans l'URL. Les URLs Wikipédia se terminent très souvent par
    # une parenthèse LÉGITIME (…/Talos_(mythologie)) : l'ancien strip aveugle
    # la coupait -> mauvaise page / 404. On strippe la ponctuation pure, puis
    # on ne consomme les fermantes finales que tant qu'elles sont en excès.
    $url =~ s/[.,!?;:]+$//;
    while ($url =~ /[)\]]$/) {
        my $last = substr($url, -1);
        my ($open, $close) = $last eq ')' ? ('(', ')') : ('[', ']');
        my $n_open  = () = $url =~ /\Q$open\E/g;
        my $n_close = () = $url =~ /\Q$close\E/g;
        last if $n_close <= $n_open;   # appariée -> elle fait partie de l'URL
        chop $url;
        $url =~ s/[.,!?;:]+$//;
    }

    # If the URL is wrapped in a single trailing quote, remove it.
    $url =~ s/["']+$//;

    return $url;
}

# ---------------------------------------------------------------------------
# _decode_html($str) — decode HTML entities in a string
# ---------------------------------------------------------------------------
sub _decode_html {
    my ($str) = @_;
    return '' unless defined $str;
    my $regex = "&(?:" . join("|", map { (my $k = $_) =~ s/;\z//; $k } keys %entity2char) . ");";
    # mb495: also trigger on HEX numeric entities (&#xa0; &#x442; &#x1f979;) —
    # they matched neither the named-entity regex nor the decimal one, so
    # Facebook reel titles reached IRC raw-encoded.
    $str = decode_entities($str) if ($str =~ /$regex/ || $str =~ /&#[0-9]+;/ || $str =~ /&#x[0-9a-fA-F]+;/);
    $str =~ s/\r|\n/ /g;
    $str =~ s/\s{2,}/ /g;
    $str =~ s/^\s+|\s+$//g;
    return $str;
}

sub _decode_http_content_utf8 {
    my ($self, $content, $context) = @_;
    return '' unless defined $content;

    my $decoded = $content;

    eval {
        $decoded = decode('UTF-8', $content, 1);
        1;
    } or do {
        my $ctx = defined $context ? $context : 'unknown';
        $self->{logger}->log(4, "_decode_http_content_utf8() UTF-8 decode failed for $ctx");
    };

    return $decoded;
}


# ---------------------------------------------------------------------------
# _clean_generic_url_title($title)
# Normalize and reject useless generic browser/security/error titles.
# ---------------------------------------------------------------------------
sub _clean_generic_url_title {
    my ($title) = @_;

    return undef unless defined $title;

    $title = _decode_html($title);
    $title =~ s/[\r\n\t]/ /g;
    $title =~ s/\s{2,}/ /g;
    $title =~ s/^\s+|\s+$//g;

    return undef if $title eq '';

    # Browser / anti-bot / CDN / error shells. They are technically titles,
    # but they are useless in an IRC UrlTitle response.
    # A4: centralised list of bot-wall / error page patterns — easy to extend
    my @_BLOCKED_TITLE_PATTERNS = (
        qr/^\s*Just a moment\.{0,3}\s*$/i,
        qr/^\s*Attention Required!\s*\|\s*Cloudflare\s*$/i,
        qr/^\s*Access Denied\s*$/i,
        qr/^\s*403 Forbidden\s*$/i,
        qr/^\s*404 Not Found\s*$/i,
        qr/^\s*Page Not Found\s*$/i,
        qr/^\s*Not Found\s*$/i,
        qr/^\s*Error\s*$/i,
        qr/please enable javascript/i,
        qr/javascript is not available/i,
        qr/checking your browser/i,
        qr/one moment, please/i,
        qr/robot check/i,
        qr/verify you are human/i,
    );
    return undef if grep { $title =~ $_ } @_BLOCKED_TITLE_PATTERNS;

    # mb408-R1: troncature à la frontière de mot + ellipse. Avant,
    # substr(0,300) coupait en plein mot sans indiquer la coupe.
    if (length($title) > 300) {
        $title = substr($title, 0, 300);
        $title =~ s/\s+\S*$// if $title =~ /\s/;   # ne pas finir sur un mot coupé
        $title .= '…';
    }

    return $title;
}

# ---------------------------------------------------------------------------
# _handle_generic_title($self, $message, $nick, $channel, $url)
# Generic URL: fetch page, extract <title>. No HTML::Tree — regex is enough.
# ---------------------------------------------------------------------------
sub _handle_generic_title {
    my ($self, $message, $nick, $channel, $url) = @_;

    my $http = Mediabot::External::_make_http(
        timeout  => 8,
        max_size => 768 * 1024,
    );

    my $res  = eval { $http->get($url); } // { success => 0, status => 0, reason => $@ };
    unless ($res->{success}) {
        $self->{logger}->log(3, "_handle_generic_title() HTTP $res->{status} $res->{reason} for $url");
        return undef;
    }

    my $content_type = '';
    if (ref($res->{headers}) eq 'HASH') {
        $content_type = $res->{headers}->{'content-type'} // $res->{headers}->{'Content-Type'} // '';
    }

    if ($content_type ne ''
        && $content_type !~ m{text/html|application/xhtml\+xml|application/xml|text/xml}i
    ) {
        $self->{logger}->log(4, "_handle_generic_title() skipped non-HTML content-type '$content_type' for $url");
        return undef;
    }

    my $content = _decode_http_content_utf8($self, $res->{content} // '', 'generic');
    my @candidates;

    # Prefer explicit social metadata when available.
    while ($content =~ /<meta\b([^>]*?)>/sig) {
        my $attrs = $1;

        next unless $attrs =~ /(?:property|name)=["'](?:og:title|twitter:title)["']/i;

        if ($attrs =~ /\bcontent=["']([^"']+)["']/i) {
            push @candidates, $1;
        }
    }

    if ($content =~ /<title[^>]*>(.*?)<\/title>/si) {
        push @candidates, $1;
    }

    unless (@candidates) {
        $self->{logger}->log(4, "_handle_generic_title() no title candidate found for $url");
        return undef;
    }

    my $title;
    for my $candidate (@candidates) {
        my $clean = _clean_generic_url_title($candidate);
        next unless defined $clean && $clean ne '';

        $title = $clean;
        last;
    }

    unless (defined $title && $title ne '') {
        $self->{logger}->log(4, "_handle_generic_title() only useless/generic title candidates found for $url");
        return undef;
    }

    # Keep historical label style, but hard-reset before the displayed title.
    # Y4: include domain in badge for context
    my $domain = '';
    if ($url =~ m{^https?://([^/?#]+)}i) {
        $domain = $1;
        $domain =~ s/^www\.//i;
        $domain = substr($domain, 0, 30);  # cap length
    }
    my $label = String::IRC->new("URL")->grey('black');
    $label   .= String::IRC->new(" $domain")->white('black') if $domain;
    $label   .= String::IRC->new(" $nick:")->grey('black');
    Mediabot::Helpers::botPrivmsg($self, $channel, "$label\x0f $title");
    return 1;
}

# ---------------------------------------------------------------------------
# URL cache identity: fold only scheme and host. Resource paths, query values,
# fragments and credentials may be case-sensitive. Keep their original spelling
# without decoding escapes or rewriting the URL sent to the HTTP handler.
# ---------------------------------------------------------------------------
sub _url_cache_identity {
    my ($url) = @_;
    $url //= '';
    my ($scheme, $authority, $suffix) = $url =~ m{\A(https?://)([^/?#]*)(.*)\z}is;
    return $url unless defined $scheme;

    my $userinfo = '';
    $userinfo = $1 if $authority =~ s{\A(.*@)}{}s;
    my ($host, $port) = $authority =~ m{\A(\[[^\]]*\]|[^:]*)(.*)\z}s;
    if ($host =~ /\A\[/) {
        # An IPv6 scope identifier is local to the interface; preserve its case.
        my ($address, $scope) = split /%/, $host, 2;
        $host = lc($address) . (defined($scope) ? "%$scope" : '');
    } else {
        $host = lc($host);
    }
    return lc($scheme) . $userinfo . $host . $port . $suffix;
}

# ---------------------------------------------------------------------------
# _url_display_cache_gate($self, $url, $channel)
#
# Anti-repeat cache for displayed URLs.  The caller invokes this only after the
# matching chanset has accepted the URL, so disabled features never burn an URL
# that should become immediately usable after being enabled.
# ---------------------------------------------------------------------------
sub _url_display_cache_gate {
    my ($self, $url, $channel) = @_;

    my $cache_key = _url_cache_identity($url) . "\x00" . lc($channel // '');
    my $cache     = $self->{_url_display_cache} //= {};
    my $now       = time();
    my $url_ttl   = 300;  # 5 minutes

    # Purge stale entries at most once per minute.
    if (($self->{_url_cache_last_purge} // 0) < $now - 60) {
        my @stale = grep { ($cache->{$_} // 0) < $now - $url_ttl } keys %$cache;
        delete @{$cache}{@stale};
        $self->{_url_cache_last_purge} = $now;
    }

    if (($cache->{$cache_key} // 0) >= $now - $url_ttl) {
        $self->{logger}->log(4, "displayUrlTitle() skipping repeated URL: $url");
        return 0;
    }

    $cache->{$cache_key} = $now;
    return 1;
}

# ---------------------------------------------------------------------------
# displayUrlTitle($self, $message, $nick, $channel, $text)
#
# Main entry point for URL handling from on_message_PRIVMSG.
# Handles all URL types: YouTube, Instagram, Spotify, Apple Music, generic.
# Chanset guards are checked here (not in mediabot.pl).
# ---------------------------------------------------------------------------
sub displayUrlTitle {
    my ($self, $message, $sNick, $sChannel, $sText) = @_;

    $self->{logger}->log(4, "displayUrlTitle() RAW input: $sText");

    my $url = _extract_url($sText);
    my $captured_url = $url // '(unknown)';  # DU1/fix: capture before eval scope

    my $result = eval {
    
        unless (defined $url && $url =~ /^https?:\/\//i) {
            $self->{logger}->log(4, "displayUrlTitle() no valid URL found in: $sText");
            return undef;
        }

        # IMP2/polish: skip obvious private/internal literal hosts before any
        # network fetch. This is a lightweight guard, not a full SSRF firewall:
        # it intentionally avoids DNS resolution here.
        if ($url =~ m{^https?://
                (?:
                    localhost(?:[/:]|\z)
                  | 0\.0\.0\.0(?:[/:]|\z)
                  | 127\.\d+\.\d+\.\d+(?:[/:]|\z)
                  | 10\.\d+\.\d+\.\d+(?:[/:]|\z)
                  | 172\.(?:1[6-9]|2\d|3[01])\.\d+\.\d+(?:[/:]|\z)
                  | 192\.168\.\d+\.\d+(?:[/:]|\z)
                  | 169\.254\.\d+\.\d+(?:[/:]|\z)
                  | \[(?: ::1
                       | fc[0-9a-f]{2}:[0-9a-f:]+
                       | fd[0-9a-f]{2}:[0-9a-f:]+
                       | fe80:[0-9a-f:]+
                    )\](?:[/:]|\z)
                )
            }xi) {
            $self->{logger}->log(4, "displayUrlTitle() skipping private/internal URL: $url");
            return undef;
        }
    
        $self->{logger}->log(4, "displayUrlTitle() URL: $url");
    
        # ── 1. YouTube ─────────────────────────────────────────────────────────
        # All YouTube URL variants (watch, shorts, live, youtu.be, nocookie, m., music.)
        my $yt_id = Mediabot::External::_is_youtube_url($url);
        if (defined $yt_id) {
            unless (Mediabot::External::_chanset_ok($self, $sChannel, 'Youtube')) {
                $self->{logger}->log(4, "displayUrlTitle() YouTube chanset not enabled on $sChannel");
                return undef;
            }
            return undef unless _url_display_cache_gate($self, $url, $sChannel);
            # Delegate to Mediabot::External::displayYoutubeDetails which uses the YouTube Data API v3
            eval { $self->{metrics}->inc('mediabot_urltitle_requests_total', { type => 'youtube' }) if $self->{metrics}; };
            return Mediabot::External::displayYoutubeDetails($self, $message, $sNick, $sChannel, $url);
        }
    
        # ── 2. Instagram ───────────────────────────────────────────────────────
        if ($url =~ m{\Ahttps?://(?:www\.)?instagram\.com(?:[/:?#]|\z)}i) { # mb406-B1: host ancré
            unless (Mediabot::External::_chanset_ok($self, $sChannel, 'UrlTitle')) {
                $self->{logger}->log(4, "displayUrlTitle() UrlTitle chanset not enabled on $sChannel (Instagram)");
                return undef;
            }
            return undef unless _url_display_cache_gate($self, $url, $sChannel);
            eval { $self->{metrics}->inc('mediabot_urltitle_requests_total', { type => 'instagram' }) if $self->{metrics}; };
            return _handle_instagram($self, $message, $sNick, $sChannel, $url);
        }
    
        # ── 3. Spotify ─────────────────────────────────────────────────────────
        if ($url =~ m{\Ahttps?://open\.spotify\.com(?:[/:?#]|\z)}i) { # mb406-B1: host ancré
            unless (Mediabot::External::_chanset_ok($self, $sChannel, 'UrlTitle')) {
                $self->{logger}->log(4, "displayUrlTitle() UrlTitle chanset not enabled on $sChannel (Spotify)");
                return undef;
            }
            return undef unless _url_display_cache_gate($self, $url, $sChannel);
            eval { $self->{metrics}->inc('mediabot_urltitle_requests_total', { type => 'spotify' }) if $self->{metrics}; };
            return Mediabot::External::_handle_spotify($self, $message, $sNick, $sChannel, $url);
        }
    
        # ── 4. Apple Music ─────────────────────────────────────────────────────
        if ($url =~ m{\Ahttps?://music\.apple\.com(?:[/:?#]|\z)}i) { # mb406-B1: host ancré
            unless (Mediabot::External::_chanset_ok($self, $sChannel, 'AppleMusic')) {
                $self->{logger}->log(4, "displayUrlTitle() AppleMusic chanset not enabled on $sChannel");
                return undef;
            }
            return undef unless _url_display_cache_gate($self, $url, $sChannel);
            eval { $self->{metrics}->inc('mediabot_urltitle_requests_total', { type => 'applemusic' }) if $self->{metrics}; };
            return _handle_applemusic($self, $message, $sNick, $sChannel, $url);
        }
    
        # ── 5. Facebook ────────────────────────────────────────────────────────
        if ($url =~ m{\Ahttps?://(?:www\.)?facebook\.com(?:/|\z)}i) { # mb416-B1: host anchored
            unless (Mediabot::External::_chanset_ok($self, $sChannel, 'UrlTitle')) {
                $self->{logger}->log(4, "displayUrlTitle() UrlTitle chanset not enabled on $sChannel (Facebook)");
                return undef;
            }
            return undef unless _url_display_cache_gate($self, $url, $sChannel);
            eval { $self->{metrics}->inc('mediabot_urltitle_requests_total', { type => 'facebook' }) if $self->{metrics}; };
            return _handle_facebook($self, $message, $sNick, $sChannel, $url);
        }
    
        # ── 6. X / Twitter ─────────────────────────────────────────────────────
        if ($url =~ m{\Ahttps?://(?:www\.)?(?:x|twitter)\.com(?:/|\z)}i) { # mb416-B1: host anchored
            unless (Mediabot::External::_chanset_ok($self, $sChannel, 'UrlTitle')) {
                $self->{logger}->log(4, "displayUrlTitle() UrlTitle chanset not enabled on $sChannel (X/Twitter)");
                return undef;
            }
            return undef unless _url_display_cache_gate($self, $url, $sChannel);
            eval { $self->{metrics}->inc('mediabot_urltitle_requests_total', { type => 'x_twitter' }) if $self->{metrics}; };
            return _handle_x_twitter($self, $message, $sNick, $sChannel, $url);
        }
    
        # ── 7. Generic ─────────────────────────────────────────────────────────
        unless (Mediabot::External::_chanset_ok($self, $sChannel, 'UrlTitle')) {
            $self->{logger}->log(4, "displayUrlTitle() UrlTitle chanset not enabled on $sChannel");
            return undef;
        }
        return undef unless _url_display_cache_gate($self, $url, $sChannel);
        eval { $self->{metrics}->inc('mediabot_urltitle_requests_total', { type => 'generic' }) if $self->{metrics}; };
        return _handle_generic_title($self, $message, $sNick, $sChannel, $url);
    };
    if ($@) {
        $self->{logger}->log(1, "displayUrlTitle() error for $captured_url: $@");
    }
    return $result;

}

# debug [0-5]
# Show or set the bot debug level.
# Requires: authenticated + Owner

1;
