package Mediabot::External::AppleMusic;

use strict;
use warnings;
use utf8;
use Exporter 'import';
use JSON::MaybeXS;
use Mediabot::AsyncWorker;
use URI::Escape qw(uri_escape_utf8);
use String::IRC;

our $VERSION = '1.00';
our @EXPORT_OK = qw(
    _am_duration_from_iso
    _am_duration_from_ms
    _applemusic_url_info
    _applemusic_extract_details
    _applemusic_lookup_track
    _applemusic_fetch_sync
    _handle_applemusic
);

# Resolve shared URL utilities at call time: URL imports the legacy AppleMusic
# aliases, and its HTTP/browser overrides must remain effective after extraction.
sub _decode_html {
    require Mediabot::External::URL;
    return Mediabot::External::URL::_decode_html(@_);
}
sub _decode_http_content_utf8 {
    require Mediabot::External::URL;
    return Mediabot::External::URL::_decode_http_content_utf8(@_);
}
sub _fetch_url_chromium_dumpdom {
    require Mediabot::External::URL;
    return Mediabot::External::URL::_fetch_url_chromium_dumpdom(@_);
}

# ---------------------------------------------------------------------------
# _handle_applemusic($self, $message, $nick, $channel, $url)
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# _am_duration_from_iso($iso) — Spotify-style IRC duration: "3m 33s", "1h02m03s"
# ---------------------------------------------------------------------------
sub _am_duration_from_iso {
    my ($iso) = @_;
    return undef unless defined $iso && $iso =~ /^P(?:[\d.]+D)?T?(?:(\d+)H)?(?:(\d+)M)?(?:([\d.]+)S)?$/i;
    my ($h, $m, $s) = ($1 // 0, $2 // 0, int($3 // 0));
    return undef unless $h || $m || $s;
    return sprintf('%dh%02dm%02ds', $h, $m, $s) if $h;
    return sprintf('%dm %02ds', $m, $s);
}

sub _am_duration_from_ms {
    my ($ms) = @_;
    return undef unless defined $ms && $ms =~ /^\d+$/;

    my $total = int($ms / 1000);
    return undef if $total <= 0;

    my $h = int($total / 3600);
    my $m = int(($total % 3600) / 60);
    my $s = $total % 60;

    return sprintf('%dh%02dm%02ds', $h, $m, $s) if $h;
    return sprintf('%dm %02ds', $m, $s);
}

sub _applemusic_url_info {
    my ($url) = @_;

    my ($storefront) = ($url // '') =~ m{^https?://music\.apple\.com/([a-z]{2})(?:/|$)}i;
    $storefront = lc($storefront // 'us');

    my ($track_id) = ($url // '') =~ /[?&]i=(\d+)/;
    if (!defined $track_id) {
        ($track_id) = ($url // '') =~ m{/song/(?:[^/?#]+/)?(\d+)(?:[/?#]|$)}i;
    }

    return {
        storefront => $storefront,
        track_id   => $track_id,
    };
}

sub _applemusic_extract_details {
    my ($self, $html) = @_;
    my %am;
    return \%am unless defined $html && $html ne '';

    while ($html =~ m{<script[^>]+type=["']application/ld\+json["'][^>]*>(.*?)</script>}sig) {
        my $raw  = _decode_html($1);
        my $data = eval { decode_json($raw) };
        next unless defined $data;
        my @objs = ref($data) eq 'ARRAY' ? @$data : ($data);
        for my $o (@objs) {
            next unless ref($o) eq 'HASH';
            my $t = $o->{'@type'} // '';
            $t = join(' ', @$t) if ref($t) eq 'ARRAY';
            if ($t =~ /MusicAlbum/i)                    { $am{type} //= 'album'; }
            elsif ($t =~ /MusicRecording|MusicSong/i)   { $am{type} //= 'song'; }
            elsif ($t =~ /MusicPlaylist/i)              { $am{type} //= 'playlist'; }
            if (my $a = $o->{byArtist}) {
                my @names = ref($a) eq 'ARRAY' ? map { ref($_) eq 'HASH' ? $_->{name} : $_ } @$a
                          : ref($a) eq 'HASH'  ? ($a->{name})
                          : ($a);
                @names = grep { defined && $_ ne '' } @names;
                $am{artist} //= join(', ', @names) if @names;
            }
            if (defined $o->{duration}) {
                my $d = _am_duration_from_iso($o->{duration});
                $am{duration} //= $d if defined $d;
            }
            if (defined $o->{datePublished} && $o->{datePublished} =~ /\b((?:19|20)\d{2})\b/) {
                $am{year} //= $1;
            }
            if (defined $o->{numTracks} && $o->{numTracks} =~ /^\d+$/) {
                $am{tracks} //= $o->{numTracks};
            }
            elsif (ref($o->{tracks} // $o->{track} // '') eq 'ARRAY') {
                my $n = scalar @{ $o->{tracks} // $o->{track} };
                $am{tracks} //= $n if $n;
            }
        }
    }

    my $desc;
    if    ($html =~ /<meta\s+property=["']og:description["']\s+content=(["'])(.*?)\1/is) { $desc = $2; }
    elsif ($html =~ /<meta\s+content=(["'])(.*?)\1\s+property=["']og:description["']/is) { $desc = $2; }
    elsif ($html =~ /<meta\s+name=["']description["']\s+content=(["'])(.*?)\1/is)        { $desc = $2; }
    elsif ($html =~ /<meta\s+content=(["'])(.*?)\1\s+name=["']description["']/is)        { $desc = $2; }
    if (defined $desc) {
        $desc = _decode_html($desc);
        for my $seg (split /\s*[·•]\s*/, $desc) {
            $seg =~ s/^\s+|\s+$//g;
            next if $seg eq '';
            if    ($seg =~ /^(Album|Single|EP|Song|Playlist)$/i)      { $am{type}   //= lc $1; }
            elsif ($seg =~ /^\s*((?:19|20)\d{2})\s*$/)                 { $am{year}   //= $1; }
            elsif ($seg =~ /^(\d+)\s+Songs?$/i)                        { $am{tracks} //= $1; }
        }
    }
    return \%am;
}

sub _applemusic_lookup_track {
    my ($self, $http, $storefront, $track_id) = @_;
    return undef unless defined $track_id && $track_id =~ /^\d+$/;

    my $lookup = 'https://itunes.apple.com/lookup?id=' . $track_id
               . '&country=' . uri_escape_utf8(uc($storefront // 'us'))
               . '&entity=song';

    my $res = eval { $http->get($lookup); } // {
        success => 0,
        status  => 0,
        reason  => $@,
    };

    unless ($res->{success}) {
        $self->{logger}->log(4,
            "_handle_applemusic() lookup HTTP $res->{status} $res->{reason} for track=$track_id");
        return undef;
    }

    my $data = eval { decode_json($res->{content} // '') };
    unless (ref($data) eq 'HASH') {
        my $error = $@ || 'not a JSON object';
        $error =~ s/\s+/ /g;
        $self->{logger}->log(4,
            "_handle_applemusic() lookup JSON decode failed for track=$track_id: $error");
        return undef;
    }

    my $results = ref($data->{results}) eq 'ARRAY' ? $data->{results} : [];
    my ($r) = grep {
        ref($_) eq 'HASH'
            && defined($_->{trackId})
            && "$_->{trackId}" eq "$track_id"
            && (!defined($_->{kind}) || $_->{kind} eq 'song')
    } @$results;

    return undef unless ref($r) eq 'HASH';

    my %am = (type => 'song');
    $am{artist} = $r->{artistName}
        if defined $r->{artistName} && $r->{artistName} ne '';
    $am{album} = $r->{collectionName}
        if defined $r->{collectionName} && $r->{collectionName} ne '';
    $am{year} = $1
        if defined($r->{releaseDate}) && $r->{releaseDate} =~ /^((?:19|20)\d{2})/;
    $am{duration} = _am_duration_from_ms($r->{trackTimeMillis})
        if defined $r->{trackTimeMillis};

    my $title = $r->{trackName};
    return undef unless defined $title && $title ne '';

    return {
        title   => $title,
        details => \%am,
        source  => 'itunes-lookup',
        status  => int($res->{status} // 200),
        bytes   => length($res->{content} // ''),
    };
}

sub _applemusic_fetch_sync {
    my ($self, $url) = @_;

    my $info = _applemusic_url_info($url);
    my $http = Mediabot::External::_make_http(
        timeout  => 12,
        max_size => 512 * 1024,
    );

    if (defined $info->{track_id}) {
        my $track = _applemusic_lookup_track(
            $self, $http, $info->{storefront}, $info->{track_id}
        );
        return $track if ref($track) eq 'HASH';
    }

    my $title;
    my $html_for_details = '';
    my $res = eval { $http->get($url); } // {
        success => 0,
        status  => 0,
        reason  => $@,
    };

    if ($res->{success}) {
        my $content = _decode_http_content_utf8(
            $self, $res->{content} // '', 'applemusic-http'
        );
        $html_for_details = $content;

        my ($og_title, $meta_description, $title_tag);

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

        for my $candidate ($og_title, $meta_description, $title_tag) {
            next unless defined $candidate && $candidate ne '';
            next if $candidate =~ /^\s*Apple Music\s*$/i;
            next if $candidate =~ /listen on apple music/i;
            next if $candidate =~ /open in music/i;
            $title = $candidate;
            last;
        }
    }
    else {
        $self->{logger}->log(3,
            "_handle_applemusic() HTTP $res->{status} $res->{reason} for $url");
    }

    my $title_check = defined($title) ? $title : '';
    $title_check =~ s/\s+/ /g;
    $title_check =~ s/^\s+|\s+$//g;

    if (!defined($title) || $title_check eq '' || $title_check =~ /^\s*Apple Music\s*$/i) {
        my $dom = _fetch_url_chromium_dumpdom(
            $self,
            $url,
            virtual_time_budget => 10000,
            alarm_timeout       => 30,
        );

        if (defined $dom && $dom ne '') {
            $html_for_details = $dom;
            my ($og_title, $meta_description, $title_tag);

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

            for my $candidate ($og_title, $meta_description, $title_tag) {
                next unless defined $candidate && $candidate ne '';
                next if $candidate =~ /^\s*Apple Music\s*$/i;
                next if $candidate =~ /listen on apple music/i;
                next if $candidate =~ /open in music/i;
                $title = $candidate;
                last;
            }
        }
    }

    return {
        title   => $title,
        details => _applemusic_extract_details($self, $html_for_details),
        source  => 'page-fallback',
        status  => int($res->{status} // 0),
        bytes   => length($html_for_details),
    };
}

sub _handle_applemusic {
    my ($self, $message, $nick, $channel, $url) = @_;

    $self->{logger}->log(4, "_handle_applemusic() start url=$url");

    my $info = _applemusic_url_info($url);
    my $cache_key = defined($info->{track_id})
        ? join(':', 'track', $info->{storefront}, $info->{track_id})
        : lc($url // '');

    my $cached = $self->{_applemusic_cache}{$cache_key};
    if ($cached && (time() - ($cached->{ts} // 0)) < 600) {
        $self->{logger}->log(4, "_handle_applemusic() cache hit for $url");
        Mediabot::Helpers::botPrivmsg($self, $channel, "($nick) $cached->{msg}");
        return 1;
    }

    my $finish = sub {
        my ($fetch, $worker_status) = @_;
        delete $self->{_applemusic_pending}{$cache_key};

        $fetch = {} unless ref($fetch) eq 'HASH';
        my $title = $fetch->{title};
        my $am = ref($fetch->{details}) eq 'HASH' ? $fetch->{details} : {};

        unless (defined $title && $title ne '') {
            $self->{logger}->log(3,
                "_handle_applemusic() could not extract title from $url worker="
                . (defined($worker_status) ? $worker_status : 'sync'));
            return undef;
        }

        $title =~ s/\s+/ /g;
        $title =~ s/^\s+|\s+$//g;

        my @parts = ($title);
        if (defined $am->{artist} && $am->{artist} ne ''
            && lc($am->{artist}) ne lc($title)
            && index(lc($title), lc($am->{artist})) < 0) {
            push @parts, "by $am->{artist}";
        }
        if (defined $am->{album} && $am->{album} ne ''
            && lc($am->{album}) ne lc($title)) {
            push @parts, "album $am->{album}";
        }
        push @parts, $am->{type}
            if defined $am->{type} && $am->{type} ne '' && lc($am->{type}) ne 'song';
        push @parts, $am->{year} if defined $am->{year};
        push @parts, $am->{duration} if defined $am->{duration};
        push @parts, "$am->{tracks} tracks"
            if defined $am->{tracks} && $am->{tracks} =~ /^\d+$/ && $am->{tracks} > 1;

        my $display = join(' - ', @parts);
        $display =~ s/\s+/ /g;
        $display =~ s/^\s+|\s+$//g;
        $display = Mediabot::Helpers::truncate_utf8($display, 300, '…');

        $self->{logger}->log(4,
            "_handle_applemusic() final display='$display' source=" . ($fetch->{source} // 'unknown'));

        my $badge = String::IRC->new("[")->white('black');
        $badge   .= String::IRC->new("AppleMusic")->white('grey');
        $badge   .= String::IRC->new("]")->white('black');
        # The previous Unicode badge upgraded the whole line. Retain that
        # representation when the new label itself contains only ASCII.
        utf8::upgrade($badge);
        my $msg = "$badge\x0f $display";

        $self->{_applemusic_cache}{$cache_key} = { ts => time(), msg => $msg };
        Mediabot::Helpers::botPrivmsg($self, $channel, "($nick) $msg");
        return 1;
    };

    my $loop = eval { $self->getLoop };
    $loop ||= $self->{loop} if ref($self);

    if ($loop
        && eval { $loop->can('add') }
        && eval { $loop->can('remove') }
        && eval { $loop->can('watch_process') }) {

        if ($self->{_applemusic_pending}{$cache_key}) {
            $self->{logger}->log(4,
                "_handle_applemusic() request already pending for $url");
            return 1;
        }
        $self->{_applemusic_pending}{$cache_key} = time();

        my $adapter_done = 0;
        my $done = sub {
            my ($result) = @_;
            return if $adapter_done++;

            my $fetch = {};
            my $worker_status = 'failed';
            if (ref($result) eq 'HASH' && $result->{ok}) {
                $fetch = ref($result->{value}) eq 'HASH' ? $result->{value} : {};
                $worker_status = 'ok';
            }
            elsif (ref($result) eq 'HASH') {
                $worker_status = $result->{error} // 'failed';
            }

            eval { $finish->($fetch, $worker_status); 1 } or do {
                my $error = $@ || 'unknown Apple Music completion error';
                $error =~ s/\s+/ /g;
                delete $self->{_applemusic_pending}{$cache_key};
                $self->{logger}->log(1,
                    "_handle_applemusic() completion failed: $error");
            };
        };

        my $worker;
        my $launch_ok = eval {
            $worker = Mediabot::AsyncWorker->start(
                loop        => $loop,
                label       => 'apple music metadata',
                timeout     => 45,
                term_grace  => 0.2,
                force_grace => 1.0,
                max_output  => 16 * 1024,
                child       => sub { return _applemusic_fetch_sync($self, $url); },
                on_done     => $done,
            );
            1;
        };

        if (!$launch_ok && !$adapter_done) {
            my $error = $@ || 'AsyncWorker launch failed';
            $error =~ s/\s+/ /g;
            $self->{logger}->log(2,
                "_handle_applemusic() async launch failed: $error");
            $done->({ ok => 0, error => 'worker_setup' });
        }
        elsif (!$worker && !$adapter_done) {
            $done->({ ok => 0, error => 'worker_setup' });
        }

        return 1;
    }

    return $finish->(_applemusic_fetch_sync($self, $url), 'sync-no-loop');
}

1;
