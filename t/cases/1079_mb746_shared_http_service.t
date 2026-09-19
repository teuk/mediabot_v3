# MB746 — shared HTTPS boundary, cache, circuit, timeout and revocation.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

{
    package T1079::Worker;
    sub new { my ($class, %args) = @_; bless { %args, cancelled => 0 }, $class }
    sub run {
        my ($self) = @_;
        my $value = eval { $self->{child}->() };
        return $self->{on_done}->({ ok => 0, error => 'worker_exception' }) if $@;
        return $self->{on_done}->({ ok => 1, value => $value });
    }
    sub fail { $_[0]{on_done}->({ ok => 0, error => $_[1] }) }
    sub cancel { $_[0]{cancelled} = 1; 1 }
}

return sub {
    my ($assert) = @_;
    require Mediabot::Plugin::HTTPServiceV3;

    my $now = 1000;
    my (@workers, @metrics, @responses);
    my $requester_calls = 0;
    my $service = Mediabot::Plugin::HTTPServiceV3->new(
        clock => sub { $now },
        resolver => sub { ['93.184.216.34'] },
        requester => sub {
            $requester_calls++;
            return {
                success => 1, status => 200,
                headers => { 'content-type' => 'application/json' },
                content => '{"text":"small magic"}',
            };
        },
        worker_factory => sub {
            my %args = @_;
            my $worker = T1079::Worker->new(%args);
            push @workers, $worker;
            return $worker;
        },
        on_metric => sub { push @metrics, [@_] },
    );

    my $accepted = $service->fetch('short-content-v3', {
        url => 'https://example.net/item.json', cache_ttl_seconds => 60,
    }, sub { push @responses, $_[0] });
    $assert->ok($accepted->{accepted} && !$accepted->{cached},
        'first HTTPS request is accepted asynchronously');
    $assert->is($service->inflight_count('short-content-v3'), 1,
        'inflight requests are counted per plugin');
    $workers[-1]->run;
    $assert->ok($responses[-1]->ok && !$responses[-1]->from_cache,
        'worker response crosses the immutable response facade');
    $assert->is($responses[-1]->body, '{"text":"small magic"}',
        'bounded UTF-8 body is preserved');
    $assert->is($service->inflight_count('short-content-v3'), 0,
        'completed request leaves no inflight slot');

    $service->fetch('short-content-v3', {
        url => 'https://example.net/item.json', cache_ttl_seconds => 60,
    }, sub { push @responses, $_[0] });
    $assert->ok($responses[-1]->from_cache,
        'fresh identical request is served from the shared cache');
    $assert->is($requester_calls, 1,
        'cache hit starts no second outbound request');

    my $ok = eval {
        $service->fetch('short-content-v3', {
            url => 'https://127.0.0.1/private',
        }, sub { });
        1;
    };
    $assert->like($@ // '', qr/destination address is blocked/,
        'loopback destination fails before worker creation');

    my @late;
    $service->fetch('short-content-v3', {
        url => 'https://example.org/slow', cache_ttl_seconds => 0,
    }, sub { push @late, $_[0] });
    my $slow = $workers[-1];
    $assert->is($service->cancel_plugin('short-content-v3'), 1,
        'disable path cancels the owned worker');
    $assert->ok($slow->{cancelled}, 'worker receives explicit cancellation');
    $slow->run;
    $assert->is(scalar @late, 0,
        'late completion is revoked after cancellation');

    my @timeouts;
    $service->fetch('another-v3', {
        url => 'https://timeout.example/item', cache_ttl_seconds => 0,
    }, sub { push @timeouts, $_[0] });
    $workers[-1]->fail('worker_timeout');
    $assert->is($timeouts[-1]->error, 'worker_timeout',
        'worker timeout becomes a bounded plugin response');

    my @failed;
    for (1 .. 3) {
        $service->fetch('circuit-v3', {
            url => 'https://failed.example/item', cache_ttl_seconds => 0,
        }, sub { push @failed, $_[0] });
        $workers[-1]->fail('transport');
    }
    my $worker_count = scalar @workers;
    $service->fetch('circuit-v3', {
        url => 'https://failed.example/item', cache_ttl_seconds => 0,
    }, sub { push @failed, $_[0] });
    $assert->is($failed[-1]->error, 'circuit_open',
        'three transport failures open the bounded circuit');
    $assert->is(scalar @workers, $worker_count,
        'open circuit starts no worker');

    my @busy;
    for my $path (qw(one two three)) {
        $service->fetch('busy-v3', {
            url => "https://busy.example/$path", cache_ttl_seconds => 0,
        }, sub { push @busy, $_[0] });
    }
    $assert->is($service->inflight_count('busy-v3'), 2,
        'per-plugin inflight work is capped at two');
    $assert->is($busy[-1]->error, 'busy',
        'third concurrent request receives a bounded busy outcome');
    $service->cancel_plugin('busy-v3');

    my (@redirect_workers, @redirected);
    my $redirect_service = Mediabot::Plugin::HTTPServiceV3->new(
        clock => sub { $now },
        resolver => sub { ['93.184.216.34'] },
        requester => sub {
            return {
                success => 0, status => 302,
                headers => { location => 'https://127.0.0.1/secret' },
                content => '',
            };
        },
        worker_factory => sub {
            my %args = @_;
            my $worker = T1079::Worker->new(%args);
            push @redirect_workers, $worker;
            return $worker;
        },
    );
    $redirect_service->fetch('redirect-v3', {
        url => 'https://public.example/start', cache_ttl_seconds => 0,
    }, sub { push @redirected, $_[0] });
    $redirect_workers[-1]->run;
    $assert->ok(!$redirected[-1]->ok,
        'redirect to a private destination fails inside the worker boundary');
};
