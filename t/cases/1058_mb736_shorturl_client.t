# t/cases/1058_mb736_shorturl_client.t
# =============================================================================
# mb736 — generic private ShortURL client, exact destination binding and
# shared cache/circuit behavior for every RSS/news presentation path.
# =============================================================================

use strict;
use warnings;
use utf8;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }

use File::Spec;
use File::Temp qw(tempdir);
use JSON::PP ();
use Mediabot::URLShortener qw(
    shorten_url make_shortener make_bot_shortener state_file_path format_event
);

{
    package FakeShortURL1058;
    sub new { my ($class, @responses) = @_; bless { responses => \@responses, calls => [] }, $class }
    sub request {
        my ($self, $method, $endpoint, $opts) = @_;
        push @{ $self->{calls} }, [$method, $endpoint, $opts];
        my $response = shift @{ $self->{responses} };
        return $response if ref($response) eq 'HASH';

        my $body = JSON::PP->new->utf8->decode($opts->{content} // '');
        my $id = defined($response) ? $response : 'Abcdef23';
        return {
            success => 1,
            status  => 201,
            reason  => 'Created',
            headers => {},
            content => JSON::PP->new->utf8->encode({
                ok        => JSON::PP::true,
                protocol  => 1,
                id        => $id,
                url       => $body->{url},
                short_url => 'https://teuk.org/shorturl/' . $id,
                created   => JSON::PP::true,
            }),
        };
    }
}

{
    package FakeConf1058;
    sub new { my ($class, %values) = @_; bless \%values, $class }
    sub get { return $_[0]{$_[1]} }
}

return sub {
    my ($assert) = @_;
    my $tmp = tempdir('mb736-shorturl-XXXXXX', TMPDIR => 1, CLEANUP => 1);
    my $config_file = File::Spec->catfile($tmp, 'mediabot.conf');
    my $state_file = state_file_path(config_file => $config_file);
    my $api = 'https://teuk.org/shorturl/api/v1/links';
    my $base = 'https://teuk.org/shorturl/';
    my $key = 'a' x 64;
    my $article = 'https://example.org/news?id=736&utm_source=rss';

    $assert->is($state_file, File::Spec->catfile($tmp, 'cache', 'shorturl-state.json'),
        'mb736-1058: default state belongs to the instance configuration directory');

    my $http = FakeShortURL1058->new('Abcdef23');
    my $short = shorten_url(
        $article, http => $http, api_key => $key, api_url => $api,
        public_base => $base,
    );
    $assert->is($short, $base . 'Abcdef23',
        'mb736-1058: valid bound service response becomes the presentation URL');
    $assert->is($http->{calls}[0][0], 'POST',
        'mb736-1058: creation uses POST');
    $assert->is($http->{calls}[0][1], $api,
        'mb736-1058: creation uses only the configured HTTPS endpoint');
    $assert->is($http->{calls}[0][2]{headers}{Authorization}, "Bearer $key",
        'mb736-1058: instance token travels only in the authorization header');
    my $sent = JSON::PP->new->utf8->decode($http->{calls}[0][2]{content});
    $assert->is(join(',', sort keys %$sent), 'url',
        'mb736-1058: request JSON contains only the destination field');
    $assert->is($sent->{url}, $article,
        'mb736-1058: exact original destination is submitted');

    my $missing = FakeShortURL1058->new('MustNotRun');
    $assert->is(shorten_url($article, http => $missing), $article,
        'mb736-1058: missing private configuration preserves the original URL');
    $assert->is(scalar @{ $missing->{calls} }, 0,
        'mb736-1058: missing private configuration performs no HTTP request');

    my $split_origin = FakeShortURL1058->new('MustNotRun');
    $assert->is(shorten_url(
        $article, http => $split_origin, api_key => $key,
        api_url => 'https://evil.example/shorturl/api/v1/links',
        public_base => $base,
    ), $article, 'mb736-1058: API and public routes must share one exact base');
    $assert->is(scalar @{ $split_origin->{calls} }, 0,
        'mb736-1058: split-origin configuration cannot receive the bearer token');

    my $mismatch = FakeShortURL1058->new({
        success => 1, status => 200, reason => 'OK', headers => {},
        content => JSON::PP->new->utf8->encode({
            ok => JSON::PP::true, protocol => 1, id => 'Mismatch2',
            url => 'https://unrelated.example/wrong',
            short_url => $base . 'Mismatch2', created => JSON::PP::false,
        }),
    });
    $assert->is(shorten_url(
        $article, http => $mismatch, api_key => $key, api_url => $api,
        public_base => $base,
    ), $article, 'mb736-1058: destination mismatch preserves the exact original URL');

    my $bad_alias = FakeShortURL1058->new({
        success => 1, status => 200, reason => 'OK', headers => {},
        content => JSON::PP->new->utf8->encode({
            ok => JSON::PP::true, protocol => 1, id => 'Abcdef23', url => $article,
            short_url => 'https://evil.example/Abcdef23', created => JSON::PP::false,
        }),
    });
    $assert->is(shorten_url(
        $article, http => $bad_alias, api_key => $key, api_url => $api,
        public_base => $base,
    ), $article, 'mb736-1058: alias outside the configured public base is rejected');

    my $already = FakeShortURL1058->new('MustNotRun');
    $assert->is(shorten_url(
        $base . 'Abcdef23', http => $already, api_key => $key,
        api_url => $api, public_base => $base,
    ), $base . 'Abcdef23', 'mb736-1058: existing private alias is not shortened again');
    $assert->is(scalar @{ $already->{calls} }, 0,
        'mb736-1058: existing private alias performs no HTTP request');

    my $persistent = FakeShortURL1058->new('CacheAb23');
    my $cached = make_shortener(
        http => $persistent, api_key => $key, api_url => $api,
        public_base => $base, state_file => $state_file, now => 1_800_000_000,
    );
    $assert->is($cached->($article), $base . 'CacheAb23',
        'mb736-1058: successful mapping is returned and persisted');
    $assert->ok(-f $state_file, 'mb736-1058: shared cache file is created');
    $assert->is(sprintf('%04o', (stat($state_file))[2] & 07777), '0600',
        'mb736-1058: shared cache remains owner-only');
    open my $state_fh, '<:raw', $state_file or die "open $state_file: $!";
    local $/;
    my $state_json = <$state_fh>;
    close $state_fh;
    $assert->unlike($state_json, qr/\Q$key\E/,
        'mb736-1058: shared state never stores the bearer token');

    my $cache_hit = FakeShortURL1058->new({ success => 0, status => 503 });
    my $fresh_worker = make_shortener(
        http => $cache_hit, api_key => $key, api_url => $api,
        public_base => $base, state_file => $state_file, now => 1_800_000_001,
    );
    $assert->is($fresh_worker->($article), $base . 'CacheAb23',
        'mb736-1058: isolated worker reuses the shared successful mapping');
    $assert->is(scalar @{ $cache_hit->{calls} }, 0,
        'mb736-1058: shared cache hit performs no network request');

    my $rate_state = File::Spec->catfile($tmp, 'rate', 'state.json');
    my @events;
    my $limited_http = FakeShortURL1058->new({
        success => 0, status => 429, reason => 'Too Many Requests',
        headers => { 'retry-after' => '120' }, content => '{"error":"rate_limited"}',
    });
    my $limited = make_shortener(
        http => $limited_http, api_key => $key, api_url => $api,
        public_base => $base, state_file => $rate_state, now => 1_900_000_000,
        on_event => sub { push @events, $_[0] },
    );
    my $other = 'https://example.org/other';
    $assert->is($limited->($other), $other,
        'mb736-1058: service rate limit preserves the original URL');
    $assert->is($events[0]{category}, 'rate_limit',
        'mb736-1058: HTTP 429 opens the dedicated rate-limit circuit');
    $assert->is($events[0]{circuit_seconds}, 120,
        'mb736-1058: bounded Retry-After controls the circuit');
    $assert->like(format_event($events[0]), qr/^ShortURL: HTTP 429 rate_limit;/,
        'mb736-1058: operator event is provider-specific and secret-free');

    my $transport_state = File::Spec->catfile($tmp, 'transport', 'state.json');
    @events = ();
    my $synthetic_599 = make_shortener(
        http => FakeShortURL1058->new({
            success => 0, status => 599, reason => 'Internal Exception',
            headers => {}, content => '',
        }),
        api_key => $key, api_url => $api, public_base => $base,
        state_file => $transport_state, now => 1_950_000_000,
        on_event => sub { push @events, $_[0] },
    );
    $assert->is($synthetic_599->('https://example.org/transport'),
        'https://example.org/transport',
        'mb736-1058: synthetic HTTP::Tiny 599 preserves the original URL');
    $assert->is($events[0]{category}, 'transport',
        'mb736-1058: synthetic 599 is classified as a local transport error');
    $assert->is($events[0]{circuit_seconds}, 300,
        'mb736-1058: transient transport circuit remains bounded to five minutes');
    $assert->like(format_event($events[0]), qr/^ShortURL: HTTP 599 transport;/,
        'mb736-1058: synthetic transport diagnostic does not blame the backend');

    my $blocked_http = FakeShortURL1058->new('MustNotRun');
    my $blocked = make_shortener(
        http => $blocked_http, api_key => $key, api_url => $api,
        public_base => $base, state_file => $rate_state, now => 1_900_000_001,
    );
    $assert->is($blocked->('https://example.org/blocked'),
        'https://example.org/blocked',
        'mb736-1058: a fresh worker obeys the shared open circuit');
    $assert->is(scalar @{ $blocked_http->{calls} }, 0,
        'mb736-1058: shared circuit suppresses the request storm');

    my $bot_http = FakeShortURL1058->new('BotUri234');
    my $bot = {
        config_file => $config_file,
        conf => FakeConf1058->new(
            'shorturl.API_URL' => $api,
            'shorturl.PUBLIC_BASE_URL' => $base,
            'shorturl.API_KEY' => $key,
            'shorturl.STATE_FILE' => File::Spec->catfile($tmp, 'bot-state.json'),
        ),
    };
    my $bot_shortener = make_bot_shortener(bot => $bot, http => $bot_http,
                                            now => 2_000_000_000);
    $assert->is($bot_shortener->('https://example.org/bot'), $base . 'BotUri234',
        'mb736-1058: bot factory selects the configured private service');

    @events = ();
    my $partial_http = FakeShortURL1058->new('MustNotRun');
    my $partial_bot = {
        config_file => $config_file,
        conf => FakeConf1058->new('shorturl.API_URL' => $api),
    };
    my $partial = make_bot_shortener(
        bot => $partial_bot, http => $partial_http,
        on_event => sub { push @events, $_[0] },
    );
    $assert->is($partial->($article), $article,
        'mb736-1058: partial private configuration fails closed');
    $assert->is(scalar @{ $partial_http->{calls} }, 0,
        'mb736-1058: partial private configuration performs no request');
    $assert->is($events[0]{kind}, 'configuration_error',
        'mb736-1058: invalid configuration is observable without credentials');
};
