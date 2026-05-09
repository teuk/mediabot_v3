package Mediabot::External;

# =============================================================================
# Mediabot::External
# =============================================================================

use strict;
use warnings;
use POSIX qw(strftime WNOHANG);
use Time::HiRes qw(usleep);
use List::Util qw(min);
use Exporter 'import';
use Encode qw(encode decode);
use Try::Tiny;
use Mediabot::Helpers;
use Mediabot::ChannelCommands qw(getTMDBLangChannel);
use JSON::MaybeXS;
use URI::Escape qw(uri_escape_utf8 uri_escape);
use HTML::Entities qw(decode_entities);
use HTML::Entities '%entity2char';
use IO::Socket::SSL;
use HTTP::Tiny;
use IO::Select;
use String::IRC;
use IPC::Open3;
use Symbol qw(gensym);

our @EXPORT = qw(
    _chatgpt_wrap
    chatGPT
    chatGPT_ctx
    displayUrlTitle
    displayWeather_ctx
    displayYoutubeDetails
    fortniteStats_ctx
    getFortniteId
    getYoutubeDetails
    get_tmdb_info
    mbTMDBSearch_ctx
    youtubeSearch_ctx
    _chanset_ok
    _decode_html
    _extract_url
    _handle_applemusic
    _handle_facebook
    _handle_generic_title
    _x_url
    _x_title_from_html
    _x_fallback_title_from_url
    _handle_x_twitter
    _handle_instagram
    _handle_spotify
    _is_youtube_url
    _yt_label
    _youtube_html_fallback
    _make_http
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

    my $http = _make_http(timeout => 10);
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
        noticeConsoleChan($self, "getYoutubeDetails() Invalid id : $sYoutubeId");
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

    my $sViewCount = defined($view_count) && $view_count ne ''
        ? "views $view_count"
        : "views ?";

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

    my $http = _make_http(timeout => 8, max_size => 64 * 1024);
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

    $title       = _decode_html($title);
    $author_name = _decode_html($author_name);

    $self->{logger}->log(3, "_youtube_html_fallback() oEmbed title='$title' author='$author_name'");

    my $msg = _yt_label();
    $msg .= _yt_text(" $title ");
    if ($author_name ne '') {
        $msg .= _yt_sep("- ");
        $msg .= _yt_meta("by $author_name");
    }

    botPrivmsg($self, $channel, "($nick) $msg");
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

    my $APIKEY = $conf->get('main.YOUTUBE_APIKEY');
    unless (defined($APIKEY) && $APIKEY ne '') {
        $self->{logger}->log(1, "displayYoutubeDetails() API Youtube V3 DEV KEY not set in " . $self->{config_file});
        $self->{logger}->log(1, "displayYoutubeDetails() section [main] YOUTUBE_APIKEY=key");
        return undef;
    }

    # --- Appel HTTP::Tiny ---
    my $url = "https://www.googleapis.com/youtube/v3/videos"
            . "?id=$sYoutubeId&key=$APIKEY&part=snippet,contentDetails,statistics,status";

    my $http     = _make_http(timeout => 8);
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

    my $sViewCount    = "views " . ($statistics->{viewCount} // '?');
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
    my $sDisplayDuration = '';
    my $raw = $sDuration;
    $raw =~ s/^PT//;
    if ($raw =~ /(\d+)H/) { $sDisplayDuration .= "${1}h "; }
    if ($raw =~ /(\d+)M/) { $sDisplayDuration .= "${1}mn "; }
    if ($raw =~ /(\d+)S/) { $sDisplayDuration .= "${1}s"; }
    $sDisplayDuration =~ s/\s+$//;

    $self->{logger}->log(4, "displayYoutubeDetails() sDisplayDuration : $sDisplayDuration");

    # --- Normalisation des majuscules excessives ---
    if (($sTitle        =~ tr/A-Z//) > 20) { $sTitle        = ucfirst(lc($sTitle)); }
    if (($schannelTitle =~ tr/A-Z//) > 20) { $schannelTitle = ucfirst(lc($schannelTitle)); }

    # --- Formatage IRC coloré ---
    my $sMsgSong = _yt_label();
    $sMsgSong   .= _yt_text(" $sTitle ");
    $sMsgSong   .= _yt_sep("- ");
    $sMsgSong   .= _yt_meta("$sDisplayDuration ");
    $sMsgSong   .= _yt_sep("- ");
    $sMsgSong   .= _yt_meta("$sViewCount ");
    $sMsgSong   .= _yt_sep("- ");
    $sMsgSong   .= _yt_meta("by $schannelTitle");

    $sMsgSong =~ s/\r|\n//g;
    botPrivmsg($self, $sChannel, "($sNick) $sMsgSong");

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
        botNotice($self, $nick, "Syntax (in channel): weather <City|City,CC|lat,lon>");
        return;
    }

    # Respect your chanset gate: Weather
    my $id_chanset_list = getIdChansetList($self, "Weather");
    return unless defined $id_chanset_list;

    my $id_channel_set = getIdChannelSet($self, $channel, $id_chanset_list);
    return unless defined $id_channel_set;

    my $q = join(' ', grep { defined && $_ ne '' } @args);
    $q =~ s/^\s+|\s+$//g;

    unless ($q ne '') {
        botNotice($self, $nick, "Syntax (no accents): weather <City|City,CC|lat,lon>");
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
        botPrivmsg($self, $channel, $cache->{text});
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

    my $http = _make_http(
        timeout    => 4,
        agent      => $weather_agent,
        verify_SSL => 1,   # B1/A3: override _make_http default (0) for weather
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
            botPrivmsg($self, $channel, $cache->{text} . "  (cached)");
        } else {
            botPrivmsg($self, $channel, $msg);
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
    botPrivmsg($self, $channel, $line);
    logBot($self, $ctx->message, $channel, "weather", $location);

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

sub _yt_format_duration {
    my ($iso) = @_;

    return '' unless defined $iso && $iso ne '';

    my $raw = $iso;
    $raw =~ s/^PT//i;

    my ($h)   = $raw =~ /(\d+)H/i;
    my ($m)   = $raw =~ /(\d+)M/i;
    my ($sec) = $raw =~ /(\d+)S/i;

    $h   ||= 0;
    $m   ||= 0;
    $sec ||= 0;

    return '' if !$h && !$m && !$sec;

    my $out = '';
    $out .= "${h}h "   if $h;
    $out .= "${m}mn "  if $m;
    $out .= "${sec}s"  if $sec;
    $out =~ s/\s+$//;

    return $out;
}

sub _yt_duration_seconds {
    my ($iso) = @_;

    return 0 unless defined $iso && $iso ne '';

    my $raw = $iso;
    $raw =~ s/^PT//i;

    my ($h) = $raw =~ /(\d+)H/i;
    my ($m) = $raw =~ /(\d+)M/i;
    my ($sec) = $raw =~ /(\d+)S/i;

    $h   ||= 0;
    $m   ||= 0;
    $sec ||= 0;

    return ($h * 3600) + ($m * 60) + $sec;
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
# _make_http(%opts) — shared HTTP::Tiny factory with SSL bypass
# HTTP 599 on HTTPS URLs usually means IO::Socket::SSL is present but
# certificate verification fails. SSL_options forces no-verify mode.
# ---------------------------------------------------------------------------
sub _make_http {
    my (%opts) = @_;
    return HTTP::Tiny->new(
        timeout    => $opts{timeout}  // 8,
        agent      => $opts{agent}    // 'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:125.0) Gecko/20100101 Firefox/125.0',
        verify_SSL => 0,
        SSL_options => { SSL_verify_mode => 0 },
        max_size   => $opts{max_size} // 512 * 1024,
    );
}

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
    $url =~ s/[)\].,!?;:]+$//;

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
    $str = decode_entities($str) if ($str =~ /$regex/ || $str =~ /&#[0-9]+;/);
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

sub _fetch_url_chromium_dumpdom {
    my ($self, $url, %opts) = @_;
    return undef unless defined $url && $url ne '';

    my $chromium = '/usr/bin/chromium';
    unless (-x $chromium) {
        $self->{logger}->log(3, "_fetch_url_chromium_dumpdom() chromium not found at $chromium");
        return undef;
    }

    # A3: chromium timeouts configurable via conf (chromium.VIRTUAL_TIME_BUDGET / chromium.ALARM_TIMEOUT)
    my $_default_vtb     = int(eval { $self->{conf}->get('chromium.VIRTUAL_TIME_BUDGET') } // 3500);
    my $_default_alarm   = int(eval { $self->{conf}->get('chromium.ALARM_TIMEOUT') }       // 12);
    $_default_vtb   = 1000  if $_default_vtb   < 1000;  # min 1s
    $_default_vtb   = 30000 if $_default_vtb   > 30000; # max 30s
    $_default_alarm = 5     if $_default_alarm  < 5;     # min 5s
    $_default_alarm = 60    if $_default_alarm  > 60;    # max 60s
    my $virtual_time_budget = $opts{virtual_time_budget} // $_default_vtb;
    my $alarm_timeout       = $opts{alarm_timeout}       // $_default_alarm;
    my $lang                = $opts{lang}                // 'fr-FR';
    my $user_agent          = $opts{user_agent}          // 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36';

    my @cmd = (
        $chromium,
        '--headless=new',
        '--disable-gpu',
        '--no-sandbox',
        '--disable-dev-shm-usage',
        '--disable-blink-features=AutomationControlled',
        '--window-size=1366,900',
        "--lang=$lang",
        "--user-agent=$user_agent",
        "--virtual-time-budget=$virtual_time_budget",
        '--dump-dom',
        $url,
    );

    $self->{logger}->log(
        4,
        "_fetch_url_chromium_dumpdom() budget=$virtual_time_budget alarm=$alarm_timeout exec: " . join(' ', @cmd)
    );

    my $stderr = gensym;
    my $pid;
    my $stdout = '';

    # NOTE: alarm()/SIGALRM is unsafe inside an IO::Async event loop — it can
    # interrupt epoll_wait() mid-flight.  Use a watchdog waitpid() loop instead.
    my $ok = eval {
        $pid = open3('/dev/null', my $out, $stderr, @cmd);

        # Read with a non-blocking loop so we can enforce a wall-clock timeout
        # without SIGALRM. Poll every 100ms, bail after $alarm_timeout seconds.
        my $deadline = time() + $alarm_timeout;
        my $sel = IO::Select->new($out);

        while (1) {
            my $remaining = $deadline - time();
            last if $remaining <= 0;

            if ($sel->can_read(0.1)) {
                my $chunk;
                my $n = sysread($out, $chunk, 65536);
                last unless defined $n && $n > 0;
                $stdout .= $chunk;
            } elsif (time() >= $deadline) {
                die "ALARM\n";
            }
        }
        close($out);
        1;
    };

    if (!$ok) {
        my $err = $@ || 'unknown error';
        if ($pid) {
            eval { kill 'TERM', $pid };

            my $reaped = 0;
            for (1 .. 5) {
                my $waited = waitpid($pid, WNOHANG);
                if ($waited == $pid || $waited == -1) {
                    $reaped = 1;
                    last;
                }
                usleep(200_000);
            }

            unless ($reaped) {
                eval { kill 'KILL', $pid };
                waitpid($pid, 0);
            }
        }
        $err =~ s/\s+$//;
        $self->{logger}->log(3, "_fetch_url_chromium_dumpdom() failed for $url: $err");
        return undef;
    }

    my $stderr_txt = '';
    {
        local $/;
        $stderr_txt = <$stderr> // '';
    }
    close($stderr);

    waitpid($pid, 0);
    my $rc = $? >> 8;

    eval {
        $stdout = decode('UTF-8', $stdout, 1);
        1;
    } or do {
        $self->{logger}->log(4, "_fetch_url_chromium_dumpdom() UTF-8 decode failed for $url");
    };

    my $len = length($stdout // '');
    $self->{logger}->log(4, "_fetch_url_chromium_dumpdom() rc=$rc bytes=$len for $url");

    if (defined $stderr_txt && $stderr_txt ne '') {
        my $errlog = substr($stderr_txt, 0, 500);
        $errlog =~ s/\s+/ /g;
        $self->{logger}->log(4, "_fetch_url_chromium_dumpdom() stderr=$errlog");
    }

    unless ($rc == 0 && defined $stdout && $stdout ne '') {
        $self->{logger}->log(3, "_fetch_url_chromium_dumpdom() chromium returned no usable DOM for $url");
        return undef;
    }

    return $stdout;
}




# ---------------------------------------------------------------------------
# _chanset_ok($self, $channel, $chanset_name)
# Returns 1 if the chanset is enabled on this channel (or if chanset doesn't
# exist in CHANSET_LIST at all, which means the feature is always-on).
# Returns 0 if the chanset exists but is NOT enabled on this channel.
# ---------------------------------------------------------------------------
sub _chanset_ok {
    my ($self, $channel, $chanset_name) = @_;
    my $id_cs = getIdChansetList($self, $chanset_name);
    return 1 unless defined $id_cs && $id_cs ne '';   # chanset not in DB → always on
    my $id_ch_set = getIdChannelSet($self, $channel, $id_cs);
    return (defined $id_ch_set && $id_ch_set ne '') ? 1 : 0;
}

# ---------------------------------------------------------------------------
# _is_youtube_url($url) — returns the video ID or undef
# Covers: watch?v=, /shorts/, /live/, youtu.be, youtube-nocookie, m., music.
# ---------------------------------------------------------------------------
sub _is_youtube_url {
    my ($url) = @_;
    return undef unless defined $url;

    # Standard watch URL on all subdomains
    if ($url =~ m{https?://(?:www\.|m\.|music\.)?youtube\.(?:com|fr|de|co\.uk|co\.jp|be)/watch[^\s]*[?&]v=([A-Za-z0-9_-]{11})}i) {
        return $1;
    }
    # Shorts
    if ($url =~ m{https?://(?:www\.|m\.)?youtube\.(?:com|fr|de|co\.uk|co\.jp)/shorts/([A-Za-z0-9_-]{11})}i) {
        return $1;
    }
    # Live
    if ($url =~ m{https?://(?:www\.|m\.)?youtube\.(?:com|fr|de|co\.uk|co\.jp)/live/([A-Za-z0-9_-]{11})}i) {
        return $1;
    }
    # Embed
    if ($url =~ m{https?://(?:www\.)?youtube(?:-nocookie)?\.com/embed/([A-Za-z0-9_-]{11})}i) {
        return $1;
    }
    # youtu.be short link
    if ($url =~ m{https?://youtu\.be/([A-Za-z0-9_-]{11})}i) {
        return $1;
    }
    return undef;
}


# ---------------------------------------------------------------------------
# _handle_instagram($self, $message, $nick, $channel, $url)
# Parses Instagram page for a title. Instagram's
# ---------------------------------------------------------------------------
sub _handle_instagram {
    my ($self, $message, $nick, $channel, $url) = @_;

    $self->{logger}->log(4, "_handle_instagram() start url=$url");

    my ($shortcode) = $url =~ m{/(?:p|reel|tv)/([^/?#]+)/?};
    unless (defined $shortcode && $shortcode ne '') {
        $self->{logger}->log(3, "_handle_instagram() could not extract shortcode from $url");
        return undef;
    }

    my $title;

    # ------------------------------------------------------------
    # Step 1: one cheap HTTP fetch on the public page only
    # ------------------------------------------------------------
    my $http = _make_http(
        timeout  => 8,
        max_size => 1024 * 1024,
    );

    my $res = eval { $http->get($url); } // { success => 0, status => 0, reason => $@ };

    if ($res->{success}) {
        my $content = _decode_http_content_utf8($self, $res->{content} // '', 'instagram-http');
        my $len = length($content);
        $self->{logger}->log(4, "_handle_instagram() HTTP fetched $len bytes for $url");

        my $og_description;
        my $meta_description;
        my $title_tag;

        if ($content =~ /<meta\s+property=["']og:description["']\s+content=["']([^"']+)["']/i) {
            $og_description = $1;
        }
        elsif ($content =~ /<meta\s+content=["']([^"']+)["']\s+property=["']og:description["']/i) {
            $og_description = $1;
        }

        if ($content =~ /<meta\s+name=["']description["']\s+content=["']([^"']+)["']/i) {
            $meta_description = $1;
        }
        elsif ($content =~ /<meta\s+content=["']([^"']+)["']\s+name=["']description["']/i) {
            $meta_description = $1;
        }

        if ($content =~ /<title[^>]*>([^<]+)<\/title>/i) {
            $title_tag = $1;
        }

        for ($og_description, $meta_description, $title_tag) {
            $_ = _decode_html($_) if defined $_;
        }

        $self->{logger}->log(4, "_handle_instagram() HTTP og:description=" . (defined $og_description ? $og_description : '<undef>'));
        $self->{logger}->log(4, "_handle_instagram() HTTP meta description=" . (defined $meta_description ? $meta_description : '<undef>'));
        $self->{logger}->log(4, "_handle_instagram() HTTP <title>=" . (defined $title_tag ? $title_tag : '<undef>'));

        if (defined $og_description && $og_description ne '' && $og_description !~ /^\s*Instagram\s*$/i) {
            $title = $og_description;
            $self->{logger}->log(4, "_handle_instagram() selected HTTP og:description");
        }
        elsif (defined $meta_description && $meta_description ne '' && $meta_description !~ /^\s*Instagram\s*$/i) {
            $title = $meta_description;
            $self->{logger}->log(4, "_handle_instagram() selected HTTP meta description");
        }
        elsif (defined $title_tag && $title_tag ne '' && $title_tag !~ /^\s*Instagram\s*$/i) {
            $title = $title_tag;
            $self->{logger}->log(4, "_handle_instagram() selected HTTP <title>");
        }

        if (!defined($title) || $title eq '') {
            if ($content =~ /"pageID":"httpErrorPage"/) {
                $self->{logger}->log(4, "_handle_instagram() public page is an httpErrorPage shell for $url");
            }
        }
    }
    else {
        $self->{logger}->log(4, "_handle_instagram() HTTP $res->{status} $res->{reason} for $url");
    }

    # ------------------------------------------------------------
    # Step 2: Chromium fallback on the public page only
    # ------------------------------------------------------------
    unless (defined $title && $title ne '') {
        $self->{logger}->log(4, "_handle_instagram() falling back to Chromium rendered DOM on public URL");

        my $dom = _fetch_url_chromium_dumpdom($self, $url);
        if (defined $dom && $dom ne '') {
            my $len = length($dom);
            $self->{logger}->log(4, "_handle_instagram() Chromium DOM fetched $len bytes for $url");

            my $og_description;
            my $meta_description;
            my $title_tag;

            if ($dom =~ /<meta\s+property=["']og:description["']\s+content=["']([^"']+)["']/i) {
                $og_description = $1;
            }
            elsif ($dom =~ /<meta\s+content=["']([^"']+)["']\s+property=["']og:description["']/i) {
                $og_description = $1;
            }

            if ($dom =~ /<meta\s+name=["']description["']\s+content=["']([^"']+)["']/i) {
                $meta_description = $1;
            }
            elsif ($dom =~ /<meta\s+content=["']([^"']+)["']\s+name=["']description["']/i) {
                $meta_description = $1;
            }

            if ($dom =~ /<title[^>]*>([^<]+)<\/title>/i) {
                $title_tag = $1;
            }

            for ($og_description, $meta_description, $title_tag) {
                $_ = _decode_html($_) if defined $_;
            }

            $self->{logger}->log(4, "_handle_instagram() Chromium og:description=" . (defined $og_description ? $og_description : '<undef>'));
            $self->{logger}->log(4, "_handle_instagram() Chromium meta description=" . (defined $meta_description ? $meta_description : '<undef>'));
            $self->{logger}->log(4, "_handle_instagram() Chromium <title>=" . (defined $title_tag ? $title_tag : '<undef>'));

            if (defined $og_description
                && $og_description ne ''
                && $og_description !~ /^\s*Instagram\s*$/i
                && $og_description !~ /create an account or log in to instagram/i
            ) {
                $title = $og_description;
                $self->{logger}->log(4, "_handle_instagram() selected Chromium og:description");
            }
            elsif (defined $meta_description
                && $meta_description ne ''
                && $meta_description !~ /^\s*Instagram\s*$/i
                && $meta_description !~ /create an account or log in to instagram/i
            ) {
                $title = $meta_description;
                $self->{logger}->log(4, "_handle_instagram() selected Chromium meta description");
            }
            elsif (defined $title_tag
                && $title_tag ne ''
                && $title_tag !~ /^\s*Instagram\s*$/i
                && $title_tag !~ /create an account or log in to instagram/i
            ) {
                $title = $title_tag;
                $self->{logger}->log(4, "_handle_instagram() selected Chromium <title>");
            }
        }
    }

    unless (defined $title && $title ne '') {
        $self->{logger}->log(3, "_handle_instagram() no usable title extracted for shortcode=" . ($shortcode // "undef"));
        return undef;
    }

    $title =~ s/\s+/ /g;
    $title =~ s/^\s+|\s+$//g;
    $title =~ s/\s*-\s*Watch more on Instagram\.?\s*$//i;
    $title =~ s/\s*[•·|]\s*Instagram\s*$//i;

    if ($title =~ /^\s*Instagram\s*$/i || $title =~ /DOCTYPE/i || $title eq '') {
        $self->{logger}->log(3, "_handle_instagram() extracted title is unusable after cleanup: '$title'");
        return undef;
    }

    $self->{logger}->log(4, "_handle_instagram() final title='$title'");

    my $badge = String::IRC->new("[")->white('black');
    $badge   .= String::IRC->new("Instagram")->white('pink');
    $badge   .= String::IRC->new("]")->white('black');

    my $msg = "$badge\x0f " . substr($title, 0, 300);

    botPrivmsg($self, $channel, "($nick) $msg");
    return 1;
}

# ---------------------------------------------------------------------------
# _handle_spotify($self, $message, $nick, $channel, $url)
# Parses <title> from Spotify page. Format: "Song - artist | Spotify"
# Also handles albums, playlists, podcasts via og:title.
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

    my %info = (
        type => $spotify_type,
    );

    my $is_bad = sub {
        my ($v) = @_;
        return 1 unless defined $v;

        $v = _decode_html($v);
        $v =~ s/[\r\n\t]/ /g;
        $v =~ s/\s+/ /g;
        $v =~ s/^\s+|\s+$//g;

        return 1 if $v eq '';
        return 1 if $v =~ /^Spotify$/i;
        return 1 if $v =~ /^Spotify\s*[–-]\s*Web Player$/i;
        return 1 if $v =~ /^Spotify Web Player$/i;
        return 1 if $v =~ /listening is everything/i;
        return 0;
    };

    my $clean = sub {
        my ($v) = @_;
        return undef unless defined $v;

        $v = _decode_html($v);
        $v =~ s/\\u0026/&/g;
        $v =~ s/\\\//\//g;
        $v =~ s/\\"/"/g;
        $v =~ s/[\r\n\t]/ /g;
        $v =~ s/\s{2,}/ /g;
        $v =~ s/^\s+|\s+$//g;

        $v =~ s/\s*\|\s*Spotify\s*$//i;
        $v =~ s/\s*[–-]\s*Spotify\s*$//i;
        $v =~ s/\s*[–-]\s*song and lyrics by\s*/ - /i;

        return undef if $is_bad->($v);
        return $v;
    };

    my $set_once = sub {
        my ($key, $value) = @_;
        return unless defined $key;
        return if defined $info{$key} && $info{$key} ne '';

        my $v = $clean->($value);
        return unless defined $v && $v ne '';

        $info{$key} = $v;
        $self->{logger}->log(4, "_handle_spotify() set $key='$v'");
    };

    my $duration_from_ms = sub {
        my ($ms) = @_;
        return undef unless defined $ms && $ms =~ /^\d+$/;

        my $total = int($ms / 1000);
        return undef if $total <= 0;

        my $h = int($total / 3600);
        my $m = int(($total % 3600) / 60);
        my $s = $total % 60;

        return sprintf("%dh%02dm%02ds", $h, $m, $s) if $h;
        return sprintf("%dm %02ds", $m, $s);
    };

    my $duration_from_iso = sub {
        my ($d) = @_;
        return undef unless defined $d;

        if ($d =~ /^PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?$/i) {
            my ($h, $m, $s) = ($1 // 0, $2 // 0, $3 // 0);
            return undef if !$h && !$m && !$s;

            return sprintf("%dh%02dm%02ds", $h, $m, $s) if $h;
            return sprintf("%dm %02ds", $m, $s);
        }

        return undef;
    };

    my $extract_meta = sub {
        my ($html, $context) = @_;
        return unless defined $html && $html ne '';

        my ($og_title, $twitter_title, $title_tag, $description);

        while ($html =~ /<meta\b([^>]*?)>/sig) {
            my $attrs = $1;

            if ($attrs =~ /(?:property|name)=["']og:title["']/i && $attrs =~ /\bcontent=["']([^"']+)["']/i) {
                $og_title = $1;
            }
            elsif ($attrs =~ /(?:property|name)=["']twitter:title["']/i && $attrs =~ /\bcontent=["']([^"']+)["']/i) {
                $twitter_title = $1;
            }
            elsif ($attrs =~ /(?:property|name)=["'](?:og:description|description|twitter:description)["']/i
                && $attrs =~ /\bcontent=["']([^"']+)["']/i) {
                $description = $1;
            }
        }

        if ($html =~ /<title[^>]*>(.*?)<\/title>/si) {
            $title_tag = $1;
        }

        for my $candidate ($og_title, $twitter_title, $title_tag) {
            my $v = $clean->($candidate);
            next unless defined $v && $v ne '';

            if (!defined $info{title} && $v =~ /^(.+?)\s+-\s+(.+)$/) {
                $set_once->('title',  $1);
                $set_once->('artist', $2) unless $2 =~ /Spotify/i;
            }
            else {
                $set_once->('title', $v);
            }

            last if defined $info{title};
        }

        my $desc = $clean->($description);
        if (defined $desc && $desc ne '') {
            # Typical Spotify description examples:
            #   Song · Artist · 2024
            #   Album · Artist · 2024
            #   Playlist · User · 50 songs
            if ($desc =~ /\b(?:Song|Single|Album|EP|Playlist|Episode|Show)\s*[·-]\s*([^·|.-]+)\s*[·-]\s*(\d{4})/i) {
                $set_once->('artist', $1);
                $set_once->('year',   $2);
            }
            elsif ($desc =~ /\b(?:Song|Single|Album|EP)\s*[·-]\s*([^·|.-]+)/i) {
                $set_once->('artist', $1);
            }

            if ($desc =~ /\bfrom\s+(?:the\s+)?(?:album|single)\s+([^.,|]+)(?:[.,|]|$)/i) {
                $set_once->('album', $1);
            }
        }

        $self->{logger}->log(4, "_handle_spotify() parsed meta from $context");
    };

    my $extract_jsonish = sub {
        my ($text, $context) = @_;
        return unless defined $text && $text ne '';

        # JSON-LD first: cleanest metadata when Spotify exposes it.
        while ($text =~ m{<script[^>]+type=["']application/ld\+json["'][^>]*>(.*?)</script>}sig) {
            my $json = _decode_html($1);
            my $data = eval { decode_json($json) };
            next unless defined $data;

            my @items = ref($data) eq 'ARRAY' ? @$data : ($data);

            for my $item (@items) {
                next unless ref($item) eq 'HASH';

                $set_once->('title', $item->{name});

                if (ref($item->{byArtist}) eq 'HASH') {
                    $set_once->('artist', $item->{byArtist}->{name});
                }
                elsif (ref($item->{byArtist}) eq 'ARRAY') {
                    my @artists = grep { defined $_ && $_ ne '' }
                                  map { ref($_) eq 'HASH' ? $_->{name} : $_ }
                                  @{ $item->{byArtist} };
                    $set_once->('artist', join(', ', @artists)) if @artists;
                }

                if (ref($item->{inAlbum}) eq 'HASH') {
                    $set_once->('album', $item->{inAlbum}->{name});
                }

                if (defined $item->{duration} && !defined $info{duration}) {
                    my $d = $duration_from_iso->($item->{duration});
                    $info{duration} = $d if defined $d;
                }

                $set_once->('year', $1) if defined($item->{datePublished}) && $item->{datePublished} =~ /^(\d{4})/;
            }
        }

        # Conservative regex extraction from embedded Spotify data.
        # Avoid using the first random "name" field as title: it can be junk.
        if (!defined $info{title}) {
            if ($text =~ /"track"\s*:\s*\{.{0,3000}?"name"\s*:\s*"([^"\\]*(?:\\.[^"\\]*)*)"/s) {
                my $v = $1;
                $v =~ s/\\"/"/g;
                $v =~ s/\\\\/\\/g;
                $set_once->('title', $v);
            }
            elsif ($text =~ /"type"\s*:\s*"track".{0,3000}?"name"\s*:\s*"([^"\\]*(?:\\.[^"\\]*)*)"/s) {
                my $v = $1;
                $v =~ s/\\"/"/g;
                $v =~ s/\\\\/\\/g;
                $set_once->('title', $v);
            }
        }

        if (!defined $info{artist}) {
            if ($text =~ /"artists"\s*:\s*\[(.{0,2000}?)\]/s) {
                my $artists_blob = $1;
                my @artists;

                while ($artists_blob =~ /"name"\s*:\s*"([^"\\]*(?:\\.[^"\\]*)*)"/g) {
                    my $v = $1;
                    $v =~ s/\\"/"/g;
                    $v =~ s/\\\\/\\/g;
                    my $c = $clean->($v);
                    push @artists, $c if defined $c && $c ne '';
                }

                $set_once->('artist', join(', ', @artists)) if @artists;
            }
        }

        if (!defined $info{album}) {
            if ($text =~ /"album"\s*:\s*\{.{0,2000}?"name"\s*:\s*"([^"\\]*(?:\\.[^"\\]*)*)"/s) {
                my $v = $1;
                $v =~ s/\\"/"/g;
                $v =~ s/\\\\/\\/g;
                $set_once->('album', $v);
            }
        }

        if (!defined $info{year}) {
            if ($text =~ /"release_date"\s*:\s*"(\d{4})/) {
                $set_once->('year', $1);
            }
        }

        if (!defined $info{duration}) {
            if ($text =~ /"duration_ms"\s*:\s*(\d+)/) {
                my $d = $duration_from_ms->($1);
                $info{duration} = $d if defined $d;
            }
        }

        $self->{logger}->log(4, "_handle_spotify() parsed JSON-ish metadata from $context");
    };

    my $http = _make_http(
        timeout  => 10,
        max_size => 2 * 1024 * 1024,
    );

    # Step 1: Spotify oEmbed.
    {
        my $oembed_url = "https://open.spotify.com/oembed?url=" . uri_escape_utf8($clean_url);
        my $res = eval { $http->get($oembed_url); } // { success => 0, status => 0, reason => $@ };

        if ($res->{success}) {
            my $json = _decode_http_content_utf8($self, $res->{content} // '', 'spotify-oembed');
            my $data = eval { decode_json($json) };

            if (ref($data) eq 'HASH') {
                $set_once->('title',  $data->{title});
                $set_once->('artist', $data->{author_name});
                $extract_jsonish->($json, 'oEmbed-json');
                $self->{logger}->log(4, "_handle_spotify() parsed oEmbed metadata");
            }
        }
        else {
            $self->{logger}->log(4, "_handle_spotify() oEmbed HTTP $res->{status} $res->{reason} for $oembed_url");
        }
    }

    # Step 2: Spotify embed page.
    if (!defined $info{title} || !defined $info{artist} || !defined $info{album} || !defined $info{duration} || !defined $info{year}) {
        my $embed_url = "https://open.spotify.com/embed/$spotify_type/$spotify_id";
        my $res = eval { $http->get($embed_url); } // { success => 0, status => 0, reason => $@ };

        if ($res->{success}) {
            my $content = _decode_http_content_utf8($self, $res->{content} // '', 'spotify-embed');
            $self->{logger}->log(4, "_handle_spotify() embed fetched " . length($content) . " bytes");
            $extract_meta->($content, 'embed');
            $extract_jsonish->($content, 'embed');
        }
        else {
            $self->{logger}->log(4, "_handle_spotify() embed HTTP $res->{status} $res->{reason} for $embed_url");
        }
    }

    # Step 3: normal Spotify page.
    if (!defined $info{title} || !defined $info{artist} || !defined $info{album} || !defined $info{duration} || !defined $info{year}) {
        my $res = eval { $http->get($clean_url); } // { success => 0, status => 0, reason => $@ };

        if ($res->{success}) {
            my $content = _decode_http_content_utf8($self, $res->{content} // '', 'spotify-http');
            $self->{logger}->log(4, "_handle_spotify() HTTP fetched " . length($content) . " bytes");
            $extract_meta->($content, 'HTTP');
            $extract_jsonish->($content, 'HTTP');
        }
        else {
            $self->{logger}->log(3, "_handle_spotify() HTTP $res->{status} $res->{reason} for $clean_url");
        }
    }

    # Step 4: Chromium fallback.
    if (!defined $info{title} || !defined $info{artist} || !defined $info{album} || !defined $info{duration} || !defined $info{year}) {
        $self->{logger}->log(4, "_handle_spotify() falling back to Chromium rendered DOM for $clean_url");

        my $dom = _fetch_url_chromium_dumpdom(
            $self,
            $clean_url,
            virtual_time_budget => 10000,
            alarm_timeout       => 28,
            lang                => 'fr-FR',
        );

        if (defined $dom && $dom ne '') {
            $self->{logger}->log(4, "_handle_spotify() Chromium DOM fetched " . length($dom) . " bytes");
            $extract_meta->($dom, 'Chromium');
            $extract_jsonish->($dom, 'Chromium');
        }
    }

    unless (defined $info{title} && !$is_bad->($info{title})) {
        $self->{logger}->log(3, "_handle_spotify() could not extract a usable Spotify title from $clean_url");
        return undef;
    }

    my @parts;
    push @parts, $info{title};

    if (defined $info{artist} && !$is_bad->($info{artist}) && $info{artist} ne $info{title}) {
        push @parts, "by $info{artist}";
    }

    if (defined $info{album} && !$is_bad->($info{album}) && $info{album} ne $info{title}) {
        push @parts, "album $info{album}";
    }

    if (defined $info{year} && $info{year} =~ /^\d{4}$/) {
        push @parts, $info{year};
    }

    if (defined $info{duration} && $info{duration} ne '') {
        push @parts, $info{duration};
    }

    my $display = join(' - ', @parts);
    $display =~ s/\s+/ /g;
    $display =~ s/^\s+|\s+$//g;
    $display = substr($display, 0, 300);

    $self->{logger}->log(4, "_handle_spotify() final display='$display'");

    # Badge unchanged.
    my $badge = String::IRC->new("[")->white('black');
    $badge   .= String::IRC->new("Spotify")->black('green');
    $badge   .= String::IRC->new("]")->white('black');

    # Hard IRC reset after the badge: only the badge keeps its background.
    my $msg = "$badge\x0f $display";

    botPrivmsg($self, $channel, "($nick) $msg");
    return 1;
}

# ---------------------------------------------------------------------------
# _handle_applemusic($self, $message, $nick, $channel, $url)
# ---------------------------------------------------------------------------
sub _handle_applemusic {
    my ($self, $message, $nick, $channel, $url) = @_;

    my $title;

    # ------------------------------------------------------------
    # Step 1: cheap HTTP fetch first
    # ------------------------------------------------------------
    my $http = _make_http(
        timeout  => 12,
        max_size => 512 * 1024,
    );
    my $res  = eval { $http->get($url); } // { success => 0, status => 0, reason => $@ };

    if ($res->{success}) {
        my $content = _decode_http_content_utf8($self, $res->{content} // '', 'applemusic-http');

        my $og_title;
        my $meta_description;
        my $title_tag;

        if ($content =~ /<meta\s+property=["']og:title["']\s+content=["']([^"']+)["']/i) {
            $og_title = $1;
        }
        elsif ($content =~ /<meta\s+content=["']([^"']+)["']\s+property=["']og:title["']/i) {
            $og_title = $1;
        }

        if ($content =~ /<meta\s+name=["']description["']\s+content=["']([^"']+)["']/i) {
            $meta_description = $1;
        }
        elsif ($content =~ /<meta\s+content=["']([^"']+)["']\s+name=["']description["']/i) {
            $meta_description = $1;
        }

        if ($content =~ /<title[^>]*>([^<]+)<\/title>/i) {
            $title_tag = $1;
            $title_tag =~ s/\s*[–-]\s*Apple Music\s*$//i;
        }

        for ($og_title, $meta_description, $title_tag) {
            $_ = _decode_html($_) if defined $_;
        }

        $self->{logger}->log(4, "_handle_applemusic() HTTP og:title=" . (defined $og_title ? $og_title : '<undef>'));
        $self->{logger}->log(4, "_handle_applemusic() HTTP meta description=" . (defined $meta_description ? $meta_description : '<undef>'));
        $self->{logger}->log(4, "_handle_applemusic() HTTP <title>=" . (defined $title_tag ? $title_tag : '<undef>'));

        if (defined $og_title
            && $og_title ne ''
            && $og_title !~ /^\s*Apple Music\s*$/i
            && $og_title !~ /listen on apple music/i
            && $og_title !~ /open in music/i
        ) {
            $title = $og_title;
            $self->{logger}->log(4, "_handle_applemusic() selected HTTP og:title");
        }
        elsif (defined $meta_description
            && $meta_description ne ''
            && $meta_description !~ /^\s*Apple Music\s*$/i
            && $meta_description !~ /listen on apple music/i
            && $meta_description !~ /open in music/i
        ) {
            $title = $meta_description;
            $self->{logger}->log(4, "_handle_applemusic() selected HTTP meta description");
        }
        elsif (defined $title_tag
            && $title_tag ne ''
            && $title_tag !~ /^\s*Apple Music\s*$/i
            && $title_tag !~ /listen on apple music/i
            && $title_tag !~ /open in music/i
        ) {
            $title = $title_tag;
            $self->{logger}->log(4, "_handle_applemusic() selected HTTP <title>");
        }
    }
    else {
        $self->{logger}->log(3, "_handle_applemusic() HTTP $res->{status} $res->{reason} for $url");
    }

    # ------------------------------------------------------------
    # Step 2: Chromium fallback if HTTP title is missing or generic
    # ------------------------------------------------------------
    my $title_check = defined($title) ? $title : '';
    $title_check =~ s/\s+/ /g;
    $title_check =~ s/^\s+|\s+$//g;

    if (!defined($title) || $title_check eq '' || $title_check =~ /^\s*Apple Music\s*$/i) {
        $self->{logger}->log(4, "_handle_applemusic() falling back to Chromium rendered DOM for $url");

        my $dom = _fetch_url_chromium_dumpdom(
            $self,
            $url,
            virtual_time_budget => 10000,
            alarm_timeout       => 30,
        );

        if (defined $dom && $dom ne '') {
            my $og_title;
            my $meta_description;
            my $title_tag;

            if ($dom =~ /<meta\s+property=["']og:title["']\s+content=["']([^"']+)["']/i) {
                $og_title = $1;
            }
            elsif ($dom =~ /<meta\s+content=["']([^"']+)["']\s+property=["']og:title["']/i) {
                $og_title = $1;
            }

            if ($dom =~ /<meta\s+name=["']description["']\s+content=["']([^"']+)["']/i) {
                $meta_description = $1;
            }
            elsif ($dom =~ /<meta\s+content=["']([^"']+)["']\s+name=["']description["']/i) {
                $meta_description = $1;
            }

            if ($dom =~ /<title[^>]*>([^<]+)<\/title>/i) {
                $title_tag = $1;
                $title_tag =~ s/\s*[–-]\s*Apple Music\s*$//i;
            }

            for ($og_title, $meta_description, $title_tag) {
                $_ = _decode_html($_) if defined $_;
            }

            $self->{logger}->log(4, "_handle_applemusic() Chromium og:title=" . (defined $og_title ? $og_title : '<undef>'));
            $self->{logger}->log(4, "_handle_applemusic() Chromium meta description=" . (defined $meta_description ? $meta_description : '<undef>'));
            $self->{logger}->log(4, "_handle_applemusic() Chromium <title>=" . (defined $title_tag ? $title_tag : '<undef>'));

            if (defined $og_title
                && $og_title ne ''
                && $og_title !~ /^\s*Apple Music\s*$/i
                && $og_title !~ /listen on apple music/i
                && $og_title !~ /open in music/i
            ) {
                $title = $og_title;
                $self->{logger}->log(4, "_handle_applemusic() selected Chromium og:title");
            }
            elsif (defined $meta_description
                && $meta_description ne ''
                && $meta_description !~ /^\s*Apple Music\s*$/i
                && $meta_description !~ /listen on apple music/i
                && $meta_description !~ /open in music/i
            ) {
                $title = $meta_description;
                $self->{logger}->log(4, "_handle_applemusic() selected Chromium meta description");
            }
            elsif (defined $title_tag
                && $title_tag ne ''
                && $title_tag !~ /^\s*Apple Music\s*$/i
                && $title_tag !~ /listen on apple music/i
                && $title_tag !~ /open in music/i
            ) {
                $title = $title_tag;
                $self->{logger}->log(4, "_handle_applemusic() selected Chromium <title>");
            }
        }
    }

    unless (defined $title && $title ne '') {
        $self->{logger}->log(3, "_handle_applemusic() could not extract title from $url");
        return undef;
    }

    $title =~ s/\s+/ /g;
    $title =~ s/^\s+|\s+$//g;

    my $badge = String::IRC->new("[")->white('black');
    $badge   .= String::IRC->new("AppleMusic")->white('grey');
    $badge   .= String::IRC->new("]")->white('black');

    my $msg = "$badge\x0f $title";

    botPrivmsg($self, $channel, "($nick) $msg");
    return 1;
}

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
    $title =~ s/\s{2,}/ /g;
    $title =~ s/^\s+|\s+$//g;

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

    my $fb_url = _facebook_url($url);
    unless (defined $fb_url) {
        $self->{logger}->log(4, "_handle_facebook() not a supported Facebook URL: " . ($url // '<undef>'));
        return undef;
    }

    $self->{logger}->log(4, "_handle_facebook() start url=$fb_url");

    my $title;

    # Step 1: cheap HTTP fetch.  On your server, HTTP::Tiny follows
    # facebook.com -> www.facebook.com and can receive a normal 200 page.
    my $http = _make_http(
        timeout  => 8,
        max_size => 1024 * 1024,
    );

    my $res = eval { $http->get($fb_url); } // { success => 0, status => 0, reason => $@ };

    if ($res->{success}) {
        my $content = _decode_http_content_utf8($self, $res->{content} // '', 'facebook-http');
        my $len = length($content);
        $self->{logger}->log(4, "_handle_facebook() HTTP fetched $len bytes for $fb_url");
        $title = _facebook_title_from_html($self, $content, 'HTTP');
    }
    else {
        $self->{logger}->log(4, "_handle_facebook() HTTP $res->{status} $res->{reason} for $fb_url");
    }

    # Step 2: Chromium fallback.  This is useful for Facebook shells where
    # the initial HTML is present but the useful title is rendered or altered.
    unless (defined $title && $title ne '') {
        $self->{logger}->log(4, "_handle_facebook() falling back to Chromium rendered DOM");

        my $dom = _fetch_url_chromium_dumpdom(
            $self,
            $fb_url,
            virtual_time_budget => 4500,
            alarm_timeout       => 14,
            lang                => 'fr-FR',
        );

        if (defined $dom && $dom ne '') {
            my $len = length($dom);
            $self->{logger}->log(4, "_handle_facebook() Chromium DOM fetched $len bytes for $fb_url");
            $title = _facebook_title_from_html($self, $dom, 'Chromium');
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

    my $msg = "$badge\x0f " . substr($title, 0, 300);

    botPrivmsg($self, $channel, "($nick) $msg");
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

    my $title;

    # X is rendered/client-heavy.  Go directly through Chromium, the same
    # strategy used for stubborn Facebook shells.
    my $dom = _fetch_url_chromium_dumpdom(
        $self,
        $x_url,
        virtual_time_budget => 6500,
        alarm_timeout       => 16,
        lang                => 'fr-FR',
    );

    if (defined $dom && $dom ne '') {
        my $len = length($dom);
        $self->{logger}->log(4, "_handle_x_twitter() Chromium DOM fetched $len bytes for $x_url");
        $title = _x_title_from_html($self, $dom, 'Chromium');
    }
    else {
        $self->{logger}->log(4, "_handle_x_twitter() Chromium returned no usable DOM for $x_url");
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

    my $msg = "$badge\x0f " . substr($title, 0, 300);

    botPrivmsg($self, $channel, "($nick) $msg");
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

    $title = substr($title, 0, 300);

    return $title;
}

# ---------------------------------------------------------------------------
# _handle_generic_title($self, $message, $nick, $channel, $url)
# Generic URL: fetch page, extract <title>. No HTML::Tree — regex is enough.
# ---------------------------------------------------------------------------
sub _handle_generic_title {
    my ($self, $message, $nick, $channel, $url) = @_;

    my $http = _make_http(
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
    my $label = String::IRC->new("URL Title from $nick:")->grey('black');
    botPrivmsg($self, $channel, "$label\x0f $title");
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
    unless (defined $url && $url =~ /^https?:\/\//i) {
        $self->{logger}->log(4, "displayUrlTitle() no valid URL found in: $sText");
        return undef;
    }

    $self->{logger}->log(4, "displayUrlTitle() URL: $url");

    # ── 1. YouTube ─────────────────────────────────────────────────────────
    # All YouTube URL variants (watch, shorts, live, youtu.be, nocookie, m., music.)
    my $yt_id = _is_youtube_url($url);
    if (defined $yt_id) {
        unless (_chanset_ok($self, $sChannel, 'Youtube')) {
            $self->{logger}->log(4, "displayUrlTitle() YouTube chanset not enabled on $sChannel");
            return undef;
        }
        # Delegate to displayYoutubeDetails which uses the YouTube Data API v3
        return displayYoutubeDetails($self, $message, $sNick, $sChannel, $url);
    }

    # ── 2. Instagram ───────────────────────────────────────────────────────
    if ($url =~ /instagram\.com/i) {
        unless (_chanset_ok($self, $sChannel, 'UrlTitle')) {
            $self->{logger}->log(4, "displayUrlTitle() UrlTitle chanset not enabled on $sChannel (Instagram)");
            return undef;
        }
        return _handle_instagram($self, $message, $sNick, $sChannel, $url);
    }

    # ── 3. Spotify ─────────────────────────────────────────────────────────
    if ($url =~ /open\.spotify\.com/i) {
        unless (_chanset_ok($self, $sChannel, 'UrlTitle')) {
            $self->{logger}->log(4, "displayUrlTitle() UrlTitle chanset not enabled on $sChannel (Spotify)");
            return undef;
        }
        return _handle_spotify($self, $message, $sNick, $sChannel, $url);
    }

    # ── 4. Apple Music ─────────────────────────────────────────────────────
    if ($url =~ /music\.apple\.com/i) {
        unless (_chanset_ok($self, $sChannel, 'AppleMusic')) {
            $self->{logger}->log(4, "displayUrlTitle() AppleMusic chanset not enabled on $sChannel");
            return undef;
        }
        return _handle_applemusic($self, $message, $sNick, $sChannel, $url);
    }

    # ── 5. Facebook ────────────────────────────────────────────────────────
    if ($url =~ m{https?://(?:www\.)?facebook\.com(?:/|$)}i) {
        unless (_chanset_ok($self, $sChannel, 'UrlTitle')) {
            $self->{logger}->log(4, "displayUrlTitle() UrlTitle chanset not enabled on $sChannel (Facebook)");
            return undef;
        }
        return _handle_facebook($self, $message, $sNick, $sChannel, $url);
    }

    # ── 6. X / Twitter ─────────────────────────────────────────────────────
    if ($url =~ m{https?://(?:www\.)?(?:x|twitter)\.com(?:/|$)}i) {
        unless (_chanset_ok($self, $sChannel, 'UrlTitle')) {
            $self->{logger}->log(4, "displayUrlTitle() UrlTitle chanset not enabled on $sChannel (X/Twitter)");
            return undef;
        }
        return _handle_x_twitter($self, $message, $sNick, $sChannel, $url);
    }

    # ── 7. Generic ─────────────────────────────────────────────────────────
    unless (_chanset_ok($self, $sChannel, 'UrlTitle')) {
        $self->{logger}->log(4, "displayUrlTitle() UrlTitle chanset not enabled on $sChannel");
        return undef;
    }
    return _handle_generic_title($self, $message, $sNick, $sChannel, $url);
}

# debug [0-5]
# Show or set the bot debug level.
# Requires: authenticated + Owner
sub youtubeSearch_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $message = $ctx->message;
    my $nick    = $ctx->nick;
    my $chan    = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # Args
    unless (@args && defined $args[0] && $args[0] ne "") {
        botNotice($self, $nick, "Syntax: yt <search>");
        return;
    }

    my $conf   = $self->{conf};
    my $APIKEY = $conf->get('main.YOUTUBE_APIKEY');

    unless (defined($APIKEY) && $APIKEY ne "") {
        $self->{logger}->log(1, "youtubeSearch_ctx() YOUTUBE_APIKEY not set in " . $self->{config_file});
        return;
    }

    my $query_txt = join(" ", @args);
    my $q_enc     = uri_escape_utf8($query_txt);

    # ---------- 1) search endpoint: get up to 3 videos ----------
    my $search_url =
        "https://www.googleapis.com/youtube/v3/search"
        . "?part=snippet"
        . "&type=video"
        . "&maxResults=3"
        . "&q=$q_enc"
        . "&key=$APIKEY"
        . "&fields=items(id/videoId)";

    my $json_search = '';
    {
        my $http_s = _make_http(timeout => 10);
        my $res_s  = eval { $http_s->get($search_url); }
                  // { success => 0, status => 0, reason => $@ };

        unless ($res_s->{success}) {
            $self->{logger}->log(
                2,
                "youtubeSearch_ctx(): HTTP "
                . ($res_s->{status} // 0)
                . " "
                . ($res_s->{reason} // '')
                . " for search endpoint"
            );
            botPrivmsg($self, $chan, "($nick) YouTube: service unavailable (search).");
            return;
        }

        $json_search = $res_s->{content} // '';
        unless ($json_search ne '') {
            $self->{logger}->log(2, "youtubeSearch_ctx(): empty search response");
            botPrivmsg($self, $chan, "($nick) YouTube: service unavailable (search).");
            return;
        }
    }

    my @video_ids;
    eval {
        my $data = decode_json($json_search);

        if (ref($data) eq 'HASH' && ref($data->{items}) eq 'ARRAY') {
            for my $item (@{ $data->{items} }) {
                next unless ref($item) eq 'HASH';
                next unless ref($item->{id}) eq 'HASH';

                my $video_id = $item->{id}{videoId};
                next unless defined($video_id) && $video_id =~ /^[A-Za-z0-9_-]{11}\z/;

                push @video_ids, $video_id;
                last if @video_ids >= 3;
            }
        }

        1;
    } or do {
        $self->{logger}->log(2, "youtubeSearch_ctx(): JSON decode/search parse error: $@");
        botPrivmsg($self, $chan, "($nick) YouTube: no result.");
        return;
    };

    unless (@video_ids) {
        botPrivmsg($self, $chan, "($nick) YouTube: no result.");
        return;
    }

    # ---------- 2) videos endpoint: fetch metadata for selected IDs ----------
    my $ids_enc = join(',', @video_ids);

    my $videos_url =
        "https://www.googleapis.com/youtube/v3/videos"
        . "?id=$ids_enc"
        . "&key=$APIKEY"
        . "&part=snippet,contentDetails,statistics"
        . "&fields=items(id,snippet/title,snippet/channelTitle,contentDetails/duration,statistics/viewCount)";

    my $json_vid = '';
    {
        my $http_v = _make_http(timeout => 10);
        my $res_v  = eval { $http_v->get($videos_url); }
                  // { success => 0, status => 0, reason => $@ };

        unless ($res_v->{success}) {
            $self->{logger}->log(
                2,
                "youtubeSearch_ctx(): HTTP "
                . ($res_v->{status} // 0)
                . " "
                . ($res_v->{reason} // '')
                . " for videos endpoint"
            );
            botPrivmsg($self, $chan, "($nick) https://www.youtube.com/watch?v=$video_ids[0]");
            return;
        }

        $json_vid = $res_v->{content} // '';
        unless ($json_vid ne '') {
            $self->{logger}->log(2, "youtubeSearch_ctx(): empty videos response");
            botPrivmsg($self, $chan, "($nick) https://www.youtube.com/watch?v=$video_ids[0]");
            return;
        }
    }

    my %video_by_id;
    eval {
        my $data = decode_json($json_vid);

        if (ref($data) eq 'HASH' && ref($data->{items}) eq 'ARRAY') {
            for my $it (@{ $data->{items} }) {
                next unless ref($it) eq 'HASH';

                my $id = $it->{id};
                next unless defined($id) && $id ne '';

                my $snippet = ref($it->{snippet})        eq 'HASH' ? $it->{snippet}        : {};
                my $details = ref($it->{contentDetails}) eq 'HASH' ? $it->{contentDetails} : {};
                my $stats   = ref($it->{statistics})     eq 'HASH' ? $it->{statistics}     : {};

                $video_by_id{$id} = {
                    title         => $snippet->{title}        // '',
                    channel_title => $snippet->{channelTitle} // '',
                    duration      => $details->{duration}     // '',
                    views         => $stats->{viewCount}      // '',
                };
            }
        }

        1;
    } or do {
        $self->{logger}->log(2, "youtubeSearch_ctx(): JSON decode/videos parse error: $@");
        botPrivmsg($self, $chan, "($nick) https://www.youtube.com/watch?v=$video_ids[0]");
        return;
    };

    my @entries;

    for my $video_id (@video_ids) {
        my $info = $video_by_id{$video_id};
        next unless ref($info) eq 'HASH';

        my $title         = $info->{title}         // '';
        my $channel_title = $info->{channel_title} // '';
        my $dur_iso       = $info->{duration}      // '';
        my $views         = $info->{views}         // '';

        if (($title         =~ tr/A-Z//) > 20) { $title         = ucfirst(lc($title)); }
        if (($channel_title =~ tr/A-Z//) > 20) { $channel_title = ucfirst(lc($channel_title)); }

        my $dur_disp   = _yt_format_duration($dur_iso);
        my $views_disp = ($views ne '' && $views =~ /^\d+$/) ? "views $views" : "views ?";
        my $url        = "https://www.youtube.com/watch?v=$video_id";

        my $entry = _yt_text(" $title ");

        if ($dur_disp ne '') {
            $entry .= _yt_sep("- ");
            $entry .= _yt_meta("$dur_disp ");
        }

        $entry .= _yt_sep("- ");
        $entry .= _yt_meta("$views_disp ");

        if ($channel_title ne '') {
            $entry .= _yt_sep("- ");
            $entry .= _yt_meta("by $channel_title ");
        }

        $entry .= _yt_sep("- ");
        $entry .= _yt_meta($url);

        push @entries, $entry;
        last if @entries >= 3;
    }

    unless (@entries) {
        botPrivmsg($self, $chan, "($nick) YouTube: no result.");
        return;
    }

    # ---------- output: same colors as displayYoutubeDetails(), one visible line per result ----------
    for my $i (0 .. $#entries) {
        my $rank = $i + 1;
        my $msg  = _yt_label();
        $msg    .= _yt_sep(" $rank/" . scalar(@entries) . " ");
        $msg    .= $entries[$i];

        $msg =~ s/\r|\n//g;

        botPrivmsg($self, $chan, "($nick) $msg");
    }

    logBot($self, $message, $chan, "yt", $query_txt);

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
        botNotice($self, $nick, "Syntax: f <username>");
        return;
    }

    # API key from config
    my $api_key = eval { $self->{conf}->get('fortnite.API_KEY') } // '';
    unless ($api_key) {
        $self->{logger}->log(1, "fortniteStats_ctx(): fortnite.API_KEY is undefined in config file");
        return;
    }

    # Auth + level checks (Context)
    my $user = $ctx->user || $self->get_user_from_message($message);
    unless ($user && $user->is_authenticated) {
        my $who = $user ? ($user->nickname // 'unknown') : 'unknown';
        my $msg = $message->prefix . " f command attempt (user $who is not logged in)";
        noticeConsoleChan($self, $msg);
        botNotice($self, $nick,
            "You must be logged to use this command - /msg "
          . $self->{irc}->nick_folded
          . " login username password"
        );
        logBot($self, $message, undef, "f", $msg);
        return;
    }

    unless (eval { $user->has_level("User") }) {
        my $lvl = eval { $user->level_description } || eval { $user->level } || '?';
        my $msg = $message->prefix . " f command attempt (requires User for "
                . ($user->nickname // $nick) . " [$lvl])";
        noticeConsoleChan($self, $msg);
        botNotice($self, $nick, "This command is not available for your level. Contact a bot master.");
        logBot($self, $message, undef, "f", $msg);
        return;
    }

    my $target_name = $args[0];

    # Resolve internal user + fortniteid (keep legacy helpers)
    my $id_user = getIdUser($self, $target_name);
    unless (defined $id_user) {
        botNotice($self, $nick, "Undefined user $target_name");
        return;
    }

    my $account_id = getFortniteId($self, $target_name);
    unless (defined $account_id && $account_id ne '') {
        botNotice($self, $nick, "Undefined fortniteid for user $target_name");
        return;
    }

    # Call API
    my $url = "https://fortnite-api.com/v2/stats/br/v2/$account_id";

    my $http = _make_http(timeout => 10);
    my $http_response = eval { $http->get(
        $url,
        { headers => { 'Authorization' => $api_key } }
    ) } // { success => 0, status => 0, reason => $@ };

    unless ($http_response->{success}) {
        $self->{logger}->log(3, "fortniteStats_ctx(): HTTP error $http_response->{status} $http_response->{reason}");
        botPrivmsg($self, $reply_to, "Fortnite stats: service unavailable, try again later.");
        return;
    }

    my $json_details = $http_response->{content};
    unless (defined $json_details && $json_details ne '') {
        $self->{logger}->log(3, "fortniteStats_ctx(): empty API response for $target_name/$account_id");
        botPrivmsg($self, $reply_to, "Fortnite stats: service unavailable, try again later.");
        return;
    }

    my $data = eval { decode_json($json_details) };
    if ($@ || ref($data) ne 'HASH') {
        $self->{logger}->log(3, "fortniteStats_ctx(): JSON decode/structure error: $@");
        botPrivmsg($self, $reply_to, "Fortnite stats: unexpected API response.");
        return;
    }

    # API may return {status:..., error:...}
    if (exists $data->{status} && $data->{status} != 200) {
        my $err = $data->{error} // "API error";
        $self->{logger}->log(3, "fortniteStats_ctx(): API status=$data->{status} error=$err");
        botPrivmsg($self, $reply_to, "Fortnite stats: $err");
        return;
    }

    my $payload = $data->{data};
    unless ($payload && ref($payload) eq 'HASH') {
        botPrivmsg($self, $reply_to, "Fortnite stats: no data for this account.");
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

    botPrivmsg($self, $reply_to, $line);

    logBot($self, $message, $channel, "f", @args);
    return 1;
}

# ------------------------------------------------------------------
# CONSTANTS (all prefixed with CHATGPT_)
# ------------------------------------------------------------------
use constant {
    CHATGPT_API_URL      => 'https://api.openai.com/v1/chat/completions',
    CHATGPT_MODEL        => 'gpt-4o-mini',
    CHATGPT_TEMPERATURE  => 0.7,
    CHATGPT_MAX_TOKENS   => 400,
    CHATGPT_MAX_PRIVMSG  => 4,       # how many PRIVMSG we allow to send
    CHATGPT_WRAP_BYTES   => 400,     # safe IRC payload length
    CHATGPT_SLEEP_US     => 750_000, # µs between PRIVMSG
	CHATGPT_TRUNC_MSG    => ' [¯\_(ツ)_/¯ guess you can’t have everything…]',   # suffix when we truncate
};

use constant CHATGPT_SYSTEM_PROMPT =>
    'You always answer in a helpful and serious way, precise and never start your answer with « Oh là là » when the answer is in French. Always respond using a maximum of 10 lines of text and line-based. There is one chance on two the answer contains emojis.';

sub _chatgpt_conf_int {
    my ($self, $key, $default, $min, $max) = @_;

    my $value = $self->{conf}->get($key);

    return $default unless defined($value) && $value =~ /^\d+\z/;

    $value = int($value);
    return $default if defined($min) && $value < $min;
    return $default if defined($max) && $value > $max;

    return $value;
}

sub _chatgpt_conf_float {
    my ($self, $key, $default, $min, $max) = @_;

    my $value = $self->{conf}->get($key);

    return $default unless defined($value) && $value =~ /^\d+(?:\.\d+)?\z/;

    $value = 0 + $value;
    return $default if defined($min) && $value < $min;
    return $default if defined($max) && $value > $max;

    return $value;
}

sub _chatgpt_conf_string {
    my ($self, $key, $default) = @_;

    my $value = $self->{conf}->get($key);

    return $default unless defined($value) && $value ne '';

    return $value;
}

# chatGPT_ctx() — wrapper Context pour la commande publique !tellme
sub chatGPT_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my $message = $ctx->message;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    chatGPT($self, $message, $nick, $channel, @args);
}

# ------------------------------------------------------------------
# chatGPT()
# ------------------------------------------------------------------
sub chatGPT {
    my ($self, $message, $nick, $chan, @args) = @_;

    # --------------------------------------------------------------
    #  sanity / config checks
    # --------------------------------------------------------------
	my $api_key = $self->{conf}->get('openai.API_KEY')
    	or ($self->{logger}->log(0,'chatGPT() openai.API_KEY missing'), return);

    my $chatgpt_api_url     = _chatgpt_conf_string($self, 'openai.API_URL',     CHATGPT_API_URL);
    my $chatgpt_model          = _chatgpt_conf_string($self, 'openai.MODEL',          CHATGPT_MODEL);
    my $chatgpt_fallback_model = _chatgpt_conf_string($self, 'openai.FALLBACK_MODEL', '');
    my $chatgpt_temperature    = _chatgpt_conf_float( $self, 'openai.TEMPERATURE',    CHATGPT_TEMPERATURE, 0, 2);
    my $chatgpt_system_prompt  = _chatgpt_conf_string($self, 'openai.SYSTEM_PROMPT',  CHATGPT_SYSTEM_PROMPT);
    $chatgpt_system_prompt =~ s/\r|\n/ /g;
    $chatgpt_system_prompt = substr($chatgpt_system_prompt, 0, 800);
    my $chatgpt_max_tokens  = _chatgpt_conf_int(   $self, 'openai.MAX_TOKENS',  CHATGPT_MAX_TOKENS,  1, 4000);
    my $chatgpt_max_privmsg = _chatgpt_conf_int(   $self, 'openai.MAX_PRIVMSG', CHATGPT_MAX_PRIVMSG, 1, 8);
    my $chatgpt_wrap_bytes  = _chatgpt_conf_int(   $self, 'openai.WRAP_BYTES',  CHATGPT_WRAP_BYTES,  120, 450);
    my $chatgpt_sleep_us    = _chatgpt_conf_int(   $self, 'openai.SLEEP_US',    CHATGPT_SLEEP_US,    0, 2_000_000);

    unless ($chatgpt_api_url =~ m{^https://}i) {
        $self->{logger}->log(1, "chatGPT() invalid openai.API_URL, falling back to default");
        $chatgpt_api_url = CHATGPT_API_URL;
    }

    if ($chatgpt_fallback_model ne '' && $chatgpt_fallback_model !~ /^[A-Za-z0-9._:-]+\z/) {
        $self->{logger}->log(1, "chatGPT() invalid openai.FALLBACK_MODEL ignored");
        $chatgpt_fallback_model = '';
    }

    @args
        or (botNotice($self,$nick,'Syntax: tellme <prompt>'), return);

    # opt-in check (+chatGPT chanset)
    my $setlist = getIdChansetList($self,'chatGPT') // '';
    my $setid   = getIdChannelSet($self,$chan,$setlist) // '';
    return unless length $setid;

    # --------------------------------------------------------------
    # payload preparation
    # --------------------------------------------------------------
    my $prompt = join ' ', @args;
    $self->{logger}->log(5,"chatGPT() chatGPT prompt: $prompt");

    my $build_payload = sub {
        my ($model) = @_;

        return encode_json {
            model       => $model,
            temperature => $chatgpt_temperature,
            max_tokens  => $chatgpt_max_tokens,
            messages    => [
                { role => 'system',
                  content => $chatgpt_system_prompt
                },
                { role => 'user', content => $prompt },
            ],
        };
    };

    # --------------------------------------------------------------
    # call the API with HTTP::Tiny (non-blocking, no shell)
    # --------------------------------------------------------------
    my $http = _make_http(timeout => 30);

    my $send_request = sub {
        my ($model) = @_;

        return eval {
            $http->request(
                'POST',
                $chatgpt_api_url,
                {
                    headers => {
                        'Content-Type'  => 'application/json',
                        'Authorization' => "Bearer $api_key",
                    },
                    content => $build_payload->($model),
                }
            );
        } // { success => 0, status => 0, reason => $@ };
    };

    my $request_model  = $chatgpt_model;
    my $http_response  = $send_request->($request_model);
    my $fallback_tried = 0;

    if (
        !$http_response->{success}
        && $chatgpt_fallback_model ne ''
        && $chatgpt_fallback_model ne $request_model
        && (($http_response->{status} // 0) == 400
            || ($http_response->{status} // 0) == 403
            || ($http_response->{status} // 0) == 404)
    ) {
        $self->{logger}->log(
            1,
            "chatGPT() primary model $request_model failed with HTTP "
            . ($http_response->{status} // 0) . " "
            . ($http_response->{reason} // '')
            . "; retrying with fallback model $chatgpt_fallback_model"
        );

        $request_model  = $chatgpt_fallback_model;
        $http_response  = $send_request->($request_model);
        $fallback_tried = 1;
    }

    unless ($http_response->{success}) {
        $self->{logger}->log(
            1,
            "chatGPT() HTTP error: "
            . ($http_response->{status} // 0) . " "
            . ($http_response->{reason} // '')
            . " model=$request_model"
        );

        botPrivmsg($self, $chan, "($nick) Sorry, API did not answer.");
        return;
    }

    if ($fallback_tried) {
        $self->{logger}->log(1, "chatGPT() fallback model succeeded: $request_model");
    }

    my $response = $http_response->{content};
    unless ($response) {
        $self->{logger}->log(1, "chatGPT() empty response from API");
        botPrivmsg($self, $chan, "($nick) Sorry, API did not answer.");
        return;
    }

    # --------------------------------------------------------------
	# decode the JSON response
	# --------------------------------------------------------------
	my $data = eval { decode_json($response) };
	my $answer;

	if (
		!$@
		&& ref($data) eq 'HASH'
		&& ref($data->{choices}) eq 'ARRAY'
		&& ref($data->{choices}[0]) eq 'HASH'
		&& ref($data->{choices}[0]{message}) eq 'HASH'
		&& defined($data->{choices}[0]{message}{content})
		&& $data->{choices}[0]{message}{content} ne ''
	) {
		$answer = $data->{choices}[0]{message}{content};
	}

	if ($@ || !defined($answer) || $answer eq '') {
		$self->{logger}->log( 0, 'chatGPT() chatGPT invalid JSON response');
		$self->{logger}->log( 5, "chatGPT() Raw API response: $response");
		$self->{logger}->log( 3, "chatGPT() JSON decode error: $@") if $@;
		$self->{logger}->log( 3, "chatGPT() Missing expected content in response structure") unless $@;
		botPrivmsg($self, $chan, "($nick) Could not read API response.");
		return;
	}
    $self->{logger}->log(5,"chatGPT() chatGPT raw answer: $answer");

    # -------- minimise PRIVMSG --------------------------------------
    $answer =~ s/[\r\n]+/ /g;    # strip CR/LF
    $answer =~ s/\s{2,}/ /g;     # squeeze spaces

    my @chunk = _chatgpt_wrap($answer, $chatgpt_wrap_bytes);           # word-safe
    # … after  my @chunk = _chatgpt_wrap($answer);
    my $truncate   = @chunk > $chatgpt_max_privmsg;
    my $last       = $truncate ? $chatgpt_max_privmsg - 1 : $#chunk;

    if ($truncate) {
        my $suff  = CHATGPT_TRUNC_MSG;                   # funny suffix
        my $allow = $chatgpt_wrap_bytes - length($suff);  # bytes we can keep

        if (length($chunk[$last]) > $allow) {            # always enforce room
            $chunk[$last] = substr($chunk[$last], 0, $allow);
            $chunk[$last] =~ s/\s+\S*$//;                # backtrack to prev word
            $chunk[$last] =~ s/\s+$//;                   # trim trailing spaces
        }
        $chunk[$last] .= $suff;                          # now safe to append
    }

    for my $i (0..$last) {
        botPrivmsg($self,$chan,$chunk[$i]);
        usleep($chatgpt_sleep_us);
    }
    $self->{logger}->log(4,"chatGPT() sent ".($last+1)." PRIVMSG");
}

# ------------------------------------------------------------------
# helper: wrap text to ≤CHATGPT_WRAP_BYTES without splitting words
# ------------------------------------------------------------------
sub _chatgpt_wrap {
    my ($txt, $wrap_bytes) = @_;

    $wrap_bytes = CHATGPT_WRAP_BYTES
        unless defined($wrap_bytes) && $wrap_bytes =~ /^\d+\z/ && $wrap_bytes > 0;

    my @out;

    while (length $txt) {

        # If the remainder already fits, push and break
        if (length($txt) <= $wrap_bytes) {
            push @out, $txt;
            last;
        }

        # Look ahead up to the limit
        my $slice = substr($txt, 0, $wrap_bytes);
        my $break = rindex($slice, ' ');

        # If space found, split there; else hard split
        $break = $wrap_bytes if $break == -1;

        push @out, substr($txt, 0, $break, '');   # remove from $txt
        $txt =~ s/^\s+//;                         # trim leading spaces
    }
    return @out;
}

# xlogin
# Authenticate the bot to Undernet CSERVICE and set +x on itself.
# Requires:
#   - Logged in
#   - Level >= Master
# ---------------------------------------------------------------------------
# _repair_utf8_mojibake($text)
# Repair common IRC/client mojibake where UTF-8 bytes were decoded as CP1252.
# Example:
#   "piÃ¨ge de cristal" -> "piège de cristal"
# The function is deliberately conservative: if conversion fails or does not
# reduce suspicious mojibake markers, the original text is returned unchanged.
# ---------------------------------------------------------------------------
sub _repair_utf8_mojibake {
    my ($text) = @_;

    return $text unless defined $text;
    # B3: broaden detection — double-UTF8 produces various high-byte sequences
    return $text unless $text =~ /[\xC0-\xFF]{2,}|[ÃÂâÅÄÖÜ]/;

    my $score = sub {
        my ($s) = @_;
        return 9999 unless defined $s;
        return (() = $s =~ /[ÃÂâ�]/g);
    };

    # Best case: mojibake came from UTF-8 bytes decoded as Windows-1252.
    # This repairs both accents and typographic punctuation:
    #   piÃ¨ge        -> piège
    #   Lâ€™Ã©tÃ©      -> L’été
    my $fixed_cp1252 = eval {
        decode('UTF-8', encode('Windows-1252', $text));
    };

    if (!$@ && defined($fixed_cp1252) && $score->($fixed_cp1252) < $score->($text)) {
        return $fixed_cp1252;
    }

    # Fallback: mojibake came from UTF-8 bytes decoded as Latin-1.
    my $fixed_latin1 = eval {
        decode('UTF-8', pack('C*', map { ord($_) & 0xFF } split //, $text));
    };

    if (!$@ && defined($fixed_latin1) && $score->($fixed_latin1) < $score->($text)) {
        return $fixed_latin1;
    }

    return $text;
}

sub mbTMDBSearch_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @tArgs   = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    my $conf = $self->{conf};

    my $api_key = $conf->get('tmdb.API_KEY');
    unless (defined($api_key) && $api_key ne "") {
        $self->{logger}->log(1, "tmdb.API_KEY is undefined in config file");
        botNotice($self, $nick, "TMDB API key is missing in the configuration.");
        return;
    }

    unless (defined($tArgs[0]) && $tArgs[0] ne "") {
        botNotice($self, $nick, "Syntax: tmdb <movie or series name>");
        return;
    }

    my $query = join(" ", @tArgs);
    my $raw_query = $query;

    $query = _repair_utf8_mojibake($query);

    if ($query ne $raw_query) {
        $self->{logger}->log(4, "mbTMDBSearch_ctx() repaired mojibake query '$raw_query' -> '$query'");
    }

    my $lang  = getTMDBLangChannel($self, $channel) || 'en';
    $self->{logger}->log(4, "mbTMDBSearch_ctx() tmdb_lang for $channel is $lang");

    my $info = get_tmdb_info($api_key, $lang, $query, $self->{logger});
    unless ($info) {
        botPrivmsg($self, $channel, "($nick) No results found for '$query'.");
        return;
    }

    my $title    = $info->{title}    || $info->{name}          || "Unknown title";
    my $overview = $info->{overview} || "No synopsis available.";
    my $date     = $info->{release_date} || $info->{first_air_date} || "????";
    my $year     = ($date =~ /^(\d{4})/) ? $1 : "????";
    my $rating   = defined($info->{vote_average}) ? sprintf("%.1f", $info->{vote_average}) : "?";
    my $type     = exists($info->{title}) ? "Movie" : "TV Series";

    # Build the final IRC message first, then truncate the complete line.
    # The old code truncated only the overview based on prefix length; when the
    # prefix was long or MAIN_PROG_MAXLEN was too small, the computed overview
    # budget could become negative and produce odd output.
    my $maxlen = int(eval { $self->{conf}->get('main.MAIN_PROG_MAXLEN') } || 400);
    $maxlen = 120 if $maxlen < 120;
    $maxlen = 900 if $maxlen > 900;

    my $prefix = "($nick) [$type] \"$title\" ($year) - Rating: $rating/10 - ";
    my $reply  = $prefix . $overview;

    if (length($reply) > $maxlen) {
        my $cut = $maxlen - 3;
        $cut = 1 if $cut < 1;

        $reply = substr($reply, 0, $cut);
        $reply =~ s/\s+\S*$// if length($reply) > 40;  # backtrack to last complete word when useful
        $reply =~ s/[\s.,;:!?-]+\z//;
        $reply .= "...";
    }

    botPrivmsg($self, $channel, $reply);
}

# Get TMDB info using HTTP::Tiny
sub get_tmdb_info {
    my ($api_key, $lang, $query, $logger) = @_;

    $lang = 'en-US'
        unless defined($lang) && $lang =~ /^[A-Za-z]{2}(?:-[A-Za-z]{2})?\z/;

    my $encoded_query = uri_escape_utf8($query);
    my $encoded_lang  = uri_escape_utf8($lang);
    my $url = "https://api.themoviedb.org/3/search/multi?api_key=$api_key&language=$encoded_lang&query=$encoded_query";

    my $http     = _make_http(timeout => 10);
    my $response = eval { $http->get($url); } // { success => 0, status => 0, reason => $@ };

    unless ($response->{success}) {
        my $status = $response->{status} // 0;
        my $reason = $response->{reason} // '';

        if ($logger) {
            $logger->log(3, "get_tmdb_info() HTTP error: $status $reason");
        }

        return undef;
    }

    my $content = $response->{content} // '';
    unless ($content ne '') {
        $logger->log(3, "get_tmdb_info() empty response") if $logger;
        return undef;
    }

    my $data = eval { decode_json($content) };
    if ($@ || ref($data) ne 'HASH') {
        my $err = $@ || 'decoded response is not a HASH';
        $logger->log(3, "get_tmdb_info() JSON decode error: $err") if $logger;
        return undef;
    }

    unless (ref($data->{results}) eq 'ARRAY' && @{ $data->{results} }) {
        $logger->log(4, "get_tmdb_info() no results in TMDB response") if $logger;
        return undef;
    }

    # Find the first movie or TV result.  Be defensive: API responses can
    # contain partial entries, unexpected media types, or malformed data.
    my $result;
    foreach my $item (@{ $data->{results} }) {
        next unless ref($item) eq 'HASH';

        my $media_type = $item->{media_type} // '';
        next unless $media_type eq 'movie' || $media_type eq 'tv';

        $result = $item;
        last;
    }

    return $result;
}

# --- Helpers DEBUG ------------------------------------------------------------


1;
