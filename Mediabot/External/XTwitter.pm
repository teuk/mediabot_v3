package Mediabot::External::XTwitter;

use strict;
use warnings;
use utf8;
use Exporter 'import';
use String::IRC;
use Time::HiRes ();  # Keep cache time() on the historical whole-second clock.

our $VERSION = '1.00';
our @EXPORT_OK = qw(
    _x_url
    _x_title_from_html
    _x_desc_from_html
    _x_compact_count
    _x_fallback_title_from_url
    _handle_x_twitter
);

# URL keeps the historical aliases. Resolve its normalizer, parsers, count
# formatter, JSON/HTML decoders, cache key and browser at call time so existing
# overrides remain effective. Dependent functions load URL lazily.

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
    require Mediabot::External::URL;

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

    $title = Mediabot::External::URL::_decode_html($title);
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
    require Mediabot::External::URL;
    return undef unless defined $html && $html ne '';

    my $desc;
    while ($html =~ /<meta\b([^>]*?)>/sig) {
        my $attrs = $1;
        next unless $attrs =~ /(?:property|name)=["'](?:og:description|twitter:description)["']/i;
        # mb492: paired-quote capture so apostrophes don't truncate the tweet
        if ($attrs =~ /\bcontent=(["'])(.*?)\1/is) { $desc = $2; last; }
    }
    return undef unless defined $desc && $desc ne '';

    $desc = Mediabot::External::URL::_decode_html($desc);
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
    require Mediabot::External::URL;

    my $x_url = Mediabot::External::URL::_x_url($url);
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
    require Mediabot::External::URL;

    my $x_url = Mediabot::External::URL::_x_url($url);
    unless (defined $x_url) {
        $self->{logger}->log(4, "_handle_x_twitter() not a supported X/Twitter URL: " . ($url // '<undef>'));
        return undef;
    }

    $self->{logger}->log(4, "_handle_x_twitter() start url=$x_url");

    # IMP10: cache x_twitter result (TTL 10 min) — Chromium is expensive
    my $tw_cache     = $self->{_x_twitter_cache} //= {};
    my $tw_cache_key = Mediabot::External::URL::_url_cache_identity($url);
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
            my $data = eval { Mediabot::External::URL::decode_json($res->{content} // '') };
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
        $dom = eval { Mediabot::External::URL::_fetch_url_chromium_dumpdom(
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
            $title = Mediabot::External::URL::_x_title_from_html($self, $dom, 'Chromium');
            $tweet_text = Mediabot::External::URL::_x_desc_from_html($self, $dom, 'Chromium');
        }
        else {
            $self->{logger}->log(4, "_handle_x_twitter() Chromium returned no usable DOM for $x_url");
        }
    }

    unless (defined $title && $title ne '') {
        my $fallback_title = Mediabot::External::URL::_x_fallback_title_from_url($x_url);
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
    # Validate each optional counter before any numeric comparison or formatting.
    my @st;
    push @st, Mediabot::External::URL::_x_compact_count($fx_likes) . ' likes'
        if defined $fx_likes && $fx_likes =~ /^\d+$/ && $fx_likes > 0;
    push @st, Mediabot::External::URL::_x_compact_count($fx_rts) . ' RTs'
        if defined $fx_rts && $fx_rts =~ /^\d+$/ && $fx_rts > 0;
    $line .= ' (' . join(', ', @st) . ')' if @st;

    my $msg = "$badge\x0f " . substr($line, 0, 300);

    # IMP10/fix: cache the formatted message, not just a boolean.
    # That way repeated X/Twitter URLs avoid Chromium but still produce the same
    # user-visible IRC output when the generic URL anti-repeat cache allows it.
    $tw_cache->{$tw_cache_key} = { ts => time(), msg => $msg };

    Mediabot::Helpers::botPrivmsg($self, $channel, "($nick) $msg");
    return 1;
}

1;

__END__

=head1 NAME

Mediabot::External::XTwitter - X/Twitter metadata, fallbacks and delivery

=head1 COMPATIBILITY

URL retains routing and all historical aliases; External imports this owner.
The FxTwitter-first path, browser fallback, cache, counters, character limits
and IRC presentation retain their existing behaviour. Dependent calls resolve
legacy URL symbols at runtime. The HTTP factory and IRC sender remain runtime
dependencies.

=cut
