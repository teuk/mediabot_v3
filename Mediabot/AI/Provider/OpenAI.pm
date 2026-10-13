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
    my ($request, $options) = @_;
    $options ||= {};

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

    if (($options->{api_style} // '') eq 'responses') {
        my %payload = (
            model => $model,
            input => $request->{messages},
            max_output_tokens => int($request->{max_output_tokens}),
            store => JSON::PP::false,
        );
        $payload{instructions} = $request->{system} if defined $request->{system};
        if ($model =~ /^gpt-[56]/) {
            $payload{reasoning} = { effort => 'low' };
        }
        elsif (exists $request->{temperature}) {
            $payload{temperature} = 0 + $request->{temperature};
        }
        # Web synthesis must return its evidence IDs, not merely valid JSON.
        # Scope this contract to MB818 research; legacy and native web calls
        # retain their existing payloads. Runtime still validates each ID
        # against the actual evidence supplied for this particular question.
        if (($request->{purpose}//'') =~ /\Ameta_(?:synthesis_web|citation_repair)\z/
            && $model =~ /\Agpt-(?:4o(?:-|\z)|[56])/
            && $model ne 'gpt-4o-2024-05-13') {
            $payload{text}={format=>{
                type=>'json_schema',name=>'mediabot_web_answer',strict=>JSON::PP::true,
                schema=>{type=>'object',additionalProperties=>JSON::PP::false,
                    properties=>{
                        answer=>{type=>'string'},
                        source_ids=>{type=>'array',minItems=>1,maxItems=>2,
                            items=>{type=>'integer',enum=>[1,2,3]}},
                        basis=>{type=>'string',enum=>[qw(supported partial insufficient)]},
                        support=>{type=>'array',minItems=>1,maxItems=>2,
                            items=>{type=>'object',additionalProperties=>JSON::PP::false,
                                properties=>{source_id=>{type=>'integer',enum=>[1,2,3]},quote=>{type=>'string'}},
                                required=>['source_id','quote']}},
                    },required=>['answer','source_ids','basis','support']},
            }};
        }
        if ($options->{web_search}) {
            my $tool = { type => 'web_search', search_context_size => 'low' };
            $tool->{filters} = { allowed_domains => $options->{web_domains} }
                if ref($options->{web_domains}) eq 'ARRAY' && @{$options->{web_domains}};
            $payload{tools} = [$tool];
            $payload{tool_choice} = 'required';
        }
        return encode_json(\%payload);
    }

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
    if (ref($data) eq 'HASH' && ref($data->{output}) eq 'ARRAY') {
        my @text;
        for my $item (@{$data->{output}}) {
            next unless ref($item) eq 'HASH' && ($item->{type} // '') eq 'message'
                && ref($item->{content}) eq 'ARRAY';
            for my $part (@{$item->{content}}) {
                push @text, $part->{text} if ref($part) eq 'HASH'
                    && ($part->{type} // '') eq 'output_text'
                    && defined($part->{text}) && !ref($part->{text});
            }
        }
        return @text ? join('', @text) : undef;
    }
    return undef unless ref($data) eq 'HASH'
        && ref($data->{choices}) eq 'ARRAY'
        && ref($data->{choices}[0]) eq 'HASH'
        && ref($data->{choices}[0]{message}) eq 'HASH'
        && defined($data->{choices}[0]{message}{content})
        && length($data->{choices}[0]{message}{content});

    return $data->{choices}[0]{message}{content};
}

sub extract_sources {
    my ($content) = @_;
    my $data = eval { decode_json($content // '') };
    return [] unless ref($data) eq 'HASH' && ref($data->{output}) eq 'ARRAY';
    return [] unless grep {ref($_) eq 'HASH' && ($_->{type}//'') eq 'web_search_call'
        && ($_->{status}//'') eq 'completed'} @{$data->{output}};
    my (%seen, @sources);
    for my $item (@{$data->{output}}) {
        next unless ref($item) eq 'HASH' && ($item->{type} // '') eq 'message'
            && ref($item->{content}) eq 'ARRAY';
        for my $part (@{$item->{content}}) {
            next unless ref($part) eq 'HASH' && ref($part->{annotations}) eq 'ARRAY';
            for my $citation (@{$part->{annotations}}) {
                next unless ref($citation) eq 'HASH' && ($citation->{type} // '') eq 'url_citation';
                my $url = $citation->{url};
                next unless defined($url) && !ref($url) && length($url) <= 2048
                    && $url =~ m{\Ahttps?://[A-Za-z0-9.-]+(?:/[^\s\x00-\x1f]*)?\z}
                    && !$seen{$url}++;
                push @sources, { url => $url, title => substr($citation->{title} // '', 0, 160) };
                return \@sources if @sources >= 8;
            }
        }
    }
    return \@sources;
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
