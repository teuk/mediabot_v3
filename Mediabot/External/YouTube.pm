package Mediabot::External::YouTube;
# =============================================================================
# Mediabot::External::YouTube — YouTube, Weather, Fortnite
# =============================================================================
# mb99-R1: extrait de Mediabot::External.
# =============================================================================

use strict;
use warnings;
use Exporter 'import';
use JSON::MaybeXS;
use URI::Escape qw(uri_escape_utf8);
use String::IRC;
use Encode qw(encode decode);

our $VERSION = '1.00';

use constant YT_CACHE_TTL => 300;

our @EXPORT_OK = qw(
    getYoutubeDetails
    _youtube_html_fallback
    displayYoutubeDetails
    displayWeather_ctx
    _irc_color
    _yt_text
    _yt_sep
    _yt_meta
    _yt_link
    _yt_format_duration
    _yt_duration_seconds
    _yt_label
    _is_youtube_url
    youtubeSearch_ctx
    getFortniteId
    fortniteStats_ctx
    ytSearch_ctx
);

sub getYoutubeDetails {
    my ($self, $sText) = @_;

    my $conf = $self->{conf};
    my $sYoutubeId;

    $self->{logger}->log(3, "getYoutubeDetails() $sText");

    if ($sText =~ m{https?://(?:www\.|m\.|music\.)?youtube\.[^/]+/watch[^\s]*[?&]v=([A-Za-z0-9_-]{11})}i) {
        $sYoutubeId = $1;
    }
    elsif ($sText =~ m{https?://(?:www\.|m\.)?youtube\.[^/]+/shorts/([A-Za-z0-9_-]{11})}i) {
        $sYoutubeId = $1;
    }
    elsif ($sText =~ m{https?://(?:www\.|m\.)?youtube\.[^/]+/live/([A-Za-z0-9_-]{11})}i) {
        $sYoutubeId = $1;
    }
    elsif ($sText =~ m{https?://(?:www\.)?youtube(?:-nocookie)?\.com/embed/([A-Za-z0-9_-]{11})}i) {
        $sYoutubeId = $1;
    }
    elsif ($sText =~ m{https?://youtu\.be/([A-Za-z0-9_-]{11})}i) {
        $sYoutubeId = $1;
    }

    unless (defined $sYoutubeId && $sYoutubeId ne '') {
        $self->{logger}->log(3, "getYoutubeDetails() sYoutubeId could not be determined");
        return undef;
    }

    $self->{logger}->log(4, "getYoutubeDetails() sYoutubeId = $sYoutubeId");

    my $APIKEY = $conf->get('main.YOUTUBE_APIKEY');
    unless (defined $APIKEY && $APIKEY ne '') {
        $self->{logger}->log(1, "getYoutubeDetails() API Youtube V3 DEV KEY not set in " . $self->{config_file});
        $self->{logger}->log(1, "getYoutubeDetails() section [main]");
        $self->{logger}->log(1, "getYoutubeDetails() YOUTUBE_APIKEY=key");
        return undef;
    }

    my $yt_url = "https://www.googleapis.com/youtube/v3/videos"
               . "?id=$sYoutubeId&key=$APIKEY&part=snippet,contentDetails,statistics,status";

    my $http = Mediabot::External::_make_http(timeout => 10);
    my $res  = eval { $http->get($yt_url); } // { success => 0, status => 0, reason => $@ };

    unless ($res->{success}) {
        $self->{logger}->log(3, "getYoutubeDetails() HTTP error $res->{status} for $yt_url");
        return undef;
    }

    my $json_details = $res->{content};
    unless (defined $json_details && $json_details ne '') {
        $self->{logger}->log(3, "getYoutubeDetails() empty response for: $yt_url");
        return undef;
    }

    $self->{logger}->log(5, "getYoutubeDetails() raw: $json_details");
    $self->{logger}->log(5, "getYoutubeDetails() json_details : $json_details");

    my $sYoutubeInfo = eval { decode_json($json_details) };
    if ($@ || !ref($sYoutubeInfo)) {
        $self->{logger}->log(3, "getYoutubeDetails() JSON decode error: $@");
        return undef;
    }

    my @items = ref($sYoutubeInfo->{items}) eq 'ARRAY'
        ? @{ $sYoutubeInfo->{items} }
        : ();

    $self->{logger}->log(4, "getYoutubeDetails() items length : " . scalar(@items));

    unless (@items && ref($items[0]) eq 'HASH') {
        $self->{logger}->log(3, "getYoutubeDetails() Invalid id or no usable item: $sYoutubeId");
        Mediabot::Helpers::noticeConsoleChan($self, "getYoutubeDetails() Invalid id : $sYoutubeId");
        return undef;
    }

    my $item           = $items[0];
    my $statistics     = ref($item->{statistics})     eq 'HASH' ? $item->{statistics}     : {};
    my $snippet        = ref($item->{snippet})        eq 'HASH' ? $item->{snippet}        : {};
    my $localized      = ref($snippet->{localized})   eq 'HASH' ? $snippet->{localized}   : {};
    my $contentDetails = ref($item->{contentDetails}) eq 'HASH' ? $item->{contentDetails} : {};

    my $sTitle     = $localized->{title} // $snippet->{title} // '';
    my $sDuration  = $contentDetails->{duration} // '';
    my $view_count = $statistics->{viewCount};

    # mb360-R1: vues lisibles (1.2M/45k) via le helper partagé, au lieu du nombre
    # brut — cohérent avec displayYoutubeDetails.
    my $sViewCount = "views " . _yt_format_views($view_count);

    # A4: single combined log entry (removed duplicate sDuration log)
    $self->{logger}->log(4, "getYoutubeDetails() title=" . ($sTitle || "?") . " duration=" . ($sDuration || "?"));
    $self->{logger}->log(4, "getYoutubeDetails() sViewCount : $sViewCount");
    $self->{logger}->log(4, "getYoutubeDetails() sTitle : $sTitle");

    unless ($sTitle ne '' && $sDuration ne '') {
        $self->{logger}->log(4, "getYoutubeDetails() one of the youtube fields is undef or empty");
        return undef;
    }

    my $sDisplayDuration = _yt_format_duration($sDuration);
    my $duration_seconds = _yt_duration_seconds($sDuration);

    unless ($sDisplayDuration ne '') {
        $self->{logger}->log(4, "getYoutubeDetails() duration could not be formatted: $sDuration");
        return undef;
    }

    if (($sTitle =~ tr/A-Z//) > 20) {
        $sTitle = ucfirst(lc($sTitle));
    }

    my $sMsgSong = _yt_label();
    $sMsgSong .= _yt_text(" $sTitle ");
    $sMsgSong .= _yt_sep("- ");
    $sMsgSong .= _yt_meta("$sDisplayDuration ");
    $sMsgSong .= _yt_sep("- ");
    $sMsgSong .= _yt_meta("$sViewCount");

    $sMsgSong =~ s/\r//g;
    $sMsgSong =~ s/\n//g;

    return ($duration_seconds, $sMsgSong);
}

# Display Youtube details

# ---------------------------------------------------------------------------
# _youtube_html_fallback($self, $nick, $channel, $url, $video_id)
# Called when the YouTube Data API returns no items (geo-restricted, private,
# age-restricted, or quota exceeded). Scrapes the page og:title as a
# best-effort fallback — works well for Shorts.
# ---------------------------------------------------------------------------

sub _youtube_html_fallback {
    my ($self, $nick, $channel, $url, $video_id) = @_;

    $self->{logger}->log(3, "_youtube_html_fallback() trying oEmbed for $video_id");

    # YouTube oEmbed API — no API key required, works for all video types
    # including Shorts, Live, and geo-restricted videos.
    # Returns JSON with title and author_name.
    # Pass the original URL directly to oEmbed — it handles watch, shorts, live
    # uri_escape_utf8 encodes only unsafe chars, keeping :/? readable for debug
    my $oembed_base = ($url =~ m{youtu\.be|shorts|live}i)
                    ? $url    # keep shorts/live/short-link as-is
                    : "https://www.youtube.com/watch?v=$video_id";
    my $oembed_url = 'https://www.youtube.com/oembed?format=json&url='
                   . uri_escape_utf8($oembed_base);

    my $http = Mediabot::External::_make_http(timeout => 8, max_size => 64 * 1024);
    my $res  = eval { $http->get($oembed_url); } // { success => 0, status => 0, reason => $@ };

    unless ($res->{success}) {
        if (($res->{status} // 0) == 404) {
            $self->{logger}->log(3, "_youtube_html_fallback() oEmbed 404 — video $video_id does not exist or is private");
        } else {
            $self->{logger}->log(3, "_youtube_html_fallback() oEmbed HTTP $res->{status} for $video_id");
        }
        return undef;
    }

    my $data = eval { decode_json($res->{content}) };
    if ($@ || ref($data) ne 'HASH') {
        $self->{logger}->log(3, "_youtube_html_fallback() oEmbed JSON parse/structure error: $@");
        return undef;
    }

    my $title       = $data->{title}       // '';
    my $author_name = $data->{author_name} // '';

    unless ($title ne '') {
        $self->{logger}->log(3, "_youtube_html_fallback() oEmbed returned no title for $video_id");
        return undef;
    }

    $title       = Mediabot::External::_decode_html($title);
    $author_name = Mediabot::External::_decode_html($author_name);

    $self->{logger}->log(3, "_youtube_html_fallback() oEmbed title='$title' author='$author_name'");

    my $msg = _yt_label();
    $msg .= _yt_text(" $title ");
    if ($author_name ne '') {
        $msg .= _yt_sep("- ");
        $msg .= _yt_meta("by $author_name");
    }

    Mediabot::Helpers::botPrivmsg($self, $channel, "($nick) $msg");
    return 1;
}


sub displayYoutubeDetails {
    my ($self, $message, $sNick, $sChannel, $sText) = @_;

    my $conf = $self->{conf};
    $self->{logger}->log(3, "displayYoutubeDetails() $sText");

    # --- Extraction du video ID ---
    my $sYoutubeId;
    if    ($sText =~ m{https?://(?:www\.|m\.|music\.)?youtube\.[^/]+/watch[^\s]*[?&]v=([A-Za-z0-9_-]{11})}i) {
        $sYoutubeId = $1;
    }
    elsif ($sText =~ m{https?://(?:www\.|m\.)?youtube\.[^/]+/shorts/([A-Za-z0-9_-]{11})}i) {
        $sYoutubeId = $1;
    }
    elsif ($sText =~ m{https?://(?:www\.|m\.)?youtube\.[^/]+/live/([A-Za-z0-9_-]{11})}i) {
        $sYoutubeId = $1;
    }
    elsif ($sText =~ m{https?://(?:www\.)?youtube(?:-nocookie)?\.com/embed/([A-Za-z0-9_-]{11})}i) {
        $sYoutubeId = $1;
    }
    elsif ($sText =~ m{https?://youtu\.be/([A-Za-z0-9_-]{11})}i) {
        $sYoutubeId = $1;
    }

    unless (defined($sYoutubeId) && $sYoutubeId ne '') {
        $self->{logger}->log(3, "displayYoutubeDetails() sYoutubeId could not be determined");
        return undef;
    }

    $self->{logger}->log(4, "displayYoutubeDetails() sYoutubeId = $sYoutubeId");


    # S5/cache: serve from cache if fresh (TTL = YT_CACHE_TTL seconds)
    my $now = time();
    my $yt_cache = $self->{_yt_cache}{$sYoutubeId};
    if ($yt_cache && ($now - $yt_cache->{ts}) < YT_CACHE_TTL) {
        $self->{logger}->log(4, "displayYoutubeDetails() cache hit for $sYoutubeId");
        Mediabot::Helpers::botPrivmsg($self, $sChannel, "($sNick) $yt_cache->{msg}");
        return 1;
    }

    my $APIKEY = $conf->get('main.YOUTUBE_APIKEY');
    unless (defined($APIKEY) && $APIKEY ne '') {
        $self->{logger}->log(1, "displayYoutubeDetails() API Youtube V3 DEV KEY not set in " . $self->{config_file});
        $self->{logger}->log(1, "displayYoutubeDetails() section [main] YOUTUBE_APIKEY=key");
        return undef;
    }

    # --- Appel HTTP::Tiny ---
    my $url = "https://www.googleapis.com/youtube/v3/videos"
            . "?id=$sYoutubeId&key=$APIKEY&part=snippet,contentDetails,statistics,status";

    my $http     = Mediabot::External::_make_http(timeout => 8);
    my $response = eval { $http->get($url); } // { success => 0, status => 0, reason => $@ };

    unless ($response->{success}) {
        $self->{logger}->log(3, "displayYoutubeDetails() HTTP error $response->{status} for $sYoutubeId");
        return undef;
    }

    my $json_details = $response->{content};
    unless (defined($json_details) && $json_details ne '') {
        $self->{logger}->log(3, "displayYoutubeDetails() empty response for $sYoutubeId");
        return undef;
    }

    $self->{logger}->log(5, "displayYoutubeDetails() json_details : $json_details");

    my $sYoutubeInfo = eval { decode_json($json_details) };
    if ($@ || !ref($sYoutubeInfo)) {
        $self->{logger}->log(3, "displayYoutubeDetails() JSON decode error: $@");
        return undef;
    }

    my @fTyoutubeItems = ref($sYoutubeInfo->{items}) eq 'ARRAY'
        ? @{ $sYoutubeInfo->{items} }
        : ();

    $self->{logger}->log(4, "displayYoutubeDetails() tYoutubeItems length : " . $#fTyoutubeItems);

    unless (@fTyoutubeItems && ref($fTyoutubeItems[0]) eq 'HASH') {
        $self->{logger}->log(3, "displayYoutubeDetails() API returned no usable items for $sYoutubeId — trying HTML fallback");
        return _youtube_html_fallback($self, $sNick, $sChannel, $sText, $sYoutubeId);
    }

    my $item          = $fTyoutubeItems[0];
    my $statistics    = ref($item->{statistics})     eq 'HASH' ? $item->{statistics}     : {};
    my $snippet       = ref($item->{snippet})        eq 'HASH' ? $item->{snippet}        : {};
    my $localized     = ref($snippet->{localized})   eq 'HASH' ? $snippet->{localized}   : {};
    my $contentDetails = ref($item->{contentDetails}) eq 'HASH' ? $item->{contentDetails} : {};

    # Z5 / mb360-R1: vues en format lisible (1.2M, 45k, etc.) via le helper
    # partagé _yt_format_views (sortie identique à l'ancien bloc inline).
    my $raw_views = $statistics->{viewCount} // 0;
    my $sViewCount = "views " . _yt_format_views($raw_views);
    my $sTitle        = $localized->{title}          // $snippet->{title} // '';
    my $schannelTitle = $snippet->{channelTitle}     // '';
    my $sDuration     = $contentDetails->{duration}  // '';

    # A2: single log entry for all YouTube fields
    $self->{logger}->log(4, "displayYoutubeDetails() duration=$sDuration views=$sViewCount title=$sTitle channel=$schannelTitle");

    unless ($sTitle ne '' && $sDuration ne '' && $sViewCount ne '') {
        $self->{logger}->log(3, "displayYoutubeDetails() one of the youtube field is undef or empty");
        return undef;
    }

    # --- Formatage de la durée (PT1H23M45S) ---
    # mb315-R1: utilise le helper partagé _yt_format_duration au lieu de re-coder
    # le parse ISO 8601 à la main. getYoutubeDetails() et youtubeSearch_ctx()
    # passaient déjà par le helper ; displayYoutubeDetails() était le dernier
    # chemin à dupliquer la logique (mêmes regex H/M/M/S, même libellé "mn", même
    # strip final), donc le seul exposé à une divergence future "fix d'un côté,
    # oublié de l'autre". Sortie identique pour toutes les durées YouTube réelles.
    my $sDisplayDuration = _yt_format_duration($sDuration);

    $self->{logger}->log(4, "displayYoutubeDetails() sDisplayDuration : $sDisplayDuration");

    # --- Normalisation des majuscules excessives ---
    if (($sTitle        =~ tr/A-Z//) > 20) { $sTitle        = ucfirst(lc($sTitle)); }
    if (($schannelTitle =~ tr/A-Z//) > 20) { $schannelTitle = ucfirst(lc($schannelTitle)); }

    # --- Formatage IRC coloré ---
    my $sMsgSong = _yt_label();
    $sMsgSong   .= _yt_text(" $sTitle ");

    # mb315-R2: n'affiche le bloc durée que si elle est non vide. _yt_format_duration
    # renvoie '' pour une durée nulle (PT0S), ce que YouTube renvoie pour un live en
    # cours ou une première. Sans cette garde on obtiendrait un slot vide encadré de
    # séparateurs orphelins (« Titre -  - views … »). youtubeSearch_ctx() applique
    # déjà exactement la même garde ; on aligne displayYoutubeDetails() dessus, ce qui
    # rend l'affichage des lives propre au passage.
    if (defined $sDisplayDuration && $sDisplayDuration ne '') {
        $sMsgSong .= _yt_sep("- ");
        $sMsgSong .= _yt_meta("$sDisplayDuration ");
    }

    $sMsgSong   .= _yt_sep("- ");
    $sMsgSong   .= _yt_meta("$sViewCount ");
    $sMsgSong   .= _yt_sep("- ");
    $sMsgSong   .= _yt_meta("by $schannelTitle");

    $sMsgSong =~ s/\r|\n//g;

    # S5/cache: store result
    $self->{_yt_cache}{$sYoutubeId} = { ts => time(), msg => $sMsgSong };
    # Evict entries older than YT_CACHE_TTL * 10 to prevent unbounded growth
    for my $vid (keys %{ $self->{_yt_cache} // {} }) {
        delete $self->{_yt_cache}{$vid}
            if (time() - ($self->{_yt_cache}{$vid}{ts} // 0)) > YT_CACHE_TTL * 10;
    }

    Mediabot::Helpers::botPrivmsg($self, $sChannel, "($sNick) $sMsgSong");

    return 1;
}

# Weather command using wttr.in

sub displayWeather_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel; # may be undef in private
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # Require to be used in channel (your original behavior)
    unless (defined $channel && $channel =~ /^#/) {
        Mediabot::Helpers::botNotice($self, $nick, "Syntax (in channel): weather <City|City,CC|lat,lon>");
        return;
    }

    # Respect your chanset gate: Weather
    my $id_chanset_list = Mediabot::External::getIdChansetList($self, "Weather");
    return unless defined $id_chanset_list;

    my $id_channel_set = Mediabot::External::getIdChannelSet($self, $channel, $id_chanset_list);
    return unless defined $id_channel_set;

    my $q = join(' ', grep { defined && $_ ne '' } @args);
    $q =~ s/^\s+|\s+$//g;

    unless ($q ne '') {
        Mediabot::Helpers::botNotice($self, $nick, "Syntax (no accents): weather <City|City,CC|lat,lon>");
        return;
    }

    # Normalize input a bit:
    # - allow "Paris FR" => "Paris,FR"
    # - keep "lat,lon"
    my $location = $q;
    if ($location !~ /,/ && $location =~ /\s+([A-Za-z]{2})$/) {
        my $cc = $1;
        $location =~ s/\s+[A-Za-z]{2}$/,$cc/;
    }
    $location =~ s/\s+/,/g if $location =~ /^[^,]+ [^,]+$/ && $location !~ /^\s*[-+]?\d/; # "New York" -> "New,York"
    $location =~ s/^\s+|\s+$//g;

    # Cache (keyed by location)
    my $cache_key = lc($location);
    $self->{_weather_cache} ||= {};
    my $cache = $self->{_weather_cache}{$cache_key};

    my $now = time();
    my $ttl_ok = 180;  # 3 minutes
    my $ttl_stale = 900; # 15 minutes (fallback if provider unhappy)

    if ($cache && ($now - ($cache->{ts}||0) <= $ttl_ok) && ($cache->{text}||'') ne '') {
        Mediabot::Helpers::botPrivmsg($self, $channel, $cache->{text});
        return 1;
    }

    # Build wttr request
    # A bit richer than before, still short:
    # %l location, %c icon, %t temp, %f feelslike, %h humidity, %w wind, %p precip
    my $format = '%l: %c %t (feels %f) | 💧%h | 🌬%w | ☔%p';

    my $encoded = uri_escape_utf8($location);
    my $url = "https://wttr.in/$encoded?format=" . uri_escape_utf8($format) . "&m";

    my $project_url = eval { $self->{conf}->get('main.MAIN_PROG_URL') }
        || 'https://github.com/teuk/mediabot_v3';

    my $weather_agent = "mediabot_v3 weather/1.0 (+$project_url)";

    my $http = Mediabot::External::_make_http(
        timeout    => 4,
        agent      => $weather_agent,
        verify_SSL => 1,   # B1/A3: override Mediabot::External::_make_http default (0) for weather
    );

    my $res = eval { $http->get($url, {
        headers => {
            'Accept'          => 'text/plain',
            'Accept-Language' => 'fr-FR,fr;q=0.9,en;q=0.5',
        }
    }) } // { success => 0, status => 0, reason => $@ };

    # Helper to use cached text when provider is flaky
    my $use_cache_or_msg = sub {
        my ($msg) = @_;
        if ($cache && ($now - ($cache->{ts}||0) <= $ttl_stale) && ($cache->{text}||'') ne '') {
            Mediabot::Helpers::botPrivmsg($self, $channel, $cache->{text} . "  (cached)");
        } else {
            Mediabot::Helpers::botPrivmsg($self, $channel, $msg);
        }
    };

    unless ($res && $res->{success}) {
        my $code = $res ? ($res->{status} // '??') : '??';
        $self->{logger}->log(2, "displayWeather_ctx(): wttr HTTP failure code=$code url=$url");
        $use_cache_or_msg->("Weather service unavailable (HTTP $code), try again later.");
        return;
    }

    my $line = $res->{content} // '';
    $line =~ s/^\s+|\s+$//g;
    $line =~ s/\r//g;

    # wttr sometimes replies with “Unknown location” or throttling texts
    if ($line eq '' || $line =~ /^Unknown location/i || $line =~ /try again later/i || $line =~ /Service unavailable/i) {
        $self->{logger}->log(2, "displayWeather_ctx(): wttr unhappy reply for '$location': '$line'");
        $use_cache_or_msg->("No answer from wttr.in for '$location'. Try again later.");
        return;
    }

    # Save cache + reply
    $self->{_weather_cache}{$cache_key} = { ts => $now, text => $line };

    # Evict cache entries older than ttl_stale to prevent unbounded growth.
    # This runs lazily at write time rather than on a timer.
    my $max_age = 900;  # 15 minutes (ttl_stale)
    my $max_entries = 200;
    my $cache_ref = $self->{_weather_cache};
    if (scalar(keys %$cache_ref) > $max_entries) {
        for my $k (keys %$cache_ref) {
            delete $cache_ref->{$k}
                if ($now - ($cache_ref->{$k}{ts} // 0)) > $max_age;
        }
    }
    Mediabot::Helpers::botPrivmsg($self, $channel, $line);
    Mediabot::Helpers::logBot($self, $ctx->message, $channel, "weather", $location);

    return 1;
}

# Display URL title
# =============================================================================
# URL handling — displayUrlTitle and helpers
# Architecture:
#   displayUrlTitle() → dispatch by URL type → specific handler
#
# Chanset guards:
#   Youtube    → YouTube (watch/shorts/live/youtu.be/youtube-nocookie)
#   UrlTitle   → Spotify, Instagram, generic pages
#   AppleMusic → Apple Music
# =============================================================================

# ---------------------------------------------------------------------------
# _yt_label — shared YouTube IRC label
# ---------------------------------------------------------------------------

sub _irc_color {
    my ($text, $fg) = @_;
    # A3: clamp fg to valid mIRC color range [0-15]
    $fg = int($fg) % 16 if defined $fg && $fg =~ /^\d+$/;

    $text = '' unless defined $text;
    return $text unless defined $fg && $fg ne '';

    # Foreground only. No background here.
    # This keeps title, duration, views, channel and URL transparent.
    return sprintf("\x03%02d", $fg) . $text . "\x0f";
}


sub _yt_text {
    # B1/A1: color 0 = white — invisible on light themes.
    # Use 14 (grey) which is readable on both light and dark IRC backgrounds.
    return _irc_color($_[0], 14);
}


sub _yt_sep {
    return _irc_color($_[0], 7);      # orange foreground, transparent background
}


sub _yt_meta {
    return _irc_color($_[0], 14);     # grey foreground, transparent background
}


# MB324: YouTube search URLs use a foreground-only blue plus underline.
# No background color is set, so the link remains readable on light and dark
# IRC themes. The final reset clears both color and underline cleanly.
sub _yt_link {
    my ($url) = @_;
    $url = '' unless defined $url;

    return "\x0302\x1F" . $url . "\x0F";
}


# mb360-R1: formatage des vues YouTube partagé (1.2M / 45k / brut / "?").
# getYoutubeDetails() affichait le nombre BRUT ("views 1234567") tandis que
# displayYoutubeDetails() le formatait en lisible (1.2M, 45k) : deux rendus
# différents pour la même donnée, et un risque de divergence "fix d'un côté,
# oublié de l'autre" — exactement ce que _yt_format_duration a réglé pour la
# durée (mb315-R1). On centralise ici la logique (identique à celle, inline,
# de displayYoutubeDetails). Renvoie uniquement la valeur formatée, sans le
# préfixe "views " (laissé aux appelants).
sub _yt_format_views {
    my ($raw) = @_;
    return '?' unless defined($raw) && $raw =~ /^\d+$/ && $raw > 0;
    return sprintf('%.1fM', $raw / 1_000_000) if $raw >= 1_000_000;
    return sprintf('%.1fk', $raw / 1_000)     if $raw >= 1_000;
    return $raw;
}

# mb398-B1: parsing ISO-8601 partagé, avec le composant JOURS. Les durées
# YouTube > 24h existent (streams/archives) et arrivent en "P1DT2H3M4S" —
# l'ancien parsing ("PT" strip + regex H/M/S) ignorait le D : affichage et
# secondes faux de 86400s par jour ("P3D" seul donnait même '' / 0).
# Le M n'est lu qu'APRÈS le "T" (avant le T, M = mois en ISO-8601).
sub _yt_parse_duration {
    my ($iso) = @_;
    return (0, 0, 0, 0) unless defined $iso && $iso ne '';
    my ($date_part, $time_part) = $iso =~ /\AP([^Tt]*)(?:[Tt](.*))?\z/;
    return (0, 0, 0, 0) unless defined $date_part || defined $time_part;
    my ($d)   = ($date_part // '') =~ /(\d+)D/i;
    my ($h)   = ($time_part // '') =~ /(\d+)H/i;
    my ($m)   = ($time_part // '') =~ /(\d+)M/i;
    my ($sec) = ($time_part // '') =~ /(\d+)S/i;
    return ($d || 0, $h || 0, $m || 0, $sec || 0);
}

sub _yt_format_duration {
    my ($iso) = @_;

    return '' unless defined $iso && $iso ne '';

    my ($d, $h, $m, $sec) = _yt_parse_duration($iso);

    return '' if !$d && !$h && !$m && !$sec;

    my $out = '';
    $out .= "${d}d "   if $d;
    $out .= "${h}h "   if $h;
    $out .= "${m}mn "  if $m;
    $out .= "${sec}s"  if $sec;
    $out =~ s/\s+$//;

    return $out;
}


sub _yt_duration_seconds {
    my ($iso) = @_;

    return 0 unless defined $iso && $iso ne '';

    # mb398-B1: via le parseur partagé (composant jours inclus).
    my ($d, $h, $m, $sec) = _yt_parse_duration($iso);

    return ($d * 86400) + ($h * 3600) + ($m * 60) + $sec;
}


sub _yt_label {
    # YouTube badge:
    #   [You  => black foreground on white background
    #   Tube  => white foreground on red background
    #   ]     => black foreground on white background
    #
    # The reset at the end is mandatory: only the badge keeps a background.
    # Everything after it must stay transparent.
    return "\x0301,00[You\x0300,04Tube\x0301,00]\x0f";
}

# ---------------------------------------------------------------------------
# _extract_url($text) — pull the first URL out of a message
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Mediabot::External::_make_http(%opts) — shared HTTP::Tiny factory with SSL bypass
# HTTP 599 on HTTPS URLs usually means IO::Socket::SSL is present but
# certificate verification fails. SSL_options forces no-verify mode.
# ---------------------------------------------------------------------------

sub _is_youtube_url {
    # mb406-B1: motifs ancrés en début d'URL (\A) — une URL YouTube imbriquée
    # dans la query d'un autre site ne doit pas router vers le handler YouTube.
    my ($url) = @_;
    return undef unless defined $url;

    # Standard watch URL on all subdomains
    if ($url =~ m{\Ahttps?://(?:www\.|m\.|music\.)?youtube\.(?:com|fr|de|co\.uk|co\.jp|be)/watch[^\s]*[?&]v=([A-Za-z0-9_-]{11})}i) {
        return $1;
    }
    # Shorts
    if ($url =~ m{\Ahttps?://(?:www\.|m\.)?youtube\.(?:com|fr|de|co\.uk|co\.jp)/shorts/([A-Za-z0-9_-]{11})}i) {
        return $1;
    }
    # Live
    if ($url =~ m{\Ahttps?://(?:www\.|m\.)?youtube\.(?:com|fr|de|co\.uk|co\.jp)/live/([A-Za-z0-9_-]{11})}i) {
        return $1;
    }
    # Embed
    if ($url =~ m{\Ahttps?://(?:www\.)?youtube(?:-nocookie)?\.com/embed/([A-Za-z0-9_-]{11})}i) {
        return $1;
    }
    # youtu.be short link
    if ($url =~ m{\Ahttps?://youtu\.be/([A-Za-z0-9_-]{11})}i) {
        return $1;
    }
    return undef;
}


# ---------------------------------------------------------------------------
# _handle_instagram($self, $message, $nick, $channel, $url)
# Parses Instagram page for a title. Instagram's
# ---------------------------------------------------------------------------

# Parse the YouTube search endpoint without performing network I/O.
sub _youtube_search_parse_ids {
    my ($content) = @_;

    return [] unless defined($content) && !ref($content) && $content ne '';

    require JSON::PP;
    my $data = eval { JSON::PP::decode_json($content) };
    return [] if $@ || ref($data) ne 'HASH' || ref($data->{items}) ne 'ARRAY';

    my (@ids, %seen);
    for my $item (@{ $data->{items} }) {
        next unless ref($item) eq 'HASH' && ref($item->{id}) eq 'HASH';

        my $video_id = $item->{id}{videoId};
        next unless defined($video_id)
            && !ref($video_id)
            && $video_id =~ /\A[A-Za-z0-9_-]{11}\z/;
        next if $seen{$video_id}++;

        push @ids, $video_id;
        last if @ids >= 3;
    }

    return \@ids;
}

# Parse the metadata endpoint and keep only requested video IDs.
sub _youtube_search_parse_videos {
    my ($content, $requested_ids) = @_;

    return {} unless defined($content) && !ref($content) && $content ne '';
    return {} unless ref($requested_ids) eq 'ARRAY';

    my %wanted = map { $_ => 1 } grep {
        defined($_) && !ref($_) && /\A[A-Za-z0-9_-]{11}\z/
    } @$requested_ids;

    require JSON::PP;
    my $data = eval { JSON::PP::decode_json($content) };
    return {} if $@ || ref($data) ne 'HASH' || ref($data->{items}) ne 'ARRAY';

    my %video_by_id;
    for my $item (@{ $data->{items} }) {
        next unless ref($item) eq 'HASH';

        my $id = $item->{id};
        next unless defined($id) && !ref($id) && $wanted{$id};

        my $snippet = ref($item->{snippet})        eq 'HASH' ? $item->{snippet}        : {};
        my $details = ref($item->{contentDetails}) eq 'HASH' ? $item->{contentDetails} : {};
        my $stats   = ref($item->{statistics})     eq 'HASH' ? $item->{statistics}     : {};

        my $title = $snippet->{title};
        $title = '' unless defined($title) && !ref($title);

        my $channel_title = $snippet->{channelTitle};
        $channel_title = '' unless defined($channel_title) && !ref($channel_title);

        my $duration = $details->{duration};
        $duration = '' unless defined($duration) && !ref($duration);

        my $views = $stats->{viewCount};
        $views = '' unless defined($views) && !ref($views) && $views =~ /\A\d+\z/;

        $video_by_id{$id} = {
            id            => $id,
            title         => $title,
            channel_title => $channel_title,
            duration      => $duration,
            views         => $views,
        };
    }

    return \%video_by_id;
}

# Perform both YouTube API calls synchronously. Runtime commands invoke this
# helper only inside _youtube_search_fetch_async().
sub _youtube_search_fetch_sync {
    my ($api_key, $query_txt) = @_;

    return { ok => 0, status => 'invalid_request' }
        unless defined($api_key) && !ref($api_key) && $api_key ne ''
            && defined($query_txt) && !ref($query_txt) && $query_txt ne '';

    my $q_enc = uri_escape_utf8($query_txt);
    my $search_url =
        'https://www.googleapis.com/youtube/v3/search'
        . '?part=snippet'
        . '&type=video'
        . '&maxResults=3'
        . "&q=$q_enc"
        . "&key=$api_key"
        . '&fields=items(id/videoId)';

    my $http_s = Mediabot::External::_make_http(
        timeout  => 10,
        max_size => 256 * 1024,
    );
    my $res_s = eval { $http_s->get($search_url) }
        // { success => 0, status => 0, reason => $@ };

    unless (ref($res_s) eq 'HASH' && $res_s->{success}) {
        return {
            ok     => 0,
            status => 'search_unavailable',
            detail => join(' ', grep { defined($_) && $_ ne '' }
                ($res_s->{status} // 0, $res_s->{reason} // '')),
        };
    }

    my $video_ids = _youtube_search_parse_ids($res_s->{content} // '');
    return { ok => 0, status => 'no_result' }
        unless @$video_ids;

    my $ids_enc = join(',', @$video_ids);
    my $videos_url =
        'https://www.googleapis.com/youtube/v3/videos'
        . "?id=$ids_enc"
        . "&key=$api_key"
        . '&part=snippet,contentDetails,statistics'
        . '&fields=items(id,snippet/title,snippet/channelTitle,contentDetails/duration,statistics/viewCount)';

    my $http_v = Mediabot::External::_make_http(
        timeout  => 10,
        max_size => 512 * 1024,
    );
    my $res_v = eval { $http_v->get($videos_url) }
        // { success => 0, status => 0, reason => $@ };

    unless (ref($res_v) eq 'HASH' && $res_v->{success}) {
        return {
            ok           => 0,
            status       => 'metadata_unavailable',
            fallback_url => "https://www.youtube.com/watch?v=$video_ids->[0]",
            detail       => join(' ', grep { defined($_) && $_ ne '' }
                ($res_v->{status} // 0, $res_v->{reason} // '')),
        };
    }

    my $video_by_id = _youtube_search_parse_videos(
        $res_v->{content} // '',
        $video_ids,
    );

    my @entries = map { $video_by_id->{$_} }
        grep { ref($video_by_id->{$_}) eq 'HASH' }
        @$video_ids;

    return {
        ok           => 0,
        status       => 'metadata_unavailable',
        fallback_url => "https://www.youtube.com/watch?v=$video_ids->[0]",
        detail       => 'no usable metadata returned',
    } unless @entries;

    return {
        ok      => 1,
        status  => 'ok',
        entries => \@entries,
    };
}

# MB320: the public YouTube search command must not perform two sequential
# Google API requests inside the IRC event loop. Run the blocking work in a
# child, consume a bounded JSON result asynchronously, and invoke the callback
# exactly once.
sub _youtube_search_fetch_async {
    my ($self, $api_key, $query_txt, $callback, %opts) = @_;

    return 0 unless ref($callback) eq 'CODE';

    my $timeout = $opts{timeout};
    $timeout = 22
        unless defined($timeout)
            && !ref($timeout)
            && $timeout =~ /\A\d+(?:\.\d+)?\z/;
    $timeout = 0.1 if $timeout < 0.1;
    $timeout = 30  if $timeout > 30;

    my $loop = eval { $self->getLoop };
    $loop ||= $self->{loop} if ref($self);

    my $fallback = { ok => 0, status => 'worker_failed' };

    unless ($loop && $loop->can('add') && $loop->can('remove')) {
        my $result = eval { _youtube_search_fetch_sync($api_key, $query_txt) };
        $result = $fallback unless ref($result) eq 'HASH';
        eval { $callback->($result); 1 };
        return 1;
    }

    # MB321: IO::Async owns SIGCHLD/process collection. Register the child with
    # watch_process() instead of polling waitpid() ourselves; otherwise the
    # loop and this helper can race to reap the same PID and turn a successful
    # worker into an immediate, detail-free worker_failed result.
    unless ($loop->can('watch_process')) {
        my $result = {
            ok     => 0,
            status => 'worker_setup_failed',
            detail => 'IO::Async loop does not support watch_process',
        };
        eval { $callback->($result); 1 };
        return 1;
    }

    require IO::Async::Stream;
    require IO::Async::Timer::Countdown;
    require JSON::PP;
    require POSIX;

    my $child_pid = open(my $pipe, '-|');

    unless (defined $child_pid) {
        my $detail = $! || 'fork/pipe setup failed';
        eval {
            $callback->({
                ok     => 0,
                status => 'worker_setup_failed',
                detail => "$detail",
            });
            1;
        };
        return 1;
    }

    if ($child_pid == 0) {
        my $result = eval { _youtube_search_fetch_sync($api_key, $query_txt) };
        if ($@) {
            my $error = $@;
            $error =~ s/\s+/ /g;
            $result = {
                ok     => 0,
                status => 'worker_exception',
                detail => $error,
            };
        }
        $result = $fallback unless ref($result) eq 'HASH';

        my $payload = eval { JSON::PP::encode_json($result) };
        if (!defined($payload) || ref($payload) || $payload eq '') {
            my $error = $@ || 'JSON encoding failed';
            $error =~ s/\s+/ /g;
            $payload = JSON::PP::encode_json({
                ok     => 0,
                status => 'worker_encode_failed',
                detail => $error,
            });
        }
        $payload = JSON::PP::encode_json({
            ok     => 0,
            status => 'worker_payload_too_large',
            detail => 'worker payload exceeded 64 KiB',
        }) if length($payload) > 64 * 1024;

        my $offset = 0;
        local $SIG{PIPE} = 'IGNORE';
        binmode(STDOUT, ':raw');

        while ($offset < length($payload)) {
            my $written = syswrite(
                STDOUT,
                $payload,
                length($payload) - $offset,
                $offset,
            );

            next if !defined($written) && $!{EINTR};
            last unless defined($written) && $written > 0;
            $offset += $written;
        }

        POSIX::_exit(0);
    }

    my $state = {
        output      => '',
        pipe_eof    => 0,
        child_done  => 0,
        finalized   => 0,
        timed_out   => 0,
        wait_status => undef,
        term_sent   => 0,
        kill_sent   => 0,
    };

    my ($stream, $timeout_timer, $kill_timer);
    my $finish;

    my $remove_timer = sub {
        my ($timer) = @_;
        return unless $timer;
        eval { $timer->stop };
        eval { $loop->remove($timer) };
    };

    $finish = sub {
        return if $state->{finalized};
        return unless $state->{child_done};
        return unless $state->{pipe_eof} || $state->{timed_out};

        $state->{finalized} = 1;

        $remove_timer->($timeout_timer);
        $remove_timer->($kill_timer);
        eval { $loop->remove($stream) } if $stream;
        eval { close $pipe };

        my $result = $fallback;
        my $status = $state->{wait_status} // 0;
        my $signal = $status & 127;
        my $exit   = ($status >> 8) & 255;

        if ($state->{timed_out}) {
            $result = {
                ok     => 0,
                status => 'worker_timeout',
                detail => "YouTube worker timed out (exit=$exit signal=$signal)",
            };
        }
        elsif ($signal || $exit != 0) {
            $result = {
                ok     => 0,
                status => 'worker_failed',
                detail => "YouTube worker exited abnormally (exit=$exit signal=$signal)",
            };
        }
        else {
            my $decoded = eval {
                JSON::PP::decode_json($state->{output} // '')
            };

            if (!$@ && ref($decoded) eq 'HASH'
                    && defined($decoded->{status})
                    && !ref($decoded->{status})) {
                $result = $decoded;
            }
            else {
                my $error = $@ || 'invalid or empty worker payload';
                $error =~ s/\s+/ /g;
                $result = {
                    ok     => 0,
                    status => 'worker_decode_failed',
                    detail => $error,
                };
            }
        }

        my $callback_ok = eval { $callback->($result); 1 };
        if (!$callback_ok && $self && ref($self) && $self->{logger}) {
            my $error = $@ || 'unknown callback failure';
            $error =~ s/\s+/ /g;
            $self->{logger}->log(1, "YouTube search async callback failed: $error");
        }

        $finish = undef;
    };

    my $watch_ok = eval {
        $loop->watch_process(
            $child_pid,
            sub {
                my ($pid, $wait_status) = @_;
                return if $state->{finalized};
                return unless defined($pid) && $pid == $child_pid;

                $state->{wait_status} = $wait_status;
                $state->{child_done}  = 1;
                $finish->();
            },
        );
        1;
    };

    unless ($watch_ok) {
        my $error = $@ || 'watch_process registration failed';
        $error =~ s/\s+/ /g;

        kill 'TERM', $child_pid;
        eval { close $pipe };
        eval {
            $callback->({
                ok     => 0,
                status => 'worker_setup_failed',
                detail => $error,
            });
            1;
        };
        return 1;
    }

    $timeout_timer = IO::Async::Timer::Countdown->new(
        delay     => $timeout,
        on_expire => sub {
            return if $state->{finalized} || $state->{child_done};

            $state->{timed_out} = 1;

            unless ($state->{term_sent}) {
                kill 'TERM', $child_pid;
                $state->{term_sent} = 1;
            }

            $kill_timer = IO::Async::Timer::Countdown->new(
                delay     => 0.5,
                on_expire => sub {
                    return if $state->{finalized} || $state->{child_done};

                    unless ($state->{kill_sent}) {
                        kill 'KILL', $child_pid;
                        $state->{kill_sent} = 1;
                    }
                },
            );

            $loop->add($kill_timer);
            $kill_timer->start;
        },
    );

    $loop->add($timeout_timer);
    $timeout_timer->start;

    $stream = IO::Async::Stream->new(
        read_handle => $pipe,
        on_read     => sub {
            my ($io, $buffref, $eof) = @_;

            if (length $$buffref) {
                my $remaining = (64 * 1024) - length($state->{output});
                $state->{output} .= substr($$buffref, 0, $remaining)
                    if $remaining > 0;
                $$buffref = '';
            }

            if ($eof && !$state->{pipe_eof}++) {
                eval { $loop->remove($io) };
                $finish->();
            }

            return 0;
        },
    );

    $loop->add($stream);
    return 1;
}

sub _youtube_search_format_entry {
    my ($info) = @_;
    return '' unless ref($info) eq 'HASH';

    my $video_id = $info->{id};
    return '' unless defined($video_id)
        && !ref($video_id)
        && $video_id =~ /\A[A-Za-z0-9_-]{11}\z/;

    my $title = $info->{title};
    $title = '' unless defined($title) && !ref($title);

    my $channel_title = $info->{channel_title};
    $channel_title = '' unless defined($channel_title) && !ref($channel_title);

    if (($title =~ tr/A-Z//) > 20) {
        $title = ucfirst(lc($title));
    }
    if (($channel_title =~ tr/A-Z//) > 20) {
        $channel_title = ucfirst(lc($channel_title));
    }

    my $dur_disp = _yt_format_duration($info->{duration} // '');
    my $views = $info->{views};
    my $views_disp = 'views ?';
    if (defined($views) && !ref($views) && $views =~ /\A\d+\z/) {
        $views_disp = 'views ' . (
            $views >= 1_000_000 ? sprintf('%.1fM', $views / 1_000_000)
          : $views >= 1_000     ? sprintf('%.1fk', $views / 1_000)
          :                       $views
        );
    }

    my $entry = _yt_text(" $title ");

    if ($dur_disp ne '') {
        $entry .= _yt_sep('- ');
        $entry .= _yt_meta("$dur_disp ");
    }

    $entry .= _yt_sep('- ');
    $entry .= _yt_meta("$views_disp ");

    if ($channel_title ne '') {
        $entry .= _yt_sep('- ');
        $entry .= _yt_meta("by $channel_title ");
    }

    $entry .= _yt_sep('- ');
    $entry .= _yt_link("https://www.youtube.com/watch?v=$video_id");

    $entry =~ s/[\r\n]+//g;
    return $entry;
}

sub youtubeSearch_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    unless (@args && defined($args[0]) && $args[0] ne '') {
        $ctx->reply_private('Syntax: yt <search>');
        return;
    }

    my $api_key = $self->{conf}->get('main.YOUTUBE_APIKEY');
    unless (defined($api_key) && $api_key ne '') {
        $self->{logger}->log(
            1,
            'youtubeSearch_ctx() YOUTUBE_APIKEY not set in '
                . $self->{config_file},
        );
        $ctx->reply_private('YouTube: API key is not configured.');
        return;
    }

    my $query_txt   = join(' ', @args);
    my $log_message = $ctx->message;
    my $log_channel = $ctx->channel // $nick // '';

    # MB323: restore the proven synchronous transport after the MB320/MB321
    # worker regression, and keep the MB320 parsers, size caps, formatting,
    # Context routing and defensive result validation.
    my $result = eval {
        _youtube_search_fetch_sync($api_key, $query_txt)
    };

    if ($@) {
        my $error = $@;
        $error =~ s/\s+/ /g;
        $result = {
            ok     => 0,
            status => 'search_exception',
            detail => $error,
        };
    }

    unless (ref($result) eq 'HASH') {
        $result = {
            ok     => 0,
            status => 'search_failed',
            detail => 'invalid search helper result',
        };
    }

    my $status = $result->{status} // 'search_failed';
    my $detail = $result->{detail};
    if (defined($detail) && !ref($detail) && $detail ne ''
            && $self->{logger}) {
        $detail =~ s/\s+/ /g;
        $self->{logger}->log(
            2,
            "youtubeSearch_ctx(): $status: $detail",
        );
    }

    if (!$result->{ok}) {
        if ($status eq 'no_result') {
            $ctx->reply("($nick) YouTube: no result.");
            return 1;
        }

        my $fallback_url = $result->{fallback_url};
        if (defined($fallback_url)
                && !ref($fallback_url)
                && $fallback_url =~ m{\Ahttps://www\.youtube\.com/watch\?v=[A-Za-z0-9_-]{11}\z}) {
            $ctx->reply("($nick) $fallback_url");
            return 1;
        }

        $ctx->reply("($nick) YouTube: service unavailable (search).");
        return 1;
    }

    my $entries = $result->{entries};
    unless (ref($entries) eq 'ARRAY') {
        $ctx->reply("($nick) YouTube: no result.");
        return 1;
    }

    my @formatted;
    for my $info (@$entries) {
        my $entry = _youtube_search_format_entry($info);
        push @formatted, $entry if $entry ne '';
        last if @formatted >= 3;
    }

    unless (@formatted) {
        $ctx->reply("($nick) YouTube: no result.");
        return 1;
    }

    for my $i (0 .. $#formatted) {
        my $rank = $i + 1;
        my $msg  = _yt_label();
        $msg    .= _yt_sep(' ' . $rank . '/' . scalar(@formatted) . ' ');
        $msg    .= $formatted[$i];
        $ctx->reply("($nick) $msg");
    }

    Mediabot::Helpers::logBot(
        $self,
        $log_message,
        $log_channel,
        'yt',
        $query_txt,
    );

    return 1;
}

# Return the Fortnite account id stored for a Mediabot user nickname.
# This is used by fortniteStats_ctx() before calling fortnite-api.com.

sub getFortniteId {
    my ($self, $sUser) = @_;

    return undef unless defined($sUser) && $sUser ne '';
    return undef unless $self->{dbh};

    my $sQuery = "SELECT fortniteid FROM USER WHERE nickname = ?";
    my $sth = $self->{dbh}->prepare($sQuery);

    unless ($sth) {
        $self->{logger}->log(1, "getFortniteId() SQL prepare error : " . $DBI::errstr . " Query : " . $sQuery)
            if $self->{logger};
        return undef;
    }

    unless ($sth->execute($sUser)) {
        $self->{logger}->log(1, "getFortniteId() SQL execute error : " . $DBI::errstr . " Query : " . $sQuery)
            if $self->{logger};
        $sth->finish;
        return undef;
    }

    my $fortniteid;
    if (my $ref = $sth->fetchrow_hashref()) {
        $fortniteid = $ref->{fortniteid};
    }

    $sth->finish;
    return $fortniteid;
}


# Fortnite stats:
#   f <username>
#
# Requires:
#   - Logged in
#   - Level >= User

sub fortniteStats_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my $message = $ctx->message;

    # Reply target (notice in private, privmsg in channel)
    my $is_private = (!defined($channel) || $channel eq '');
    my $reply_to   = $is_private ? $nick : $channel;

    # Normalize args (only accept ARRAY)
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
    unless (@args && defined $args[0] && $args[0] ne '') {
        Mediabot::Helpers::botNotice($self, $nick, "Syntax: f <username>");
        return;
    }

    # API key from config
    my $api_key = eval { $self->{conf}->get('fortnite.API_KEY') } // '';
    unless ($api_key) {
        $self->{logger}->log(1, "fortniteStats_ctx(): fortnite.API_KEY is undefined in config file");
        return;
    }

    # Auth + level checks (Context)
    my $user = $ctx->user || $self->Mediabot::External::get_user_from_message($message);
    unless ($user && $user->is_authenticated) {
        my $who = $user ? ($user->nickname // 'unknown') : 'unknown';
        my $msg = $message->prefix . " f command attempt (user $who is not logged in)";
        Mediabot::Helpers::noticeConsoleChan($self, $msg);
        Mediabot::Helpers::botNotice($self, $nick,
            "You must be logged to use this command - /msg "
          . $self->{irc}->nick_folded
          . " login username password"
        );
        Mediabot::Helpers::logBot($self, $message, undef, "f", $msg);
        return;
    }

    unless (eval { $user->has_level("User") }) {
        my $lvl = eval { $user->level_description } || eval { $user->level } || '?';
        my $msg = $message->prefix . " f command attempt (requires User for "
                . ($user->nickname // $nick) . " [$lvl])";
        Mediabot::Helpers::noticeConsoleChan($self, $msg);
        Mediabot::Helpers::botNotice($self, $nick, "This command is not available for your level. Contact a bot master.");
        Mediabot::Helpers::logBot($self, $message, undef, "f", $msg);
        return;
    }

    my $target_name = $args[0];

    # Resolve internal user + fortniteid (keep legacy helpers)
    my $id_user = Mediabot::External::getIdUser($self, $target_name);
    unless (defined $id_user) {
        Mediabot::Helpers::botNotice($self, $nick, "Undefined user $target_name");
        return;
    }

    my $account_id = getFortniteId($self, $target_name);
    unless (defined $account_id && $account_id ne '') {
        Mediabot::Helpers::botNotice($self, $nick, "Undefined fortniteid for user $target_name");
        return;
    }

    # Call API
    my $url = "https://fortnite-api.com/v2/stats/br/v2/$account_id";

    my $http = Mediabot::External::_make_http(timeout => 10);
    my $http_response = eval { $http->get(
        $url,
        { headers => { 'Authorization' => $api_key } }
    ) } // { success => 0, status => 0, reason => $@ };

    unless ($http_response->{success}) {
        $self->{logger}->log(3, "fortniteStats_ctx(): HTTP error $http_response->{status} $http_response->{reason}");
        Mediabot::Helpers::botPrivmsg($self, $reply_to, "Fortnite stats: service unavailable, try again later.");
        return;
    }

    my $json_details = $http_response->{content};
    unless (defined $json_details && $json_details ne '') {
        $self->{logger}->log(3, "fortniteStats_ctx(): empty API response for $target_name/$account_id");
        Mediabot::Helpers::botPrivmsg($self, $reply_to, "Fortnite stats: service unavailable, try again later.");
        return;
    }

    my $data = eval { decode_json($json_details) };
    if ($@ || ref($data) ne 'HASH') {
        $self->{logger}->log(3, "fortniteStats_ctx(): JSON decode/structure error: $@");
        Mediabot::Helpers::botPrivmsg($self, $reply_to, "Fortnite stats: unexpected API response.");
        return;
    }

    # API may return {status:..., error:...}
    if (exists $data->{status} && $data->{status} != 200) {
        my $err = $data->{error} // "API error";
        $self->{logger}->log(3, "fortniteStats_ctx(): API status=$data->{status} error=$err");
        Mediabot::Helpers::botPrivmsg($self, $reply_to, "Fortnite stats: $err");
        return;
    }

    my $payload = $data->{data};
    unless ($payload && ref($payload) eq 'HASH') {
        Mediabot::Helpers::botPrivmsg($self, $reply_to, "Fortnite stats: no data for this account.");
        return;
    }

    my $account    = ref($payload->{account})    eq 'HASH' ? $payload->{account}    : {};
    my $battlepass = ref($payload->{battlePass}) eq 'HASH' ? $payload->{battlePass} : {};
    my $stats      = ref($payload->{stats})      eq 'HASH' ? $payload->{stats}      : {};
    my $all_stats  = ref($stats->{all})          eq 'HASH' ? $stats->{all}          : {};

    # Some payloads are nested differently depending on API versions / modes.
    # Keep this defensive: API responses can be valid JSON but missing parts.
    #
    # Preferred:
    #   stats.all.overall
    #
    # Fallback:
    #   stats.all.solo / duo / trio / squad
    my $overall = {};

    if (ref($all_stats->{overall}) eq 'HASH') {
        $overall = $all_stats->{overall};
    }
    else {
        for my $mode (qw(solo duo trio squad)) {
            next unless ref($all_stats->{$mode}) eq 'HASH';

            $overall = $all_stats->{$mode};
            last;
        }
    }

    my $name        = $account->{name}       // $target_name;
    my $matches     = $overall->{matches}    // 0;
    my $wins        = $overall->{wins}       // 0;
    my $win_rate    = defined $overall->{winRate} ? $overall->{winRate} : 0;
    my $kills       = $overall->{kills}      // 0;
    my $kd          = defined $overall->{kd} ? $overall->{kd} : 0;
    my $top3        = $overall->{top3}       // 0;
    my $top5        = $overall->{top5}       // 0;
    my $top10       = $overall->{top10}      // 0;
    my $bp_level    = $battlepass->{level}   // 0;
    my $bp_progress = defined $battlepass->{progress} ? $battlepass->{progress} : 0;

    # Readable on dark/light: bold labels only (no background colors)
    my $user_tag = String::IRC->new('[' . $name . ']')->bold;

    my $line =
        "Fortnite -- $user_tag "
      . (String::IRC->new('Matches:')->bold . " $matches")
      . " | " . (String::IRC->new('Wins:')->bold . " $wins ($win_rate%)")
      . " | " . (String::IRC->new('Kills:')->bold . " $kills")
      . " | " . (String::IRC->new('K/D:')->bold . " $kd")
      . " | " . (String::IRC->new('BP:')->bold . " L$bp_level ($bp_progress%)")
      . " | " . (String::IRC->new('Top3/5/10:')->bold . " $top3/$top5/$top10");

    Mediabot::Helpers::botPrivmsg($self, $reply_to, $line);

    Mediabot::Helpers::logBot($self, $message, $channel, "f", @args);
    return 1;
}


# ------------------------------------------------------------------
# mb95-R1: CONSTANTS, ChatGPT, Claude, TMDB déplacés dans
# Mediabot::External::Claude (Mediabot/External/Claude.pm)
# et importés en tête de ce fichier.
# ------------------------------------------------------------------

# ---------------------------------------------------------------------------
# ytSearch_ctx --- !yt search <query>
# Search YouTube via Data API v3 and return top 3 results.
# ---------------------------------------------------------------------------

sub ytSearch_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    return unless Mediabot::External::_chanset_ok($self, $channel, 'Youtube');

    my $query = join(' ', @args);
    $query =~ s/^\s+|\s+$//g;
    unless ($query ne '') {
        Mediabot::Helpers::botNotice($self, $nick, 'Syntax: yt search <query>');
        return;
    }
    if (length($query) > 128) {
        Mediabot::Helpers::botNotice($self, $nick, 'Query too long (max 128 chars).');
        return;
    }

    # A2: serve from cache if fresh (TTL = YT_CACHE_TTL seconds)
    my $search_cache_key = 'search:' . lc($query);
    my $sc = $self->{_yt_cache}{$search_cache_key};
    if ($sc && (time() - $sc->{ts}) < YT_CACHE_TTL) {
        $self->{logger}->log(4, "ytSearch_ctx() cache hit for '$query'");
        for my $line (@{ $sc->{lines} // [] }) {
            Mediabot::Helpers::botPrivmsg($self, $channel, $line);
        }
        return 1;
    }

    my $APIKEY = $self->{conf}->get('main.YOUTUBE_APIKEY');
    unless (defined $APIKEY && $APIKEY ne '') {
        $self->{logger}->log(1, 'ytSearch_ctx() YOUTUBE_APIKEY not set');
        Mediabot::Helpers::botNotice($self, $nick, 'YouTube API key not configured.');
        return;
    }

    require URI::Escape;
    my $encoded = URI::Escape::uri_escape_utf8($query);
    # K4: configurable result count (main.YT_SEARCH_RESULTS, default 3, max 5)
    my $yt_max = eval { int($self->{conf}->get('main.YT_SEARCH_RESULTS') // 3) } // 3;
    $yt_max = 3 unless $yt_max >= 1 && $yt_max <= 5;
    my $url = "https://www.googleapis.com/youtube/v3/search"
            . "?part=snippet&type=video&maxResults=$yt_max"
            . "&q=$encoded&key=$APIKEY";

    my $http = Mediabot::External::_make_http(timeout => 8);
    my $res  = eval { $http->get($url) } // { success => 0 };
    unless ($res->{success}) {
        $self->{logger}->log(3, 'ytSearch_ctx() HTTP error: ' . ($res->{status} // 0));
        Mediabot::Helpers::botPrivmsg($self, $channel, "($nick) YouTube search unavailable.");
        return;
    }

    my $data = eval { decode_json($res->{content} // '') };
    unless (ref($data) eq 'HASH' && ref($data->{items}) eq 'ARRAY') {
        $self->{logger}->log(3, 'ytSearch_ctx() unexpected response structure');
        Mediabot::Helpers::botPrivmsg($self, $channel, "($nick) No results.");
        return;
    }

    my @items = @{ $data->{items} };
    unless (@items) {
        Mediabot::Helpers::botPrivmsg($self, $channel, "($nick) No results for: $query");
        return;
    }

    my @_yt_search_lines;  # A2: accumulate output lines for cache
    push @_yt_search_lines,
        _yt_label() . _yt_text(" Search: $query ") . _yt_sep('-- ' . scalar(@items) . ' result(s)');

    # F51: fetch duration + view count via videos endpoint
    my %vid_meta;
    my @vid_ids = grep { defined $_ } map { ref($_->{id}) eq 'HASH' ? $_->{id}{videoId} : undef } @items;
    if (@vid_ids) {
        my $ids_param = join(',', map { URI::Escape::uri_escape_utf8($_) } @vid_ids);
        my $meta_url  = "https://www.googleapis.com/youtube/v3/videos"
                      . "?part=contentDetails,statistics&id=$ids_param&key=$APIKEY";
        my $mres = eval { $http->get($meta_url) } // { success => 0 };
        if ($mres->{success}) {
            my $mdata = eval { decode_json($mres->{content} // '') };
            if (ref($mdata) eq 'HASH' && ref($mdata->{items}) eq 'ARRAY') {
                for my $v (@{ $mdata->{items} }) {
                    my $vid = $v->{id} // next;
                    # Parse ISO 8601 duration: PT4M13S → 4:13
                    # Each capture is independent to avoid list-context shift when a group is absent.
                    my $dur = $v->{contentDetails}{duration} // '';
                    my ($h) = ($dur =~ /(\d+)H/);
                    my ($m) = ($dur =~ /(\d+)M/);
                    my ($s) = ($dur =~ /(\d+)S/);
                    ($h, $m, $s) = ($h // 0, $m // 0, $s // 0);
                    my $dur_str = $h ? sprintf('%d:%02d:%02d', $h, $m, $s) : sprintf('%d:%02d', $m, $s);
                    # View count
                    my $views = $v->{statistics}{viewCount} // 0;
                    my $views_str = $views >= 1_000_000 ? sprintf('%.1fM', $views/1_000_000)
                                 : $views >= 1_000      ? sprintf('%.0fK', $views/1_000)
                                 : $views;
                    $vid_meta{$vid} = { dur => $dur_str, views => $views_str };
                }
            }
        }
    }

    my $rank = 1;
    for my $item (@items) {
        next unless ref($item) eq 'HASH'
                 && ref($item->{snippet}) eq 'HASH'
                 && ref($item->{id})      eq 'HASH';
        my $vid_id  = $item->{id}{videoId}    // next;
        my $title   = $item->{snippet}{title} // '?';
        my $channel_title = $item->{snippet}{channelTitle} // '?';
        # Normalise ALL-CAPS titles
        if (($title =~ tr/A-Z//) > 20) { $title = ucfirst(lc($title)); }
        my $meta     = $vid_meta{$vid_id} // {};
        my $dur_part = $meta->{dur}   ? ' [' . $meta->{dur}   . ']' : '';
        my $vw_part  = $meta->{views} ? ' ' .  $meta->{views} . ' views' : '';
        my $line = _yt_sep("[$rank] ")
                 . _yt_text(" $title ")
                 . _yt_sep('- ')
                 . _yt_meta("by $channel_title$dur_part$vw_part ")
                 . _yt_sep('- ')
                 . _yt_meta("https://youtu.be/$vid_id");
        push @_yt_search_lines, $line;
        $rank++;
    }

    # A2: flush accumulated lines and store in cache
    Mediabot::Helpers::botPrivmsg($self, $channel, $_) for @_yt_search_lines;
    $self->{_yt_cache}{$search_cache_key} = { ts => time(), lines => \@_yt_search_lines };
    Mediabot::Helpers::logBot($self, $ctx->message, $channel, 'yt_search', $query);
    # L3: Prometheus counter for !yt search
    $self->{metrics}->inc('mediabot_ytsearch_requests_total') if $self->{metrics};
    return 1;
}



1;
