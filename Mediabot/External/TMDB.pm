package Mediabot::External::TMDB;

use strict;
use warnings;
use utf8;
use Exporter 'import';
use Encode qw(encode decode);
use JSON::MaybeXS;
use Scalar::Util qw(looks_like_number);
use POSIX qw(isfinite);
use URI::Escape qw(uri_escape_utf8);
use Mediabot::IRC::TextBudget qw(_irc_wire_bytes _irc_prefix_for_budget);

our @EXPORT_OK = qw(_repair_utf8_mojibake mbTMDBSearch_ctx get_tmdb_info _tmdb_first_nonempty);

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
        Mediabot::Helpers::botNotice($self, $nick, "TMDB API key is missing in the configuration.");
        return;
    }

    unless (defined($tArgs[0]) && $tArgs[0] ne "") {
        Mediabot::Helpers::botNotice($self, $nick, "Syntax: tmdb <movie or series name>");
        return;
    }

    my $query = join(" ", @tArgs);
    my $raw_query = $query;

    $query = _repair_utf8_mojibake($query);

    if ($query ne $raw_query) {
        $self->{logger}->log(4, "mbTMDBSearch_ctx() repaired mojibake query '$raw_query' -> '$query'");
    }

    my $lang  = Mediabot::External::getTMDBLangChannel($self, $channel) || 'en';
    $self->{logger}->log(4, "mbTMDBSearch_ctx() tmdb_lang for $channel is $lang");

    my $info = get_tmdb_info($api_key, $lang, $query, $self->{logger});
    unless ($info) {
        Mediabot::Helpers::botPrivmsg($self, $channel, "($nick) No results found for '$query'.");
        return;
    }

    # mb424-R1: TMDB renvoie parfois un titre LOCALISÉ vide (film sans
    # traduction dans la langue demandée) alors que original_title/original_name
    # est rempli -> l'ancien "$info->{title} || $info->{name}" affichait
    # "Unknown title". On déroule tous les champs de titre. Le type dérive du
    # media_type déjà validé par get_tmdb_info (source de vérité) au lieu de la
    # simple présence d'un champ.
    my $title = _tmdb_first_nonempty(
        $info->{title}, $info->{name},
        $info->{original_title}, $info->{original_name},
    ) // "Unknown title";
    my $overview = $info->{overview};
    $overview = "No synopsis available."
        unless defined($overview) && !ref($overview) && $overview =~ /\S/;
    my $date     = _tmdb_first_nonempty($info->{release_date}, $info->{first_air_date}) // "????";
    my $year     = ($date =~ /^(\d{4})/) ? $1 : "????";
    my $vote     = $info->{vote_average};
    my $rating   = defined($vote) && !ref($vote)
        && looks_like_number($vote) && isfinite(0 + $vote)
        ? sprintf("%.1f", $vote) : "?";
    my $type     = (($info->{media_type} // '') eq 'tv') ? "TV Series" : "Movie";

    # Build the final IRC message first, then truncate the complete line.
    # The old code truncated only the overview based on prefix length; when the
    # prefix was long or MAIN_PROG_MAXLEN was too small, the computed overview
    # budget could become negative and produce odd output.
    my $maxlen = int(eval { $self->{conf}->get('main.MAIN_PROG_MAXLEN') } || 400);
    $maxlen = 120 if $maxlen < 120;
    $maxlen = 900 if $maxlen > 900;

    my $prefix = "($nick) [$type] \"$title\" ($year) - Rating: $rating/10 - ";
    my $reply  = $prefix . $overview;

    # MB877: the complete IRC payload is bounded in UTF-8 bytes, including
    # its prefix and the three-byte truncation suffix.
    if (_irc_wire_bytes($reply) > $maxlen) {
        my $cut = $maxlen - 3;
        $cut = 1 if $cut < 1;

        # No more than $cut characters can fit in $cut bytes. Limit the
        # shared splitter's input before it considers the UTF-8 byte costs.
        $reply = _irc_prefix_for_budget(substr($reply, 0, $cut), $cut);
        $reply =~ s/\s+\S*$// if length($reply) > 40;  # backtrack to last complete word when useful
        $reply =~ s/[\s.,;:!?-]+\z//;
        $reply .= "...";
    }

    Mediabot::Helpers::botPrivmsg($self, $channel, $reply);
}

# mb424-R1: premier argument défini, non vide (après trim), sinon undef.
sub _tmdb_first_nonempty {
    for my $v (@_) {
        next unless defined $v && !ref($v);
        (my $t = $v) =~ s/^\s+|\s+$//g;
        return $t if $t ne '';
    }
    return undef;
}

# Get TMDB info using HTTP::Tiny
sub get_tmdb_info {
    my ($api_key, $lang, $query, $logger) = @_;

    $lang = 'en-US'
        unless defined($lang) && $lang =~ /^[A-Za-z]{2}(?:-[A-Za-z]{2})?\z/;

    my $encoded_query = uri_escape_utf8($query);
    my $encoded_lang  = uri_escape_utf8($lang);
    my $url = "https://api.themoviedb.org/3/search/multi?api_key=$api_key&language=$encoded_lang&query=$encoded_query";

    my $http     = Mediabot::External::_make_http(timeout => 10, verify_SSL => 1);
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

1;
