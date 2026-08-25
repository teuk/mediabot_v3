package Mediabot::AI::Provider::OpenAI;

use strict;
use warnings;

use Carp qw(croak);
use Exporter 'import';
use JSON::PP qw(encode_json decode_json);

use Mediabot::AI qw(normalize_provider);
use Mediabot::AI::Request qw(validate_request);

our $VERSION = '1.0';
our @EXPORT_OK = qw(
    build_payload
    build_headers
    extract_answer
    extract_error
    user_error_message
);

sub _require_scalar {
    my ($name, $value) = @_;
    croak "$name is required" unless defined($value) && !ref($value) && length("$value");
    return "$value";
}

sub build_payload {
    my ($request) = @_;

    my $error = validate_request($request);
    croak "invalid AI request: $error" if defined $error;

    my $provider = normalize_provider(
        exists($request->{provider}) ? $request->{provider} : 'auto'
    );
    croak 'OpenAI adapter received a non-OpenAI request'
        unless defined($provider) && ($provider eq 'openai' || $provider eq 'auto');

    my $model = _require_scalar('model', $request->{model});
    croak 'max_output_tokens is required'
        unless exists $request->{max_output_tokens};

    my @messages;
    push @messages, {
        role    => 'system',
        content => "$request->{system}",
    } if exists($request->{system}) && defined($request->{system});

    push @messages, map {
        +{
            role    => "$_->{role}",
            content => "$_->{content}",
        }
    } @{ $request->{messages} };

    my %payload = (
        model      => $model,
        max_tokens => int($request->{max_output_tokens}),
        messages   => \@messages,
    );

    $payload{temperature} = 0 + $request->{temperature}
        if exists $request->{temperature};

    return encode_json(\%payload);
}

sub build_headers {
    my ($transport) = @_;
    croak 'transport must be a hash reference' unless ref($transport) eq 'HASH';

    my $api_key = _require_scalar('api_key', $transport->{api_key});

    return {
        'Content-Type'  => 'application/json',
        'Authorization' => "Bearer $api_key",
    };
}

sub extract_answer {
    my ($content) = @_;

    my $data = eval { decode_json($content // '') };
    return undef unless ref($data) eq 'HASH'
        && ref($data->{choices}) eq 'ARRAY'
        && ref($data->{choices}[0]) eq 'HASH'
        && ref($data->{choices}[0]{message}) eq 'HASH'
        && defined($data->{choices}[0]{message}{content})
        && length($data->{choices}[0]{message}{content});

    return $data->{choices}[0]{message}{content};
}

sub extract_error {
    my ($body) = @_;
    return ('', '', '') unless defined($body) && length($body);

    my $data = eval { decode_json($body) };
    return ('', '', '') unless ref($data) eq 'HASH'
        && ref($data->{error}) eq 'HASH';

    my $error = $data->{error};
    my $clean = sub {
        my $value = defined($_[0]) ? "$_[0]" : '';
        $value =~ s/[\x00-\x1F\x7F]+/ /g;
        $value =~ s/\s+/ /g;
        $value =~ s/^\s+|\s+$//g;
        return substr($value, 0, 200);
    };

    return (
        $clean->($error->{type}),
        $clean->($error->{code}),
        $clean->($error->{message}),
    );
}

sub user_error_message {
    my ($status, $type, $code) = @_;
    $status = 0 unless defined($status) && "$status" =~ /^\d+\z/;
    my $tc = lc((defined($type) ? "$type" : '') . ' ' . (defined($code) ? "$code" : ''));

    if ($tc =~ /insufficient_quota/) {
        return 'OpenAI API key accepted, but API credits/budget are exhausted; add API credits or raise the project limit.';
    }
    if ($status == 429 || $tc =~ /rate_limit/) {
        return 'OpenAI rate limit reached; retry shortly (do not replace the API key).';
    }
    if ($status == 401 || $tc =~ /invalid_api_key|authentication/) {
        return 'OpenAI rejected the API key; replace openai.API_KEY and reload/restart Mediabot.';
    }
    if ($status == 403 || $tc =~ /permission|access_denied/) {
        return 'OpenAI denied access; check project/model/region permissions (the key is not necessarily invalid).';
    }
    if ($status == 404 || $tc =~ /model_not_found/) {
        return 'OpenAI model unavailable or not permitted; check openai.MODEL and openai.FALLBACK_MODEL.';
    }
    if ($status == 0) {
        return 'Could not reach OpenAI; check DNS, TLS, firewall and openai.API_URL.';
    }
    if ($status >= 500) {
        return 'OpenAI service error; retry shortly.';
    }
    return 'Sorry, API did not answer.';
}

1;
