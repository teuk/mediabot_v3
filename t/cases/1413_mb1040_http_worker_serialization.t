use strict;
use warnings;
use utf8;
use Test::More;
use Encode qw(encode);
use Digest::SHA qw(sha256_hex);
use JSON::PP ();
use Time::HiRes ();
use IO::Async::Loop;
use Mediabot::AsyncWorker;
use Mediabot::Plugin::HTTPServiceV3;

# Exercise the production fork/JSON/pipe path. Only DNS and the remote HTTP
# endpoint are fixtures; no worker factory or output limit is replaced.
my @warnings;
local $SIG{__WARN__} = sub { push @warnings, @_ };
my $loop = IO::Async::Loop->really_new;
my ($wire, $status, $type) = ('', 200, 'application/json');
my $service = Mediabot::Plugin::HTTPServiceV3->new(
    loop => $loop,
    resolver => sub { ['93.184.216.34'] },
    requester => sub {
        return {status => $status, headers => {'content-type' => $type}, content => $wire};
    },
);
sub fetch_1413 {
    my ($path, %options) = @_;
    my @responses;
    my $admission = $service->fetch('serialization-v3', {
        url => "https://$path.example.net/item", timeout_seconds => 2,
        cache_ttl_seconds => 0, %options,
    }, sub { push @responses, shift });
    my $deadline = Time::HiRes::time() + 5;
    $loop->loop_once(.01) while !@responses && Time::HiRes::time() < $deadline;
    return ($responses[0], $admission, scalar @responses);
}
sub signature_1413 {
    my ($response, $admission, $callbacks) = @_;
    return ['no_response', $callbacks] unless $response;
    my $bytes = encode('UTF-8', $response->body);
    return [$admission->{accepted} ? 1 : 0, $admission->{cached} ? 1 : 0,
        $callbacks, $response->ok, $response->status, $response->error,
        $response->from_cache, length($bytes), sha256_hex($bytes),
        $service->inflight_count('serialization-v3')];
}
sub expected_1413 {
    my ($body, $code, $cached) = @_;
    return [1, $cached, 1, $code == 200 ? 1 : 0, $code,
        $code == 200 ? '' : "http_$code", $cached, length($body), sha256_hex($body), 0];
}
my $json = JSON::PP::encode_json([('') x 10000]); # 30,001 wire bytes, below the default 32 KiB cap.
$wire = $json;
my @first = fetch_1413('json', cache_ttl_seconds => 60);
is_deeply(signature_1413(@first), expected_1413($json, 200, 0),
    'a valid JSON response below the default HTTP cap survives native worker serialization');
my $decoded = eval { JSON::PP::decode_json($first[0] ? $first[0]->body : '') };
is(ref($decoded) eq 'ARRAY' ? scalar(@$decoded) : -1, 10000,
    'the plugin receives the complete parseable JSON document, not a truncated prefix');
is_deeply(signature_1413(fetch_1413('json', cache_ttl_seconds => 60)), expected_1413($json, 200, 1),
    'the complete escaped response can be reused by the existing positive-TTL cache');
$wire = JSON::PP::encode_json([('') x 10001]);
is_deeply(signature_1413(fetch_1413('json')), expected_1413($wire, 200, 0),
    'an uncached request still obtains a fresh escaped body despite a warm positive cache');

$type = 'text/plain';
$wire = "\x00" x 65536;
my @max = fetch_1413('maximum-escaped', max_bytes => 65536);
is_deeply(signature_1413(@max), expected_1413($wire, 200, 0),
    'six-byte JSON escapes fit for an exact 64 KiB HTTP body without changing its bytes');
$wire = encode('UTF-8', "\x01\"\\é🪄" x 3000);
is_deeply(signature_1413(fetch_1413('utf8')), expected_1413($wire, 200, 0),
    'UTF-8 characters, quotes, backslashes and controls retain their exact body bytes');
$status = 503; $type = 'application/json'; $wire = $json;
is_deeply(signature_1413(fetch_1413('unavailable')), expected_1413($wire, 503, 0),
    'a large HTTP error body preserves its real status instead of becoming a worker-output failure');
$status = 200; $type = 'text/plain'; $wire = 'a' x 65536;
is_deeply(signature_1413(fetch_1413('plain', max_bytes => 65536)), expected_1413($wire, 200, 0),
    'ordinary unescaped bodies at the maximum limit keep their successful behavior');

$wire = 'x' x 32769;
my @oversize = fetch_1413('oversize', cache_ttl_seconds => 60);
is_deeply(signature_1413(@oversize), [1,0,1,0,0,'worker_exception',0,0,sha256_hex(''),0],
    'a body above the HTTP cap is still refused before it can be delivered or cached');
$wire = 'recovered';
is_deeply(signature_1413(fetch_1413('oversize', cache_ttl_seconds => 60)), expected_1413($wire, 200, 0),
    'oversize refusal leaves capacity available and does not populate the response cache');
$wire = "\xff";
is_deeply(signature_1413(fetch_1413('invalid-utf8')), [1,0,1,0,0,'worker_exception',0,0,sha256_hex(''),0],
    'invalid UTF-8 remains a transport failure despite the larger serialized allowance');
$wire = 'valid again';
is_deeply(signature_1413(fetch_1413('invalid-utf8')), expected_1413($wire, 200, 0),
    'a later valid response recovers after malformed text and releases its worker slot');
$wire = "\x00" x 256;
is_deeply(signature_1413(fetch_1413('small-exact', max_bytes => 256)), expected_1413($wire, 200, 0),
    'an explicitly small body limit still accepts the exact boundary');
$wire .= "\x00";
is_deeply(signature_1413(fetch_1413('small-over', max_bytes => 256)), [1,0,1,0,0,'worker_exception',0,0,sha256_hex(''),0],
    'one byte over an explicitly small body limit remains refused');
my @active = Mediabot::AsyncWorker->active_workers($loop);
is_deeply([scalar(@active), $service->inflight_count('serialization-v3')], [0,0],
    'all real workers and HTTP capacity slots are released after success and failure');
is_deeply(\@warnings, [], 'HTTP/worker roundtrips produce no parent warnings');
done_testing;
