package Mediabot::External::URL;
# =============================================================================
# Mediabot::External::URL — URL routing, Facebook, X/Twitter and generic titles;
#                           Instagram and Apple Music have dedicated owners
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
# Mediabot::External::_handle_spotify($self, $message, $nick, $channel, $url)
# Parses <title> from Spotify page. Format: "Song - artist | Spotify"
# Also handles albums, playlists, podcasts via og:title.
# ---------------------------------------------------------------------------
# mb94-R1: toutes les subs _spotify_* et Mediabot::External::_handle_spotify sont dans
# Mediabot::External::Spotify (Mediabot/External/Spotify.pm)
# et importées en tête de ce fichier.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# _facebook_url($url)
# Normalize Facebook root URLs so they behave like browser/curl -L tests.
# ---------------------------------------------------------------------------
sub _facebook_url {
    my ($url) = @_;

    return undef unless defined $url && $url =~ m{^https?://(?:www\.)?facebook\.com(?:/|$)}i;

    $url =~ s{^http://}{https://}i;
    $url =~ s{^https://facebook\.com/?}{https://www.facebook.com/}i;

    return $url;
}

# ---------------------------------------------------------------------------
# _facebook_title_from_html($self, $html, $context)
# Extract a usable Facebook title from HTML/DOM.
# ---------------------------------------------------------------------------
sub _facebook_title_from_html {
    my ($self, $html, $context) = @_;

    return undef unless defined $html && $html ne '';

    my $title;

    while ($html =~ /<meta\b([^>]*?)>/sig) {
        my $attrs = $1;

        next unless $attrs =~ /property=["']og:title["']/i;

        if ($attrs =~ /\bcontent=["']([^"']+)["']/i) {
            $title = $1;
            last;
        }
    }

    if (!defined($title) && $html =~ /<title[^>]*>(.*?)<\/title>/si) {
        $title = $1;
    }

    return undef unless defined $title && $title ne '';

    $title = _decode_html($title);
    $title =~ s/[\r\n\t]/ /g;
    $title =~ s/\x{a0}/ /g;   # mb495: nbsp from decoded counters -> plain space
    $title =~ s/\s{2,}/ /g;
    $title =~ s/^\s+|\s+$//g;

    # mb495: reel og:title = "<view/reaction counters, random locale> | <caption>"
    # (e.g. "377 K views · 2.6 K reactions | Would you be so kind..."). When the
    # title STARTS with a digit and carries a pipe, keep the caption side.
    if ($title =~ /^\s*\d/ && $title =~ /^[^|]{1,120}\|\s*(\S.*)$/s) {
        $title = $1;
        $title =~ s/\s{2,}/ /g;
        $title =~ s/^\s+|\s+$//g;
    }

    return undef if $title eq '';
    return undef if $title =~ /^\s*Facebook\s*$/i;
    return undef if $title =~ /^(?:Log in|Se connecter|Connexion|Sign up|Inscription)\s*(?:to|à|sur)?\s*Facebook/i;
    return undef if $title =~ /(?:log in|se connecter).*(?:Facebook)/i && length($title) < 80;

    $self->{logger}->log(4, "_facebook_title_from_html() $context selected title='$title'");

    return $title;
}

# ---------------------------------------------------------------------------
# _facebook_fallback_title_from_url($url)
# Last-resort label for Facebook URLs when both HTTP and Chromium only expose
# a login shell or unusable generic title.
# ---------------------------------------------------------------------------
sub _facebook_fallback_title_from_url {
    my ($url) = @_;

    return undef unless defined $url && $url =~ m{^https?://(?:www\.)?facebook\.com(?:/|$)}i;

    my $normalized = $url;
    $normalized =~ s{^http://}{https://}i;
    $normalized =~ s{^https://facebook\.com/?}{https://www.facebook.com/}i;

    return 'Facebook' if $normalized =~ m{^https://www\.facebook\.com/?(?:[?#].*)?\z}i;

    my $path = $normalized;
    $path =~ s{^https://www\.facebook\.com/?}{}i;
    $path =~ s/[?#].*\z//;
    $path =~ s{/+\z}{};

    return 'Facebook link' if $path eq '';

    $path =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/eg;

    my @parts = grep { defined $_ && $_ ne '' } split m{/+}, $path;

    my $clean = sub {
        my ($s) = @_;

        return '' unless defined $s;

        $s =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/eg;
        $s =~ s/[._-]+/ /g;
        $s =~ s/\s{2,}/ /g;
        $s =~ s/^\s+|\s+\z//g;

        return $s;
    };

    return 'Facebook reel'  if $path =~ m{^(?:reel|reels)/}i;
    return 'Facebook video' if $path =~ m{^(?:watch|videos?)(?:/|\z)}i;
    return 'Facebook photo' if $path =~ m{^(?:photo\.php|photo/|photos?)(?:/|\z)}i;
    return 'Facebook story' if $path =~ m{^(?:stories|story\.php)(?:/|\z)}i;
    return 'Facebook event' if $path =~ m{^events?/}i;

    if (@parts >= 4 && lc($parts[0]) eq 'groups' && lc($parts[2]) eq 'posts') {
        my $group = $clean->($parts[1]);
        return $group ne '' ? "Facebook group post: $group" : 'Facebook group post';
    }

    if (@parts >= 2 && lc($parts[0]) eq 'groups') {
        my $group = $clean->($parts[1]);
        return $group ne '' ? "Facebook group: $group" : 'Facebook group';
    }

    if (@parts >= 3 && lc($parts[1]) eq 'posts') {
        my $owner = $clean->($parts[0]);
        return $owner ne '' ? "Facebook post by $owner" : 'Facebook post';
    }

    if (@parts >= 3 && lc($parts[1]) =~ /^videos?$/) {
        my $owner = $clean->($parts[0]);
        return $owner ne '' ? "Facebook video by $owner" : 'Facebook video';
    }

    if (@parts >= 1) {
        my $owner = $clean->($parts[0]);

        return 'Facebook link'
            if $owner eq ''
            || $owner =~ /^(?:permalink\.php|profile\.php|share|sharer|login|recover|help|marketplace)$/i;

        return "Facebook: $owner";
    }

    return 'Facebook link';
}

# ---------------------------------------------------------------------------
# _handle_facebook($self, $message, $nick, $channel, $url)
# Facebook often behaves differently than generic sites.  Keep it out of the
# generic title path and use a dedicated HTTP + Chromium fallback.
# ---------------------------------------------------------------------------
sub _handle_facebook {
    my ($self, $message, $nick, $channel, $url) = @_;

    my $fb_html = '';   # mb492: html we ended up trusting

    my $fb_url = _facebook_url($url);
    unless (defined $fb_url) {
        $self->{logger}->log(4, "_handle_facebook() not a supported Facebook URL: " . ($url // '<undef>'));
        return undef;
    }

    $self->{logger}->log(4, "_handle_facebook() start url=$fb_url");

    # IMP10: serve from cache if fresh (TTL 10 min)
    # Resource IDs and query values retain their case, as at URL admission.
    my $fb_cache_key = _url_cache_identity($fb_url);
    my $fb_cached = $self->{_facebook_cache}{$fb_cache_key};
    if ($fb_cached && (time() - ($fb_cached->{ts} // 0)) < 600) {
        $self->{logger}->log(4, "_handle_facebook() cache hit for $fb_url");
        Mediabot::Helpers::botPrivmsg($self, $channel, "($nick) $fb_cached->{msg}");
        return 1;
    }

    my $title;

    # Step 1: cheap HTTP fetch.  On your server, HTTP::Tiny follows
    # facebook.com -> www.facebook.com and can receive a normal 200 page.
    my $http = Mediabot::External::_make_http(
        timeout  => 8,
        max_size => 1024 * 1024,
        agent    => 'facebookexternalhit/1.1 (+http://www.facebook.com/externalhit_uatext.php)',   # mb494: social-crawler UA -> server-side og: tags
        default_headers => { 'accept-language' => 'en-US,en;q=0.8' },   # mb495: stable counter locale
    );

    my $res = eval { $http->get($fb_url); } // { success => 0, status => 0, reason => $@ };

    if ($res->{success}) {
        my $content = _decode_http_content_utf8($self, $res->{content} // '', 'facebook-http');
        my $len = length($content);
        $self->{logger}->log(4, "_handle_facebook() HTTP fetched $len bytes for $fb_url");
        $fb_html = $content;   # mb492
        $title = _facebook_title_from_html($self, $content, 'HTTP');
    }
    else {
        $self->{logger}->log(4, "_handle_facebook() HTTP $res->{status} $res->{reason} for $fb_url");
    }

    # Step 2: Chromium fallback.  Keep it for non-Reel Facebook URLs where
    # rendered metadata can still add value. Public Reel shells are different:
    # when the crawler HTML has no usable title, Chromium commonly waits until
    # its alarm and still exposes no metadata. Skip that known-dead path so the
    # deterministic Reel fallback is returned immediately.
    unless (defined $title && $title ne '') {
        my $is_reel = $fb_url =~ m{^https://www\.facebook\.com/(?:reel|reels)/}i ? 1 : 0;

        if ($is_reel) {
            $self->{logger}->log(4, "_handle_facebook() Reel shell has no usable HTTP metadata; skipping Chromium");
        }
        else {
            $self->{logger}->log(4, "_handle_facebook() falling back to Chromium rendered DOM");

            my $fb_vtb = int(eval { $self->{conf}->get('chromium.FACEBOOK_VIRTUAL_TIME_BUDGET') } // 6500);
            my $fb_alarm = int(eval { $self->{conf}->get('chromium.FACEBOOK_ALARM_TIMEOUT') } // 22);

            $fb_vtb = 1000 if $fb_vtb < 1000;
            $fb_vtb = 30000 if $fb_vtb > 30000;
            $fb_alarm = 5 if $fb_alarm < 5;
            $fb_alarm = 60 if $fb_alarm > 60;

            my $dom = _fetch_url_chromium_dumpdom(
                $self,
                $fb_url,
                virtual_time_budget => $fb_vtb,
                alarm_timeout       => $fb_alarm,
                lang                => 'fr-FR',
            );

            if (defined $dom && $dom ne '') {
                my $len = length($dom);
                $self->{logger}->log(4, "_handle_facebook() Chromium DOM fetched $len bytes for $fb_url");
                $fb_html = $dom;   # mb492
                $title = _facebook_title_from_html($self, $dom, 'Chromium');
            }
        }
    }

    unless (defined $title && $title ne '') {
        my $fallback_title = _facebook_fallback_title_from_url($fb_url);
        if (defined $fallback_title && $fallback_title ne '') {
            $title = $fallback_title;
            $self->{logger}->log(4, "_handle_facebook() using URL fallback title '$title' for $fb_url");
        }
    }

    unless (defined $title && $title ne '') {
        $self->{logger}->log(3, "_handle_facebook() no usable title extracted for $fb_url");
        return undef;
    }

    my $badge = String::IRC->new("[")->white('black');
    $badge   .= String::IRC->new("Facebook")->white('blue');
    $badge   .= String::IRC->new("]")->white('black');

    # mb492: append og:description when informative and not a duplicate
    my $fb_line = $title;
    my $fb_desc;
    if    ($fb_html =~ /<meta\s+property=["']og:description["']\s+content=(["'])(.*?)\1/is) { $fb_desc = $2; }
    elsif ($fb_html =~ /<meta\s+content=(["'])(.*?)\1\s+property=["']og:description["']/is) { $fb_desc = $2; }
    if (defined $fb_desc) {
        $fb_desc = _decode_html($fb_desc);
        $fb_desc =~ s/[\r\n\t]/ /g; $fb_desc =~ s/\s{2,}/ /g; $fb_desc =~ s/^\s+|\s+$//g;
        if ($fb_desc ne ''
            && $fb_desc !~ /^(?:Log in|Se connecter|Sign in|Connexion)/i
            && $fb_desc !~ /facebook/i
            && index(lc($fb_line), lc(substr($fb_desc, 0, 40))) < 0) {
            my $d = length($fb_desc) > 150 ? substr($fb_desc, 0, 147) . '...' : $fb_desc;
            $fb_line .= " - $d";
        }
    }

    my $msg = "$badge\x0f " . substr($fb_line, 0, 300);
    # IMP10: cache the result (TTL 10 min) to avoid redundant Chromium fetches
    $self->{_facebook_cache}{$fb_cache_key} = { ts => time(), msg => $msg };

    Mediabot::Helpers::botPrivmsg($self, $channel, "($nick) $msg");
    return 1;
}

# ---------------------------------------------------------------------------
# _x_url($url)
# Normalize X/Twitter URLs so the dedicated handler has one canonical shape.
# ---------------------------------------------------------------------------
sub _x_url {
    my ($url) = @_;

    return undef unless defined $url && $url =~ m{^https?://(?:www\.)?(?:x|twitter)\.com(?:/|$)}i;

    $url =~ s{^http://}{https://}i;
    $url =~ s{^https://(?:www\.)?twitter\.com(?=/|$)}{https://x.com}i;
    $url =~ s{^https://www\.x\.com(?=/|$)}{https://x.com}i;
    $url =~ s{^https://x\.com/?}{https://x.com/}i;

    $url .= '/' if $url =~ m{^https://x\.com\z}i;

    return $url;
}

# ---------------------------------------------------------------------------
# _x_title_from_html($self, $html, $context)
# Extract a usable X/Twitter title from rendered DOM or HTML.
# ---------------------------------------------------------------------------
sub _x_title_from_html {
    my ($self, $html, $context) = @_;

    return undef unless defined $html && $html ne '';

    my $title;

    while ($html =~ /<meta\b([^>]*?)>/sig) {
        my $attrs = $1;

        next unless $attrs =~ /(?:property|name)=["'](?:og:title|twitter:title)["']/i;

        if ($attrs =~ /\bcontent=["']([^"']+)["']/i) {
            $title = $1;
            last;
        }
    }

    if (!defined($title) && $html =~ /<title[^>]*>(.*?)<\/title>/si) {
        $title = $1;
    }

    return undef unless defined $title && $title ne '';

    $title = _decode_html($title);
    $title =~ s/[\r\n\t]/ /g;
    $title =~ s/\s{2,}/ /g;
    $title =~ s/^\s+|\s+$//g;

    return undef if $title eq '';
    return undef if $title =~ /^(?:X|Twitter)$/i;
    return undef if $title =~ /^(?:Log in|Se connecter|Sign in|Connexion)\s*(?:to|à|sur)?\s*(?:X|Twitter)/i;
    return undef if $title =~ /(?:JavaScript is not available|This browser is no longer supported)/i;

    $self->{logger}->log(4, "_x_title_from_html() $context selected title='$title'");

    return $title;
}

# ---------------------------------------------------------------------------
# _x_fallback_title_from_url($url)
# Last-resort honest label when X only exposes a login shell.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# _x_desc_from_html($self, $html, $context)
# mb492: pull the tweet text (og:description / twitter:description) with the
# same anti-login-shell guards as the title. Returns undef when unusable.
# ---------------------------------------------------------------------------
sub _x_desc_from_html {
    my ($self, $html, $context) = @_;
    return undef unless defined $html && $html ne '';

    my $desc;
    while ($html =~ /<meta\b([^>]*?)>/sig) {
        my $attrs = $1;
        next unless $attrs =~ /(?:property|name)=["'](?:og:description|twitter:description)["']/i;
        # mb492: paired-quote capture so apostrophes don't truncate the tweet
        if ($attrs =~ /\bcontent=(["'])(.*?)\1/is) { $desc = $2; last; }
    }
    return undef unless defined $desc && $desc ne '';

    $desc = _decode_html($desc);
    $desc =~ s/[\r\n\t]/ /g;
    $desc =~ s/\s{2,}/ /g;
    $desc =~ s/^\s+|\s+$//g;
    # strip X's decorative curly quotes wrapping the tweet text
    $desc =~ s/^[\x{201C}"]//; $desc =~ s/[\x{201D}"]$//;

    return undef if $desc eq '';
    return undef if $desc =~ /^(?:X|Twitter)$/i;
    return undef if $desc =~ /(?:JavaScript is not available|This browser is no longer supported)/i;
    return undef if $desc =~ /^(?:Log in|Se connecter|Sign in|Connexion)/i;

    $self->{logger}->log(4, "_x_desc_from_html() $context selected desc len=" . length($desc));
    return $desc;
}

# ---------------------------------------------------------------------------
# _x_compact_count($n) — mb494: 950 -> "950", 12345 -> "12.3k", 4200000 -> "4.2M"
# ---------------------------------------------------------------------------
sub _x_compact_count {
    my ($n) = @_;
    return '0' unless defined $n && $n =~ /^\d+$/;
    return "$n" if $n < 1000;
    # mb496 fix: 999999 rounded to "1000.0k" -> promote to M at the boundary
    if ($n < 1_000_000) {
        my $s = sprintf('%.1f', $n / 1000);
        return ($s =~ s/\.0$//r) . 'k' if $s ne '1000.0';
    }
    my $m = sprintf('%.1f', $n / 1_000_000);
    return ($m =~ s/\.0$//r) . 'M';
}

sub _x_fallback_title_from_url {
    my ($url) = @_;

    my $x_url = _x_url($url);
    return undef unless defined $x_url;

    return 'X' if $x_url =~ m{^https://x\.com/?(?:[?#].*)?\z}i;

    my $path = $x_url;
    $path =~ s{^https://x\.com/?}{}i;
    $path =~ s/[?#].*\z//;
    $path =~ s{/+\z}{};

    return 'X link' if $path eq '';

    $path =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/eg;

    my @parts = grep { defined $_ && $_ ne '' } split m{/+}, $path;

    my $clean = sub {
        my ($s) = @_;

        return '' unless defined $s;

        $s =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/eg;
        $s =~ s/[._-]+/ /g;
        $s =~ s/\s{2,}/ /g;
        $s =~ s/^\s+|\s+\z//g;

        return $s;
    };

    if (@parts >= 3 && lc($parts[0]) eq 'i' && lc($parts[1]) eq 'web' && lc($parts[2]) eq 'status') {
        return 'X post';
    }

    if (@parts >= 3 && lc($parts[1]) =~ /^status(?:es)?$/) {
        my $owner = $clean->($parts[0]);
        return $owner ne '' ? "X post by \@$owner" : 'X post';
    }

    if (@parts >= 3 && lc($parts[1]) eq 'lists') {
        my $owner = $clean->($parts[0]);
        my $list  = $clean->($parts[2]);

        return "X list by \@$owner: $list" if $owner ne '' && $list ne '';
        return "X list by \@$owner"       if $owner ne '';
        return 'X list';
    }

    if (@parts >= 2 && lc($parts[0]) eq 'i' && lc($parts[1]) eq 'communities') {
        return 'X community';
    }

    if (@parts >= 1) {
        my $owner = $clean->($parts[0]);

        return 'X link'
            if $owner eq ''
            || $owner =~ /^(?:home|explore|search|notifications|messages|i|intent|share|login|logout|settings)$/i;

        return "X profile: \@$owner";
    }

    return 'X link';
}

# ---------------------------------------------------------------------------
# _handle_x_twitter($self, $message, $nick, $channel, $url)
# X/Twitter is not a generic website for URL titles.  It often needs a rendered
# DOM to expose useful metadata, and it may still only show a login shell.
# ---------------------------------------------------------------------------
sub _handle_x_twitter {
    my ($self, $message, $nick, $channel, $url) = @_;

    my $x_url = _x_url($url);
    unless (defined $x_url) {
        $self->{logger}->log(4, "_handle_x_twitter() not a supported X/Twitter URL: " . ($url // '<undef>'));
        return undef;
    }

    $self->{logger}->log(4, "_handle_x_twitter() start url=$x_url");

    # IMP10: cache x_twitter result (TTL 10 min) — Chromium is expensive
    my $tw_cache     = $self->{_x_twitter_cache} //= {};
    my $tw_cache_key = _url_cache_identity($url);
    my $tw_now       = time();
    if (my $cached = $tw_cache->{$tw_cache_key}) {
        if ($tw_now - ($cached->{ts} // 0) < 600) {
            $self->{logger}->log(4, "_handle_x_twitter() serving from cache: $url");

            # IMP10/fix: replay the cached IRC message.
            # Older mb76 code cached only result => 1, which made cache hits silent.
            if (defined($cached->{msg}) && $cached->{msg} ne '') {
                Mediabot::Helpers::botPrivmsg($self, $channel, "($nick) $cached->{msg}");
                return 1;
            }

            # Backward-compatible cleanup for any stale in-memory entries created
            # by the old code during the same process lifetime.
            delete $tw_cache->{$tw_cache_key};
        }
        else {
            delete $tw_cache->{$tw_cache_key};
        }
    }

    my $title;
    my $tweet_text;
    my ($fx_likes, $fx_rts);

    # mb494: FAST PATH — public fxtwitter JSON API (~300 ms), the way fast
    # bots answer in under a second. Chromium only runs if this misses.
    if ($x_url =~ m{^https://x\.com/([^/]+)/status/(\d+)}i) {
        my ($screen, $tid) = ($1, $2);
        my $api  = "https://api.fxtwitter.com/$screen/status/$tid";
        my $http = Mediabot::External::_make_http(timeout => 6, max_size => 512 * 1024);
        my $t0   = Time::HiRes::time();
        my $res  = eval { $http->get($api) } // { success => 0, status => 0, reason => "die: $@" };
        my $dt   = sprintf('%.2f', Time::HiRes::time() - $t0);
        if ($res->{success}) {
            my $data = eval { decode_json($res->{content} // '') };
            if (ref($data) eq 'HASH' && ($data->{code} // 0) == 200 && ref($data->{tweet}) eq 'HASH') {
                my $tw      = $data->{tweet};
                my $name    = eval { $tw->{author}{name} }        // '';
                my $screen2 = eval { $tw->{author}{screen_name} } // $screen;
                # mb496: guard against unexpected non-scalar API shapes
                $name    = '' if ref $name;
                $screen2 = $screen if ref $screen2;
                $title      = $name ne '' ? "$name (\@$screen2) on X" : "\@$screen2 on X";
                $tweet_text = (defined $tw->{text}  && !ref $tw->{text})  ? $tw->{text}  : undef;
                $fx_likes   = (defined $tw->{likes} && !ref $tw->{likes}) ? $tw->{likes} : undef;
                $fx_rts     = (defined $tw->{retweets} && !ref $tw->{retweets}) ? $tw->{retweets} : undef;
                $self->{logger}->log(4, "_handle_x_twitter() fxtwitter hit in ${dt}s for $x_url");
            }
            else {
                $self->{logger}->log(4, "_handle_x_twitter() fxtwitter unusable JSON (code="
                    . (ref($data) eq 'HASH' ? ($data->{code} // '?') : '?') . ") in ${dt}s for $x_url");
            }
        }
        else {
            $self->{logger}->log(4, "_handle_x_twitter() fxtwitter HTTP "
                . ($res->{status} // '?') . " in ${dt}s for $x_url");
        }
    }

    # X is rendered/client-heavy.  Go through Chromium ONLY when the fast
    # path above did not deliver (profiles, or fxtwitter outage).
    # XT1/fix: eval around chromium call — external process may die/timeout
    my $dom;
    unless (defined $title && $title ne '') {
        $dom = eval { _fetch_url_chromium_dumpdom(
            $self,
            $x_url,
            virtual_time_budget => 6500,
            alarm_timeout       => 16,
            lang                => 'fr-FR',
        ) };
        if ($@) {
            $self->{logger}->log(1, "_handle_x_twitter() chromium error: $@");
            return undef;
        }

        if (defined $dom && $dom ne '') {
            my $len = length($dom);
            $self->{logger}->log(4, "_handle_x_twitter() Chromium DOM fetched $len bytes for $x_url");
            $title = _x_title_from_html($self, $dom, 'Chromium');
            $tweet_text = _x_desc_from_html($self, $dom, 'Chromium');
        }
        else {
            $self->{logger}->log(4, "_handle_x_twitter() Chromium returned no usable DOM for $x_url");
        }
    }

    unless (defined $title && $title ne '') {
        my $fallback_title = _x_fallback_title_from_url($x_url);
        if (defined $fallback_title && $fallback_title ne '') {
            $title = $fallback_title;
            $self->{logger}->log(4, "_handle_x_twitter() using URL fallback title '$title' for $x_url");
        }
    }

    unless (defined $title && $title ne '') {
        $self->{logger}->log(3, "_handle_x_twitter() no usable title extracted for $x_url");
        return undef;
    }

    my $badge = String::IRC->new("[")->white('black');
    $badge   .= String::IRC->new("X")->white('black');
    $badge   .= String::IRC->new("]")->white('black');

    # mb492: append the tweet text when we have it and the title doesn't
    # already carry it (X og:title is often just 'Nick on X').
    my $line = $title;
    if (defined $tweet_text && $tweet_text ne '') {
        my $probe = substr($tweet_text, 0, 40);
        if (index(lc($line), lc($probe)) < 0) {
            my $t = length($tweet_text) > 200 ? substr($tweet_text, 0, 197) . '...' : $tweet_text;
            $t =~ s/[\r\n]+/ /g;
            $line .= qq{: "$t"};
        }
    }
    # mb494: engagement stats from the fxtwitter fast path
    if ((defined $fx_likes && $fx_likes =~ /^\d+$/ && $fx_likes > 0)
        || (defined $fx_rts && $fx_rts =~ /^\d+$/ && $fx_rts > 0)) {
        my @st;
        push @st, _x_compact_count($fx_likes) . ' likes' if defined $fx_likes && $fx_likes > 0;
        push @st, _x_compact_count($fx_rts)   . ' RTs'   if defined $fx_rts   && $fx_rts > 0;
        $line .= ' (' . join(', ', @st) . ')' if @st;
    }

    my $msg = "$badge\x0f " . substr($line, 0, 300);

    # IMP10/fix: cache the formatted message, not just a boolean.
    # That way repeated X/Twitter URLs avoid Chromium but still produce the same
    # user-visible IRC output when the generic URL anti-repeat cache allows it.
    $tw_cache->{$tw_cache_key} = { ts => time(), msg => $msg };

    Mediabot::Helpers::botPrivmsg($self, $channel, "($nick) $msg");
    return 1;
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
