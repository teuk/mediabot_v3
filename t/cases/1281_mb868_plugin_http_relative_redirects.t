use strict;
use warnings;
use Test::More;
use Mediabot::Plugin::HTTPServiceV3;

# Real URL admission, redirect resolution and transport orchestration. Only
# DNS and HTTP are local fixtures; no live endpoint is needed.
for my $case (
    ['parent path', 'https://api.example.test/a/b/feed', '../latest?limit=2',
        'https://api.example.test/a/latest?limit=2'],
    ['current directory', 'https://api.example.test/a/b/feed', './latest',
        'https://api.example.test/a/b/latest'],
    ['two parents', 'https://api.example.test/a/b/feed', '../../latest',
        'https://api.example.test/latest'],
    ['query replacement', 'https://api.example.test/a/feed?old=1', '?page=2',
        'https://api.example.test/a/feed?page=2'],
    ['pathless query replacement', 'https://api.example.test?old=1', '?page=2',
        'https://api.example.test/?page=2'],
    ['pathless relative path', 'https://api.example.test?old=1', 'Latest?ID=AbC',
        'https://api.example.test/Latest?ID=AbC'],
    ['origin relative', 'https://api.example.test/a/b/feed', '/latest',
        'https://api.example.test/latest'],
    ['new HTTPS origin', 'https://api.example.test/a/feed', '//other.example.test/Latest',
        'https://other.example.test/Latest'],
    ['absolute HTTPS', 'https://api.example.test/a/feed', 'https://other.example.test/Latest',
        'https://other.example.test/Latest'],
    ['encoded path', 'https://api.example.test/a/feed', '%2e%2e/Latest%2FID?x=../AbC',
        'https://api.example.test/a/%2e%2e/Latest%2FID?x=../AbC'],
) {
    my ($label, $start, $location, $expected) = @$case;
    my (@requests, @resolved, $result);
    my $ok = eval {
        $result = Mediabot::Plugin::HTTPServiceV3::_perform_request(
            sub {
                my ($url, %args) = @_;
                push @requests, {url => $url, %args};
                return {status => 302, headers => {location => $location}}
                    if @requests == 1;
                return {status => $url eq $expected ? 200 : 404,
                    headers => {'content-type' => 'application/json'}, content => '{"ok":true}'};
            },
            sub {push @resolved, [@_]; ['8.8.8.8']},
            $start, 3, 4096, 'application/json',
        );
        1;
    };
    ok($ok, "$label: follows without an exception") or diag($@);
    ok($result && $result->{ok}, "$label: reaches the intended endpoint");
    is($requests[1] ? $requests[1]{url} : undef, $expected, "$label: exact request target");
    is(ref($result) eq 'HASH' ? $result->{url} : undef, $expected,
        "$label: response identifies the final target");
    is(scalar @requests, 2, "$label: one request per hop");
    is(scalar @resolved, 2, "$label: DNS admission repeated for each hop");
    is_deeply($_->{validated_addresses}, ['8.8.8.8'], "$label: validated peer retained") for @requests;
}

my ($normalized) = Mediabot::Plugin::HTTPServiceV3::_url_parts('HTTPS://API.EXAMPLE.TEST?ID=AbC');
is($normalized, 'https://api.example.test/?ID=AbC', 'pathless query gets a root path; query case is preserved');

for my $location ('http://other.example.test/feed', '//127.0.0.1/private',
    '//user:secret@other.example.test/feed', '/feed#fragment', "/bad path", "/bad\tpath") {
    my $requests = 0;
    my $ok = eval {
        Mediabot::Plugin::HTTPServiceV3::_perform_request(
            sub { $requests++; {status => 302, headers => {location => $location}} },
            sub {['8.8.8.8']}, 'https://api.example.test/feed', 3, 4096, 'text/plain');
        1;
    };
    ok(!$ok, 'unsafe or unsupported redirect is rejected');
    is($requests, 1, 'rejected redirect is never requested');
}

{
    my $requests = 0;
    my $ok = eval {
        Mediabot::Plugin::HTTPServiceV3::_perform_request(
            sub {$requests++; {status => 302, headers => {location => './again'}}},
            sub {['8.8.8.8']}, 'https://api.example.test/feed', 3, 4096, 'text/plain');
        1;
    };
    ok(!$ok, 'relative redirect loop is rejected');
    like($@, qr/redirect limit exceeded/, 'redirect bound retains its explicit error');
    is($requests, 3, 'two-redirect budget is unchanged');
}

{
    my (@jobs, @responses, @requests);
    my $service = Mediabot::Plugin::HTTPServiceV3->new(
        resolver => sub {['8.8.8.8']},
        requester => sub {
            push @requests, $_[0];
            return @requests == 1
                ? {status => 302, headers => {location => './Latest?ID=AbC'}}
                : {status => 200, headers => {}, content => 'local result'};
        },
        worker_factory => sub {my $job = {@_}; push @jobs, $job; return $job},
    );
    my $request = {url => 'https://api.example.test?old=1', cache_ttl_seconds => 60};
    ok($service->fetch('redirect-v3', $request, sub {push @responses, $_[0]})->{accepted},
        'public fetch accepts a pathless query URL');
    is($service->inflight_count('redirect-v3'), 1, 'request owns its worker slot');
    my $value = $jobs[0]{child}->();
    $jobs[0]{on_done}->({ok => 1, value => $value});
    ok($responses[0]->ok, 'public callback receives a successful response');
    is($responses[0]->url, 'https://api.example.test/Latest?ID=AbC', 'public response uses the resolved URL');
    is($responses[0]->body, 'local result', 'public response retains the body');
    is($service->inflight_count('redirect-v3'), 0, 'completion releases its worker slot');
    $service->fetch('redirect-v3', $request, sub {push @responses, $_[0]});
    ok($responses[1]->from_cache, 'redirected result remains cacheable by the original request');
    is(scalar @requests, 2, 'cache hit sends no further requests');
}
done_testing();
