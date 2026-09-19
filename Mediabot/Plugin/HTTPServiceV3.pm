package Mediabot::Plugin::HTTPServiceV3;

use strict;
use warnings;
use utf8;

use Encode qw(decode FB_CROAK);
use HTTP::Tiny;
use Socket qw(AF_INET6 AF_UNSPEC SOCK_STREAM NI_NUMERICHOST NI_NUMERICSERV getaddrinfo getnameinfo inet_pton);

use Mediabot::Plugin::HTTPResponseV3;

our $MAX_BODY_BYTES = 64 * 1024;
our $MAX_CACHE_ENTRIES = 128;
our $MAX_REDIRECTS = 2;
our $MAX_INFLIGHT_PER_PLUGIN = 2;
our $CIRCUIT_FAILURES = 3;
our $CIRCUIT_SECONDS = 60;

sub _public_ipv4 {
    my ($ip) = @_;
    return 0 unless defined($ip)
        && $ip =~ /\A(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})\z/;
    my @o = ($1, $2, $3, $4);
    return 0 if grep { $_ > 255 } @o;
    return 0 if $o[0] == 0 || $o[0] == 10 || $o[0] == 127 || $o[0] >= 224;
    return 0 if $o[0] == 100 && $o[1] >= 64 && $o[1] <= 127;
    return 0 if $o[0] == 169 && $o[1] == 254;
    return 0 if $o[0] == 172 && $o[1] >= 16 && $o[1] <= 31;
    return 0 if $o[0] == 192 && ($o[1] == 168
        || ($o[1] == 0 && ($o[2] == 0 || $o[2] == 2)));
    return 0 if $o[0] == 198 && ($o[1] == 18 || $o[1] == 19
        || ($o[1] == 51 && $o[2] == 100));
    return 0 if $o[0] == 203 && $o[1] == 0 && $o[2] == 113;
    return 1;
}

sub _public_ipv6 {
    my ($ip) = @_;
    my $packed = eval { inet_pton(AF_INET6, $ip) };
    return 0 unless defined($packed) && length($packed) == 16;
    my @b = unpack('C16', $packed);
    return 0 if !grep { $_ != 0 } @b;
    return 0 if (grep { $_ != 0 } @b[0 .. 14]) == 0 && $b[15] == 1;
    return 0 if ($b[0] & 0xfe) == 0xfc;
    return 0 if $b[0] == 0xfe && ($b[1] & 0xc0) == 0x80;
    return 0 if $b[0] == 0xff;
    return 0 if $b[0] == 0x20 && $b[1] == 0x01
        && $b[2] == 0x0d && $b[3] == 0xb8;
    if ((grep { $_ != 0 } @b[0 .. 9]) == 0
        && $b[10] == 0xff && $b[11] == 0xff) {
        return _public_ipv4(join('.', @b[12 .. 15]));
    }
    return 1;
}

sub _public_ip_literal {
    my ($host) = @_;
    return 0 unless defined($host) && !ref($host);
    $host =~ s/^\[|\]$//g;
    return _public_ipv4($host) if $host =~ /\A\d+(?:\.\d+){3}\z/;
    return _public_ipv6($host) if index($host, ':') >= 0;
    return undef;
}

sub new {
    my ($class, %args) = @_;
    return bless {
        loop           => $args{loop},
        worker_factory => $args{worker_factory},
        requester      => $args{requester} || \&_default_requester,
        resolver       => $args{resolver} || \&_default_resolver,
        clock          => $args{clock} || sub { time() },
        on_metric      => ref($args{on_metric}) eq 'CODE'
            ? $args{on_metric} : sub { },
        on_log         => ref($args{on_log}) eq 'CODE'
            ? $args{on_log} : sub { },
        cache          => {},
        cache_order    => [],
        circuit        => {},
        inflight       => {},
        generation     => {},
        sequence       => 0,
    }, $class;
}

