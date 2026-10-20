use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use IO::Async::Loop;
use Time::HiRes ();
use Mediabot::Plugin::HTTPServiceV3;

{
    package MB861Worker;
    sub new { my ($class, %args) = @_; bless \%args, $class }
    sub run { my ($self) = @_; $self->{on_done}->({ok => 1, value => $self->{child}->()}) }
    sub cancel { 1 }
}
my ($now, $calls, $status) = (100, 0, 200);
my (@metrics, @workers); my $defer = 0;
my $s = Mediabot::Plugin::HTTPServiceV3->new(
    clock => sub { $now }, resolver => sub { ['93.184.216.34'] },
    requester => sub {
        $calls++;
        return {status => $status, headers => {'content-type' => 'text/plain'}, content => "revision$calls"};
    },
    worker_factory => sub {
        my %args = @_; my $w = MB861Worker->new(%args); push @workers, $w;
        $w->run unless $defer; return $w;
    }, on_metric => sub { push @metrics, [@_] },
);
sub fetch {
    my ($ttl, %extra) = @_;
    my ($out, $callbacks) = (undef, 0);
    my $result = $s->fetch('fixture-v3', {
        url => 'https://example.net/item', cache_ttl_seconds => $ttl, %extra,
    }, sub { $out = shift; $callbacks++ });
    is($callbacks, 1, 'one completed HTTP request has one terminal callback');
    return ($out, $result);
}
my ($r) = fetch(60);
ok($r->ok && !$r->from_cache, 'positive TTL first fetch uses the worker');
is($calls, 1, 'first response performs one local transport call');
($r) = fetch(60);
ok($r->from_cache, 'identical positive TTL reuses its live entry');
is($calls, 1, 'cache hit performs no transport call');
$now += 5;
for my $revision (2, 3) {
    ($r) = fetch(0);
    ok($r->ok && !$r->from_cache, 'zero TTL bypasses an existing positive-TTL cache entry');
    is($r->body, "revision$revision", 'zero TTL receives the newly fetched body');
}
($r) = fetch(60);
ok($r->from_cache, 'zero TTL leaves another cache policy usable');
is($r->body, 'revision1', 'zero TTL does not overwrite the positive-TTL entry');
($r) = fetch(1);
ok(!$r->from_cache, 'shorter TTL cannot inherit the five-second-old long-TTL response');
is($r->body, 'revision4', 'shorter policy fetches its own response');
($r) = fetch(1);
ok($r->from_cache, 'shorter policy can reuse its own still-fresh response');
$now++;
($r) = fetch(1);
ok(!$r->from_cache, 'shorter policy expires at its exact own boundary');
is($r->body, 'revision5', 'expired short policy refreshes through transport');
($r) = fetch(300);
ok(!$r->from_cache, 'longer TTL receives its own independently dated entry');
is($r->body, 'revision6', 'longer policy cannot extend the age of another response');
($r) = fetch(undef);
ok($r->from_cache, 'omitted TTL normalizes to the existing 300-second default');
is($r->body, 'revision6', 'default and explicit equivalent policy share their response');
$now = 160;
($r) = fetch(60);
ok(!$r->from_cache, 'original policy expires at its exact original deadline');
is($r->body, 'revision7', 'original policy refreshes after expiry');
($r) = fetch(300);
is($r->body, 'revision6', 'refresh of a shorter policy preserves the longer policy entry');
($r) = fetch(60, accept => 'text/plain');
ok(!$r->from_cache, 'Accept remains part of cache identity');
($r) = fetch(60, max_bytes => 256);
ok(!$r->from_cache, 'body limit remains part of cache identity');
my @other;
$s->fetch('another-v3', {url => 'https://example.net/item', cache_ttl_seconds => 60}, sub {push @other, shift});
ok(!$other[0]->from_cache, 'another plugin cannot use the first plugin cache entry');

# A warm positive cache must not hide the normal failure/concurrency controls
# for an explicitly uncached request.
$status = 503;
for (1..3) { ($r) = fetch(0); is($r->status, 503, 'uncached request observes its current server failure') }
my $before = $calls;
($r) = fetch(0);
is($r->error, 'circuit_open', 'zero TTL still honors the shared open circuit');
is($calls, $before, 'open circuit starts no extra transport work');
($r) = fetch(60);
ok($r->ok && $r->from_cache, 'live positive cache remains available while the circuit is open');
$now += 61; $status = 200;
($r) = fetch(0);
ok($r->ok && !$r->from_cache, 'uncached request recovers after the circuit delay');
is($s->inflight_count('fixture-v3'), 0, 'completed requests retain no capacity slots');

