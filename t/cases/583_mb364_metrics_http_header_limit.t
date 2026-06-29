# t/cases/583_mb364_metrics_http_header_limit.t
#
# mb364 — L'endpoint Metrics ne doit pas accumuler un en-tête HTTP sans limite.
# Le test charge Metrics avec de petits stubs pour rester exécutable même sur
# une machine d'audit sans IO::Async::Listener ni JSON::MaybeXS.

use strict;
use warnings;

BEGIN {
    unless ($INC{'IO/Async/Listener.pm'}) {
        eval q{
            package IO::Async::Listener;
            sub new {
                my ($class, %args) = @_;
                return bless { %args }, $class;
            }
            1;
        } or die $@;
        $INC{'IO/Async/Listener.pm'} = __FILE__;
    }

    unless ($INC{'JSON/MaybeXS.pm'}) {
        eval q{
            package JSON::MaybeXS;
            require Exporter;
            our @ISA       = qw(Exporter);
            our @EXPORT_OK = qw(encode_json);
            sub encode_json {
                require JSON::PP;
                return JSON::PP::encode_json($_[0]);
            }
            1;
        } or die $@;
        $INC{'JSON/MaybeXS.pm'} = __FILE__;
    }
}

use FindBin qw($Bin);
use lib "$Bin/../..";

use Encode qw(encode_utf8);
use Mediabot::Metrics;

sub _slurp_583 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path
        or die "cannot read $path: $!";
    local $/;
    my $text = <$fh>;
    close $fh;
    return $text;
}

return sub {
    my ($assert) = @_;

    my $metrics = Mediabot::Metrics->new(enabled => 1);

    my $limit = Mediabot::Metrics::MAX_HTTP_HEADER_BYTES();
    $assert->is($limit, 16 * 1024,
        'HTTP header limit is fixed at 16 KiB');

    $assert->is($metrics->_http_request_state(undef, 0), 'incomplete',
        'undefined request buffer is treated as empty and incomplete');
    $assert->is($metrics->_http_request_state("GET /metrics HTTP/1.1\r\n", 0), 'incomplete',
        'partial normal header remains incomplete');
    $assert->is($metrics->_http_request_state('x' x $limit, 0), 'incomplete',
        'header exactly at the limit is still accepted');
    $assert->is($metrics->_http_request_state('x' x ($limit + 1), 0), 'too_large',
        'header above the limit is rejected');
    $assert->is($metrics->_http_request_state("GET /metrics HTTP/1.1\r\n\r\n", 0), 'complete',
        'terminated request header is complete');
    $assert->is($metrics->_http_request_state("GET /metrics HTTP/1.1\r\n", 1), 'complete',
        'EOF completes a bounded partial request');
    $assert->is(
        $metrics->_http_request_state(('x' x ($limit + 1)) . "\r\n\r\n", 0),
        'too_large',
        'oversized request is rejected before normal routing even if terminated'
    );

    my $prom = $metrics->_route_http_request("GET /metrics HTTP/1.1\r\nHost: localhost\r\n\r\n");
    $assert->like($prom, qr{\AHTTP/1\.1 200 OK\r\n},
        '/metrics returns HTTP 200');
    $assert->like($prom, qr/Content-Type: text\/plain; version=0\.0\.4; charset=utf-8\r\n/,
        '/metrics keeps the Prometheus content type');
    $assert->like($prom, qr/\r\n\r\n.*mediabot_up 1/s,
        '/metrics response contains rendered metrics');

    my ($prom_len)  = $prom =~ /Content-Length: (\d+)\r\n/;
    my ($prom_body) = $prom =~ /\r\n\r\n(.*)\z/s;
    $assert->is($prom_len, length($prom_body // ''),
        '/metrics Content-Length matches response bytes');

    $metrics->set_radio_status_provider(sub {
        return {
            ok        => 1,
            listeners => 3,
            title     => 'Café',
        };
    });

    my $radio = $metrics->_route_http_request(
        "GET /api/radio/status HTTP/1.1\r\nHost: localhost\r\n\r\n"
    );
    $assert->like($radio, qr{\AHTTP/1\.1 200 OK\r\n},
        'radio status returns HTTP 200');
    $assert->like($radio, qr/Content-Type: application\/json; charset=utf-8\r\n/,
        'radio status keeps JSON content type');
    $assert->like($radio, qr/"listeners":3/,
        'radio status provider payload is rendered');

    my $post = $metrics->_route_http_request(
        "POST /metrics HTTP/1.1\r\nHost: localhost\r\n\r\n"
    );
    $assert->like($post, qr{\AHTTP/1\.1 404 Not Found\r\n},
        'unsupported method remains a 404');

    my $missing = $metrics->_route_http_request(
        "GET /unknown HTTP/1.1\r\nHost: localhost\r\n\r\n"
    );
    $assert->like($missing, qr{\AHTTP/1\.1 404 Not Found\r\n},
        'unknown path remains a 404');

    my $utf8 = $metrics->_http_response_bytes(
        '200 OK',
        "Café\n",
        'text/plain; charset=utf-8',
    );
    my ($utf8_len)  = $utf8 =~ /Content-Length: (\d+)\r\n/;
    my ($utf8_body) = $utf8 =~ /\r\n\r\n(.*)\z/s;
    $assert->is($utf8_len, length(encode_utf8("Café\n")),
        'UTF-8 Content-Length is counted in bytes');
    $assert->is($utf8_len, length($utf8_body // ''),
        'UTF-8 body byte count matches the emitted payload');

    my $src = _slurp_583("$Bin/../../Mediabot/Metrics.pm");

    $assert->like($src, qr/mb364-B1/,
        'mb364-B1 marker is present');
    $assert->like($src, qr/use constant MAX_HTTP_HEADER_BYTES => 16 \* 1024;/,
        'source declares the 16 KiB hard limit');
    $assert->like(
        $src,
        qr/my \$state = \$self->_http_request_state\(\$buffer, \$eof\);\s*return 0 if \$state eq 'incomplete';/s,
        'on_read uses the bounded request-state helper before routing'
    );
    $assert->like($src, qr/431 Request Header Fields Too Large/,
        'oversized headers receive HTTP 431');
    $assert->like($src, qr/my \$responded = 0;.*?return 0 if \$responded;.*?\$responded = 1;/s,
        'one connection can schedule only one response');
    $assert->like($src, qr/\$buffer = '';/,
        'request bytes are released after the response is scheduled');
    $assert->unlike(
        $src,
        qr/\$buffer \.= \$\$buffref;.*?if \(\$buffer =~ \\/s,
        'legacy unbounded direct-routing pattern is gone'
    );
};
