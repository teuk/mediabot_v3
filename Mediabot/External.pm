package Mediabot::External;

# =============================================================================
# Mediabot::External
# =============================================================================

use strict;
use warnings;
use POSIX qw(strftime);
use Time::HiRes qw(usleep);
use List::Util qw(min);
use Exporter 'import';
use Encode qw(encode decode);
use Try::Tiny;
use Mediabot::Helpers;
use JSON::MaybeXS;
use URI::Escape qw(uri_escape_utf8 uri_escape);
use HTML::Entities qw(decode_entities);
use HTML::Entities '%entity2char';
use IO::Socket::SSL;
use HTTP::Tiny;
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
    _handle_generic_title
    _handle_instagram
    _handle_spotify
    _is_youtube_url
    _yt_label
    _youtube_html_fallback
    _make_http
);

sub getYoutubeDetails {
	my ($self,$sText) = @_;
	my $conf = $self->{conf};
	my $sYoutubeId;
	$self->{logger}->log(3,"getYoutubeDetails() $sText");
	if ( $sText =~ /http.*:\/\/www\.youtube\..*\/watch.*v=/i ) {
		$sYoutubeId = $sText;
		$sYoutubeId =~ s/^.*watch.*v=//;
		$sYoutubeId = substr($sYoutubeId,0,11);
	}
	elsif ( $sText =~ /http.*:\/\/m\.youtube\..*\/watch.*v=/i ) {
		$sYoutubeId = $sText;
		$sYoutubeId =~ s/^.*watch.*v=//;
		$sYoutubeId = substr($sYoutubeId,0,11);
	}
	elsif ( $sText =~ /http.*:\/\/music\.youtube\..*\/watch.*v=/i ) {
		$sYoutubeId = $sText;
		$sYoutubeId =~ s/^.*watch.*v=//;
		$sYoutubeId = substr($sYoutubeId,0,11);
	}
	elsif ( $sText =~ /http.*:\/\/youtu\.be.*/i ) {
		$sYoutubeId = $sText;
		$sYoutubeId =~ s/^.*youtu\.be\///;
		$sYoutubeId = substr($sYoutubeId,0,11);
	}
	if (defined($sYoutubeId) && ( $sYoutubeId ne "" )) {
		$self->{logger}->log(4,"getYoutubeDetails() sYoutubeId = $sYoutubeId");
		my $APIKEY = $conf->get('main.YOUTUBE_APIKEY');
		unless (defined($APIKEY) && ($APIKEY ne "")) {
			$self->{logger}->log(1,"getYoutubeDetails() API Youtube V3 DEV KEY not set in " . $self->{config_file});
			$self->{logger}->log(1,"getYoutubeDetails() section [main]");
			$self->{logger}->log(1,"getYoutubeDetails() YOUTUBE_APIKEY=key");
			return undef;
		}
		my $yt_url = "https://www.googleapis.com/youtube/v3/videos"
		           . "?id=$sYoutubeId&key=$APIKEY&part=snippet,contentDetails,statistics,status";
		my $http = HTTP::Tiny->new(timeout => 10);
		my $res  = $http->get($yt_url);
		unless ($res->{success}) {
			$self->{logger}->log(3,"getYoutubeDetails() HTTP error $res->{status} for $yt_url");
		}
		else {
			my $sTitle;
			my $sDuration;
			my $sDururationSeconds;
			my $sViewCount;
			my $json_details = $res->{content};
			$self->{logger}->log(5,"getYoutubeDetails() raw: $json_details");
			if (defined($json_details) && ($json_details ne "")) {
				$self->{logger}->log(4,"getYoutubeDetails() json_details : $json_details");
				my $sYoutubeInfo = eval { decode_json $json_details };
				if ($@ || !defined $sYoutubeInfo) {
					$self->{logger}->log(3, "getYoutubeDetails() JSON decode error: $@");
					return undef;
				}
				my %hYoutubeInfo = %$sYoutubeInfo;
				my @tYoutubeItems = $hYoutubeInfo{'items'};
				my @fTyoutubeItems = @{$tYoutubeItems[0]};
				$self->{logger}->log(4,"getYoutubeDetails() tYoutubeItems length : " . $#fTyoutubeItems);
				# Check items
				if ( $#fTyoutubeItems >= 0 ) {
					my %hYoutubeItems = %{$tYoutubeItems[0][0]};
					$self->{logger}->log(4,"getYoutubeDetails() title=" . ($hYoutubeItems{snippet}{localized}{title} // "?") . " duration=" . ($hYoutubeItems{contentDetails}{duration} // "?"));
					$sViewCount = "views $hYoutubeItems{'statistics'}{'viewCount'}";
					my $sTitleItem = $hYoutubeItems{'snippet'}{'localized'}{'title'};
					$sDuration = $hYoutubeItems{'contentDetails'}{'duration'};
					$self->{logger}->log(4,"getYoutubeDetails() sDuration : $sDuration");
					$sDuration =~ s/^PT//;
					my $sDisplayDuration;
					my $sHour = $sDuration;
					if ( $sHour =~ /H/ ) {
						$sHour =~ s/H.*$//;
						$sDisplayDuration .= "$sHour" . "h ";
						$sDururationSeconds = $sHour * 3600;
					}
					my $sMin = $sDuration;
					if ( $sMin =~ /M/ ) {
						$sMin =~ s/^.*H//;
						$sMin =~ s/M.*$//;
						$sDisplayDuration .= "$sMin" . "mn ";
						$sDururationSeconds += $sMin * 60;
					}
					my $sSec = $sDuration;
					if ( $sSec =~ /S/ ) {
						$sSec =~ s/^.*H//;
						$sSec =~ s/^.*M//;
						$sSec =~ s/S$//;
						$sDisplayDuration .= "$sSec" . "s";
						$sDururationSeconds += $sSec;
					}
					$self->{logger}->log(4,"getYoutubeDetails() sYoutubeInfo statistics duration : $sDisplayDuration");
					$self->{logger}->log(4,"getYoutubeDetails() sYoutubeInfo statistics viewCount : $sViewCount");
					$self->{logger}->log(4,"getYoutubeDetails() sYoutubeInfo statistics title : $sTitle");
					
					if (defined($sTitle) && ( $sTitle ne "" ) && defined($sDuration) && ( $sDuration ne "" ) && defined($sViewCount) && ( $sViewCount ne "" )) {
						my $sMsgSong .= String::IRC->new('You')->black('white');
						$sMsgSong .= String::IRC->new('Tube')->white('red');
						$sMsgSong .= String::IRC->new(" $sTitle ")->white('black');
						$sMsgSong .= String::IRC->new("- ")->orange('black');
						$sMsgSong .= String::IRC->new("$sDisplayDuration ")->grey('black');
						$sMsgSong .= String::IRC->new("- ")->orange('black');
						$sMsgSong .= String::IRC->new("$sViewCount")->grey('black');
						$sMsgSong =~ s/\r//;
						$sMsgSong =~ s/\n//;
						return($sDururationSeconds,$sMsgSong);
					}
					else {
						$self->{logger}->log(4,"getYoutubeDetails() one of the youtube field is undef or empty");
						if (defined($sTitle)) {
							$self->{logger}->log(4,"getYoutubeDetails() sTitle=$sTitle");
						}
						else {
							$self->{logger}->log(4,"getYoutubeDetails() sTitle is undefined");
						}
						
						if (defined($sDuration)) {
							$self->{logger}->log(4,"getYoutubeDetails() sDuration=$sDuration");
						}
						else {
							$self->{logger}->log(3,"getYoutubeDetails() sDuration is undefined");
						}
						if (defined($sViewCount)) {
							$self->{logger}->log(4,"getYoutubeDetails() sViewCount=$sViewCount");
						}
						else {
							$self->{logger}->log(4,"getYoutubeDetails() sViewCount is undefined");
						}
					}
				}
				else {
					$self->{logger}->log(3,"getYoutubeDetails() Invalid id : $sYoutubeId");
					my $sNoticeMsg = "getYoutubeDetails() Invalid id : $sYoutubeId";
					noticeConsoleChan($self,$sNoticeMsg);
				}
			}
			else {
				$self->{logger}->log(3,"getYoutubeDetails() empty response for: $yt_url");
			}
		}
	}
	else {
		$self->{logger}->log(3,"getYoutubeDetails() sYoutubeId could not be determined");
	}
	return undef;
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
    my $res  = $http->get($oembed_url);

    unless ($res->{success}) {
        if (($res->{status} // 0) == 404) {
            $self->{logger}->log(3, "_youtube_html_fallback() oEmbed 404 — video $video_id does not exist or is private");
        } else {
            $self->{logger}->log(3, "_youtube_html_fallback() oEmbed HTTP $res->{status} for $video_id");
        }
        return undef;
    }

    my $data = eval { decode_json($res->{content}) };
    if ($@ || !ref $data) {
        $self->{logger}->log(3, "_youtube_html_fallback() oEmbed JSON parse error: $@");
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
    $msg .= String::IRC->new(" $title ")->white('black');
    if ($author_name ne '') {
        $msg .= String::IRC->new("- ")->orange('black');
        $msg .= String::IRC->new("by $author_name")->grey('black');
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

    my $http     = HTTP::Tiny->new(timeout => 8);
    my $response = $http->get($url);

    unless ($response->{success}) {
        $self->{logger}->log(3, "displayYoutubeDetails() HTTP error $response->{status} for $sYoutubeId");
        return undef;
    }

    my $json_details = $response->{content};
    unless (defined($json_details) && $json_details ne '') {
        $self->{logger}->log(3, "displayYoutubeDetails() empty response for $sYoutubeId");
        return undef;
    }

    $self->{logger}->log(4, "displayYoutubeDetails() json_details : $json_details");

    my $sYoutubeInfo = eval { decode_json($json_details) };
    if ($@ || !ref($sYoutubeInfo)) {
        $self->{logger}->log(3, "displayYoutubeDetails() JSON decode error: $@");
        return undef;
    }

    my @fTyoutubeItems = @{ $sYoutubeInfo->{items} // [] };
    $self->{logger}->log(4, "displayYoutubeDetails() tYoutubeItems length : " . $#fTyoutubeItems);

    unless (@fTyoutubeItems && $fTyoutubeItems[0]) {
        $self->{logger}->log(3, "displayYoutubeDetails() API returned no items for $sYoutubeId — trying HTML fallback");
        return _youtube_html_fallback($self, $sNick, $sChannel, $sText, $sYoutubeId);
    }

    my $item         = $fTyoutubeItems[0];
    my $sViewCount   = "views " . ($item->{statistics}{viewCount} // '?');
    my $sTitle       = $item->{snippet}{localized}{title}  // '';
    my $schannelTitle = $item->{snippet}{channelTitle}     // '';
    my $sDuration    = $item->{contentDetails}{duration}   // '';

    $self->{logger}->log(4, "displayYoutubeDetails() sDuration : $sDuration");
    $self->{logger}->log(4, "displayYoutubeDetails() sViewCount : $sViewCount");
    $self->{logger}->log(4, "displayYoutubeDetails() sTitle : $sTitle");
    $self->{logger}->log(4, "displayYoutubeDetails() schannelTitle : $schannelTitle");

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
    my $sMsgSong = String::IRC->new('[')->white('black');
    $sMsgSong   .= String::IRC->new('You')->black('white');
    $sMsgSong   .= String::IRC->new('Tube')->white('red');
    $sMsgSong   .= String::IRC->new(']')->white('black');
    $sMsgSong   .= String::IRC->new(" $sTitle ")->white('black');
    $sMsgSong   .= String::IRC->new("- ")->orange('black');
    $sMsgSong   .= String::IRC->new("$sDisplayDuration ")->grey('black');
    $sMsgSong   .= String::IRC->new("- ")->orange('black');
    $sMsgSong   .= String::IRC->new("$sViewCount ")->grey('black');
    $sMsgSong   .= String::IRC->new("- ")->orange('black');
    $sMsgSong   .= String::IRC->new("by $schannelTitle")->grey('black');

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

    my $http = HTTP::Tiny->new(
        timeout => 4,
        agent   => "mediabot_v3 weather/1.0 (+https://teuk.org)",
        verify_SSL => 1,
    );

    my $res = $http->get($url, {
        headers => {
            'Accept'          => 'text/plain',
            'Accept-Language' => 'fr-FR,fr;q=0.9,en;q=0.5',
        }
    });

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
sub _yt_label {
    my $label = String::IRC->new('[')->white('black');
    $label   .= String::IRC->new('You')->black('white');
    $label   .= String::IRC->new('Tube')->white('red');
    $label   .= String::IRC->new(']')->white('black');
    return $label;
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
    $text =~ s/^.*?(https?:\/\/)/$1/i;
    $text =~ s/\s+.*$//;
    return $text;
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

    my $virtual_time_budget = $opts{virtual_time_budget} // 3500;
    my $alarm_timeout       = $opts{alarm_timeout}       // 12;
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

    $self->{logger}->log(4, "_fetch_url_chromium_dumpdom() exec: " . join(' ', @cmd));

    my $stderr = gensym;
    my $pid;
    my $stdout = '';

    my $ok = eval {
        local $SIG{ALRM} = sub { die "ALARM\n" };
        alarm $alarm_timeout;

        $pid = open3(undef, my $out, $stderr, @cmd);

        {
            local $/;
            $stdout = <$out> // '';
        }

        alarm 0;
        1;
    };

    if (!$ok) {
        my $err = $@ || 'unknown error';
        if ($pid) {
            eval { kill 'TERM', $pid };
            waitpid($pid, 0);
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

sub _extract_meta_content_by_attr {
    my ($html, $attr_name, $attr_value) = @_;
    return undef unless defined $html && defined $attr_name && defined $attr_value;

    while ($html =~ /<meta\b([^>]*?)>/sig) {
        my $attrs = $1;
        my %meta;

        while ($attrs =~ /\b([a-zA-Z_:.-]+)\s*=\s*(["'])(.*?)\2/sg) {
            $meta{lc $1} = $3;
        }

        next unless defined $meta{lc $attr_name};
        next unless lc($meta{lc $attr_name}) eq lc($attr_value);

        return $meta{content} if defined $meta{content} && $meta{content} ne '';
    }

    return undef;
}

sub _extract_title_tag {
    my ($html) = @_;
    return undef unless defined $html;

    if ($html =~ /<title[^>]*>(.*?)<\/title>/si) {
        my $title = $1;
        $title =~ s/\s+/ /g;
        $title =~ s/^\s+|\s+$//g;
        return $title;
    }

    return undef;
}

sub _json_unescape_basic {
    my ($s) = @_;
    return undef unless defined $s;

    $s =~ s/\\\\/\\/g;
    $s =~ s/\\"/"/g;
    $s =~ s#\\/#/#g;
    $s =~ s/\\n/ /g;
    $s =~ s/\\r/ /g;
    $s =~ s/\\t/ /g;
    $s =~ s/\s+/ /g;
    $s =~ s/^\s+|\s+$//g;

    return $s;
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
    if ($url =~ m{https?://(?:www\.|m\.|music\.)?youtube\.[a-z.]+/watch[^\s]*[?&]v=([A-Za-z0-9_-]{11})}i) {
        return $1;
    }
    # Shorts
    if ($url =~ m{https?://(?:www\.|m\.)?youtube\.[a-z.]+/shorts/([A-Za-z0-9_-]{11})}i) {
        return $1;
    }
    # Live
    if ($url =~ m{https?://(?:www\.|m\.)?youtube\.[a-z.]+/live/([A-Za-z0-9_-]{11})}i) {
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

    my ($shortcode) = $url =~ m{/p/([^/?#]+)/?};
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

    my $res = $http->get($url);

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
        $self->{logger}->log(3, "_handle_instagram() no usable title extracted for shortcode=$shortcode");
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

    my $msg = String::IRC->new("[")->white('black');
    $msg   .= String::IRC->new("Instagram")->white('pink');
    $msg   .= String::IRC->new("]")->white('black');
    $msg   .= " " . substr($title, 0, 300);

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

    # Strip query string (Spotify redirects work without it)
    (my $clean_url = $url) =~ s/\?.*$//;

    my $display;

    # ------------------------------------------------------------
    # Step 1: cheap HTTP fetch first
    # ------------------------------------------------------------
    my $http = _make_http(max_size => 256 * 1024);
    my $res  = $http->get($clean_url);

    if ($res->{success}) {
        my $content = _decode_http_content_utf8($self, $res->{content} // '', 'spotify-http');

        # Try og:title first
        if ($content =~ /<meta\s+property=["']og:title["']\s+content=["']([^"']+)["']/i) {
            $display = $1;
        }
        elsif ($content =~ /<meta\s+content=["']([^"']+)["']\s+property=["']og:title["']/i) {
            $display = $1;
        }

        # Fallback: <title>
        unless (defined $display && $display ne '') {
            if ($content =~ /<title[^>]*>([^<]+)<\/title>/i) {
                $display = $1;
                $display =~ s/\s*\|\s*Spotify\s*$//i;
            }
        }

        $display = _decode_html($display) if defined $display;

        $self->{logger}->log(4, "_handle_spotify() HTTP title=" . (defined $display ? $display : '<undef>'));
    }
    else {
        $self->{logger}->log(3, "_handle_spotify() HTTP $res->{status} $res->{reason} for $clean_url");
    }

    # ------------------------------------------------------------
    # Step 2: Chromium fallback if HTTP title is missing or generic
    # ------------------------------------------------------------
    my $display_check = defined($display) ? $display : '';
    $display_check =~ s/\s+/ /g;
    $display_check =~ s/^\s+|\s+$//g;

    if (!defined($display) || $display_check eq '' || $display_check =~ /spotify.*web player/i) {
        $self->{logger}->log(4, "_handle_spotify() falling back to Chromium rendered DOM for $clean_url");

        my $dom = _fetch_url_chromium_dumpdom($self, $clean_url);

        if (defined $dom && $dom ne '') {
            my $og_title;
            my $title_tag;

            if ($dom =~ /<meta\s+property=["']og:title["']\s+content=["']([^"']+)["']/i) {
                $og_title = $1;
            }
            elsif ($dom =~ /<meta\s+content=["']([^"']+)["']\s+property=["']og:title["']/i) {
                $og_title = $1;
            }

            if ($dom =~ /<title[^>]*>([^<]+)<\/title>/i) {
                $title_tag = $1;
                $title_tag =~ s/\s*\|\s*Spotify\s*$//i;
            }

            for ($og_title, $title_tag) {
                $_ = _decode_html($_) if defined $_;
            }

            $self->{logger}->log(4, "_handle_spotify() Chromium og:title=" . (defined $og_title ? $og_title : '<undef>'));
            $self->{logger}->log(4, "_handle_spotify() Chromium <title>=" . (defined $title_tag ? $title_tag : '<undef>'));

            if (defined $og_title && $og_title ne '' && $og_title !~ /spotify.*web player/i) {
                $display = $og_title;
                $self->{logger}->log(4, "_handle_spotify() selected Chromium og:title");
            }
            elsif (defined $title_tag && $title_tag ne '' && $title_tag !~ /spotify.*web player/i) {
                $display = $title_tag;
                $self->{logger}->log(4, "_handle_spotify() selected Chromium <title>");
            }
        }
    }

    unless (defined $display && $display ne '') {
        $self->{logger}->log(3, "_handle_spotify() could not extract title from $clean_url");
        return undef;
    }

    $display =~ s/\s+/ /g;
    $display =~ s/^\s+|\s+$//g;

    my $msg = String::IRC->new("[")->white('black');
    $msg   .= String::IRC->new("Spotify")->black('green');
    $msg   .= String::IRC->new("]")->white('black');
    $msg   .= " $display";

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
    my $res  = $http->get($url);

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
            virtual_time_budget => 7000,
            alarm_timeout       => 20,
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

    my $msg = String::IRC->new("[")->white('black');
    $msg   .= String::IRC->new("AppleMusic")->white('grey');
    $msg   .= String::IRC->new("]")->white('black');
    $msg   .= " $title";

    botPrivmsg($self, $channel, "($nick) $msg");
    return 1;
}

# ---------------------------------------------------------------------------
# _handle_generic_title($self, $message, $nick, $channel, $url)
# Generic URL: fetch page, extract <title>. No HTML::Tree — regex is enough.
# ---------------------------------------------------------------------------
sub _handle_generic_title {
    my ($self, $message, $nick, $channel, $url) = @_;

    my $http = _make_http();
    my $res  = $http->get($url);
    unless ($res->{success}) {
        $self->{logger}->log(3, "_handle_generic_title() HTTP $res->{status} $res->{reason} for $url");
        return undef;
    }

    my $content = _decode_http_content_utf8($self, $res->{content} // '', 'generic');
    my $title;

    if ($content =~ /<title[^>]*>(.*?)<\/title>/si) {
        $title = $1;
    }

    unless (defined $title && $title ne '') {
        $self->{logger}->log(4, "_handle_generic_title() no <title> found for $url");
        return undef;
    }

    $title = _decode_html($title);
    return undef if $title eq '';
    return undef if $title =~ /The page is temporarily unavailable/i;

    my $msg = String::IRC->new("URL Title from $nick:")->grey('black');
    botPrivmsg($self, $channel, "$msg $title");
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

    # ── 5. Twitter / X — ignored silently ──────────────────────────────────
    return undef if $url =~ /(?:twitter|x)\.com/i;

    # ── 6. Generic ─────────────────────────────────────────────────────────
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
    my $chan    = $ctx->channel;  # undef si privé
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # Feature gate via chanset
    my $id_chanset_list = getIdChansetList($self, "YoutubeSearch");
    return unless defined($id_chanset_list) && $id_chanset_list ne "";

    # en privé, on n’a pas de channel => on refuse (ou tu peux autoriser si tu veux)
    unless (defined $chan && $chan ne '') {
        botNotice($self, $nick, "yt can only be used in a channel (YoutubeSearch chanset scoped).");
        return;
    }

    my $id_channel_set = getIdChannelSet($self, $chan, $id_chanset_list);
    return unless defined($id_channel_set) && $id_channel_set ne "";

    # Args
    unless (@args && defined $args[0] && $args[0] ne "") {
        botNotice($self, $nick, "Syntax: yt <search>");
        return;
    }

    my $conf   = $self->{conf};
    my $APIKEY = $conf->get('main.YOUTUBE_APIKEY');

    unless (defined($APIKEY) && $APIKEY ne "") {
        $self->{logger}->log(1, "youtubeSearch_ctx() YOUTUBE_APIKEY not set in ".$self->{config_file});
        return;
    }

    my $query_txt = join(" ", @args);
    my $q_enc     = url_encode_utf8($query_txt);

    # ---------- 1) search endpoint (maxResults=1, type=video, fields réduits) ----------
    my $search_url =
        "https://www.googleapis.com/youtube/v3/search"
        . "?part=snippet"
        . "&type=video"
        . "&maxResults=1"
        . "&q=$q_enc"
        . "&key=$APIKEY"
        . "&fields=items(id/videoId)";

    my $json_search = '';
    {
        my $http_s = HTTP::Tiny->new(timeout => 10);
        my $res_s  = $http_s->get($search_url);
        unless ($res_s->{success}) {
            $self->{logger}->log(2, "youtubeSearch_ctx(): HTTP $res_s->{status} for search endpoint");
            botPrivmsg($self, $chan, "($nick) YouTube: service unavailable (search).");
            return;
        }
        $json_search = $res_s->{content} // '';
    }

    my $video_id;
    eval {
        my $data = decode_json($json_search);
        $video_id = $data->{items}[0]{id}{videoId};
        1;
    } or do {
        $self->{logger}->log(2, "youtubeSearch_ctx(): JSON decode/search parse error: $@");
        botPrivmsg($self, $chan, "($nick) YouTube: no result.");
        return;
    };

    unless (defined $video_id && $video_id ne '') {
        botPrivmsg($self, $chan, "($nick) YouTube: no result.");
        return;
    }

    # ---------- 2) videos endpoint (fields réduits) ----------
    my $videos_url =
        "https://www.googleapis.com/youtube/v3/videos"
        . "?id=$video_id"
        . "&key=$APIKEY"
        . "&part=snippet,contentDetails,statistics"
        . "&fields=items(snippet/title,contentDetails/duration,statistics/viewCount)";

    my $json_vid = '';
    {
        my $http_v = HTTP::Tiny->new(timeout => 10);
        my $res_v  = $http_v->get($videos_url);
        unless ($res_v->{success}) {
            $self->{logger}->log(2, "youtubeSearch_ctx(): HTTP $res_v->{status} for videos endpoint");
            botPrivmsg($self, $chan, "($nick) https://www.youtube.com/watch?v=$video_id");
            return;
        }
        $json_vid = $res_v->{content} // '';
    }

    my ($title, $dur_iso, $views);
    eval {
        my $data = decode_json($json_vid);
        my $it   = $data->{items}[0] || {};
        $title   = $it->{snippet}{title};
        $dur_iso = $it->{contentDetails}{duration};
        $views   = $it->{statistics}{viewCount};
        1;
    } or do {
        $self->{logger}->log(2, "youtubeSearch_ctx(): JSON decode/videos parse error: $@");
        botPrivmsg($self, $chan, "($nick) https://www.youtube.com/watch?v=$video_id");
        return;
    };

    $title   //= '';
    $dur_iso //= '';
    $views   //= '';

    my $dur_disp = _yt_format_duration($dur_iso);
    my $views_disp = ($views ne '' && $views =~ /^\d+$/) ? "views $views" : "views ?";

    # ---------- output (safe colors) ----------
    my $badge = _yt_badge();

    my $url = "https://www.youtube.com/watch?v=$video_id";
    my $msg = "$badge $url";
    $msg   .= " - $title" if $title ne '';
    $msg   .= " - $dur_disp" if $dur_disp ne '';
    $msg   .= " - $views_disp";

    botPrivmsg($self, $chan, "($nick) $msg");
    logBot($self, $message, $chan, "yt", $query_txt);

    return 1;
}

# Duration: ISO8601 "PT#H#M#S" -> "1h 02m 03s" / "3m 12s" / "45s"
sub getFortniteId {
	my ($self,$sUser) = @_;
	my $sQuery = "SELECT fortniteid FROM USER WHERE nickname LIKE ?";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute($sUser)) {
		$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
	}
	else {
		if (my $ref = $sth->fetchrow_hashref()) {
			my $fortniteid = $ref->{'fortniteid'};
			$sth->finish;
			return $fortniteid;
		}
		else {
			$sth->finish;
			return undef;
		}
	}
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

    my $http = HTTP::Tiny->new(timeout => 10);
    my $http_response = $http->get(
        $url,
        { headers => { 'Authorization' => $api_key } }
    );

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
    if ($@ || !$data) {
        $self->{logger}->log(3, "fortniteStats_ctx(): JSON decode error: $@");
        botPrivmsg($self, $reply_to, "Fortnite stats: unexpected API response.");
        return;
    }

    # API may return {status:..., error:...}
    if (ref($data) eq 'HASH' && exists $data->{status} && $data->{status} != 200) {
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

    my $account    = $payload->{account}    || {};
    my $battlepass = $payload->{battlePass} || {};

    # Some payloads are nested differently depending on API versions / modes
    my $overall = $payload->{stats}{all}{overall}
              || $payload->{stats}{all}{overall}{solo}   # defensive (rare)
              || {};

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

# chatGPT_ctx() — wrapper Context pour la commande publique !tellme
sub chatGPT_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my $message = $ctx->message;
    my @args    = @{ $ctx->args };

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
    $self->{logger}->log(4,"chatGPT() chatGPT prompt: $prompt");

    my $json = encode_json {
        model       => CHATGPT_MODEL,
        temperature => CHATGPT_TEMPERATURE,
        max_tokens  => CHATGPT_MAX_TOKENS,
        messages    => [
            { role => 'system',
              content =>
                'You always answer in a helpfull and serious way , precise and never start your answer with « Oh là là » when the answer is in french, always respond using a maximum of 10 lines of text and line-based. There is one chance on two the answer contains emojis'
            },
            { role => 'user', content => $prompt },
        ],
    };

    # --------------------------------------------------------------
    # call the API with HTTP::Tiny (non-blocking, no shell)
    # --------------------------------------------------------------
    my $http = HTTP::Tiny->new(timeout => 30);
    my $http_response = $http->request(
        'POST',
        CHATGPT_API_URL,
        {
            headers => {
                'Content-Type'  => 'application/json',
                'Authorization' => "Bearer $api_key",
            },
            content => $json,
        }
    );

    unless ($http_response->{success}) {
        $self->{logger}->log(1, "chatGPT() HTTP error: $http_response->{status} $http_response->{reason}");
        botPrivmsg($self, $chan, "($nick) Sorry, API did not answer.");
        return;
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
	if ($@ || !($data->{choices}[0]{message}{content} || '')) {
		$self->{logger}->log( 0, 'chatGPT() chatGPT invalid JSON response');
		$self->{logger}->log( 3, "chatGPT() Raw API response: $response");
		$self->{logger}->log( 3, "chatGPT() JSON decode error: $@") if $@;
		$self->{logger}->log( 3, "chatGPT() Missing expected content in response structure") unless $@;
		botPrivmsg($self, $chan, "($nick) Could not read API response.");
		return;
	}

	my $answer = $data->{choices}[0]{message}{content};
    $self->{logger}->log(4,"chatGPT() chatGPT raw answer: $answer");

    # -------- minimise PRIVMSG --------------------------------------
    $answer =~ s/[\r\n]+/ /g;    # strip CR/LF
    $answer =~ s/\s{2,}/ /g;     # squeeze spaces

    my @chunk = _chatgpt_wrap($answer);           # word-safe
    # … after  my @chunk = _chatgpt_wrap($answer);
    my $truncate   = @chunk > CHATGPT_MAX_PRIVMSG;
    my $last       = $truncate ? CHATGPT_MAX_PRIVMSG-1 : $#chunk;

    if ($truncate) {
        my $suff  = CHATGPT_TRUNC_MSG;                   # funny suffix
        my $allow = CHATGPT_WRAP_BYTES - length($suff);  # bytes we can keep

        if (length($chunk[$last]) > $allow) {            # always enforce room
            $chunk[$last] = substr($chunk[$last], 0, $allow);
            $chunk[$last] =~ s/\s+\S*$//;                # backtrack to prev word
            $chunk[$last] =~ s/\s+$//;                   # trim trailing spaces
        }
        $chunk[$last] .= $suff;                          # now safe to append
    }

    for my $i (0..$last) {
        botPrivmsg($self,$chan,$chunk[$i]);
        usleep(CHATGPT_SLEEP_US);
    }
    $self->{logger}->log(4,"chatGPT() sent ".($last+1)." PRIVMSG");
}

# ------------------------------------------------------------------
# helper: wrap text to ≤CHATGPT_WRAP_BYTES without splitting words
# ------------------------------------------------------------------
sub _chatgpt_wrap {
    my ($txt) = @_;
    my @out;

    while (length $txt) {

        # If the remainder already fits, push and break
        if (length($txt) <= CHATGPT_WRAP_BYTES) {
            push @out, $txt;
            last;
        }

        # Look ahead up to the limit
        my $slice = substr($txt, 0, CHATGPT_WRAP_BYTES);
        my $break = rindex($slice, ' ');

        # If space found, split there; else hard split
        $break = CHATGPT_WRAP_BYTES if $break == -1;

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
sub mbTMDBSearch_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @tArgs   = @{ $ctx->args };

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
    my $lang  = getTMDBLangChannel($self, $channel) || 'en';
    $self->{logger}->log(4, "mbTMDBSearch_ctx() tmdb_lang for $channel is $lang");

    my $info = get_tmdb_info($api_key, $lang, $query);
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

    # Truncate overview to fit within MAXLEN (prefix takes ~40 chars)
    my $maxlen   = $self->{conf}->get('main.MAIN_PROG_MAXLEN') || 400;
    my $prefix   = "($nick) [$type] \"$title\" ($year) - Rating: $rating/10 - ";
    my $overview_max = $maxlen - length($prefix) - 4; # 4 = "..." + margin
    if (length($overview) > $overview_max) {
        $overview = substr($overview, 0, $overview_max);
        $overview =~ s/\s+\S*$//;  # backtrack to last complete word
        $overview .= "...";
    }

    botPrivmsg($self, $channel, $prefix . $overview);
}

# Get TMDB info using curl
sub get_tmdb_info {
    my ($api_key, $lang, $query) = @_;

    my $encoded_query = uri_escape($query);
    my $url = "https://api.themoviedb.org/3/search/multi?api_key=$api_key&language=$lang&query=$encoded_query";

    my $http     = HTTP::Tiny->new(timeout => 10);
    my $response = $http->get($url);

    unless ($response->{success}) {
        warn "get_tmdb_info() HTTP error: $response->{status} $response->{reason}";
        return undef;
    }

    my $data = eval { decode_json($response->{content}) };
    return undef if $@ || !ref($data) || !$data->{results} || !@{$data->{results}};

    # Find the first movie or TV result
    my $result;
    foreach my $item (@{$data->{results}}) {
        next unless $item->{media_type} eq 'movie' || $item->{media_type} eq 'tv';
        $result = $item;
        last;
    }

    return $result;
}

# --- Helpers DEBUG ------------------------------------------------------------


1;
