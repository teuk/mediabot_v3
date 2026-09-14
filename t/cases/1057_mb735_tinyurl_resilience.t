# t/cases/1057_mb735_tinyurl_resilience.t
# =============================================================================
# MB735 — TinyURL resilience shared by isolated RSS/news workers.
# =============================================================================

use strict;
use warnings;
use utf8;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }

use File::Spec;
use File::Temp qw(tempdir);
use JSON::PP ();
use Mediabot::RSS::TinyURL qw(make_shortener state_file_path format_event);

{
    package FakeTiny1057;
    sub new { my ($class, @responses) = @_; bless { responses => \@responses, calls => 0 }, $class }
    sub request {
        my ($self, undef, undef, $opts) = @_;
        $self->{calls}++;
        my $response = shift @{ $self->{responses} };
        return $response if ref($response) eq 'HASH';

        my $payload = JSON::PP->new->utf8->decode($opts->{content} // '');
        my $url = $payload->{url};
        return {
            success => 1,
            status  => 200,
            reason  => 'OK',
            headers => {},
            content => JSON::PP->new->utf8->encode({
                data => { url => $url, tiny_url => 'https://tinyurl.com/' . $response },
            }),
        };
    }
}

return sub {
    my ($assert) = @_;
    my $tmp = tempdir('mb735-tinyurl-XXXXXX', TMPDIR => 1, CLEANUP => 1);
    my $config_file = File::Spec->catfile($tmp, 'mediabot.conf');
    my $state_file = state_file_path(config_file => $config_file);
    my $expected_state = File::Spec->catfile($tmp, 'cache', 'tinyurl-state.json');
    $assert->is($state_file, $expected_state,
        'mb735-1057: default state is private to the instance configuration directory');

    my $key = 'mb735-test-token-12345678901234567890';
    my $now = 1_800_000_000;
    my $article_a = 'https://example.org/news/a?utm_source=rss';
    my $article_b = 'https://example.org/news/b';
    my $article_c = 'https://example.org/news/c';

    my @events;
    my $success = FakeTiny1057->new('cached-a');
    my $shorten = make_shortener(
        api_key => $key, http => $success, state_file => $state_file,
        now => sub { $now }, on_event => sub { push @events, $_[0] },
    );
    $assert->is($shorten->($article_a), 'https://tinyurl.com/cached-a',
        'mb735-1057: successful shortening returns the bound alias');
    $assert->is($success->{calls}, 1,
        'mb735-1057: first URL performs one authenticated request');
    $assert->ok(-f $state_file,
        'mb735-1057: successful mapping creates the shared state file');
    $assert->is(sprintf('%04o', (stat($state_file))[2] & 07777), '0600',
        'mb735-1057: shared state is private');

    my $never_for_cache = FakeTiny1057->new({ success => 0, status => 500 });
    my $cached = make_shortener(
        api_key => $key, http => $never_for_cache, state_file => $state_file,
        now => sub { $now + 1 },
    );
    $assert->is($cached->($article_a), 'https://tinyurl.com/cached-a',
        'mb735-1057: a fresh worker reuses the persistent URL mapping');
    $assert->is($never_for_cache->{calls}, 0,
        'mb735-1057: cache hit performs no TinyURL request');

    my $limit = FakeTiny1057->new({
        success => 0,
        status  => 422,
        reason  => 'Unprocessable Entity',
        headers => {},
        content => JSON::PP->new->utf8->encode({ errors => ['TinyURL links limit reached.'] }),
    });
    @events = ();
    my $limited = make_shortener(
        api_key => $key, http => $limit, state_file => $state_file,
        now => sub { $now + 2 }, on_event => sub { push @events, $_[0] },
    );
    $assert->is($limited->($article_b), $article_b,
        'mb735-1057: account link limit preserves the original article URL');
    $assert->is($limit->{calls}, 1,
        'mb735-1057: the first account-limit response performs one request');
    $assert->is($events[0]{category}, 'link_limit',
        'mb735-1057: HTTP 422 payload is classified as the account link limit');
    $assert->is($events[0]{status}, 422,
        'mb735-1057: safe event retains the HTTP status');
    $assert->is($events[0]{circuit_seconds}, 86_400,
        'mb735-1057: link limit opens a 24-hour circuit');
    $assert->like(format_event($events[0]), qr/^TinyURL: HTTP 422 link creation limit reached;/,
        'mb735-1057: operator log explains the real TinyURL failure');

    open my $state_fh, '<:raw', $state_file or die "open $state_file: $!";
    local $/;
    my $state_json = <$state_fh>;
    close $state_fh;
    $assert->unlike($state_json, qr/\Q$key\E/,
        'mb735-1057: shared state never stores the API token');

    my $blocked_http = FakeTiny1057->new('must-not-run');
    @events = ();
    my $blocked = make_shortener(
        api_key => $key, http => $blocked_http, state_file => $state_file,
        now => sub { $now + 3 }, on_event => sub { push @events, $_[0] },
    );
    $assert->is($blocked->($article_c), $article_c,
        'mb735-1057: a fresh worker observes the shared open circuit');
    $assert->is($blocked_http->{calls}, 0,
        'mb735-1057: open circuit suppresses every further API request');
    $assert->is(scalar @events, 0,
        'mb735-1057: open circuit is silent inside the notice interval');
    $assert->is($blocked->($article_a), 'https://tinyurl.com/cached-a',
        'mb735-1057: cached links remain available while the circuit is open');

    $now += 6 * 3600 + 3;
    $assert->is($blocked->($article_c), $article_c,
        'mb735-1057: circuit remains protective before its 24-hour expiry');
    $assert->is($blocked_http->{calls}, 0,
        'mb735-1057: periodic circuit notice does not probe the API');
    $assert->is($events[0]{kind}, 'circuit_open',
        'mb735-1057: shared circuit emits one bounded periodic reminder');

    $now = 1_800_000_000 + 86_403;
    my $recovered_http = FakeTiny1057->new('recovered-c');
    @events = ();
    my $recovered = make_shortener(
        api_key => $key, http => $recovered_http, state_file => $state_file,
        now => sub { $now }, on_event => sub { push @events, $_[0] },
    );
    $assert->is($recovered->($article_c), 'https://tinyurl.com/recovered-c',
        'mb735-1057: API is probed again after circuit expiry');
    $assert->is($events[0]{kind}, 'recovery',
        'mb735-1057: successful post-circuit request emits recovery');
    $assert->is($events[0]{category}, 'link_limit',
        'mb735-1057: recovery identifies the previous failure category');

    my $rate_state = File::Spec->catfile($tmp, 'rate', 'state.json');
    my $rate_http = FakeTiny1057->new({
        success => 0, status => 429, reason => 'Too Many Requests',
        headers => { 'retry-after' => '120' }, content => '{}',
    });
    @events = ();
    my $rate_limited = make_shortener(
        api_key => $key, http => $rate_http, state_file => $rate_state,
        now => 1_900_000_000, on_event => sub { push @events, $_[0] },
    );
    $assert->is($rate_limited->('https://example.org/rate'), 'https://example.org/rate',
        'mb735-1057: HTTP 429 preserves the original URL');
    $assert->is($events[0]{category}, 'rate_limit',
        'mb735-1057: HTTP 429 is distinct from the account link limit');
    $assert->is($events[0]{circuit_seconds}, 120,
        'mb735-1057: Retry-After controls the rate-limit circuit');

    my $broken_state = File::Spec->catfile($tmp, 'broken', 'state.json');
    require File::Path;
    File::Path::make_path(File::Spec->catdir($tmp, 'broken'));
    open my $broken_fh, '>:raw', $broken_state or die "open $broken_state: $!";
    print {$broken_fh} '{broken';
    close $broken_fh;
    my $state_http = FakeTiny1057->new('must-not-run');
    @events = ();
    my $state_safe = make_shortener(
        api_key => $key, http => $state_http, state_file => $broken_state,
        now => 2_000_000_000, on_event => sub { push @events, $_[0] },
    );
    $assert->is($state_safe->('https://example.org/state'), 'https://example.org/state',
        'mb735-1057: unreadable shared state fails safely to the original URL');
    $assert->is($state_http->{calls}, 0,
        'mb735-1057: state failure cannot bypass shared burst protection');
    $assert->is($events[0]{kind}, 'state_error',
        'mb735-1057: state failure is observable without leaking its contents');
};
