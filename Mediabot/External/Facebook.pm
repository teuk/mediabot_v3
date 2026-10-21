package Mediabot::External::Facebook;

use strict;
use warnings;
use utf8;
use Exporter 'import';
use String::IRC;

our $VERSION = '1.00';
our @EXPORT_OK = qw(
    _facebook_url
    _facebook_title_from_html
    _facebook_fallback_title_from_url
    _handle_facebook
);

# Resolve historical URL helper symbols at call time. This preserves existing
# parser, decoder, cache-key and browser overrides through the legacy aliases.
# The dependent functions load URL lazily to support either module load order.

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
    require Mediabot::External::URL;

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

    $title = Mediabot::External::URL::_decode_html($title);
    $title =~ s/[\r\n\t]/ /g;
    $title =~ s/\x{a0}/ /g;   # mb495: nbsp from decoded counters -> plain space
    $title =~ s/\s{2,}/ /g;
    $title =~ s/^\s+|\s+$//g;

    # mb495: reel og:title = "<view/reaction counters, random locale> | <caption>"
    # (e.g. "377 K views · 2.6 K reactions | Would you be so kind..."). When the
    # title STARTS with a digit and carries a pipe, keep the caption side.
    if ($title =~ /^\s*\d/ && $title =~ /^[^|]{1,120}\|\s*(\S.*)$/s) {
        $title = $1;
        $title =~ s/\s{2,}/ /g;
        $title =~ s/^\s+|\s+$//g;
    }

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
    require Mediabot::External::URL;

    my $fb_html = '';   # mb492: html we ended up trusting

    my $fb_url = Mediabot::External::URL::_facebook_url($url);
    unless (defined $fb_url) {
        $self->{logger}->log(4, "_handle_facebook() not a supported Facebook URL: " . ($url // '<undef>'));
        return undef;
    }

    $self->{logger}->log(4, "_handle_facebook() start url=$fb_url");

    # IMP10: serve from cache if fresh (TTL 10 min)
    # Resource IDs and query values retain their case, as at URL admission.
    my $fb_cache_key = Mediabot::External::URL::_url_cache_identity($fb_url);
    my $fb_cached = $self->{_facebook_cache}{$fb_cache_key};
    if ($fb_cached && (time() - ($fb_cached->{ts} // 0)) < 600) {
        $self->{logger}->log(4, "_handle_facebook() cache hit for $fb_url");
        Mediabot::Helpers::botPrivmsg($self, $channel, "($nick) $fb_cached->{msg}");
        return 1;
    }

    my $title;

    # Step 1: cheap HTTP fetch.  On your server, HTTP::Tiny follows
    # facebook.com -> www.facebook.com and can receive a normal 200 page.
    my $http = Mediabot::External::_make_http(
        timeout  => 8,
        max_size => 1024 * 1024,
        agent    => 'facebookexternalhit/1.1 (+http://www.facebook.com/externalhit_uatext.php)',   # mb494: social-crawler UA -> server-side og: tags
        default_headers => { 'accept-language' => 'en-US,en;q=0.8' },   # mb495: stable counter locale
    );

    my $res = eval { $http->get($fb_url); } // { success => 0, status => 0, reason => $@ };

    if ($res->{success}) {
        my $content = Mediabot::External::URL::_decode_http_content_utf8($self, $res->{content} // '', 'facebook-http');
        my $len = length($content);
        $self->{logger}->log(4, "_handle_facebook() HTTP fetched $len bytes for $fb_url");
        $fb_html = $content;   # mb492
        $title = Mediabot::External::URL::_facebook_title_from_html($self, $content, 'HTTP');
    }
    else {
        $self->{logger}->log(4, "_handle_facebook() HTTP $res->{status} $res->{reason} for $fb_url");
    }

    # Step 2: Chromium fallback.  Keep it for non-Reel Facebook URLs where
    # rendered metadata can still add value. Public Reel shells are different:
    # when the crawler HTML has no usable title, Chromium commonly waits until
    # its alarm and still exposes no metadata. Skip that known-dead path so the
    # deterministic Reel fallback is returned immediately.
    unless (defined $title && $title ne '') {
        my $is_reel = $fb_url =~ m{^https://www\.facebook\.com/(?:reel|reels)/}i ? 1 : 0;

        if ($is_reel) {
            $self->{logger}->log(4, "_handle_facebook() Reel shell has no usable HTTP metadata; skipping Chromium");
        }
        else {
            $self->{logger}->log(4, "_handle_facebook() falling back to Chromium rendered DOM");

            my $fb_vtb = int(eval { $self->{conf}->get('chromium.FACEBOOK_VIRTUAL_TIME_BUDGET') } // 6500);
            my $fb_alarm = int(eval { $self->{conf}->get('chromium.FACEBOOK_ALARM_TIMEOUT') } // 22);

            $fb_vtb = 1000 if $fb_vtb < 1000;
            $fb_vtb = 30000 if $fb_vtb > 30000;
            $fb_alarm = 5 if $fb_alarm < 5;
            $fb_alarm = 60 if $fb_alarm > 60;

            my $dom = Mediabot::External::URL::_fetch_url_chromium_dumpdom(
                $self,
                $fb_url,
                virtual_time_budget => $fb_vtb,
                alarm_timeout       => $fb_alarm,
                lang                => 'fr-FR',
            );

            if (defined $dom && $dom ne '') {
                my $len = length($dom);
                $self->{logger}->log(4, "_handle_facebook() Chromium DOM fetched $len bytes for $fb_url");
                $fb_html = $dom;   # mb492
                $title = Mediabot::External::URL::_facebook_title_from_html($self, $dom, 'Chromium');
            }
        }
    }

    unless (defined $title && $title ne '') {
        my $fallback_title = Mediabot::External::URL::_facebook_fallback_title_from_url($fb_url);
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

    # mb492: append og:description when informative and not a duplicate
    my $fb_line = $title;
    my $fb_desc;
    if    ($fb_html =~ /<meta\s+property=["']og:description["']\s+content=(["'])(.*?)\1/is) { $fb_desc = $2; }
    elsif ($fb_html =~ /<meta\s+content=(["'])(.*?)\1\s+property=["']og:description["']/is) { $fb_desc = $2; }
    if (defined $fb_desc) {
        $fb_desc = Mediabot::External::URL::_decode_html($fb_desc);
        $fb_desc =~ s/[\r\n\t]/ /g; $fb_desc =~ s/\s{2,}/ /g; $fb_desc =~ s/^\s+|\s+$//g;
        if ($fb_desc ne ''
            && $fb_desc !~ /^(?:Log in|Se connecter|Sign in|Connexion)/i
            && $fb_desc !~ /facebook/i
            && index(lc($fb_line), lc(substr($fb_desc, 0, 40))) < 0) {
            my $d = length($fb_desc) > 150 ? substr($fb_desc, 0, 147) . '...' : $fb_desc;
            $fb_line .= " - $d";
        }
    }

    my $msg = "$badge\x0f " . substr($fb_line, 0, 300);
    # IMP10: cache the result (TTL 10 min) to avoid redundant Chromium fetches
    $self->{_facebook_cache}{$fb_cache_key} = { ts => time(), msg => $msg };

    Mediabot::Helpers::botPrivmsg($self, $channel, "($nick) $msg");
    return 1;
}

1;

__END__

=head1 NAME

Mediabot::External::Facebook - Facebook titles, fallbacks and delivery

=head1 COMPATIBILITY

URL keeps its routing and historical aliases; External imports this owner.
Parsing, cache policy, HTTP options, browser fallback and IRC presentation
retain their existing behaviour. Dependent calls resolve legacy URL symbols
at runtime. The HTTP factory and IRC helpers remain runtime dependencies.

=cut
