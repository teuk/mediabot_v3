package Mediabot::RSS::TinyURL;

# =============================================================================
# Presentation-only TinyURL helper for native RSS announcements (mb693/mb730).
#
# RSS feed fetching has its own strict SSRF-aware transport. This helper does
# not fetch user-controlled hosts: it talks only to TinyURL's authenticated
# fixed API and falls back to the original article URL on missing credentials
# or any shortener failure. The retired anonymous endpoint must never be used:
# it can return a syntactically valid alias unrelated to the submitted URL.
# =============================================================================

use strict;
use warnings;
use utf8;

use Exporter 'import';
use HTTP::Tiny;
use JSON::PP ();

our @EXPORT_OK = qw(shorten_url make_shortener);

our $API = 'https://api.tinyurl.com/create';

sub _default_http {
    return HTTP::Tiny->new(
        timeout      => 2,
        max_size     => 4096,
        verify_SSL   => 1,
        max_redirect => 0,
        agent        => 'Mediabot-RSS-TinyURL/3.5',
    );
}

sub _api_key {
    my ($value) = @_;
    return '' unless defined($value) && !ref($value);
    $value =~ s/^\s+|\s+$//g;
    return '' unless $value =~ /\A[!-~]{16,512}\z/;
    return $value;
}

sub shorten_url {
    my ($url, %opts) = @_;

    return '' unless defined($url) && !ref($url) && length($url);
    return $url unless $url =~ m{\Ahttps?://}i;
    return $url if $url =~ m{\Ahttps://tinyurl\.com/\S+\z}i;

    my $api_key = _api_key($opts{api_key});
    return $url unless length($api_key);

    # TinyURL is presentation-only. Never let ambient proxy settings turn a
    # cosmetic shortening request into a different network path. Localize the
    # environment before constructing HTTP::Tiny, because it reads proxy
    # variables in its constructor.
    local @ENV{qw(http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy)};
    my $http = $opts{http} || _default_http();
    return $url unless $http;

    my $payload = eval {
        JSON::PP->new->utf8->canonical->encode({
            domain => 'tinyurl.com',
            url    => $url,
        });
    };
    return $url unless defined($payload) && length($payload);

    my $res = eval {
        $http->request('POST', $API, {
            headers => {
                Accept          => 'application/json',
                Authorization   => "Bearer $api_key",
                'Content-Type'  => 'application/json',
                'Cache-Control' => 'no-store',
            },
            content => $payload,
        });
    } || { success => 0 };
    return $url unless $res->{success};

    my $decoded = eval { JSON::PP->new->utf8->decode($res->{content} // '') };
    return $url unless ref($decoded) eq 'HASH'
        && ref($decoded->{data}) eq 'HASH';

    # Bind the returned alias to the destination TinyURL says it stored. A
    # valid-looking but unrelated alias is a failure, never a news link.
    my $returned_url = $decoded->{data}{url};
    return $url unless defined($returned_url) && !ref($returned_url)
        && $returned_url eq $url;

    my $short = $decoded->{data}{tiny_url} // '';
    return $url if ref($short);
    $short =~ s/^[\s\r\n]+|[\s\r\n]+\z//g;

    return $short =~ m{\Ahttps://tinyurl\.com/[A-Za-z0-9_-]+\z}i
        ? $short
        : $url;
}

sub make_shortener {
    my (%opts) = @_;
    my $api_key = _api_key($opts{api_key});
    return sub { defined($_[0]) && !ref($_[0]) ? $_[0] : '' }
        unless length($api_key);

    local @ENV{qw(http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy)};
    my $http = $opts{http} || _default_http();
    return sub { shorten_url($_[0], http => $http, api_key => $api_key) };
}

1;
