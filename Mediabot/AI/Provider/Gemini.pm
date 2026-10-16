package Mediabot::AI::Provider::Gemini;

use strict;
use warnings;

use Carp qw(croak);
use Exporter 'import';
use JSON::PP qw(encode_json decode_json);

use Mediabot::AI qw(normalize_provider);
use Mediabot::AI::Request qw(validate_request);

our $VERSION = '1.0';
our @EXPORT_OK = qw(
    build_url
    build_payload
    build_headers
    extract_answer
    extract_diagnostic
    extract_error
    user_error_message
    failure_category
);

sub _require_scalar {
    my ($name, $value) = @_;
    croak "$name is required"
        unless defined($value) && !ref($value) && length("$value");
    return "$value";
}

sub build_url {
    my ($base_url, $model) = @_;
    $base_url = _require_scalar('base_url', $base_url);
    $model    = _require_scalar('model', $model);

    croak 'Gemini base URL must be HTTPS without query or fragment'
        unless $base_url =~ m{\Ahttps://[^\s/?#]+(?:/[^\s?#]*)?\z}i;
    croak 'invalid Gemini model identifier'
        unless $model =~ /\A[A-Za-z0-9][A-Za-z0-9._-]{0,159}\z/;

    $base_url =~ s{/+\z}{};
    return "$base_url/$model:generateContent";
}

sub build_payload {
    my ($request, $options) = @_;
    $options = {} unless defined $options;
    croak 'Gemini payload options must be a hash reference'
        unless ref($options) eq 'HASH';

    my $error = validate_request($request);
    croak "invalid AI request: $error" if defined $error;

    my $provider = normalize_provider(
        exists($request->{provider}) ? $request->{provider} : 'auto'
    );
    croak 'Gemini adapter received a non-Gemini request'
        unless defined($provider) && ($provider eq 'gemini' || $provider eq 'auto');

    _require_scalar('model', $request->{model});
    croak 'max_output_tokens is required'
        unless exists $request->{max_output_tokens};

    my @contents = map {
        +{
            role  => $_->{role} eq 'assistant' ? 'model' : 'user',
            parts => [ { text => "$_->{content}" } ],
        }
    } @{ $request->{messages} };

    my %generation = (
        candidateCount  => 1,
        maxOutputTokens => int($request->{max_output_tokens}),
    );
    $generation{temperature} = 0 + $request->{temperature}
        if exists $request->{temperature};

    if (exists $options->{thinking_level}) {
        my $level = uc _require_scalar(
            'thinking_level', $options->{thinking_level}
        );
        croak 'invalid Gemini thinking level'
            unless $level =~ /\A(?:LOW|MEDIUM|HIGH)\z/;
        if ($request->{model} =~ /\Agemini-2[.]5-/i) {
            my %budget=(LOW=>($request->{model}=~/\bpro\b/i?128:0),MEDIUM=>1024,HIGH=>4096);
            $generation{thinkingConfig} = { thinkingBudget => $budget{$level} };
        }
        elsif ($request->{model} !~ /\Agemini-2[.]0-/i) {
            $generation{thinkingConfig} = { thinkingLevel => $level };
        }
    }

    my %payload = (
        contents         => \@contents,
        generationConfig => \%generation,
    );
    $payload{systemInstruction} = {
        parts => [ { text => "$request->{system}" } ],
    } if exists($request->{system}) && defined($request->{system});

    return encode_json(\%payload);
}

sub build_headers {
    my ($transport) = @_;
    croak 'transport must be a hash reference' unless ref($transport) eq 'HASH';

    my $api_key = _require_scalar('api_key', $transport->{api_key});
    return {
        'Content-Type'   => 'application/json',
        'x-goog-api-key' => $api_key,
    };
}

sub extract_answer {
    my ($content) = @_;

    my $data = eval { decode_json($content // '') };
    return undef unless ref($data) eq 'HASH'
        && ref($data->{candidates}) eq 'ARRAY'
        && ref($data->{candidates}[0]) eq 'HASH'
        && ref($data->{candidates}[0]{content}) eq 'HASH'
        && ref($data->{candidates}[0]{content}{parts}) eq 'ARRAY';

    my @texts;
    for my $part (@{ $data->{candidates}[0]{content}{parts} }) {
        next unless ref($part) eq 'HASH';
        # Gemini may return internal thinking parts. They are never IRC output.
        next if $part->{thought};
        next unless defined($part->{text}) && !ref($part->{text})
            && length($part->{text});
        push @texts, "$part->{text}";
    }

    my $joined = join('', @texts);
    return length($joined) ? $joined : undef;
}

sub _diagnostic_scalar {
    my ($value, $default) = @_;
    return $default unless defined($value) && !ref($value);
    $value = "$value";
    $value =~ s/[^A-Za-z0-9_.:-]+/_/g;
    return length($value) ? substr($value, 0, 80) : $default;
}

sub _diagnostic_count {
    my ($value) = @_;
    return 0 unless defined($value) && !ref($value)
        && "$value" =~ /\A\d+\z/;
    return 0 + $value;
}

sub extract_diagnostic {
    my ($body) = @_;

    my $data = eval { decode_json($body // '') };
    return ('INVALID_JSON', '', 'response_json=invalid')
        unless ref($data) eq 'HASH';

    my $candidate = ref($data->{candidates}) eq 'ARRAY'
        && ref($data->{candidates}[0]) eq 'HASH'
            ? $data->{candidates}[0]
            : {};
    my $parts = ref($candidate->{content}) eq 'HASH'
        && ref($candidate->{content}{parts}) eq 'ARRAY'
            ? $candidate->{content}{parts}
            : [];

    my ($thought_parts, $text_parts) = (0, 0);
    for my $part (@$parts) {
        next unless ref($part) eq 'HASH';
        $thought_parts++ if $part->{thought};
        $text_parts++ if !$part->{thought}
            && defined($part->{text}) && !ref($part->{text})
            && length($part->{text});
    }

    my $finish = _diagnostic_scalar($candidate->{finishReason}, '');
    my $block = ref($data->{promptFeedback}) eq 'HASH'
        ? _diagnostic_scalar($data->{promptFeedback}{blockReason}, '')
        : '';
    my $usage = ref($data->{usageMetadata}) eq 'HASH'
        ? $data->{usageMetadata}
        : {};
    my $thoughts = _diagnostic_count($usage->{thoughtsTokenCount});
    my $visible = _diagnostic_count($usage->{candidatesTokenCount});
    my $total = _diagnostic_count($usage->{totalTokenCount});

    my $type = length($block) ? $block
        : length($finish) ? $finish
        : 'EMPTY_RESPONSE';
    my $code = $type eq 'MAX_TOKENS' ? 'OUTPUT_BUDGET_EXHAUSTED'
        : length($block) ? 'PROMPT_BLOCKED'
        : 'NO_VISIBLE_TEXT';
    my $message = join ' ',
        "finish=" . (length($finish) ? $finish : 'none'),
        "block=" . (length($block) ? $block : 'none'),
        "thoughts=$thoughts",
        "candidates=$visible",
        "total=$total",
        "parts=" . scalar(@$parts),
        "thought_parts=$thought_parts",
        "text_parts=$text_parts";

    return ($type, $code, $message);
}

sub extract_error {
    my ($body) = @_;
    return ('', '', '') unless defined($body) && length($body);

    my $data = eval { decode_json($body) };
    return ('', '', '') unless ref($data) eq 'HASH'
        && ref($data->{error}) eq 'HASH';

    my $error = $data->{error};
    my $clean = sub {
        my $value = defined($_[0]) && !ref($_[0]) ? "$_[0]" : '';
        $value =~ s/[\x00-\x1F\x7F]+/ /g;
        $value =~ s/\s+/ /g;
        $value =~ s/^\s+|\s+$//g;
        return substr($value, 0, 200);
    };

    return (
        $clean->($error->{status}),
        $clean->($error->{code}),
        $clean->($error->{message}),
    );
}

sub failure_category {
    my ($status,$type,$code,$reason,$body)=@_;
    $status=0 unless defined($status) && !ref($status) && "$status" =~ /\A\d{1,3}\z/;
    my $tc=lc join(' ',map {defined($_) && !ref($_)?substr($_,0,100):''} ($type,$code));
    return 'quota' if $status==429 || $status==402 || $tc =~ /resource_exhausted/;
    return 'access' if $status==401 || $status==403 || $tc =~ /unauthenticated|permission_denied/;
    return 'model' if $status==404 || $tc =~ /not_found/;
    return 'request' if $status==400 || $tc =~ /invalid_argument|failed_precondition/;
    return 'output_budget' if $tc =~ /max_tokens|output_budget_exhausted/;
    return 'service_unavailable' if $status==503 || $tc =~ /\bunavailable\b/;
    return 'server_error' if $status==500 || $status==502;
    return 'timeout' if $status==504 || $tc =~ /deadline_exceeded/;
    if ($status==0 || $status==599) {
        my $detail=lc join(' ',map {defined($_) && !ref($_)?substr($_,0,1000):''} ($reason,$body));
        return 'tls' if $detail =~ /\b(?:tls|ssl)\b|certificate|certificat/;
        return 'dns' if $detail =~ /getaddrinfo|resolve|name or service|name resolution|nodename/;
        return 'timeout' if $detail =~ /timed?\s*out|timeout|deadline/;
        return 'connection' if $detail =~ /connect|connection|network|socket|broken pipe/;
        return 'transport';
    }
    return 'response' if $status>=200 && $status<300;
    return 'http_error';
}

sub user_error_message {
    my ($status, $type, $code) = @_;
    $status = 0 unless defined($status) && "$status" =~ /^\d+\z/;
    my $tc = lc((defined($type) ? "$type" : '') . ' '
        . (defined($code) ? "$code" : ''));

    if ($status == 429 || $tc =~ /resource_exhausted|quota|rate/) {
        return 'Gemini quota or rate limit reached; check the Google AI project quota and retry later.';
    }
    if ($status == 401 || $status == 403
        || $tc =~ /unauthenticated|permission_denied/) {
        return 'Gemini rejected access; check gemini.API_KEY and its Gemini API restrictions.';
    }
    if ($status == 404 || $tc =~ /not_found/) {
        return 'Gemini model unavailable; check gemini.MODEL.';
    }
    if ($status == 400 || $tc =~ /invalid_argument/) {
        return 'Gemini rejected the request; check gemini.MODEL and generation settings.';
    }
    if ($tc =~ /max_tokens|output_budget_exhausted/) {
        return 'Gemini used its response budget before producing visible text; retry shortly.';
    }
    if ($status == 0 || $status == 599) {
        return 'Could not reach Gemini; check DNS, TLS, firewall and gemini.API_URL.';
    }
    if ($status >= 500) {
        return 'Gemini service error; retry shortly.';
    }
    return 'Sorry, Gemini did not answer.';
}

1;
