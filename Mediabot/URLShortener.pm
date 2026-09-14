package Mediabot::URLShortener;

# =============================================================================
# Shared URL presentation client for Mediabot announcements (mb736).
#
# The private creation endpoint is optional. Every failure preserves the exact
# original URL. Successful mappings and a failure circuit are persisted beside
# the instance configuration so isolated workers reuse one cache and never
# turn an unavailable shortening service into a request storm.
# =============================================================================

use strict;
use warnings;
use utf8;

use Exporter 'import';
use Fcntl qw(:DEFAULT :flock);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempfile);
use HTTP::Tiny;
use JSON::PP ();
use Mediabot::RSS::TinyURL ();

our @EXPORT_OK = qw(
    shorten_url make_shortener make_bot_shortener state_file_path format_event
);

our $STATE_VERSION = 1;
our $MAX_CACHE_ENTRIES = 5000;
our $MAX_STATE_BYTES = 8 * 1024 * 1024;
our $CIRCUIT_NOTICE_SECONDS = 6 * 3600;

sub _default_http {
    return HTTP::Tiny->new(
        timeout      => 2,
        max_size     => 4096,
        verify_SSL   => 1,
        max_redirect => 0,
        agent        => 'Mediabot-ShortURL/3.6',
    );
}

sub _api_key {
    my ($value) = @_;
    return '' unless defined($value) && !ref($value);
    $value =~ s/^\s+|\s+$//g;
    return '' unless $value =~ /\A[a-f0-9]{64}\z/;
    return $value;
}

