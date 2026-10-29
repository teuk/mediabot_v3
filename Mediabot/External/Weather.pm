package Mediabot::External::Weather;

use strict;
use warnings;
use utf8;
use Exporter 'import';
use Mediabot::External::URLCodec qw(_uri_escape_bytes);

our @EXPORT_OK = qw(displayWeather_ctx);

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
    # Preserve spaces inside city names; _uri_escape_bytes encodes them for HTTP.
    $location =~ s/^\s+|\s+$//g;

    # Cache (keyed by location)
    my $cache_key = lc($location);
    $self->{_weather_cache} ||= {};
    my $cache = $self->{_weather_cache}{$cache_key};

    my $now = time();
    my $ttl_ok = 180;  # 3 minutes
    my $ttl_stale = 900; # 15 minutes (fallback if provider unhappy)

    my $cache_age = $cache && defined($cache->{ts}) ? $now - $cache->{ts} : undef;
    if (defined($cache_age) && $cache_age >= 0 && $cache_age <= $ttl_ok && ($cache->{text}||'') ne '') {
        Mediabot::Helpers::botPrivmsg($self, $channel, $cache->{text});
        return 1;
    }

    # Build wttr request
    # A bit richer than before, still short:
    # %l location, %c icon, %t temp, %f feelslike, %h humidity, %w wind, %p precip
    my $format = '%l: %c %t (feels %f) | 💧%h | 🌬%w | ☔%p';

    my $encoded = _uri_escape_bytes($location);
    my $url = "https://wttr.in/$encoded?format=" . _uri_escape_bytes($format) . "&m";

    my $project_url = eval { $self->{conf}->get('main.MAIN_PROG_URL') }
        || 'https://github.com/teuk/mediabot_v3';

    my $weather_agent = "mediabot_v3 weather/1.0 (+$project_url)";

    my $http = Mediabot::External::_make_http(
        timeout    => 4,
        agent      => $weather_agent,
        verify_SSL => 1,   # explicit verified TLS for the weather endpoint
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
        # HTTP may consume the remaining lifetime or span a clock adjustment.
        my $age = $cache && defined($cache->{ts}) ? time() - $cache->{ts} : undef;
        if (defined($age) && $age >= 0 && $age <= $ttl_stale && ($cache->{text}||'') ne '') {
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
    $now = time(); # Date the completed response, not the start of its request.
    $self->{_weather_cache}{$cache_key} = { ts => $now, text => $line };

    # Remove expired data first, then the oldest excess entries, so a burst of
    # recent locations cannot grow the cache beyond max_entries.
    # This runs lazily at write time rather than on a timer.
    my $max_age = 900;  # 15 minutes (ttl_stale)
    my $max_entries = 200;
    my $cache_ref = $self->{_weather_cache};
    if (scalar(keys %$cache_ref) > $max_entries) {
        for my $k (keys %$cache_ref) {
            delete $cache_ref->{$k}
                if ($now - ($cache_ref->{$k}{ts} // 0)) > $max_age;
        }
        for my $k (sort {
            ($cache_ref->{$a}{ts} // 0) <=> ($cache_ref->{$b}{ts} // 0)
                || $a cmp $b
        } grep { $_ ne $cache_key } keys %$cache_ref) {
            last if scalar(keys %$cache_ref) <= $max_entries;
            delete $cache_ref->{$k};
        }
    }
    Mediabot::Helpers::botPrivmsg($self, $channel, $line);
    Mediabot::Helpers::logBot($self, $ctx->message, $channel, "weather", $location);

    return 1;
}

1;
