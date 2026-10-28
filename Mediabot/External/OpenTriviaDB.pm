package Mediabot::External::OpenTriviaDB;

# MB888: synchronous remote source and response parsing. UserCommands retains
# command policy and asynchronous orchestration, importing the legacy names.
use strict;
use warnings;
use utf8;
use Exporter 'import';

our $VERSION = '1.00';
our @EXPORT_OK = qw(_trivia_parse_api_content _trivia_fetch_sync);

# ---------------------------------------------------------------------------
# _trivia_parse_api_content($json)
# Validate and normalize one Open Trivia DB multiple-choice question.
# This pure helper keeps malformed remote data away from the live game state.
# ---------------------------------------------------------------------------
sub _trivia_parse_api_content {
    my ($content, $meta) = @_;

    $meta = undef unless ref($meta) eq 'HASH';

    unless (defined($content) && !ref($content)) {
        $meta->{error} = 'content_type' if $meta;
        return;
    }

    if (length($content) == 0 || length($content) > 64 * 1024) {
        $meta->{error} = 'content_size' if $meta;
        return;
    }

    require JSON::PP;
    my $data = eval { JSON::PP::decode_json($content) };
    if ($@ || ref($data) ne 'HASH') {
        $meta->{error} = 'json' if $meta;
        return;
    }

    if (exists $data->{response_code}) {
        my $response_code = $data->{response_code};

        unless (defined($response_code)
                && !ref($response_code)
                && $response_code =~ /\A\d+\z/) {
            $meta->{error} = 'response_code' if $meta;
            return;
        }

        $response_code = int($response_code);
        $meta->{response_code} = $response_code if $meta;

        if ($response_code != 0) {
            $meta->{error} = 'api_response' if $meta;
            return;
        }
    }

    my $results = $data->{results};
    unless (ref($results) eq 'ARRAY' && @$results) {
        $meta->{error} = 'results' if $meta;
        return;
    }

    my $question = $results->[0];
    unless (ref($question) eq 'HASH') {
        $meta->{error} = 'question_type' if $meta;
        return;
    }

    my $question_text = $question->{question};
    my $correct       = $question->{correct_answer};
    my $incorrect     = $question->{incorrect_answers};

    unless (defined($question_text)
            && !ref($question_text)
            && $question_text ne ''
            && length($question_text) <= 2048) {
        $meta->{error} = 'question_text' if $meta;
        return;
    }

    unless (defined($correct)
            && !ref($correct)
            && $correct ne ''
            && length($correct) <= 512) {
        $meta->{error} = 'correct_answer' if $meta;
        return;
    }

    unless (ref($incorrect) eq 'ARRAY'
            && @$incorrect >= 1
            && @$incorrect <= 10) {
        $meta->{error} = 'incorrect_answers' if $meta;
        return;
    }

    my @wrong;
    for my $answer (@$incorrect) {
        unless (defined($answer)
                && !ref($answer)
                && $answer ne ''
                && length($answer) <= 512) {
            $meta->{error} = 'incorrect_answer' if $meta;
            return;
        }
        push @wrong, $answer;
    }

    my $category = $question->{category};
    $category = 'Unknown'
        unless defined($category)
            && !ref($category)
            && $category ne ''
            && length($category) <= 256;

    my $difficulty = $question->{difficulty};
    $difficulty = ''
        unless defined($difficulty)
            && !ref($difficulty)
            && $difficulty =~ /\A(?:easy|medium|hard)\z/i;

    delete $meta->{error} if $meta;

    return {
        question          => $question_text,
        correct_answer    => $correct,
        incorrect_answers => \@wrong,
        category          => $category,
        difficulty        => lc($difficulty),
    };
}

