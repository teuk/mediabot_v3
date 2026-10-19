use strict;
use warnings;
use utf8;
use Test::More;
use Encode qw(encode_utf8 decode_utf8);
use JSON::MaybeXS qw(decode_json);
use IO::Socket::INET;
use IO::Async::Loop;
use IO::Async::Stream;
use Time::HiRes qw(time);
use Mediabot::Metrics;

sub response847 {
    my ($bytes)=@_;
    my ($header,$body)=split /\r\n\r\n/,$bytes,2;
    my ($size)=($header//'')=~/\r\nContent-Length: (\d+)/;
    is($size,length($body//''),'HTTP Content-Length matches exactly the emitted byte body');
    ok(!utf8::is_utf8($body//''),'HTTP body is a byte string');
    return ($header,$body);
}
for my $title ('Björk — Jóga','Café','Niño 🎶','東京の夜','العربية','plain ASCII','') {
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
sub scrape847 {
    my ($m,$path)=@_;my $loop=$m->{loop};
    my $port=$m->{listener}->read_handle->sockport;
    my $socket=IO::Socket::INET->new(PeerAddr=>'127.0.0.1',PeerPort=>$port,Proto=>'tcp',Timeout=>2)
        or die "Cannot connect to isolated metrics listener: $!";
    my ($bytes,$ended)=('',0);
    my $stream=IO::Async::Stream->new(handle=>$socket,on_read=>sub {
        my ($io,$buffer,$eof)=@_;$bytes.=$$buffer;$$buffer='';$ended=1 if $eof;0;
    });
    $loop->add($stream);$stream->write("GET $path HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    my $until=time()+4;$loop->loop_once(.01) while !$ended && time()<$until;
    $stream->close_now;eval {$loop->remove($stream)};
    ok($ended,'actual loopback request completes within its deadline');
    return $bytes;
}
{
    my $loop=IO::Async::Loop->really_new;my $m=Mediabot::Metrics->new(enabled=>1,loop=>$loop);
    $m->{port}=0; # Test-only OS-selected ephemeral port; never binds a configured host endpoint.
    $m->set_radio_status_provider(sub {{title=>'Björk — Jóga 🎶',listeners=>9}});
    ok($m->start_http_server,'actual isolated metrics HTTP listener starts');
    my ($head,$body)=response847(scrape847($m,'/api/radio/status'));
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
    ($head,$body)=response847(scrape847($m,'/metrics'));
    like($head,qr/\AHTTP\/1[.]1 200 OK/,'metrics scrape remains available after rejected mutations');
    like($body,qr/^mediabot_db_up 1$/m,'last valid scalar sample survives rejected instrumentation');
    like($body,qr/^mediabot_scheduler_tick_seconds_count\{task="test"\} 1$/m,
        'real scrape retains the valid histogram count');
    unlike($body,qr/^injected |HASH\(|\sInf(?:\s|$)/m,'invalid scalar/reference/infinite values do not reach wire samples');
    ok($m->stop_http_server,'isolated listener stops normally');
}
done_testing;