sub _clean_error {
    my ($value, $fallback) = @_;
    $fallback ||= 'http_failed';
    return $fallback unless defined($value) && !ref($value);
    my $text = "$value";
    $text =~ s/[\r\n\0]+/ /g;
    $text =~ s/[^A-Za-z0-9_.-]+/_/g;
    $text =~ s/\A_+|_+\z//g;
    return length($text) ? substr(lc($text), 0, 80) : $fallback;
}

sub _plugin_name {
    my ($plugin) = @_;
    die "HTTPServiceV3: invalid plugin name\n"
        unless defined($plugin) && !ref($plugin)
            && $plugin =~ /\A[a-z0-9][a-z0-9-]{0,47}\z/;
    return "$plugin";
}

sub _bounded_integer {
    my ($value, $default, $minimum, $maximum, $label) = @_;
    $value = $default unless defined $value;
    die "HTTPServiceV3: $label must be an integer\n"
        if ref($value) || "$value" !~ /\A(?:0|[1-9][0-9]*)\z/;
    my $number = 0 + $value;
    die "HTTPServiceV3: $label must be between $minimum and $maximum\n"
        unless $number >= $minimum && $number <= $maximum;
    return $number;
}

sub _url_parts {
    my ($url) = @_;
    die "HTTPServiceV3: URL must be a scalar\n"
        unless defined($url) && !ref($url);
    die "HTTPServiceV3: URL length is invalid\n"
        unless length($url) >= 12 && length($url) <= 2048;
    die "HTTPServiceV3: URL contains forbidden whitespace or controls\n"
        if $url =~ /[\x00-\x20\x7f]/;
    die "HTTPServiceV3: only HTTPS URLs are allowed\n"
        unless $url =~ m{\Ahttps://([^/?#]+)([^#]*)\z}i;
    my ($authority, $rest) = ($1, $2);
    die "HTTPServiceV3: URL credentials are forbidden\n"
        if $authority =~ /\@/;
    die "HTTPServiceV3: URL fragments are forbidden\n"
        if $url =~ /#/;
    my ($host, $port);
    if ($authority =~ /\A\[([0-9A-Fa-f:.]+)\](?::([0-9]+))?\z/) {
        ($host, $port) = (lc($1), $2);
    }
    elsif ($authority =~ /\A([^:]+)(?::([0-9]+))?\z/) {
        ($host, $port) = (lc($1), $2);
    }
    else {
        die "HTTPServiceV3: URL authority is invalid\n";
    }
    $host =~ s/\.\z//;
    die "HTTPServiceV3: URL host is invalid\n"
        unless length($host) && $host =~ /\A[A-Za-z0-9_.:-]+\z/;
    die "HTTPServiceV3: local destinations are forbidden\n"
        if $host eq 'localhost' || $host =~ /(?:\.localhost|\.local|\.internal|\.home\.arpa)\z/
            || $host eq 'home.arpa';
    $port = 443 unless defined $port;
    die "HTTPServiceV3: only HTTPS port 443 is allowed\n"
        unless "$port" eq '443';
    my $literal = _public_ip_literal($host);
    die "HTTPServiceV3: destination address is blocked\n"
        if defined($literal) && !$literal;
    $rest = '/' unless defined($rest) && length($rest);
    my $rendered_host = index($host, ':') >= 0 ? "[$host]" : $host;
    my $normalized = "https://$rendered_host$rest";
    return ($normalized, $host, 443, "https://$rendered_host");
}

sub _resolve_location {
    my ($base, $location) = @_;
    die "HTTPServiceV3: redirect location is invalid\n"
        unless defined($location) && !ref($location)
            && length($location) <= 2048 && $location !~ /[\r\n\0]/;
    return "$location" if $location =~ m{\Ahttps://}i;
    return "https:$location" if $location =~ m{\A//};
    die "HTTPServiceV3: redirect changed scheme\n"
        if $location =~ m{\A[A-Za-z][A-Za-z0-9+.-]*:};
    my ($origin, $path) = $base =~ m{\A(https://[^/]+)(/[^?#]*)?};
    die "HTTPServiceV3: redirect base is invalid\n" unless defined $origin;
    $path = '/' unless defined($path) && length($path);
    return "$origin$location" if $location =~ m{\A/};
    return "$origin$path$location" if $location =~ m{\A\?};
    $path =~ s{[^/]*\z}{};
    return "$origin$path$location";
}

sub _default_resolver {
    my ($host, $port) = @_;
    my ($error, @results) = getaddrinfo($host, $port, {
        family => AF_UNSPEC, socktype => SOCK_STREAM,
    });
    die "DNS resolution failed" if $error;
    my (%seen, @ips);
    for my $item (@results) {
        my ($ni_error, $ip) = getnameinfo(
            $item->{addr}, NI_NUMERICHOST | NI_NUMERICSERV);
        next if $ni_error || !defined($ip) || $seen{$ip}++;
        push @ips, $ip;
    }
    return \@ips;
}

sub _validated_addresses {
    my ($host, $port, $resolver) = @_;
    my $literal = _public_ip_literal($host);
    return [ $host ] if defined($literal) && $literal;
    my $ips = $resolver->($host, $port);
    die "HTTPServiceV3: destination has no address\n"
        unless ref($ips) eq 'ARRAY' && @$ips;
    my (%seen, @public);
    for my $ip (@$ips) {
        my $is_public = _public_ip_literal($ip);
        die "HTTPServiceV3: destination resolved to a blocked address\n"
            unless defined($is_public) && $is_public;
        push @public, $ip unless $seen{$ip}++;
    }
    splice @public, 4 if @public > 4;
    return \@public;
}

sub _default_requester {
    my ($url, %args) = @_;
    my $peers = $args{validated_addresses};
    return { success => 0, status => 599, headers => {}, content => '' }
        unless ref($peers) eq 'ARRAY' && @$peers;
    local @ENV{qw(http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy)};
    my @ordered = (
        grep { index($_, ':') < 0 } @$peers,
        grep { index($_, ':') >= 0 } @$peers,
    );
    my $last;
    for my $peer (@ordered) {
        my $http = HTTP::Tiny->new(
            timeout      => $args{timeout},
            max_size     => $args{max_bytes},
            max_redirect => 0,
            verify_SSL   => 1,
            agent        => 'Mediabot-PluginHTTP/3.6',
        );
        my $response = eval { $http->get($url, {
            peer => $peer,
            headers => { Accept => $args{accept} },
        }) };
        $response = { success => 0, status => 599, headers => {}, content => '' }
            unless ref($response) eq 'HASH';
        $last = $response;
        last unless ($response->{status} // 599) == 599;
    }
    return $last;
}

sub _perform_request {
    my ($requester, $resolver, $url, $timeout, $max_bytes, $accept) = @_;
    my $current = $url;
    for my $redirect (0 .. $MAX_REDIRECTS) {
        my ($validated, $host, $port) = _url_parts($current);
        my $addresses = _validated_addresses($host, $port, $resolver);
        my $response = $requester->($validated,
            timeout => $timeout,
            max_bytes => $max_bytes,
            accept => $accept,
            validated_addresses => $addresses,
        );
        die "HTTPServiceV3: requester returned an invalid response\n"
            unless ref($response) eq 'HASH';
        my $status = defined($response->{status}) && !ref($response->{status})
            && "$response->{status}" =~ /\A[0-9]{3}\z/
            ? int($response->{status}) : 599;
        my $headers = ref($response->{headers}) eq 'HASH'
            ? $response->{headers} : {};
        if ($status =~ /\A30[12378]\z/) {
            die "HTTPServiceV3: redirect limit exceeded\n"
                if $redirect >= $MAX_REDIRECTS;
            my $location = $headers->{location} // $headers->{Location};
            die "HTTPServiceV3: redirect has no location\n"
                unless defined($location) && !ref($location) && length($location);
            $current = _resolve_location($validated, $location);
            next;
        }
        my $raw = defined($response->{content}) && !ref($response->{content})
            ? "$response->{content}" : '';
        die "HTTPServiceV3: response exceeds body limit\n"
            if length($raw) > $max_bytes;
        my $body = eval { decode('UTF-8', $raw, FB_CROAK) };
        die "HTTPServiceV3: response is not UTF-8\n" if $@;
        my $content_type = $headers->{'content-type'} // $headers->{'Content-Type'} // '';
        $content_type = '' if ref($content_type);
        $content_type = substr($content_type, 0, 160);
        return {
            ok           => ($status >= 200 && $status < 300) ? 1 : 0,
            status       => $status,
            url          => $validated,
            content_type => $content_type,
            body         => $body,
            error        => ($status >= 200 && $status < 300) ? '' : "http_$status",
        };
    }
    die "HTTPServiceV3: redirect processing failed\n";
}

sub _response {
    my ($data, %extra) = @_;
    $data = {} unless ref($data) eq 'HASH';
    return Mediabot::Plugin::HTTPResponseV3->new(%$data, %extra);
}

sub _metric {
    my ($self, $name, $labels) = @_;
    eval { $self->{on_metric}->($name, $labels) };
    return;
}

sub _cache_store {
    my ($self, $key, $data, $expires) = @_;
    $self->{cache}{$key} = { data => { %$data }, expires => $expires };
    @{ $self->{cache_order} } = grep { $_ ne $key } @{ $self->{cache_order} };
    push @{ $self->{cache_order} }, $key;
    while (@{ $self->{cache_order} } > $MAX_CACHE_ENTRIES) {
        my $oldest = shift @{ $self->{cache_order} };
        delete $self->{cache}{$oldest};
    }
}

sub fetch {
    my ($self, $plugin, $request, $callback) = @_;
    $plugin = _plugin_name($plugin);
    die "HTTPServiceV3: request must be an object\n"
        unless ref($request) eq 'HASH';
    die "HTTPServiceV3: callback must be CODE\n"
        unless ref($callback) eq 'CODE';
    my ($url, undef, undef, $origin) = _url_parts($request->{url});
    my $timeout = _bounded_integer($request->{timeout_seconds},
        5, 1, 10, 'timeout');
    my $ttl = _bounded_integer($request->{cache_ttl_seconds},
        300, 0, 3600, 'cache TTL');
    my $max_bytes = _bounded_integer($request->{max_bytes},
        32768, 256, $MAX_BODY_BYTES, 'max_bytes');
    my $accept = defined($request->{accept}) && !ref($request->{accept})
        ? "$request->{accept}" : 'application/json';
    die "HTTPServiceV3: invalid Accept value\n"
        unless length($accept) <= 160 && $accept !~ /[\r\n\0]/;

    my $now = $self->{clock}->();
    my $cache_key = join("\0", $plugin, $url, $accept, $max_bytes);
    my $cached = $self->{cache}{$cache_key};
    if ($cached && $cached->{expires} > $now) {
        $self->_metric('mediabot_plugin_v3_http_cache_hit_total', { plugin => $plugin });
        $self->_metric('mediabot_plugin_v3_http_request_total', {
            plugin => $plugin, outcome => 'cache',
        });
        $callback->(_response($cached->{data}, from_cache => 1));
        return { accepted => 1, cached => 1 };
    }
    delete $self->{cache}{$cache_key} if $cached;

    my $circuit = $self->{circuit}{$origin} || {};
    if (($circuit->{open_until} // 0) > $now) {
        $self->_metric('mediabot_plugin_v3_http_request_total', {
            plugin => $plugin, outcome => 'circuit_open',
        });
        $callback->(_response({ ok => 0, error => 'circuit_open', url => $url }));
        return { accepted => 0, error => 'circuit_open' };
    }

    my $inflight = $self->{inflight}{$plugin} ||= {};
    if (keys(%$inflight) >= $MAX_INFLIGHT_PER_PLUGIN) {
        $self->_metric('mediabot_plugin_v3_http_request_total', {
            plugin => $plugin, outcome => 'busy',
        });
        $callback->(_response({ ok => 0, error => 'busy', url => $url }));
        return { accepted => 0, error => 'busy' };
    }

    my $id = ++$self->{sequence};
    my $generation = $self->{generation}{$plugin} // 0;
    my $finished = 0;
    my $finish = sub {
        my ($worker_result) = @_;
        return if $finished++;
        delete $self->{inflight}{$plugin}{$id};
        delete $self->{inflight}{$plugin}
            unless keys %{ $self->{inflight}{$plugin} || {} };
        return if ($self->{generation}{$plugin} // 0) != $generation;

        my $data;
        if (ref($worker_result) eq 'HASH' && $worker_result->{ok}
            && ref($worker_result->{value}) eq 'HASH') {
            $data = { %{ $worker_result->{value} } };
        }
        else {
            my $error = ref($worker_result) eq 'HASH'
                ? _clean_error($worker_result->{error}, 'transport') : 'transport';
            $data = { ok => 0, error => $error, url => $url };
        }

        my $failed = !$data->{ok} && (($data->{status} // 0) == 0
            || ($data->{status} // 0) == 429 || ($data->{status} // 0) >= 500);
        if ($failed) {
            my $state = $self->{circuit}{$origin} ||= { failures => 0 };
            $state->{failures}++;
            if ($state->{failures} >= $CIRCUIT_FAILURES) {
                $state->{open_until} = $self->{clock}->() + $CIRCUIT_SECONDS;
                $self->_metric('mediabot_plugin_v3_http_circuit_open_total', {
                    plugin => $plugin,
                });
            }
        }
        else {
            delete $self->{circuit}{$origin};
        }
        if ($data->{ok} && $ttl > 0) {
            $self->_cache_store($cache_key, $data, $self->{clock}->() + $ttl);
        }
        my $outcome = $data->{ok} ? 'ok' : _clean_error($data->{error}, 'failed');
        $self->_metric('mediabot_plugin_v3_http_request_total', {
            plugin => $plugin, outcome => $outcome,
        });
        eval { $callback->(_response($data)); 1 } or do {
            my $error = $@ || 'callback failed';
            eval { $self->{on_log}->(1, $error) };
        };
    };

    my %worker_args = (
        loop       => $self->{loop},
        label      => "plugin-http:$plugin",
        timeout    => $timeout,
        max_output => $max_bytes + 8192,
        child      => sub {
            return _perform_request(
                $self->{requester}, $self->{resolver}, $url,
                $timeout, $max_bytes, $accept);
        },
        on_done    => $finish,
    );
    $self->{inflight}{$plugin}{$id} = bless({}, 'Mediabot::Plugin::HTTPServiceV3::Pending');
    my $worker;
    if (ref($self->{worker_factory}) eq 'CODE') {
        $worker = $self->{worker_factory}->(%worker_args);
    }
    else {
        require Mediabot::AsyncWorker;
        $worker = Mediabot::AsyncWorker->start(%worker_args);
    }
    unless ($worker) {
        $finish->({ ok => 0, error => 'worker_setup' });
        return { accepted => 0, error => 'worker_setup' };
    }
    $self->{inflight}{$plugin}{$id} = $worker unless $finished;
    return { accepted => 1, request_id => $id };
}

sub cancel_plugin {
    my ($self, $plugin) = @_;
    $plugin = _plugin_name($plugin);
    $self->{generation}{$plugin} = ($self->{generation}{$plugin} // 0) + 1;
    my $workers = delete $self->{inflight}{$plugin} || {};
    my $cancelled = 0;
    for my $worker (values %$workers) {
        next unless ref($worker) && eval { $worker->can('cancel') };
        $cancelled++ if eval { $worker->cancel('plugin disabled') };
    }
    return $cancelled;
}

sub inflight_count {
    my ($self, $plugin) = @_;
    $plugin = _plugin_name($plugin);
    return scalar keys %{ $self->{inflight}{$plugin} || {} };
}

1;
