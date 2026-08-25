package Mediabot::AI::Provider::Anthropic;

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
    croak 'Anthropic adapter received a non-Anthropic request'
        unless defined($provider) && ($provider eq 'anthropic' || $provider eq 'auto');

    my $model = _require_scalar('model', $request->{model});
    croak 'max_output_tokens is required'
        unless exists $request->{max_output_tokens};

    my %payload = (
        model      => $model,
        max_tokens => int($request->{max_output_tokens}),
        messages   => $request->{messages},
    );

    $payload{system} = "$request->{system}"
        if exists($request->{system}) && defined($request->{system});
    $payload{temperature} = 0 + $request->{temperature}
        if exists $request->{temperature};

    return encode_json(\%payload);
}

sub build_headers {
    my ($transport) = @_;
    croak 'transport must be a hash reference' unless ref($transport) eq 'HASH';

    my $api_key = _require_scalar('api_key', $transport->{api_key});
    my $api_version = _require_scalar('api_version', $transport->{api_version});

    return {
        'Content-Type'      => 'application/json',
        'x-api-key'         => $api_key,
        'anthropic-version' => $api_version,
    };
}

sub extract_answer {
    my ($content) = @_;

    my $data = eval { decode_json($content // '') };
    return undef unless ref($data) eq 'HASH'
        && ref($data->{content}) eq 'ARRAY';

    my @texts;
    for my $blk (@{ $data->{content} }) {
        next unless ref($blk) eq 'HASH'
            && ($blk->{type} // '') eq 'text'
            && defined($blk->{text})
            && length($blk->{text});
        push @texts, $blk->{text};
    }

    my $joined = join('', @texts);
    return length($joined) ? $joined : undef;
}

1;
