# t/cases/612_mb394_trivia_rate_limit_retry.t
# =============================================================================
# MB394:
#   Open Trivia DB applies a per-public-IP request window. Multiple Mediabot
#   instances on the same host can therefore receive API response_code 5 even
#   when each process respects its own command cooldown.
#
#   The forked worker must retry one rate-limited response after >5 seconds,
#   preserve bounded execution, and expose useful failure metadata without
#   blocking the IRC event loop.
# =============================================================================

use strict;
use warnings;
use File::Spec;

sub _slurp_mb394 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path
        or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_mb394 {
    my ($src, $name) = @_;

    my $re = qr/^sub\s+\Q$name\E\s*\{/m;
    return undef unless $src =~ /$re/g;

    my $start = $-[0];
    my $pos   = pos($src);
    my $depth = 1;
    my $quote;
    my $escape  = 0;
    my $comment = 0;

    while ($pos < length($src)) {
        my $ch = substr($src, $pos, 1);

        if ($comment) {
            $comment = 0 if $ch eq "\n";
            $pos++;
            next;
        }

        if (defined $quote) {
            if ($escape) {
                $escape = 0;
            }
            elsif ($ch eq '\\') {
                $escape = 1;
            }
            elsif ($ch eq $quote) {
                undef $quote;
            }
            $pos++;
            next;
        }

        if ($ch eq '#') {
            $comment = 1;
        }
        elsif ($ch eq q{'}) {
            $quote = q{'};
        }
        elsif ($ch eq q{"}) {
            $quote = q{"};
        }
        elsif ($ch eq '{') {
            $depth++;
        }
        elsif ($ch eq '}') {
            $depth--;
            return substr($src, $start, $pos + 1 - $start)
                if $depth == 0;
        }

        $pos++;
    }

    return undef;
}

{
    package MB394::HTTP;

    sub new {
        my ($class, @responses) = @_;
        return bless {
            responses => \@responses,
            calls     => 0,
            urls      => [],
        }, $class;
    }

    sub get {
        my ($self, $url, $opts) = @_;
        $self->{calls}++;
        push @{ $self->{urls} }, $url;
        return shift @{ $self->{responses} };
    }
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_mb394(
        File::Spec->catfile('.', 'Mediabot', 'UserCommands.pm')
    );

    my $parse   = _extract_sub_mb394($src, '_trivia_parse_api_content');
    my $sync    = _extract_sub_mb394($src, '_trivia_fetch_sync');
    my $async   = _extract_sub_mb394($src, '_trivia_fetch_async');
    my $command = _extract_sub_mb394($src, 'mbTrivia_ctx');

    $assert->ok(defined $parse,   'trivia parser found');
    $assert->ok(defined $sync,    'trivia synchronous worker found');
    $assert->ok(defined $async,   'trivia asynchronous wrapper found');
    $assert->ok(defined $command, 'trivia command found');

    $assert->like(
        $sync // '',
        qr/response_code\s*==\s*5/,
        'Open Trivia DB response code 5 is handled explicitly'
    );

    $assert->like(
        $sync // '',
        qr/5\.25\s*\+\s*rand\(0\.75\)/,
        'rate-limit retry waits beyond five seconds with jitter'
    );

    $assert->like(
        $sync // '',
        qr/\$max_attempts\s*=\s*2/,
        'worker performs at most one retry by default'
    );

    $assert->like(
        $async // '',
        qr/\$timeout\s*=\s*24/,
        'async worker budget includes the bounded rate-limit retry'
    );

    $assert->like(
        $async // '',
        qr/\$timeout\s*=\s*30\s+if\s+\$timeout\s*>\s*30/,
        'caller-provided async timeout remains capped'
    );

    $assert->unlike(
        $async // '',
        qr/\b(?:sleep|usleep)\s*\(/,
        'IRC event-loop wrapper still contains no blocking sleep'
    );

    $assert->like(
        $command // '',
        qr/trivia fetch failed for \$channel(?: token=\$request_token)?:/,
        'final fetch failures are logged with structured details'
    );

    $assert->like(
        $command // '',
        qr/rate-limiting this server/,
        'persistent API rate limiting receives a clear user message'
    );

    $assert->like(
        $command // '',
        qr/recovered after rate-limit retry/,
        'successful retry is visible at debug level'
    );

    my $compiled = eval "package MB394::Probe;\n$parse\n$sync\n1;";
    $assert->ok($compiled, 'parser and synchronous worker compile in isolation');

    my $rate_json = '{"response_code":5,"results":[]}';
    my $ok_json = <<'JSON';
{"response_code":0,"results":[{"type":"multiple","difficulty":"easy","category":"General Knowledge","question":"Question?","correct_answer":"Answer","incorrect_answers":["Wrong 1","Wrong 2","Wrong 3"]}]}
JSON

    my %meta;
    my $parsed = MB394::Probe::_trivia_parse_api_content($rate_json, \%meta);
    $assert->ok(!defined $parsed, 'rate-limit payload is not accepted as a question');
    $assert->is($meta{response_code}, 5, 'parser exposes API response code 5');
    $assert->is($meta{error}, 'api_response', 'parser exposes API response failure class');

    my @slept;
    my $http = MB394::HTTP->new(
        { success => 1, status => 200, content => $rate_json },
        { success => 1, status => 200, content => $ok_json },
    );

    my $recovered = MB394::Probe::_trivia_fetch_sync(
        undef,
        undef,
        http         => $http,
        retry_delay  => 5.5,
        sleep_cb     => sub { push @slept, $_[0] },
        max_attempts => 2,
    );

    $assert->ok($recovered->{ok}, 'one API rate-limit response is retried successfully');
    $assert->is($recovered->{attempts}, 2, 'successful result reports the second attempt');
    $assert->is($http->{calls}, 2, 'rate-limit recovery performs exactly two HTTP requests');
    $assert->is(scalar @slept, 1, 'rate-limit recovery waits exactly once');
    $assert->is($slept[0], 5.5, 'test-injected retry delay is honoured');

    @slept = ();
    $http = MB394::HTTP->new(
        { success => 1, status => 200, content => $rate_json },
        { success => 1, status => 200, content => $rate_json },
    );

    my $limited = MB394::Probe::_trivia_fetch_sync(
        undef,
        undef,
        http         => $http,
        retry_delay  => 5.5,
        sleep_cb     => sub { push @slept, $_[0] },
        max_attempts => 2,
    );

    $assert->ok(!$limited->{ok}, 'persistent rate limit remains a controlled failure');
    $assert->is($limited->{error}, 'rate_limit', 'persistent API limit has a specific error class');
    $assert->is($limited->{response_code}, 5, 'persistent API limit keeps response code 5');
    $assert->is($limited->{attempts}, 2, 'persistent limit stops after the bounded retry');
    $assert->is($http->{calls}, 2, 'persistent limit never loops indefinitely');

    @slept = ();
    $http = MB394::HTTP->new(
        { success => 0, status => 429, reason => 'Too Many Requests', content => '' },
        { success => 1, status => 200, content => $ok_json },
    );

    my $http_recovered = MB394::Probe::_trivia_fetch_sync(
        undef,
        undef,
        http         => $http,
        retry_delay  => 5.5,
        sleep_cb     => sub { push @slept, $_[0] },
        max_attempts => 2,
    );

    $assert->ok($http_recovered->{ok}, 'HTTP 429 is retried with the same bounded policy');
    $assert->is($http_recovered->{attempts}, 2, 'HTTP 429 recovery reports second attempt');
    $assert->is($http->{calls}, 2, 'HTTP 429 recovery performs one retry only');

    $http = MB394::HTTP->new(
        { success => 0, status => 500, reason => "Server\r\nFailure", content => '' },
    );

    my $http_error = MB394::Probe::_trivia_fetch_sync(
        undef,
        undef,
        http         => $http,
        sleep_cb     => sub { die 'must not sleep' },
        max_attempts => 2,
    );

    $assert->ok(!$http_error->{ok}, 'ordinary HTTP failure remains controlled');
    $assert->is($http_error->{error}, 'http', 'ordinary HTTP failure has a distinct error class');
    $assert->is($http_error->{status}, 500, 'ordinary HTTP status is preserved');
    $assert->is($http_error->{reason}, 'Server Failure', 'HTTP reason is log-line sanitized');
    $assert->is($http->{calls}, 1, 'ordinary HTTP failure is not retried blindly');

    $http = MB394::HTTP->new(
        { success => 1, status => 200, content => '{broken json' },
    );

    my $bad_json = MB394::Probe::_trivia_fetch_sync(
        undef,
        undef,
        http         => $http,
        sleep_cb     => sub { die 'must not sleep' },
        max_attempts => 2,
    );

    $assert->ok(!$bad_json->{ok}, 'malformed JSON remains a controlled failure');
    $assert->is($bad_json->{error}, 'response', 'malformed JSON is classified as response failure');
    $assert->is($bad_json->{parse_error}, 'json', 'malformed JSON keeps parser diagnostic');
    $assert->is($http->{calls}, 1, 'malformed JSON is not retried as rate limiting');
};