# Perform the Open Trivia DB request synchronously. Runtime IRC commands call
# it only from _trivia_fetch_async(), so the bounded retry below runs in the
# forked worker and never blocks the IRC event loop.
sub _trivia_fetch_sync {
    my ($category_id, $difficulty, %opts) = @_;

    # MB984: French is an additional source. The complete English HTTP path
    # below, its category ids, retry budget and validation remain unchanged.
    if (($opts{language} // '') eq 'fr') {
        require Mediabot::External::TriviaFR;
        return Mediabot::External::TriviaFR::fetch($category_id, $difficulty, %opts);
    }

    require Time::HiRes;

    my $started_at = Time::HiRes::time();
    my $elapsed_ms = sub {
        return int((Time::HiRes::time() - $started_at) * 1000 + 0.5);
    };
    my $clean_detail = sub {
        my ($value, $limit) = @_;
        $limit ||= 240;
        return '' unless defined($value) && !ref($value);
        $value =~ s/[\r\n\0]+/ /g;
        $value =~ s/\s{2,}/ /g;
        $value =~ s/^\s+|\s+$//g;
        return substr($value, 0, $limit);
    };
    my $progress_cb = ref($opts{progress_cb}) eq 'CODE'
        ? $opts{progress_cb}
        : undef;
    my $progress = sub {
        my ($stage, %fields) = @_;
        return unless $progress_cb;
        return unless defined($stage) && !ref($stage)
            && $stage =~ /\A[a-z_]+\z/;
        my %event = (
            stage      => $stage,
            elapsed_ms => $elapsed_ms->(),
        );
        for my $field (keys %fields) {
            my $value = $fields{$field};
            next unless defined($value) && !ref($value);
            $event{$field} = $value;
        }
        eval { $progress_cb->(\%event); 1; };
    };

    $category_id = undef
        unless defined($category_id)
            && !ref($category_id)
            && $category_id =~ /\A\d+\z/
            && $category_id >= 9
            && $category_id <= 32;

    $difficulty = undef
        unless defined($difficulty)
            && !ref($difficulty)
            && $difficulty =~ /\A(?:easy|medium|hard)\z/i;

    my $url = 'https://opentdb.com/api.php?amount=1&type=multiple';
    $url .= '&category=' . int($category_id) if defined $category_id;
    $url .= '&difficulty=' . lc($difficulty) if defined $difficulty;

    my $hard_timeout = $opts{hard_timeout};
    $hard_timeout = 7
        unless defined($hard_timeout)
            && !ref($hard_timeout)
            && $hard_timeout =~ /\A\d+(?:\.\d+)?\z/;
    $hard_timeout = 0.1 if $hard_timeout < 0.1;
    $hard_timeout = 12  if $hard_timeout > 12;

    my $http = $opts{http};
    unless ($http && ref($http) && $http->can('get')) {
        $progress->('http_client_start');
        my $made = eval {
            Mediabot::External::_make_http(
                timeout    => 8,
                verify_SSL => 1,
                max_size   => 64 * 1024,
            );
        };

        if ($@ || !$made || !ref($made) || !$made->can('get')) {
            $progress->('http_client_failed');
            return {
                ok         => 0,
                error      => 'http_setup',
                stage      => 'http_client',
                detail     => $clean_detail->($@ || 'HTTP client creation failed'),
                elapsed_ms => $elapsed_ms->(),
            };
        }

        $http = $made;
        $progress->('http_client_ready');
    }
    else {
        $progress->('http_client_injected');
    }

    my $sleep_cb = ref($opts{sleep_cb}) eq 'CODE'
        ? $opts{sleep_cb}
        : sub {
            my ($seconds) = @_;
            Time::HiRes::sleep($seconds);
        };

    my $max_attempts = $opts{max_attempts};
    $max_attempts = 2
        unless defined($max_attempts)
            && !ref($max_attempts)
            && $max_attempts =~ /\A\d+\z/;
    $max_attempts = 1 if $max_attempts < 1;
    $max_attempts = 2 if $max_attempts > 2;

    ATTEMPT:
    for my $attempt (1 .. $max_attempts) {
        my $attempt_started = Time::HiRes::time();
        my ($response, $request_error);
        my $alarm_marker = '__MEDIABOT_TRIVIA_HTTP_DEADLINE__';

        $progress->('http_get_start', attempt => $attempt);

        {
            local $@;
            local $SIG{ALRM} = sub { die "$alarm_marker\n" };
            Time::HiRes::alarm($hard_timeout);
            $response = eval {
                $http->get($url, {
                    headers => {
                        Accept => 'application/json',
                    },
                });
            };
            $request_error = $@;
            Time::HiRes::alarm(0);
        }

        my $attempt_elapsed_ms = int(
            (Time::HiRes::time() - $attempt_started) * 1000 + 0.5
        );

        if (defined($request_error) && $request_error ne '') {
            if ($request_error =~ /\Q$alarm_marker\E/) {
                $progress->(
                    'http_get_timeout',
                    attempt            => $attempt,
                    attempt_elapsed_ms => $attempt_elapsed_ms,
                );
                return {
                    ok                 => 0,
                    error              => 'http_timeout',
                    stage              => 'http_get',
                    attempts           => $attempt,
                    detail             => 'hard request deadline exceeded',
                    attempt_elapsed_ms => $attempt_elapsed_ms,
                    elapsed_ms         => $elapsed_ms->(),
                };
            }

            $progress->(
                'http_get_exception',
                attempt            => $attempt,
                attempt_elapsed_ms => $attempt_elapsed_ms,
            );
            return {
                ok                 => 0,
                error              => 'http_exception',
                stage              => 'http_get',
                attempts           => $attempt,
                detail             => $clean_detail->($request_error),
                attempt_elapsed_ms => $attempt_elapsed_ms,
                elapsed_ms         => $elapsed_ms->(),
            };
        }

        my $status = ref($response) eq 'HASH'
            && defined($response->{status})
            && !ref($response->{status})
            && $response->{status} =~ /\A\d+\z/
                ? int($response->{status})
                : undef;

        my $headers = ref($response) eq 'HASH'
            && ref($response->{headers}) eq 'HASH'
                ? $response->{headers}
                : {};
        my $content_type = $clean_detail->(
            $headers->{'content-type'} // $headers->{'Content-Type'} // '',
            120,
        );
        my $content = ref($response) eq 'HASH'
            && defined($response->{content})
            && !ref($response->{content})
                ? $response->{content}
                : '';
        my $content_bytes = length($content);
        my $http_rate_limited = defined($status) && $status == 429;

        $progress->(
            'http_get_done',
            attempt            => $attempt,
            status             => (defined($status) ? $status : 0),
            success            => (ref($response) eq 'HASH' && $response->{success}) ? 1 : 0,
            content_bytes      => $content_bytes,
            attempt_elapsed_ms => $attempt_elapsed_ms,
        );

        unless (ref($response) eq 'HASH' && $response->{success}) {
            if ($http_rate_limited && $attempt < $max_attempts) {
                my $delay = exists($opts{retry_delay})
                    ? $opts{retry_delay}
                    : 5.25 + rand(0.75);
                $delay = 5.25
                    unless defined($delay)
                        && !ref($delay)
                        && $delay =~ /\A\d+(?:\.\d+)?\z/
                        && $delay >= 5.1
                        && $delay <= 8;

                $progress->(
                    'rate_limit_wait_start',
                    attempt => $attempt,
                    status  => $status,
                    delay_ms => int($delay * 1000 + 0.5),
                );
                my $slept = eval { $sleep_cb->($delay); 1; };
                return {
                    ok                 => 0,
                    error              => 'retry_wait',
                    stage              => 'rate_limit_wait',
                    attempts           => $attempt,
                    status             => $status,
                    content_type       => $content_type,
                    content_bytes      => $content_bytes,
                    attempt_elapsed_ms => $attempt_elapsed_ms,
                    elapsed_ms         => $elapsed_ms->(),
                    detail             => $clean_detail->($@ || 'retry wait failed'),
                } unless $slept;

                $progress->('rate_limit_wait_done', attempt => $attempt);
                next ATTEMPT;
            }

            my $reason = ref($response) eq 'HASH'
                ? $clean_detail->($response->{reason}, 160)
                : '';

            return {
                ok                 => 0,
                error              => $http_rate_limited ? 'rate_limit' : 'http',
                stage              => 'http_response',
                attempts           => $attempt,
                status             => $status,
                reason             => $reason,
                content_type       => $content_type,
                content_bytes      => $content_bytes,
                attempt_elapsed_ms => $attempt_elapsed_ms,
                elapsed_ms         => $elapsed_ms->(),
            };
        }

        $progress->('api_parse_start', attempt => $attempt);
        my %meta;
        my $question = _trivia_parse_api_content(
            $content,
            \%meta,
        );

        if (ref($question) eq 'HASH') {
            $progress->('api_parse_ok', attempt => $attempt);
            return {
                ok                 => 1,
                question           => $question,
                attempts           => $attempt,
                status             => $status,
                content_type       => $content_type,
                content_bytes      => $content_bytes,
                attempt_elapsed_ms => $attempt_elapsed_ms,
                elapsed_ms         => $elapsed_ms->(),
            };
        }

        my $response_code = $meta{response_code};
        my $api_rate_limited = defined($response_code)
            && $response_code == 5;

        $progress->(
            'api_parse_failed',
            attempt       => $attempt,
            response_code => (defined($response_code) ? $response_code : -1),
            parse_error   => ($meta{error} // 'unknown'),
        );

        if ($api_rate_limited && $attempt < $max_attempts) {
            # Open Trivia DB limits one request per public IP every five
            # seconds. Separate Mediabot instances on the same host can race,
            # so retry once with a small jitter inside this forked worker.
            my $delay = exists($opts{retry_delay})
                ? $opts{retry_delay}
                : 5.25 + rand(0.75);
            $delay = 5.25
                unless defined($delay)
                    && !ref($delay)
                    && $delay =~ /\A\d+(?:\.\d+)?\z/
                    && $delay >= 5.1
                    && $delay <= 8;

            $progress->(
                'rate_limit_wait_start',
                attempt       => $attempt,
                response_code => $response_code,
                delay_ms      => int($delay * 1000 + 0.5),
            );
            my $slept = eval { $sleep_cb->($delay); 1; };
            return {
                ok                 => 0,
                error              => 'retry_wait',
                stage              => 'rate_limit_wait',
                attempts           => $attempt,
                status             => $status,
                response_code      => $response_code,
                parse_error        => $meta{error},
                content_type       => $content_type,
                content_bytes      => $content_bytes,
                attempt_elapsed_ms => $attempt_elapsed_ms,
                elapsed_ms         => $elapsed_ms->(),
                detail             => $clean_detail->($@ || 'retry wait failed'),
            } unless $slept;

            $progress->('rate_limit_wait_done', attempt => $attempt);
            next ATTEMPT;
        }

        return {
            ok                 => 0,
            error              => $api_rate_limited ? 'rate_limit' : 'response',
            stage              => 'api_parse',
            attempts           => $attempt,
            status             => $status,
            response_code      => $response_code,
            parse_error        => $meta{error},
            content_type       => $content_type,
            content_bytes      => $content_bytes,
            attempt_elapsed_ms => $attempt_elapsed_ms,
            elapsed_ms         => $elapsed_ms->(),
        };
    }

    return {
        ok         => 0,
        error      => 'fetch',
        stage      => 'attempt_loop',
        elapsed_ms => $elapsed_ms->(),
    };
}

1;
