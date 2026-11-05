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

use Mediabot::Metrics;

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

    my $missing = $metrics->_route_http_request(
        "GET /unknown HTTP/1.1\r\nHost: localhost\r\n\r\n"
    );
    $assert->like($missing, qr{\AHTTP/1\.1 404 Not Found\r\n},
        'unknown path remains a 404');
};