# Use the same URL and a newly warmed cache before switching to deferred work.
($r) = fetch(60); $defer = 1;
my @pending;
for (1..2) {
    my $result = $s->fetch('fixture-v3', {url => 'https://example.net/item', cache_ttl_seconds => 0},
        sub {push @pending, shift});
    ok($result->{accepted} && !$result->{cached}, 'uncached work takes a bounded worker slot despite warm cache');
}
is($s->inflight_count('fixture-v3'), 2, 'uncached work keeps the two-worker limit');
my @busy;
my $busy = $s->fetch('fixture-v3', {url => 'https://example.net/item', cache_ttl_seconds => 0}, sub {push @busy, shift});
is($busy->{error}, 'busy', 'third uncached request cannot evade the concurrency cap');
is($busy[0] ? $busy[0]->error : '', 'busy', 'concurrency refusal remains a bounded response');
$s->cancel_plugin('fixture-v3');
$_->run for @workers[-2,-1];
is(scalar @pending, 0, 'disable still revokes pending uncached completions');
is($s->inflight_count('fixture-v3'), 0, 'revocation releases the uncached slots');
ok(grep($_->[0] eq 'mediabot_plugin_v3_http_cache_hit_total', @metrics), 'cache-hit metrics remain emitted');
{
    local $Mediabot::Plugin::HTTPServiceV3::MAX_CACHE_ENTRIES = 2;
    $defer = 0;
    for my $ttl (2, 3, 4) { fetch($ttl, url => 'https://example.net/bounded') }
    is(scalar keys %{$s->{cache}}, 2, 'additional TTL identities retain the total cache capacity bound');
    is(scalar @{$s->{cache_order}}, 2, 'cache ordering remains bounded across policies');
    ($r) = fetch(4, url => 'https://example.net/bounded');
    ok($r->from_cache, 'most recent policy remains cached after capacity eviction');
    ($r) = fetch(2, url => 'https://example.net/bounded');
    ok(!$r->from_cache, 'oldest policy is evicted and fetched again');
    is(scalar keys %{$s->{cache}}, 2, 'refresh after eviction still obeys the capacity bound');
}
{
    # Cross the real fork/pipe boundary with local response data, without TCP.
    my $dir = tempdir(CLEANUP => 1); my $file = "$dir/body";
    my $write = sub { open my $fh, '>', $file or die $!; print {$fh} $_[0]; close $fh or die $! };
    $write->('native first');
    my $loop = IO::Async::Loop->really_new;
    my $native = Mediabot::Plugin::HTTPServiceV3->new(loop => $loop,
        resolver => sub { ['93.184.216.34'] }, requester => sub {
            open my $fh, '<', $file or die $!; local $/; my $body = <$fh>; close $fh;
            return {status => 200, headers => {}, content => $body};
        });
    my @out;
    my $res = $native->fetch('native-v3', {url => 'https://example.net/item', cache_ttl_seconds => 60}, sub {push @out, shift});
    ok($res->{accepted} && !$res->{cached}, 'real initial request starts a native worker');
    my $end = Time::HiRes::time() + 5;
    $loop->loop_once(.02) while @out < 1 && Time::HiRes::time() < $end;
    is($out[0] ? $out[0]->body : '', 'native first', 'native worker supplies the initial cached response');
    $write->('native second');
    $res = $native->fetch('native-v3', {url => 'https://example.net/item', cache_ttl_seconds => 0}, sub {push @out, shift});
    ok($res->{accepted} && !$res->{cached}, 'zero TTL starts another native worker despite warm cache');
    $end = Time::HiRes::time() + 5;
    $loop->loop_once(.02) while @out < 2 && Time::HiRes::time() < $end;
    is($out[1] ? $out[1]->body : '', 'native second', 'native uncached completion contains the new response');
    ok($out[1] && !$out[1]->from_cache, 'native fresh response has no cache provenance');
    is($native->inflight_count('native-v3'), 0, 'native worker completion releases capacity');
    $native->fetch('native-v3', {url => 'https://example.net/item', cache_ttl_seconds => 60}, sub {push @out, shift});
    is($out[2] ? $out[2]->body : '', 'native first', 'native uncached fetch leaves the other policy intact');
}
done_testing;
