package Mediabot::RSS::Fetcher;

use strict;
use warnings;
use utf8;

use HTTP::Tiny;
use Encode qw(decode find_encoding FB_CROAK);
use Socket qw(AF_UNSPEC SOCK_STREAM NI_NUMERICHOST NI_NUMERICSERV getaddrinfo getnameinfo);
use URI;
use Mediabot::RSS qw(validate_feed_url is_public_ip_literal parse_feed_document);

use constant MAX_REDIRECTS => 3;
use constant MAX_BYTES     => 2 * 1024 * 1024;

sub _default_resolver {
    my ($host, $port) = @_;
    my ($err, @res) = getaddrinfo($host, $port, {
        family   => AF_UNSPEC,
        socktype => SOCK_STREAM,
    });
    die "DNS resolution failed for $host: $err" if $err;

    my @ips;
    for my $ai (@res) {
        my ($ni_err, $ip) = getnameinfo($ai->{addr}, NI_NUMERICHOST | NI_NUMERICSERV);
        next if $ni_err || !defined $ip || $ip eq '';
        push @ips, $ip;
    }
    my %seen;
    return [ grep { !$seen{$_}++ } @ips ];
}

sub _validated_addresses {
    my ($host, $port, $resolver) = @_;
    my $literal = is_public_ip_literal($host);
    if (defined $literal) {
        die "blocked RSS destination $host" unless $literal;
        return [ $host ];
    }

    $resolver ||= \&_default_resolver;
    my $ips = $resolver->($host, $port);
    die "RSS destination has no address" unless ref($ips) eq 'ARRAY' && @$ips;
    for my $ip (@$ips) {
        my $public = is_public_ip_literal($ip);
        die "RSS destination resolved to blocked address $ip"
            unless defined($public) && $public;
    }
    return $ips;
}

sub _default_requester {
    my ($url, %opts) = @_;
    my $peers = $opts{validated_addresses};
    return { success => 0, status => 599, headers => {},
             content => 'RSS destination has no pinned address' }
        unless ref($peers) eq 'ARRAY' && @$peers;

    # HTTP::Tiny's peer argument connects to an exact numeric address while
    # retaining the URL hostname for Host/SNI/certificate verification. This
    # closes the validate-then-resolve-again DNS-rebinding window.
    #
    # A hostname may legitimately have several validated A/AAAA records. Try
    # the next already-validated peer only when HTTP::Tiny reports a transport
    # failure (599), so a dead IPv6 route cannot mask a healthy IPv4 path.
    local @ENV{qw(http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy)};
    my @ordered = (
        grep { index($_, ':') < 0 } @$peers,
        grep { index($_, ':') >= 0 } @$peers,
    );
    splice @ordered, 4 if @ordered > 4; # stay well inside CommandAsync timeout

    my %headers = (
        Accept => 'application/atom+xml, application/rss+xml, application/xml, text/xml, */*;q=0.2',
    );
    if (ref($opts{request_headers}) eq 'HASH') {
        for my $name (qw(If-None-Match If-Modified-Since)) {
            my $value = $opts{request_headers}{$name};
            next unless defined($value) && !ref($value) && length($value);
            $headers{$name} = substr($value, 0, 1024);
        }
    }

    my $last;
    for my $peer (@ordered) {
        my $http = HTTP::Tiny->new(
            timeout      => $opts{timeout} || 8,
            max_size     => $opts{max_size} || MAX_BYTES,
            max_redirect => 0,
            verify_SSL   => 1,
            agent        => 'Mediabot-RSS/3.4',
        );
        my $res = eval {
            $http->get($url, {
                peer    => $peer,
                headers => \%headers,
            })
        };
        $res = { success => 0, status => 599, headers => {},
                 content => ($@ || 'RSS peer connection failed') }
            unless $res && ref($res) eq 'HASH';
        $last = $res;
        return $res unless int($res->{status} || 0) == 599;
    }
    return $last || { success => 0, status => 599, headers => {},
                      content => 'RSS destination has no usable pinned peer' };
}

