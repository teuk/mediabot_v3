package Mediabot::External;

# =============================================================================
# Mediabot::External
# =============================================================================

use strict;
use warnings;
# mb94-R1: ajouter le dossier racine de l'application à @INC pour les sous-modules
# Cwd::abs_path garantit un chemin absolu quel que soit le cwd au lancement
BEGIN {
    use File::Basename qw(dirname);
    use Cwd qw(abs_path);
    my $root = abs_path(dirname(__FILE__) . '/..');
    push @INC, $root unless grep { $_ eq $root } @INC;
}
use constant YT_CACHE_TTL => 300;  # S5: YouTube result cache TTL (seconds)

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
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);

# mb94-R1: sous-module Spotify
require Mediabot::External::Spotify;
Mediabot::External::Spotify->import(qw(
    _spotify_is_bad
    _spotify_clean
    _spotify_duration_from_ms
    _spotify_duration_from_iso
    _spotify_extract_meta
    _spotify_extract_jsonish
    _handle_spotify
));

# mb95-R1: sous-module Claude/ChatGPT/TMDB
require Mediabot::External::Claude;
Mediabot::External::Claude->import(qw(
    _chatgpt_conf_int
    _chatgpt_conf_float
    _chatgpt_conf_string
    chatGPT_ctx
    chatGPT
    _chatgpt_wrap
    _repair_utf8_mojibake
    mbTMDBSearch_ctx
    get_tmdb_info
    claude_ctx
    claudeAI
    _claude_send_and_parse
));

# mb99-R1: sous-module YouTube/Weather/Fortnite
require Mediabot::External::YouTube;
Mediabot::External::YouTube->import(qw(
    getYoutubeDetails
    _youtube_html_fallback
    displayYoutubeDetails
    displayWeather_ctx
    _irc_color
    _yt_text
    _yt_sep
    _yt_meta
    _yt_format_duration
    _yt_duration_seconds
    _yt_label
    _is_youtube_url
    youtubeSearch_ctx
    getFortniteId
    fortniteStats_ctx
    ytSearch_ctx
));

# mb99-R1: sous-module URL/Instagram/Facebook/X/AppleMusic
require Mediabot::External::URL;
Mediabot::External::URL->import(qw(
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
));

our @EXPORT = qw(
    _chatgpt_wrap
    chatGPT
    chatGPT_ctx
    claudeAI
    claude_ctx
    ytSearch_ctx
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


# mb99-R1: getYoutubeDetails, displayYoutubeDetails, _yt_*, displayWeather_ctx,
# getFortniteId, fortniteStats_ctx, youtubeSearch_ctx, ytSearch_ctx
# déplacés dans Mediabot::External::YouTube

# _extract_url($text) — pull the first URL out of a message
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# _make_http(%opts) — shared HTTP::Tiny factory with SSL bypass
# HTTP 599 on HTTPS URLs usually means IO::Socket::SSL is present but
# certificate verification fails. SSL_options forces no-verify mode.
# ---------------------------------------------------------------------------
sub _make_http {
    my (%opts) = @_;
    # verify_SSL defaults to 0 for OVH/Kimsufi compatibility but caller can override (e.g. weather)
    my $verify = exists $opts{verify_SSL} ? $opts{verify_SSL} : 0;
    my %ssl_opts = $verify ? () : (SSL_options => { SSL_verify_mode => 0 });
    return HTTP::Tiny->new(
        timeout    => $opts{timeout}  // 8,
        agent      => $opts{agent}    // 'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:125.0) Gecko/20100101 Firefox/125.0',
        verify_SSL => $verify,
        %ssl_opts,
        max_size   => $opts{max_size} // 512 * 1024,
    );
}
# mb99-R1: _extract_url déplacée dans Mediabot::External::URL

# mb99-R1: _decode_html déplacée dans Mediabot::External::URL

# mb99-R1: _decode_http_content_utf8 déplacée dans Mediabot::External::URL

# mb99-R1: _fetch_url_chromium_dumpdom déplacée dans Mediabot::External::URL





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


# mb99-R1: _is_youtube_url déplacée dans Mediabot::External::YouTube



# ---------------------------------------------------------------------------
# _handle_instagram($self, $message, $nick, $channel, $url)
# Parses Instagram page for a title. Instagram's
# ---------------------------------------------------------------------------

# mb99-R1: _handle_instagram, _handle_facebook, _handle_x_twitter,
# _handle_applemusic, displayUrlTitle et helpers URL
# déplacés dans Mediabot::External::URL


# mb99-R1: youtubeSearch_ctx, getFortniteId, fortniteStats_ctx, ytSearch_ctx
# déplacés dans Mediabot::External::YouTube

1;
