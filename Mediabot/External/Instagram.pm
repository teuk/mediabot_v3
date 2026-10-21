package Mediabot::External::Instagram;

use strict;
use warnings;
use utf8;
use Exporter 'import';
use Encode qw(decode);
use String::IRC;
use Mediabot::AsyncWorker;

our $VERSION = '1.00';
our @EXPORT_OK = qw(
    _instagram_url_info
    _instagram_clean_meta_value
    _instagram_meta_from_html
    _instagram_parse_social_description
    _instagram_fetch_sync
    _instagram_build_display
    _handle_instagram
);

# URL retains the historical aliases. Resolve its helper symbols at call time
# so existing decoder, cache-key and Instagram overrides keep their effect.
# Loading URL here is deferred to calls to support either module load order.

sub _instagram_url_info {
    my ($url) = @_;

    return { kind => 'link', label => 'Instagram', icon => '🔗' }
        unless defined $url && $url ne '';

    my $path = $url;
    $path =~ s{\Ahttps?://(?:www\.)?instagram\.com}{}i;
    $path =~ s/[?#].*\z//;
    $path =~ s{/+\z}{};
    $path =~ s{\A/+}{};

    if ($path =~ m{\A(p|reel|tv)/([^/]+)\z}i) {
        my ($raw_kind, $ref) = (lc($1), $2);
        return {
            kind  => $raw_kind eq 'p' ? 'post' : $raw_kind,
            label => $raw_kind eq 'p' ? 'Post' : $raw_kind eq 'reel' ? 'Reel' : 'Video',
            icon  => $raw_kind eq 'p' ? '📷' : $raw_kind eq 'reel' ? '🎬' : '📺',
            ref   => $ref,
        };
    }

    if ($path =~ m{\Astories/highlights/([^/]+)\z}i) {
        return {
            kind  => 'highlight',
            label => 'Highlight',
            icon  => '✨',
            ref   => $1,
        };
    }

    if ($path =~ m{\Astories/([^/]+)/([^/]+)\z}i) {
        return {
            kind  => 'story',
            label => 'Story',
            icon  => '📖',
            owner => $1,
            ref   => $2,
        };
    }

    if ($path =~ m{\A([^/]+)\z} && $1 !~ /\A(?:accounts|about|direct|emails|explore|legal|privacy|reels?|stories|web)\z/i) {
        return {
            kind  => 'profile',
            label => 'Profile',
            icon  => '👤',
            owner => $1,
        };
    }

    return { kind => 'link', label => 'Instagram', icon => '🔗' };
}

sub _instagram_clean_meta_value {
    my ($value) = @_;
    require Mediabot::External::URL;
    return undef unless defined $value;

    $value = Mediabot::External::URL::_decode_html($value);
    $value =~ s/[\r\n\t]+/ /g;
    $value =~ s/\s{2,}/ /g;
    $value =~ s/^\s+|\s+$//g;

    return undef if $value eq '';
    return undef if $value =~ /^Instagram$/i;
    return undef if $value =~ /create an account or log in to instagram/i;
    return undef if $value =~ /log in to instagram/i;

    return $value;
}

sub _instagram_meta_from_html {
    my ($html) = @_;
    require Mediabot::External::URL;
    return {} unless defined $html && $html ne '';

    my %meta;

    while ($html =~ /<meta\b([^>]*?)>/sig) {
        my $attrs = $1;
        my %attr;

        while ($attrs =~ /\b([A-Za-z_:.-]+)\s*=\s*(["'])(.*?)\2/sig) {
            $attr{lc($1)} = $3;
        }

        my $key = lc($attr{property} // $attr{name} // '');
        next unless $key =~ /\A(?:og:title|og:description|twitter:title|twitter:description|description)\z/;
        next unless exists $attr{content};
        next if exists $meta{$key};

        my $value = Mediabot::External::URL::_instagram_clean_meta_value($attr{content});
        $meta{$key} = $value if defined $value;
    }

    if ($html =~ /<title[^>]*>(.*?)<\/title>/si) {
        my $title = Mediabot::External::URL::_instagram_clean_meta_value($1);
        $meta{title} = $title if defined $title;
    }

    return \%meta;
}

sub _instagram_parse_social_description {
    my ($desc) = @_;
    return undef unless defined $desc && $desc ne '';

    # With the crawler request forced to en-US Instagram commonly serves:
    #   55K likes, 282 comments - natgeo on April 1, 2025: "caption...".
    if ($desc =~ /^\s*([0-9][0-9.,]*\s*[KMB]?)\s+likes?,\s*([0-9][0-9.,]*\s*[KMB]?)\s+comments?\s+-\s+([A-Za-z0-9._]+)\s+on\s+(.+?):\s*["“](.*)["”]\.??\s*$/s) {
        my ($likes, $comments, $owner, $date, $caption) = ($1, $2, $3, $4, $5);
        for ($likes, $comments, $owner, $date, $caption) {
            $_ =~ s/\s+/ /g if defined $_;
            $_ =~ s/^\s+|\s+$//g if defined $_;
        }
        $caption =~ s/\.\z// if defined $caption && $caption =~ /\.\z/;

        return {
            likes    => $likes,
            comments => $comments,
            owner    => $owner,
            date     => $date,
            caption  => $caption,
        };
    }

    return undef;
}

sub _instagram_fetch_sync {
    my ($url) = @_;
    require Mediabot::External::URL;

    my $http = Mediabot::External::_make_http(
        timeout  => 4,
        max_size => 1024 * 1024,
        agent    => 'facebookexternalhit/1.1 (+http://www.facebook.com/externalhit_uatext.php)',
        default_headers => { 'accept-language' => 'en-US,en;q=0.8' },
    );

    my $res = eval { $http->get($url); } // {
        success => 0,
        status  => 0,
        reason  => $@,
    };

    unless ($res->{success}) {
        return {
            ok     => 0,
            status => int($res->{status} // 0),
            reason => substr(($res->{reason} // 'HTTP fetch failed'), 0, 160),
            meta   => {},
        };
    }

    my $content = $res->{content} // '';
    eval { $content = decode('UTF-8', $content, 1); 1 };

    my $meta = Mediabot::External::URL::_instagram_meta_from_html($content);

    return {
        ok     => 1,
        status => int($res->{status} // 200),
        bytes  => length($content),
        meta   => $meta,
    };
}

sub _instagram_build_display {
    my ($url_info, $fetch) = @_;
    require Mediabot::External::URL;

    $url_info = {} unless ref($url_info) eq 'HASH';
    $fetch    = {} unless ref($fetch) eq 'HASH';

    my $meta = ref($fetch->{meta}) eq 'HASH' ? $fetch->{meta} : {};
    my $desc = $meta->{'og:description'}
        // $meta->{'twitter:description'}
        // $meta->{description};
    my $headline = $meta->{'og:title'}
        // $meta->{'twitter:title'}
        // $meta->{title};

    my @parts;
    push @parts, (($url_info->{icon} // '🔗') . ' ' . ($url_info->{label} // 'Instagram'));

    # Instagram can return a generic Story viewer shell for an unavailable
    # story id.  The title is generic and the description contains profile
    # counters, not story-specific content.  Suppress only that combination so
    # a real Story with useful metadata is still rendered normally.
    if (($url_info->{kind} // '') eq 'story'
        && defined($headline)
        && defined($desc)
        && $headline =~ /^Watch this story by .+ on Instagram before it disappears\.?$/i
        && $desc =~ /^\s*[0-9][0-9.,]*\s*[KMB]?\s+Followers,\s*
                      [0-9][0-9.,]*\s*[KMB]?\s+Following,\s*
                      [0-9][0-9.,]*\s*[KMB]?\s+Posts\s*$/ix) {
        $headline = undef;
        $desc = undef;
    }

    my $structured = Mediabot::External::URL::_instagram_parse_social_description($desc);
    if ($structured) {
        my $owner = $structured->{owner} // $url_info->{owner};
        push @parts, '@' . $owner if defined $owner && $owner ne '';
        push @parts, '❤️ ' . $structured->{likes}
            if defined $structured->{likes} && $structured->{likes} ne '';
        push @parts, '💬 ' . $structured->{comments}
            if defined $structured->{comments} && $structured->{comments} ne '';
        push @parts, '📅 ' . $structured->{date}
            if defined $structured->{date} && $structured->{date} ne '';
        push @parts, $structured->{caption}
            if defined $structured->{caption} && $structured->{caption} ne '';
    }
    else {
        my $owner = $url_info->{owner};
        push @parts, '@' . $owner if defined $owner && $owner ne '';

        my @detail;
        if (defined $headline && $headline ne '' && $headline !~ /^Instagram$/i) {
            push @detail, $headline;
        }
        if (defined $desc && $desc ne '') {
            my $duplicate = @detail && index(lc($desc), lc($detail[0])) >= 0;
            push @detail, $desc unless $duplicate;
        }

        if (@detail) {
            push @parts, @detail;
        }
        elsif (($url_info->{kind} // '') ne 'profile') {
            push @parts, 'public details unavailable';
        }
    }

    my $display = join(' · ', grep { defined $_ && $_ ne '' } @parts);
    $display =~ s/\s+/ /g;
    $display =~ s/^\s+|\s+$//g;

    return $display ne '' ? $display : '🔗 Instagram';
}

sub _handle_instagram {
    my ($self, $message, $nick, $channel, $url) = @_;
    require Mediabot::External::URL;

    $self->{logger}->log(4, "_handle_instagram() start url=$url");

    my $cache_key = Mediabot::External::URL::_url_cache_identity($url);

    # Preserve the existing badge/result cache (TTL 10 min).
    my $ig_cached = $self->{_instagram_cache}{$cache_key};
    if ($ig_cached && (time() - ($ig_cached->{ts} // 0)) < 600) {
        $self->{logger}->log(4, "_handle_instagram() cache hit for $url");
        Mediabot::Helpers::botPrivmsg($self, $channel, "($nick) $ig_cached->{msg}");
        return 1;
    }

    my $url_info = Mediabot::External::URL::_instagram_url_info($url);

    my $finish = sub {
        my ($fetch, $worker_status) = @_;
        delete $self->{_instagram_pending}{$cache_key};

        $fetch = {} unless ref($fetch) eq 'HASH';
        my $status = int($fetch->{status} // 0);
        my $bytes  = int($fetch->{bytes} // 0);
        my $ok     = $fetch->{ok} ? 1 : 0;

        $self->{logger}->log(4,
            "_handle_instagram() fetch done ok=$ok status=$status bytes=$bytes worker="
            . (defined($worker_status) ? $worker_status : 'sync'));

        my $title = Mediabot::External::URL::_instagram_build_display($url_info, $fetch);
        $title = Mediabot::Helpers::truncate_utf8($title, 300, '…');

        my $badge = String::IRC->new("[")->white('black');
        $badge   .= String::IRC->new("Instagram")->white('pink');
        $badge   .= String::IRC->new("]")->white('black');

        # Keep the historical Instagram badge exactly as-is. Reset immediately
        # afterwards so all rich details use the IRC client's normal foreground
        # and remain readable on both dark and light themes.
        my $msg = "$badge\x0f " . $title;
        $self->{_instagram_cache}{$cache_key} = { ts => time(), msg => $msg };

        Mediabot::Helpers::botPrivmsg($self, $channel, "($nick) $msg");
        return 1;
    };

    # At runtime URL processing happens inside the IRC event loop. Never run
    # Instagram's network request there: even a normal timeout must not stall
    # PRIVMSG processing. Tests and isolated probes without an IO::Async loop
    # keep a deterministic synchronous adapter around the same fetch function.
    my $loop = eval { $self->getLoop };
    $loop ||= $self->{loop} if ref($self) eq 'HASH' || ref($self);

    if ($loop
        && eval { $loop->can('add') }
        && eval { $loop->can('remove') }
        && eval { $loop->can('watch_process') }) {

        if ($self->{_instagram_pending}{$cache_key}) {
            $self->{logger}->log(4, "_handle_instagram() request already pending for $url");
            return 1;
        }
        $self->{_instagram_pending}{$cache_key} = time();

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
                my $error = $@ || 'unknown Instagram completion error';
                $error =~ s/\s+/ /g;
                delete $self->{_instagram_pending}{$cache_key};
                $self->{logger}->log(1, "_handle_instagram() completion failed: $error");
            };
        };

        my $worker;
        my $launch_ok = eval {
            $worker = Mediabot::AsyncWorker->start(
                loop        => $loop,
                label       => 'instagram metadata',
                timeout     => 6,
                term_grace  => 0.2,
                force_grace => 1.0,
                max_output  => 16 * 1024,
                child       => sub {
                    return Mediabot::External::URL::_instagram_fetch_sync($url);
                },
                on_done => $done,
            );
            1;
        };

        if (!$launch_ok && !$adapter_done) {
            my $error = $@ || 'AsyncWorker launch failed';
            $error =~ s/\s+/ /g;
            $self->{logger}->log(2, "_handle_instagram() async launch failed: $error");
            $done->({ ok => 0, error => 'worker_setup' });
        }
        elsif (!$worker && !$adapter_done) {
            $done->({ ok => 0, error => 'worker_setup' });
        }

        return 1;
    }

    return $finish->(Mediabot::External::URL::_instagram_fetch_sync($url), 'sync-no-loop');
}

1;

__END__

=head1 NAME

Mediabot::External::Instagram - Instagram metadata, display and async delivery

=head1 COMPATIBILITY

The URL router and External facade retain their historical entry points.
Instagram owns its parser, HTTP fetch, display, metadata cache and worker
lifecycle. Cross-calls resolve the legacy URL helper symbols at call time.
The existing HTTP factory and IRC helpers remain runtime dependencies.

No browser fallback, cache policy, worker deadline or presentation rule is
changed by this extraction.

=cut
