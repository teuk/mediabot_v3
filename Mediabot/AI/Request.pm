package Mediabot::AI::Request;

use strict;
use warnings;

use Carp qw(croak);
use Exporter 'import';
use Scalar::Util qw(looks_like_number);

use Mediabot::AI qw(normalize_provider);

our $VERSION = '1.0';
our @EXPORT_OK = qw(
    build_request
    validate_request
    request_summary
);

my %ALLOWED_FIELD = map { $_ => 1 } qw(
    provider
    purpose
    model
    system
    messages
    max_output_tokens
    temperature
    timeout_seconds
);

sub _plain_scalar {
    my ($value) = @_;
    return defined($value) && !ref($value);
}

sub _clean_short_scalar {
    my ($value, $max) = @_;
    return undef unless _plain_scalar($value);

    $value = "$value";
    $value =~ s/^\s+|\s+$//g;
    return undef if $value eq '' || length($value) > $max;
    return undef if $value =~ /[\x00-\x1F\x7F]/;

    return $value;
}

sub validate_request {
    my ($request) = @_;
    return 'request must be a hash reference' unless ref($request) eq 'HASH';

    for my $key (keys %$request) {
        return "unknown request field: $key" unless $ALLOWED_FIELD{$key};
    }

    my $provider = normalize_provider(
        exists($request->{provider}) ? $request->{provider} : 'auto'
    );
    return 'provider is unknown' unless defined $provider;

    if (exists $request->{purpose}) {
        my $purpose = _clean_short_scalar($request->{purpose}, 64);
        return 'purpose must be a short identifier'
            unless defined($purpose) && $purpose =~ /^[a-z][a-z0-9_.-]*\z/i;
    }

    if (exists $request->{model} && defined $request->{model}) {
        return 'model must be a short printable string'
            unless defined _clean_short_scalar($request->{model}, 160);
    }

    if (exists $request->{system} && defined $request->{system}) {
        return 'system must be a scalar string' unless _plain_scalar($request->{system});
        return 'system contains a NUL byte' if "$request->{system}" =~ /\x00/;
    }

    my $messages = $request->{messages};
    return 'messages must be a non-empty array reference'
        unless ref($messages) eq 'ARRAY' && @$messages;

    my $expected_role = 'user';
    my $total_chars = 0;
    for my $idx (0 .. $#$messages) {
        my $message = $messages->[$idx];
        return "messages[$idx] must be a hash reference"
            unless ref($message) eq 'HASH';

        my @keys = sort keys %$message;
        return "messages[$idx] must contain only role and content"
            unless @keys == 2 && $keys[0] eq 'content' && $keys[1] eq 'role';

        my $role = $message->{role};
        return "messages[$idx].role must be user or assistant"
            unless _plain_scalar($role) && ($role eq 'user' || $role eq 'assistant');
        return "messages[$idx].role must alternate from user"
            unless $role eq $expected_role;

        my $content = $message->{content};
        return "messages[$idx].content must be a non-empty scalar string"
            unless _plain_scalar($content) && length("$content") > 0;
        return "messages[$idx].content contains a NUL byte"
            if "$content" =~ /\x00/;

        $total_chars += length("$content");
        return 'message content exceeds the provider-neutral safety ceiling'
            if $total_chars > 250_000;

        $expected_role = $role eq 'user' ? 'assistant' : 'user';
    }

    return 'the final message must have role=user'
        unless $messages->[-1]{role} eq 'user';

    if (exists $request->{max_output_tokens}) {
        my $v = $request->{max_output_tokens};
        return 'max_output_tokens must be an integer between 1 and 100000'
            unless _plain_scalar($v) && "$v" =~ /^\d+\z/
                && $v >= 1 && $v <= 100_000;
    }

    if (exists $request->{temperature}) {
        my $v = $request->{temperature};
        return 'temperature must be numeric between 0 and 2'
            unless _plain_scalar($v) && looks_like_number($v)
                && $v >= 0 && $v <= 2;
    }

    if (exists $request->{timeout_seconds}) {
        my $v = $request->{timeout_seconds};
        return 'timeout_seconds must be an integer between 1 and 300'
            unless _plain_scalar($v) && "$v" =~ /^\d+\z/
                && $v >= 1 && $v <= 300;
    }

    return undef;
}

sub build_request {
    my (%args) = @_;

    my $error = validate_request(\%args);
    croak "invalid AI request: $error" if defined $error;

    my $provider = normalize_provider(
        exists($args{provider}) ? $args{provider} : 'auto'
    );

    my %request = (
        provider => $provider,
        purpose  => exists($args{purpose}) ? "$args{purpose}" : 'generic',
        messages => [
            map {
                +{
                    role    => "$_->{role}",
                    content => "$_->{content}",
                }
            } @{ $args{messages} }
        ],
    );

    $request{model} = _clean_short_scalar($args{model}, 160)
        if exists($args{model}) && defined($args{model});
    $request{system} = "$args{system}"
        if exists($args{system}) && defined($args{system});
    $request{max_output_tokens} = int($args{max_output_tokens})
        if exists $args{max_output_tokens};
    $request{temperature} = 0 + $args{temperature}
        if exists $args{temperature};
    $request{timeout_seconds} = int($args{timeout_seconds})
        if exists $args{timeout_seconds};

    return \%request;
}

sub request_summary {
    my ($request) = @_;
    my $error = validate_request($request);
    return undef if defined $error;

    my $messages = $request->{messages};
    my $chars = 0;
    $chars += length("$_->{content}") for @$messages;
    $chars += length("$request->{system}")
        if exists($request->{system}) && defined($request->{system});

    return {
        provider => normalize_provider(
            exists($request->{provider}) ? $request->{provider} : 'auto'
        ),
        purpose => exists($request->{purpose}) ? "$request->{purpose}" : 'generic',
        model => exists($request->{model}) && defined($request->{model})
            ? "$request->{model}" : undef,
        messages => scalar(@$messages),
        chars => $chars,
        max_output_tokens => exists($request->{max_output_tokens})
            ? int($request->{max_output_tokens}) : undef,
    };
}

1;