sub _api_url {
    my ($value) = @_;
    return '' unless defined($value) && !ref($value);
    $value =~ s/^\s+|\s+$//g;
    return '' unless $value =~ m{\Ahttps://[A-Za-z0-9.-]+(?::([0-9]{2,5}))?/[A-Za-z0-9._~/%+-]*/api/v1/links\z};
    return '' if defined($1) && $1 > 65535;
    return $value;
}

sub _public_base {
    my ($value) = @_;
    return '' unless defined($value) && !ref($value);
    $value =~ s/^\s+|\s+$//g;
    return '' unless $value =~ m{\Ahttps://[A-Za-z0-9.-]+(?::([0-9]{2,5}))?/shorturl/\z};
    return '' if defined($1) && $1 > 65535;
    return $value;
}

sub _service_contract {
    my ($api_url, $public_base) = @_;
    $api_url = _api_url($api_url);
    $public_base = _public_base($public_base);
    return ('', '') unless length($api_url) && length($public_base);
    return ('', '') unless $api_url eq $public_base . 'api/v1/links';
    return ($api_url, $public_base);
}

sub _valid_target {
    my ($url) = @_;
    return 0 unless defined($url) && !ref($url)
        && length($url) && length($url) <= 4096;
    return 0 unless $url =~ /\A[\x21-\x7e]+\z/;
    return 0 unless $url =~ m{\Ahttps?://([^/?#]+)}i;
    my $authority = $1;
    return 0 if $authority =~ /\@/;
    my $port;
    if ($authority =~ /\A\[[0-9A-Fa-f:.]+\](?::(\d{1,5}))?\z/) {
        $port = $1;
    }
    elsif ($authority =~ /\A[^:]+(?::(\d{1,5}))?\z/) {
        $port = $1;
    }
    else {
        return 0;
    }
    return 0 if defined($port) && $port > 65535;
    return 1;
}

sub _clean_scalar {
    my ($value, $fallback, $max) = @_;
    $fallback = '' unless defined $fallback;
    $max ||= 160;
    return $fallback unless defined($value) && !ref($value);
    $value =~ s/[\x00-\x1f\x7f]+/ /g;
    $value =~ s/^\s+|\s+$//g;
    $value = substr($value, 0, $max) if length($value) > $max;
    return length($value) ? $value : $fallback;
}

sub _now {
    my ($value) = @_;
    if (ref($value) eq 'CODE') {
        my $seen = eval { $value->() };
        return 0 + $seen if defined($seen) && !ref($seen) && $seen =~ /^\d+(?:\.\d+)?$/;
    }
    return 0 + $value if defined($value) && !ref($value) && $value =~ /^\d+(?:\.\d+)?$/;
    return time();
}

sub state_file_path {
    my (%opts) = @_;
    my $configured = $opts{state_file};
    my $config_file = $opts{config_file};

    $configured = '' unless defined($configured) && !ref($configured);
    $config_file = '' unless defined($config_file) && !ref($config_file);
    $configured =~ s/^\s+|\s+$//g;
    $config_file =~ s/^\s+|\s+$//g;

    return '' if $configured =~ /[\x00\r\n]/ || $config_file =~ /[\x00\r\n]/;

    my $base = length($config_file) ? dirname(File::Spec->rel2abs($config_file)) : '';
    if (!length($configured)) {
        return '' unless length($base);
        return File::Spec->catfile($base, 'cache', 'shorturl-state.json');
    }

    return File::Spec->rel2abs($configured, length($base) ? $base : File::Spec->curdir())
        unless File::Spec->file_name_is_absolute($configured);
    return File::Spec->canonpath($configured);
}

sub _empty_state {
    return {
        version => $STATE_VERSION,
        cache   => {},
        circuit => {},
    };
}

sub _read_state {
    my ($path) = @_;
    return (_empty_state(), undef) unless -e $path;
    return (undef, 'state_symlink') if -l $path;

    my $size = -s $path;
    return (undef, 'state_too_large') if defined($size) && $size > $MAX_STATE_BYTES;

    open my $fh, '<:raw', $path or return (undef, 'state_open');
    local $/;
    my $raw = <$fh>;
    close $fh or return (undef, 'state_close');

    my $state = eval { JSON::PP->new->utf8->decode($raw // '') };
    return (undef, 'state_json') if $@ || ref($state) ne 'HASH';
    return (undef, 'state_version')
        unless ($state->{version} // 0) == $STATE_VERSION;

    $state->{cache} = {} unless ref($state->{cache}) eq 'HASH';
    $state->{circuit} = {} unless ref($state->{circuit}) eq 'HASH';
    return ($state, undef);
}

sub _write_state {
    my ($path, $state) = @_;
    my $dir = dirname($path);
    my ($fh, $tmp);
    my $created = eval {
        ($fh, $tmp) = tempfile('.shorturl-state.XXXXXX', DIR => $dir, UNLINK => 0);
        1;
    };
    return 'state_tmp_open' unless $created && $fh && defined($tmp);
    binmode $fh, ':raw';
    chmod 0600, $tmp or do { close $fh; unlink $tmp; return 'state_tmp_mode' };

    my $payload = eval { JSON::PP->new->utf8->canonical->encode($state) };
    if ($@ || !defined($payload) || length($payload) > $MAX_STATE_BYTES) {
        close $fh;
        unlink $tmp;
        return 'state_encode';
    }

    print {$fh} $payload or do { close $fh; unlink $tmp; return 'state_tmp_write' };
    close $fh or do { unlink $tmp; return 'state_tmp_close' };
    rename $tmp, $path or do { unlink $tmp; return 'state_rename' };
    chmod 0600, $path or return 'state_mode';
    return undef;
}

sub _with_locked_state {
    my ($path, $code) = @_;
    return (undef, 'state_path') unless defined($path) && length($path);
    return (undef, 'state_symlink') if -l $path || -l "$path.lock";

    my $dir = dirname($path);
    if (!-d $dir) {
        eval { make_path($dir, { mode => 0750 }); 1 }
            or return (undef, 'state_directory');
    }
    return (undef, 'state_directory') unless -d $dir && -w $dir;

    my $lock_path = "$path.lock";
    sysopen(my $lock_fh, $lock_path, O_RDWR | O_CREAT, 0600)
        or return (undef, 'state_lock_open');
    chmod 0600, $lock_path;
    flock($lock_fh, LOCK_EX) or do { close $lock_fh; return (undef, 'state_lock') };

    my ($state, $read_error) = _read_state($path);
    if ($read_error) {
        close $lock_fh;
        return (undef, $read_error);
    }

    my ($result, $dirty, $event);
    my $callback_ok = eval {
        ($result, $dirty, $event) = $code->($state);
        1;
    };
    if (!$callback_ok) {
        close $lock_fh;
        return (undef, 'state_callback');
    }
    if ($dirty) {
        my $write_error = _write_state($path, $state);
        if ($write_error) {
            close $lock_fh;
            return ({ result => $result, event => $event }, $write_error);
        }
    }

    close $lock_fh;
    return ({ result => $result, event => $event }, undef);
}

sub _circuit_seconds {
    my ($category, $status, $headers) = @_;
    if ($category eq 'rate_limit') {
        my $retry = ref($headers) eq 'HASH' ? $headers->{'retry-after'} : undef;
        $retry = 900 unless defined($retry) && !ref($retry) && $retry =~ /^\d+$/;
        $retry = 60 if $retry < 60;
        $retry = 24 * 3600 if $retry > 24 * 3600;
        return int($retry);
    }
    return 6 * 3600 if $category eq 'auth';
    return 3600 if $category =~ /^(?:client|contract|destination_mismatch|invalid_alias)$/;
    return 600 if $category eq 'service';
    return 300;
}

sub _request_outcome {
    my ($http, $url, $api_key, $api_url, $public_base) = @_;

    my $payload = eval {
        JSON::PP->new->utf8->canonical->encode({
            url => $url,
        });
    };
    return { ok => 0, category => 'contract', status => 0, reason => 'payload' }
        unless defined($payload) && length($payload);

    my $res;
    my $request_ok = eval {
        $res = $http->request('POST', $api_url, {
            headers => {
                Accept          => 'application/json',
                Authorization   => "Bearer $api_key",
                'Content-Type'  => 'application/json',
                'Cache-Control' => 'no-store',
            },
            content => $payload,
        });
        1;
    };
    return { ok => 0, category => 'transport', status => 0, reason => 'request' }
        unless $request_ok && ref($res) eq 'HASH';

    my $status = ($res->{status} // 0) =~ /^\d+$/ ? int($res->{status}) : 0;
    my $reason = _clean_scalar($res->{reason}, '', 80);
    my $decoded = eval { JSON::PP->new->utf8->decode($res->{content} // '') };
    $decoded = undef if $@ || ref($decoded) ne 'HASH';

    if (!$res->{success}) {
        # HTTP::Tiny reserves 599 for a local transport exception. It is not
        # an HTTP response emitted by the ShortURL backend.
        my $category = $status == 599 ? 'transport' : 'client';
        $category = 'rate_limit' if $status == 429;
        $category = 'auth' if $status == 401 || $status == 403;
        $category = 'service' if $status >= 500 && $status != 599;
        return {
            ok       => 0,
            category => $category,
            status   => $status,
            reason   => $reason,
            headers  => ref($res->{headers}) eq 'HASH' ? $res->{headers} : {},
        };
    }

    return { ok => 0, category => 'contract', status => $status, reason => 'invalid_json' }
        unless ref($decoded) eq 'HASH'
            && defined($decoded->{protocol}) && !ref($decoded->{protocol})
            && $decoded->{protocol} =~ /\A1\z/;

    my $returned_url = $decoded->{url};
    return { ok => 0, category => 'destination_mismatch', status => $status, reason => 'destination' }
        unless defined($returned_url) && !ref($returned_url) && $returned_url eq $url;

    my $identifier = $decoded->{id} // '';
    return { ok => 0, category => 'invalid_alias', status => $status, reason => 'identifier' }
        if ref($identifier)
            || $identifier !~ /\A[23456789A-HJ-NP-Za-km-z]{8,16}\z/;

    my $short = $decoded->{short_url} // '';
    return { ok => 0, category => 'invalid_alias', status => $status, reason => 'alias' }
        if ref($short);
    $short =~ s/^[\s\r\n]+|[\s\r\n]+\z//g;
    return { ok => 0, category => 'invalid_alias', status => $status, reason => 'alias' }
        unless $short eq $public_base . $identifier;

    return { ok => 1, url => $short, status => $status };
}

sub _failure_event {
    my ($outcome, $seconds) = @_;
    return {
        kind            => 'failure',
        level           => 1,
        category        => $outcome->{category},
        status          => int($outcome->{status} || 0),
        reason          => _clean_scalar($outcome->{reason}, '', 80),
        circuit_seconds => int($seconds || 0),
    };
}

sub _emit {
    my ($callback, $event) = @_;
    return unless ref($callback) eq 'CODE' && ref($event) eq 'HASH';
    eval { $callback->($event); 1 };
    return;
}

sub format_event {
    my ($event) = @_;
    return 'ShortURL: unknown event' unless ref($event) eq 'HASH';
    if (($event->{provider} // '') eq 'tinyurl') {
        my %legacy = %$event;
        delete $legacy{provider};
        return Mediabot::RSS::TinyURL::format_event(\%legacy);
    }
    my $kind = _clean_scalar($event->{kind}, 'unknown', 40);
    my $category = _clean_scalar($event->{category}, 'unknown', 48);
    my $status = int($event->{status} || 0);

    if ($kind eq 'failure') {
        my $http = $status ? "HTTP $status " : '';
        return sprintf('ShortURL: %s%s; circuit open for %ds',
            $http, $category, int($event->{circuit_seconds} || 0));
    }
    if ($kind eq 'circuit_open') {
        return sprintf('ShortURL: circuit remains open for %ds (%s)',
            int($event->{remaining} || 0), $category);
    }
    if ($kind eq 'recovery') {
        return "ShortURL: shortening recovered after $category";
    }
    if ($kind eq 'state_error') {
        return 'ShortURL: shared cache/circuit state unavailable; using safe URL fallback';
    }
    if ($kind eq 'configuration_error') {
        return 'ShortURL: incomplete or invalid private endpoint configuration; using original URLs';
    }
    return "ShortURL: $kind ($category)";
}

sub _prune_cache {
    my ($cache) = @_;
    return unless ref($cache) eq 'HASH';
    my @keys = keys %$cache;
    return if @keys <= $MAX_CACHE_ENTRIES;
    @keys = sort {
        int(ref($cache->{$a}) eq 'HASH' ? ($cache->{$a}{created_at} || 0) : 0)
            <=>
        int(ref($cache->{$b}) eq 'HASH' ? ($cache->{$b}{created_at} || 0) : 0)
    } @keys;
    my $remove = @keys - $MAX_CACHE_ENTRIES;
    delete $cache->{$_} for @keys[0 .. $remove - 1];
}

sub _stateful_shorten {
    my ($url, %opts) = @_;
    my $state_file = $opts{state_file};
    my $api_key = $opts{api_key};
    my $http = $opts{http};
    my $api_url = $opts{api_url};
    my $public_base = $opts{public_base};
    my $now = _now($opts{now});

    my ($wrapped, $state_error) = _with_locked_state($state_file, sub {
        my ($state) = @_;
        my $cache = $state->{cache};
        my $dirty_cache = 0;
        my $cached = $cache->{$url};
        if (ref($cached) eq 'HASH') {
            my $short = $cached->{short};
            if (defined($short) && !ref($short)
                && $short =~ /\A\Q$public_base\E[23456789A-HJ-NP-Za-km-z]{8,16}\z/) {
                return ($short, 0, undef);
            }
            delete $cache->{$url};
            $dirty_cache = 1;
        }

        my $circuit = $state->{circuit};
        my $until = int($circuit->{until} || 0);
        if ($until > $now) {
            my $event;
            my $dirty = $dirty_cache;
            my $last_notice = int($circuit->{last_notice_at} || 0);
            if ($now - $last_notice >= $CIRCUIT_NOTICE_SECONDS) {
                $circuit->{last_notice_at} = int($now);
                $dirty = 1;
                $event = {
                    kind      => 'circuit_open',
                    level     => 2,
                    category  => _clean_scalar($circuit->{category}, 'unknown', 48),
                    status    => int($circuit->{status} || 0),
                    remaining => int($until - $now),
                };
            }
            return ($url, $dirty, $event);
        }

        my $previous_category = _clean_scalar($circuit->{category}, '', 48);
        my $outcome = _request_outcome(
            $http, $url, $api_key, $api_url, $public_base);
        if ($outcome->{ok}) {
            $cache->{$url} = {
                short      => $outcome->{url},
                created_at => int($now),
            };
            _prune_cache($cache);
            $state->{circuit} = {};
            my $event = length($previous_category) ? {
                kind     => 'recovery',
                level    => 2,
                category => $previous_category,
                status   => int($outcome->{status} || 0),
            } : undef;
            return ($outcome->{url}, 1, $event);
        }

        my $seconds = _circuit_seconds(
            $outcome->{category}, $outcome->{status}, $outcome->{headers});
        $state->{circuit} = {
            category       => $outcome->{category},
            status         => int($outcome->{status} || 0),
            reason         => _clean_scalar($outcome->{reason}, '', 80),
            opened_at      => int($now),
            until          => int($now + $seconds),
            last_notice_at => int($now),
        };
        return ($url, 1, _failure_event($outcome, $seconds));
    });

    if ($state_error) {
        _emit($opts{on_event}, {
            kind => 'state_error', level => 1, category => $state_error, status => 0,
        });
        return $wrapped->{result}
            if ref($wrapped) eq 'HASH' && defined($wrapped->{result});
        return $url;
    }

    _emit($opts{on_event}, $wrapped->{event});
    return $wrapped->{result};
}

sub shorten_url {
    my ($url, %opts) = @_;

    return '' unless defined($url) && !ref($url) && length($url);
    return $url unless _valid_target($url);

    my $api_key = _api_key($opts{api_key});
    my ($api_url, $public_base) = _service_contract(
        $opts{api_url}, $opts{public_base});
    return $url unless length($api_key) && length($api_url) && length($public_base);
    return $url
        if $url =~ /\A\Q$public_base\E[23456789A-HJ-NP-Za-km-z]{8,16}\z/;

    local @ENV{qw(http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy)};
    my $http = $opts{http} || _default_http();
    return $url unless $http;

    my $state_file = state_file_path(
        state_file => $opts{state_file},
        config_file => $opts{config_file},
    );
    return _stateful_shorten($url, %opts,
        api_key => $api_key, api_url => $api_url, public_base => $public_base,
        http => $http, state_file => $state_file)
        if length($state_file);

    my $outcome = _request_outcome(
        $http, $url, $api_key, $api_url, $public_base);
    if (!$outcome->{ok}) {
        my $seconds = _circuit_seconds(
            $outcome->{category}, $outcome->{status}, $outcome->{headers});
        _emit($opts{on_event}, _failure_event($outcome, $seconds));
        return $url;
    }
    return $outcome->{url};
}

sub make_shortener {
    my (%opts) = @_;
    my $api_key = _api_key($opts{api_key});
    my ($api_url, $public_base) = _service_contract(
        $opts{api_url}, $opts{public_base});
    return sub { defined($_[0]) && !ref($_[0]) ? $_[0] : '' }
        unless length($api_key) && length($api_url) && length($public_base);

    local @ENV{qw(http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy)};
    my $http = $opts{http} || _default_http();
    return sub { defined($_[0]) && !ref($_[0]) ? $_[0] : '' } unless $http;

    my $state_file = state_file_path(
        state_file => $opts{state_file},
        config_file => $opts{config_file},
    );
    return sub {
        shorten_url($_[0], %opts,
            http => $http, api_key => $api_key, api_url => $api_url,
            public_base => $public_base, state_file => $state_file)
    };
}

sub _bot_config {
    my ($bot, $key) = @_;
    return '' unless $bot && ref($bot->{conf});
    my $value = eval { $bot->{conf}->get($key) };
    return defined($value) && !ref($value) ? $value : '';
}

sub make_bot_shortener {
    my (%opts) = @_;
    my $bot = $opts{bot};
    my $passthrough = sub {
        return defined($_[0]) && !ref($_[0]) ? $_[0] : '';
    };
    return $passthrough unless $bot;

    my %service = (
        api_url     => _bot_config($bot, 'shorturl.API_URL'),
        public_base => _bot_config($bot, 'shorturl.PUBLIC_BASE_URL'),
        api_key     => _bot_config($bot, 'shorturl.API_KEY'),
        state_file  => _bot_config($bot, 'shorturl.STATE_FILE'),
    );
    my $selected = grep { length($service{$_}) }
        qw(api_url public_base api_key state_file);

    if ($selected) {
        my ($api_url, $public_base) = _service_contract(
            $service{api_url}, $service{public_base});
        unless (length($api_url) && length($public_base)
            && length(_api_key($service{api_key}))) {
            _emit($opts{on_event}, {
                kind => 'configuration_error', level => 1,
                category => 'invalid_config', status => 0,
            });
            return $passthrough;
        }
        $service{api_url} = $api_url;
        $service{public_base} = $public_base;
        return make_shortener(
            %service,
            config_file => $bot->{config_file},
            map { exists($opts{$_}) ? ($_ => $opts{$_}) : () }
                qw(http now on_event),
        );
    }

    my $legacy_key = _bot_config($bot, 'tinyurl.API_KEY');
    my $legacy_state = _bot_config($bot, 'tinyurl.STATE_FILE');
    return $passthrough unless length($legacy_key);
    return Mediabot::RSS::TinyURL::make_shortener(
        api_key     => $legacy_key,
        state_file  => $legacy_state,
        config_file => $bot->{config_file},
        on_event    => sub {
            my ($event) = @_;
            return unless ref($event) eq 'HASH';
            _emit($opts{on_event}, { %$event, provider => 'tinyurl' });
        },
        map { exists($opts{$_}) ? ($_ => $opts{$_}) : () } qw(http now),
    );
}

1;