sub _header_value {
    my ($headers, $wanted) = @_;
    return undef unless ref($headers) eq 'HASH';
    my $needle = lc($wanted // '');
    for my $name (keys %$headers) {
        return $headers->{$name} if lc($name) eq $needle;
    }
    return undef;
}

sub _detect_feed_encoding {
    my ($body, $headers) = @_;
    return undef if utf8::is_utf8($body);

    return ('UTF-8',    3) if substr($body, 0, 3) eq "\xEF\xBB\xBF";
    return ('UTF-16LE', 2) if substr($body, 0, 2) eq "\xFF\xFE";
    return ('UTF-16BE', 2) if substr($body, 0, 2) eq "\xFE\xFF";

    my $ctype = _header_value($headers, 'content-type') // '';
    if ($ctype =~ /\bcharset\s*=\s*["']?\s*([A-Za-z0-9._:-]+)/i) {
        return ($1, 0);
    }

    my $head = substr($body, 0, 512);
    if ($head =~ /<\?xml\b[^>]*\bencoding\s*=\s*["']([^"']+)["']/i) {
        return ($1, 0);
    }

    # XML 1.0 defaults to UTF-8 when no encoding information is supplied.
    return ('UTF-8', 0);
}

sub _decode_feed_body {
    my ($body, $headers) = @_;
    $body = '' unless defined $body;
    return $body if utf8::is_utf8($body);

    my ($name, $bom_len) = _detect_feed_encoding($body, $headers);
    die "unsupported RSS encoding" unless defined($name) && find_encoding($name);

    $body = substr($body, $bom_len) if $bom_len;
    my $decoded = decode($name, $body, FB_CROAK);
    $decoded =~ s/^\x{FEFF}//;
    return $decoded;
}

sub fetch_feed_once {
    my ($url, %opts) = @_;
    my $resolver  = $opts{resolver};
    my $requester = $opts{requester} || \&_default_requester;
    my $parser    = ref($opts{parser}) eq 'CODE' ? $opts{parser} : \&parse_feed_document;
    my $max_items = $opts{max_items} || 10;
    my $current   = $url;
    my $etag      = $opts{etag};
    my $modified  = $opts{last_modified};

    for my $hop (0 .. MAX_REDIRECTS) {
        my $valid = validate_feed_url($current);
        return { ok => 0, error => $valid->{error} || 'invalid_url' }
            unless $valid->{ok};

        my $ips = eval { _validated_addresses($valid->{host}, $valid->{port}, $resolver) };
        if (!$ips) {
            my $err = $@ || 'dns_validation_failed';
            $err =~ s/[\r\n\0]+/ /g;
            return { ok => 0, error => 'blocked_destination', detail => $err };
        }

        my %request_headers;
        $request_headers{'If-None-Match'} = $etag
            if defined($etag) && !ref($etag) && length($etag);
        $request_headers{'If-Modified-Since'} = $modified
            if defined($modified) && !ref($modified) && length($modified);

        my $res = eval {
            $requester->($current,
                timeout => ($opts{timeout} || 8),
                max_size => MAX_BYTES,
                validated_addresses => $ips,
                request_headers => \%request_headers,
            )
        };
        if (!$res || ref($res) ne 'HASH') {
            return { ok => 0, error => 'http_error', detail => 'request failed' };
        }

        my $status = int($res->{status} || 0);
        my $res_etag = _header_value($res->{headers}, 'etag');
        my $res_modified = _header_value($res->{headers}, 'last-modified');

        if ($status == 304) {
            return {
                ok            => 1,
                not_modified  => 1,
                status        => 304,
                url           => $current,
                resolved      => $ips,
                etag          => $res_etag,
                last_modified => $res_modified,
                headers       => $res->{headers} || {},
            };
        }

        if ($status =~ /^(?:301|302|303|307|308)$/) {
            return { ok => 0, error => 'too_many_redirects' }
                if $hop >= MAX_REDIRECTS;
            my $loc = ref($res->{headers}) eq 'HASH' ? $res->{headers}{location} : undef;
            return { ok => 0, error => 'redirect_without_location' }
                unless defined $loc && length $loc;
            my $next = eval { URI->new_abs($loc, $current)->as_string };
            return { ok => 0, error => 'invalid_redirect' }
                unless defined $next && length $next;
            $current = $next;
            # Validators belong to the representation that supplied them. Do
            # not leak or misapply them to a redirect target.
            $etag = undef;
            $modified = undef;
            next;
        }

        return { ok => 0, error => 'http_status', status => $status }
            unless $res->{success};

        my $body = $res->{content} // '';
        return { ok => 0, error => 'feed_too_large' }
            if length($body) > MAX_BYTES;

        my $decoded;
        my $decode_ok = eval {
            $decoded = _decode_feed_body($body, $res->{headers});
            1;
        };
        unless ($decode_ok) {
            my $err = $@ || 'RSS feed decoding failed';
            $err =~ s/[\r\n\0]+/ /g;
            return { ok => 0, error => 'invalid_encoding', detail => $err };
        }

        my $parsed = eval { $parser->($decoded, max_items => $max_items) };
        unless ($parsed && ref($parsed) eq 'HASH') {
            my $err = $@ || 'RSS parser returned no result';
            $err =~ s/[\r\n\0]+/ /g;
            return { ok => 0, error => 'parse_exception', detail => substr($err, 0, 240),
                     status => $status, url => $current, resolved => $ips };
        }
        return { %$parsed, status => $status, url => $current, resolved => $ips }
            unless $parsed->{ok};

        return {
            ok            => 1,
            status        => $status,
            url           => $current,
            resolved      => $ips,
            feed          => $parsed,
            etag          => $res_etag,
            last_modified => $res_modified,
            headers       => $res->{headers} || {},
        };
    }

    return { ok => 0, error => 'too_many_redirects' };
}

1;
