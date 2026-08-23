package Mediabot::RSS::TinyURL;

# =============================================================================
# Presentation-only TinyURL helper for native RSS announcements (mb693).
#
# RSS feed fetching has its own strict SSRF-aware transport. This helper does
# not fetch user-controlled hosts: it talks only to TinyURL's fixed public API
# and falls back to the original article URL on any shortener failure.
# =============================================================================

use strict;
use warnings;
use utf8;

use Exporter 'import';
use HTTP::Tiny;
use URI::Escape qw(uri_escape_utf8);

our @EXPORT_OK = qw(shorten_url make_shortener);

our $API = 'https://tinyurl.com/api-create.php?url=';

sub _default_http {
    return HTTP::Tiny->new(
        timeout      => 2,
        max_size     => 4096,
        verify_SSL   => 1,
        max_redirect => 0,
        agent        => 'Mediabot-RSS-TinyURL/3.4',
    );
}

sub shorten_url {
    my ($url, %opts) = @_;

    return '' unless defined($url) && !ref($url) && length($url);
    return $url unless $url =~ m{\Ahttps?://}i;
    return $url if $url =~ m{\Ahttps://tinyurl\.com/\S+\z}i;

    my $http = $opts{http} || _default_http();
    return $url unless $http;

    # TinyURL is presentation-only. Never let ambient proxy settings turn a
    # cosmetic shortening request into a different network path.
    local @ENV{qw(http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy)};

    my $endpoint = $API . uri_escape_utf8($url);
    my $res = eval { $http->get($endpoint) } || { success => 0 };
    return $url unless $res->{success};

    my $short = $res->{content} // '';
    $short =~ s/^[\s\r\n]+|[\s\r\n]+\z//g;

    return $short =~ m{\Ahttps://tinyurl\.com/[A-Za-z0-9_-]+\z}i
        ? $short
        : $url;
}

sub make_shortener {
    my (%opts) = @_;
    my $http = $opts{http} || _default_http();
    return sub { shorten_url($_[0], http => $http) };
}

1;
