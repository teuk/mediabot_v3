use strict;
use warnings;
use utf8;
use Test::More;
use Encode qw(encode_utf8 decode_utf8);
use JSON::MaybeXS qw(decode_json);
use IO::Socket::INET;
use IO::Async::Loop;
use IO::Async::Stream;
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);
use Mediabot::Metrics;

sub response847 {
    my ($bytes)=@_;
    my ($header,$body)=split /\r\n\r\n/,$bytes,2;
    my ($size)=($header//'')=~/\r\nContent-Length: (\d+)/;
    is($size,length($body//''),'HTTP Content-Length matches exactly the emitted byte body');
    ok(!utf8::is_utf8($body//''),'HTTP body is a byte string');
    return ($header,$body);
}
{
    my $title = 'Björk — Jóga 🎶 / 東京の夜 / العربية';
    my $m=Mediabot::Metrics->new(enabled=>1);
    my $payload={ok=>1,listeners=>3,title=>$title,metadata=>{artist=>'Zoë',tags=>['Été','音楽']}};
    $m->set_radio_status_provider(sub {$payload});
    is_deeply(decode_json($m->render_radio_status_json),$payload,'direct JSON API retains its encoded-byte contract');
    my ($head,$body)=response847($m->_route_http_request("GET /api/radio/status HTTP/1.1\r\nHost: localhost\r\n\r\n"));
    like($head,qr/\AHTTP\/1[.]1 200 OK/,'radio status keeps HTTP success');
    like($head,qr/Content-Type: application\/json; charset=utf-8/,'radio status keeps its JSON media type');
    my $decoded;ok(eval {$decoded=decode_json($body);1},'radio HTTP body is valid UTF-8 JSON');
    is_deeply($decoded,$payload,'radio metadata arrives without double encoding or changed fields');
}
{
    my $m=Mediabot::Metrics->new(enabled=>1);
    # An unflagged Latin-1 character is still a character body, not pre-encoded UTF-8.
    my ($head,$body)=response847($m->_http_response_bytes('200 OK',"\xE9\n",'text/plain; charset=utf-8'));
    is($body,encode_utf8("é\n"),'plain body is encoded even when its Perl UTF-8 flag is off');
    is(decode_utf8($body),"é\n",'plain character response retains its original meaning');
    $m->set('mediabot_channel_nick_count',2,{channel=>'#café🚀'});
    ($head,$body)=response847($m->_route_http_request("GET /metrics HTTP/1.1\r\n\r\n"));
    like(decode_utf8($body),qr/mediabot_channel_nick_count\{channel="#café🚀"\} 2/,
        'Prometheus labels retain character-to-UTF-8 encoding exactly once');
    like($head,qr/version=0[.]0[.]4/,'Prometheus format remains unchanged');
    ($head,$body)=response847($m->_route_http_request("POST /api/radio/status HTTP/1.1\r\n\r\n"));
    like($head,qr/404 Not Found/,'unsupported method remains rejected');
}
sub connect847 {
    my ($m)=@_;
    my $port=$m->{listener}->read_handle->sockport;
    my $socket=IO::Socket::INET->new(PeerAddr=>'127.0.0.1',PeerPort=>$port,Proto=>'tcp',Timeout=>2)
        or die "Cannot connect to isolated metrics listener: $!";
    my $received = { bytes => '', eof => 0 };
    my $stream=IO::Async::Stream->new(handle=>$socket,on_read=>sub {
        my ($io,$buffer,$eof)=@_;
        $received->{bytes}.=$$buffer;
        $$buffer='';
        $received->{eof}=1 if $eof;
        return 0;
    });
    $m->{loop}->add($stream);
    return ($stream, $received);
}

sub await847 {
    my ($loop, $condition, $seconds) = @_;
    my $until = clock_gettime(CLOCK_MONOTONIC) + $seconds;
    $loop->loop_once(.01) until $condition->() || clock_gettime(CLOCK_MONOTONIC) >= $until;
    return $condition->();
}

sub scrape847 {
    my ($m, $request)=@_;
    my ($client, $reply) = connect847($m);
    $client->write($request);
    ok(await847($m->{loop}, sub { $reply->{eof} }, 4),
        'actual loopback request completes within its deadline');
    $client->close_now;
    return $reply->{bytes};
}

sub get847 {
    return "GET $_[0] HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
}

{
    my $loop=IO::Async::Loop->really_new;my $m=Mediabot::Metrics->new(enabled=>1,loop=>$loop);
    $m->{port}=0; # Test-only OS-selected ephemeral port; never binds a configured host endpoint.
    $m->set_radio_status_provider(sub {{title=>'Björk — Jóga 🎶',listeners=>9}});
    ok($m->start_http_server,'actual isolated metrics HTTP listener starts');
    my ($head,$body)=response847(scrape847($m,get847('/api/radio/status')));
    my $radio=decode_json($body);
    is($radio->{title},'Björk — Jóga 🎶','real socket preserves international title and emoji');
    is($radio->{listeners},9,'real socket preserves numeric radio data');
    # Invalid instrumentation must not poison later scrapes or block the listener.
    ok(eval {
        $m->set('mediabot_db_up',1);$m->set('mediabot_db_up',"bad\ninjected 9");
        $m->observe('mediabot_scheduler_tick_seconds',.05,{task=>'test'});
        $m->set('mediabot_scheduler_tick_seconds',3,{task=>'test'});
        $m->observe('mediabot_scheduler_tick_seconds','1e999',{task=>'test'});1;
    },'invalid instrumentation does not throw through the caller');
    ($head,$body)=response847(scrape847($m,get847('/metrics')));
    like($head,qr/\AHTTP\/1[.]1 200 OK/,'metrics scrape remains available after rejected mutations');
    like($body,qr/^mediabot_db_up 1$/m,'last valid scalar sample survives rejected instrumentation');
    like($body,qr/^mediabot_scheduler_tick_seconds_count\{task="test"\} 1$/m,
        'real scrape retains the valid histogram count');
    unlike($body,qr/^injected |HASH\(|\sInf(?:\s|$)/m,'invalid scalar/reference/infinite values do not reach wire samples');
    my $too_large = "GET /metrics HTTP/1.1\r\nX-Test: " . ('x' x (16 * 1024));
    like(scrape847($m, $too_large), qr/\AHTTP\/1[.]1 431 /,
        'oversized unfinished headers still receive HTTP 431 over TCP');

    my ($client, $reply) = connect847($m);
    $client->write("GET /metrics HTTP/1.1\r\n");
    $loop->loop_once(.01) for 1..3; # Accept the socket and read its partial header.
    $m->stop_http_server;
    ok(await847($loop, sub { $reply->{eof} }, .5) && $reply->{bytes} eq '',
        'stopping the listener closes its already accepted client without routing');
    $client->close_now;
    ok($m->start_http_server, 'listener can start again after closing active connections');
    like(scrape847($m, get847('/metrics')), qr/\AHTTP\/1[.]1 200 OK/,
        'restarted listener serves a fresh scrape');
    $m->stop_http_server;
}
{
    no warnings 'redefine';
    local *Mediabot::Metrics::_http_connection_timeout = sub { .2 };
    my $loop = IO::Async::Loop->really_new;
    my $m = Mediabot::Metrics->new(enabled => 1, loop => $loop);
    $m->{port} = 0;
    die 'Cannot start the isolated deadline fixture' unless $m->start_http_server;
    my ($silent, $silent_reply) = connect847($m);
    my ($partial, $partial_reply) = connect847($m);
    $partial->write("GET /metrics HTTP/1.1\r\n");
    ok(await847($loop, sub { $silent_reply->{eof} && $partial_reply->{eof} }, 1)
            && $silent_reply->{bytes} eq '' && $partial_reply->{bytes} eq '',
        'a fixed deadline closes silent and partial clients without a response');
    $silent->close_now;
    $partial->close_now;
    like(scrape847($m, get847('/metrics')), qr/\AHTTP\/1[.]1 200 OK/,
        'expired connections do not disrupt later requests');
    $m->stop_http_server;
}
done_testing;
