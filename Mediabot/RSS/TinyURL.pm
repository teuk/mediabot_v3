package Mediabot::RSS::TinyURL;

# =============================================================================
# Presentation-only TinyURL helper for RSS/news announcements (mb693/mb730).
#
# The authenticated API remains optional: every failure preserves the exact
# article URL. Successful mappings and a failure circuit are persisted below
# the instance configuration directory so isolated command/RSS workers share
# one cache and stop hammering a depleted or unavailable TinyURL account.
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

our @EXPORT_OK = qw(
    shorten_url make_shortener state_file_path format_event
);

our $API = 'https://api.tinyurl.com/create';
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
        agent        => 'Mediabot-RSS-TinyURL/3.6',
    );
}

sub _api_key {
    my ($value) = @_;
    return '' unless defined($value) && !ref($value);
    $value =~ s/^\s+|\s+$//g;
    return '' unless $value =~ /\A[!-~]{16,512}\z/;
    return $value;
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
        return File::Spec->catfile($base, 'cache', 'tinyurl-state.json');
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
        ($fh, $tmp) = tempfile('.tinyurl-state.XXXXXX', DIR => $dir, UNLINK => 0);
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

sub _api_error_text {
    my ($decoded) = @_;
    return '' unless ref($decoded) eq 'HASH';
    my $errors = $decoded->{errors};
    return _clean_scalar($errors, '', 240) unless ref($errors);
    return '' unless ref($errors) eq 'ARRAY';
    my @parts;
    for my $error (@$errors) {
        my $text = ref($error) eq 'HASH'
            ? ($error->{message} // $error->{code} // '')
            : $error;
        $text = _clean_scalar($text, '', 120);
        push @parts, $text if length($text);
        last if @parts >= 2;
    }
    return join('; ', @parts);
}

sub _circuit_seconds {
    my ($category, $status, $headers) = @_;
    if ($category eq 'link_limit') {
        return 24 * 3600;
    }
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
    my ($http, $url, $api_key) = @_;

    my $payload = eval {
        JSON::PP->new->utf8->canonical->encode({
            domain => 'tinyurl.com',
            url    => $url,
        });
    };
    return { ok => 0, category => 'contract', status => 0, reason => 'payload' }
        unless defined($payload) && length($payload);

    my $res;
    my $request_ok = eval {
        $res = $http->request('POST', $API, {
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
        my $api_error = lc _api_error_text($decoded);
        my $category = ($status == 422 && $api_error =~ /tinyurl links? limit reached/)
            ? 'link_limit'
            : ($status == 429 ? 'rate_limit'
            : (($status == 401 || $status == 403) ? 'auth'
            : ($status >= 500 ? 'service' : 'client')));
        return {
            ok       => 0,
            category => $category,
            status   => $status,
            reason   => $reason,
            headers  => ref($res->{headers}) eq 'HASH' ? $res->{headers} : {},
        };
    }

    return { ok => 0, category => 'contract', status => $status, reason => 'invalid_json' }
        unless ref($decoded) eq 'HASH' && ref($decoded->{data}) eq 'HASH';

    my $returned_url = $decoded->{data}{url};
    return { ok => 0, category => 'destination_mismatch', status => $status, reason => 'destination' }
        unless defined($returned_url) && !ref($returned_url) && $returned_url eq $url;

    my $short = $decoded->{data}{tiny_url} // '';
    return { ok => 0, category => 'invalid_alias', status => $status, reason => 'alias' }
        if ref($short);
    $short =~ s/^[\s\r\n]+|[\s\r\n]+\z//g;
    return { ok => 0, category => 'invalid_alias', status => $status, reason => 'alias' }
        unless $short =~ m{\Ahttps://tinyurl\.com/[A-Za-z0-9_-]+\z}i;

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
    return 'TinyURL: unknown event' unless ref($event) eq 'HASH';
    my $kind = _clean_scalar($event->{kind}, 'unknown', 40);
    my $category = _clean_scalar($event->{category}, 'unknown', 48);
    my $status = int($event->{status} || 0);

    if ($kind eq 'failure') {
        my $label = $category eq 'link_limit'
            ? 'link creation limit reached'
            : $category;
        my $http = $status ? "HTTP $status " : '';
        return sprintf('TinyURL: %s%s; circuit open for %ds',
            $http, $label, int($event->{circuit_seconds} || 0));
    }
    if ($kind eq 'circuit_open') {
        return sprintf('TinyURL: circuit remains open for %ds (%s)',
            int($event->{remaining} || 0), $category);
    }
    if ($kind eq 'recovery') {
        return "TinyURL: shortening recovered after $category";
    }
    if ($kind eq 'state_error') {
        return 'TinyURL: shared cache/circuit state unavailable; using safe URL fallback';
    }
    return "TinyURL: $kind ($category)";
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
    my $now = _now($opts{now});

    my ($wrapped, $state_error) = _with_locked_state($state_file, sub {
        my ($state) = @_;
        my $cache = $state->{cache};
        my $dirty_cache = 0;
        my $cached = $cache->{$url};
        if (ref($cached) eq 'HASH') {
            my $short = $cached->{short};
            if (defined($short) && !ref($short)
                && $short =~ m{\Ahttps://tinyurl\.com/[A-Za-z0-9_-]+\z}i) {
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
        my $outcome = _request_outcome($http, $url, $api_key);
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
    return $url unless $url =~ m{\Ahttps?://}i;
    return $url if $url =~ m{\Ahttps://tinyurl\.com/\S+\z}i;

    my $api_key = _api_key($opts{api_key});
    return $url unless length($api_key);

    local @ENV{qw(http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy)};
    my $http = $opts{http} || _default_http();
    return $url unless $http;

    my $state_file = state_file_path(
        state_file => $opts{state_file},
        config_file => $opts{config_file},
    );
    return _stateful_shorten($url, %opts,
        api_key => $api_key, http => $http, state_file => $state_file)
        if length($state_file);

    my $outcome = _request_outcome($http, $url, $api_key);
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
    return sub { defined($_[0]) && !ref($_[0]) ? $_[0] : '' }
        unless length($api_key);

    local @ENV{qw(http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy)};
    my $http = $opts{http} || _default_http();
    return sub { defined($_[0]) && !ref($_[0]) ? $_[0] : '' } unless $http;

    my $state_file = state_file_path(
        state_file => $opts{state_file},
        config_file => $opts{config_file},
    );
    return sub {
        shorten_url($_[0], %opts,
            http => $http, api_key => $api_key, state_file => $state_file)
    };
}

1;
