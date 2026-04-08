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
use Encode qw(encode);
use Try::Tiny;
use Mediabot::Helpers;
use JSON::MaybeXS;
use URI::Escape qw(uri_escape_utf8 uri_escape);
use HTML::Entities qw(decode_entities);
use HTML::Entities '%entity2char';

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
sub displayYoutubeDetails {
    my ($self, $message, $sNick, $sChannel, $sText) = @_;

    my $conf = $self->{conf};
    $self->{logger}->log(3, "displayYoutubeDetails() $sText");

    # --- Extraction du video ID ---
    my $sYoutubeId;
    if    ($sText =~ /https?:\/\/(?:www\.|m\.|music\.)?youtube\.[^\/]+\/watch.*[?&]v=([A-Za-z0-9_-]{11})/i) {
        $sYoutubeId = $1;
    }
    elsif ($sText =~ /https?:\/\/youtu\.be\/([A-Za-z0-9_-]{11})/i) {
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
        $self->{logger}->log(3, "displayYoutubeDetails() Invalid id : $sYoutubeId");
        return undef;
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
sub displayUrlTitle {
    my ($self, $message, $sNick, $sChannel, $sText) = @_;

    $self->{logger}->log(4, "displayUrlTitle() RAW input: $sText");

    # Extraction stricte de l'URL
    $sText =~ s/^.*http/http/;
    $sText =~ s/\s+.*$//;
    $self->{logger}->log(4, "displayUrlTitle() URL extracted: $sText");

    my $UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:109.0) Gecko/20100101 Firefox/117.0";
    my $http = HTTP::Tiny->new(
        timeout    => 5,
        agent      => $UA,
        verify_SSL => 0,
    );

    # --- Twitter (x.com) chanset ---
    if ($sText =~ /x\.com/) {
        my $id_chanset_list = getIdChansetList($self, "Twitter");
        if (defined $id_chanset_list && $id_chanset_list ne "") {
            my $id_channel_set = getIdChannelSet($self, $sChannel, $id_chanset_list);
            unless (defined $id_channel_set && $id_channel_set ne "") {
                return undef;
            }
        }
    }

    # --- Twitter special prank ---
    if (($sText =~ /x\.com/ || $sText =~ /twitter\.com/)
        && ($sNick =~ /^\[k\]$/ || $sNick =~ /^NHI$/ || $sNick =~ /^PersianYeti$/)) {
        $self->{logger}->log(4, "displayUrlTitle() Twitter URL = $sText");
        return undef;
    }

    # --- Instagram ---
    if ($sText =~ /instagram\.com/) {
        my $res = $http->get($sText);
        unless ($res->{success}) {
            $self->{logger}->log(3, "displayUrlTitle() insta HTTP error $res->{status}");
            return undef;
        }
        my $content = $res->{content} // '';
        my $title = $content;
        $title =~ s/^.*og:title" content="//;
        $title =~ s/" .><meta property="og:image".*$//;
        if ($title =~ /DOCTYPE html/) {
            $title = $content;
            $title =~ s/^.*<title//;
            $title =~ s/<\/title>.*$//;
            $title =~ s/^\s*>//;
        }
        if (defined($title) && $title ne "") {
            my $msg = String::IRC->new("[")->white('black');
            $msg .= String::IRC->new("Instagram")->white('pink');
            $msg .= String::IRC->new("]")->white('black');
            $msg .= " $title";
            my $regex = "&(?:" . join("|", map { s/;\z//; $_ } keys %entity2char) . ");";
            $msg = decode_entities($msg) if ($msg =~ /$regex/ || $msg =~ /&#.*;/);
            $msg = "($sNick) " . $msg;
            botPrivmsg($self, $sChannel, substr($msg, 0, 300)) unless $msg =~ /DOCTYPE html/;
        }
        return undef;
    }

    # --- HEAD request : vérification content-type + HTTP code ---
    my $head_res = $http->request('HEAD', $sText);
    my $iHttpResponseCode = $head_res->{status}  // 0;
    my $sContentType      = $head_res->{headers}{'content-type'} // '';
    # HTTP::Tiny suit les redirects, le status final est le bon
    $self->{logger}->log(4, "displayUrlTitle() HTTP code=$iHttpResponseCode content-type=$sContentType");

    unless ($iHttpResponseCode == 200) {
        $self->{logger}->log(3, "displayUrlTitle() Wrong HTTP response code ($iHttpResponseCode) for $sText");
        return undef;
    }

    unless ($sContentType =~ /text\/html/i) {
        $self->{logger}->log(3, "displayUrlTitle() Wrong Content-Type for $sText ($sContentType)");
        return undef;
    }

    # --- Spotify ---
    if ($sText =~ /open\.spotify\.com/) {
        my $url = $sText;
        $url =~ s/\?.*$//;
        my $res = $http->get($url);
        unless ($res->{success}) {
            $self->{logger}->log(0, "displayUrlTitle() Spotify HTTP error $res->{status}");
            return undef;
        }
        my $content = $res->{content} // '';
        if ($content =~ /<title[^>]*>(.*?)<\/title>/si) {
            my $sDisplayMsg = $1;
            $sDisplayMsg =~ s/^\s+|\s+$//g;
            my $artist = $sDisplayMsg;
            $artist =~ s/^.*song and lyrics by //;
            $artist =~ s/ \| Spotify//;
            my $song = $sDisplayMsg;
            $song =~ s/ - song and lyrics by.*$//;
            $self->{logger}->log(4, "displayUrlTitle() artist=$artist song=$song");
            my $sTextIrc = String::IRC->new("[")->white('black');
            $sTextIrc .= String::IRC->new("Spotify")->black('green');
            $sTextIrc .= String::IRC->new("]")->white('black');
            $sTextIrc .= " $artist - $song";
            my $regex = "&(?:" . join("|", map { s/;\z//; $_ } keys %entity2char) . ");";
            $sTextIrc = decode_entities($sTextIrc) if ($sTextIrc =~ /$regex/ || $sTextIrc =~ /&#.*;/);
            botPrivmsg($self, $sChannel, "($sNick) $sTextIrc");
        }
        return undef;
    }

    # --- URL générique ---
    my $res = $http->get($sText);
    unless ($res->{success}) {
        $self->{logger}->log(0, "displayUrlTitle() HTTP error $res->{status} for $sText");
        return undef;
    }

    my $sContent = $res->{content} // '';
    my $tree = HTML::Tree->new();
    $tree->parse($sContent);
    my ($title) = $tree->look_down('_tag', 'title');

    if (defined($title) && $title->as_text ne "") {
        if ($sText =~ /youtube\.com/ || $sText =~ /youtu\.be/) {
            my $yt = String::IRC->new('[')->white('black');
            $yt .= String::IRC->new('You')->black('white');
            $yt .= String::IRC->new('Tube')->white('red');
            $yt .= String::IRC->new(']')->white('black');
            botPrivmsg($self, $sChannel, "($sNick) $yt " . $title->as_text);
        }
        elsif ($sText =~ /music\.apple\.com/) {
            my $id_chanset_list = getIdChansetList($self, "AppleMusic");
            if (defined($id_chanset_list) && $id_chanset_list ne "") {
                my $id_channel_set = getIdChannelSet($self, $sChannel, $id_chanset_list);
                return undef unless defined($id_channel_set) && $id_channel_set ne "";
            }
            my $apple = String::IRC->new('[')->white('black');
            $apple .= String::IRC->new('AppleMusic')->white('grey');
            $apple .= String::IRC->new(']')->white('black');
            botPrivmsg($self, $sChannel, "($sNick) $apple " . $title->as_text);
        }
        else {
            unless ($title->as_text =~ /The page is temporarily unavailable/i) {
                my $msg = String::IRC->new("URL Title from $sNick:")->grey('black');
                botPrivmsg($self, $sChannel, $msg . " " . $title->as_text);
            }
        }
    }
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
