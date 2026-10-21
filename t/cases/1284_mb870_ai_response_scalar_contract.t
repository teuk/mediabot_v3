use strict;
use warnings;
use Test::More;
use JSON::PP qw(encode_json);
use Mediabot::AI::Client;
use Mediabot::AI::Request qw(build_request);
use Mediabot::AI::Provider::Anthropic;
use Mediabot::AI::Provider::OpenAI;

{
    package MB870ShapeConf;
    sub get {
        my ($self, $key) = @_;
        return 'fixture' if $key =~ /API_KEY\z/;
        return "https://$1.example.test/v1/messages" if $key =~ /\A(anthropic|openai)\.API_URL\z/;
        return 'https://gemini.example.test/v1beta/models' if $key eq 'gemini.API_URL';
        return;
    }
    package MB870ShapeHTTP;
    sub request {$_[0]{reply}->(@_[1 .. $#_])}
}
sub body_for {
    my ($provider, $text) = @_;
    return {content => [{type => 'text', text => $text}]} if $provider eq 'anthropic';
    return {choices => [{message => {content => $text}}]} if $provider eq 'openai';
    return {candidates => [{content => {parts => [{text => $text}]}}]};
}

for my $value ([], {}, JSON::PP::true, JSON::PP::false) {
    is(Mediabot::AI::Provider::Anthropic::extract_answer(encode_json(body_for('anthropic', $value))),
        undef, 'Anthropic rejects a reference-valued text block');
    is(Mediabot::AI::Provider::OpenAI::extract_answer(encode_json(body_for('openai', $value))),
        undef, 'OpenAI chat completion rejects reference-valued content');
}
is(Mediabot::AI::Provider::Anthropic::extract_answer(encode_json({content => [
    undef, 'bad', {type => 'text', text => []}, {type => 'text', text => 'safe '},
    {type => 'thinking', text => 'internal'}, {type => 'text', text => 'answer'},
]})), 'safe answer', 'Anthropic preserves valid text around invalid and non-text blocks');
is(Mediabot::AI::Provider::OpenAI::extract_answer(encode_json({output => [
    {type => 'message', content => [
        {type => 'output_text', text => []}, {type => 'output_text', text => 'safe '},
        {type => 'output_text', text => 'answer'},
    ]},
]})), 'safe answer', 'OpenAI Responses text handling retains its scalar guard');

for my $value ([], {}, JSON::PP::true) {
    is_deeply([Mediabot::AI::Provider::OpenAI::extract_error(encode_json({error => {
        type => $value, code => $value, message => $value,
    }}))], ['', '', ''], 'malformed OpenAI diagnostics do not stringify internal references');
    my $sources = Mediabot::AI::Provider::OpenAI::extract_sources(encode_json({output => [
        {type => 'web_search_call', status => 'completed'},
        {type => 'message', content => [{annotations => [{type => 'url_citation',
            url => 'https://source.example.test/item', title => $value}]}]},
    ]}));
    is_deeply($sources, [{url => 'https://source.example.test/item', title => ''}],
        'malformed citation title does not leak a reference or discard the valid URL');
}
is_deeply([Mediabot::AI::Provider::OpenAI::extract_error(encode_json({error => {
    type => 'invalid_request_error', code => 'model_not_found', message => "  try\nagain  ",
}}))], ['invalid_request_error', 'model_not_found', 'try again'], 'valid error diagnostic cleaning is preserved');

for my $provider (qw(anthropic openai gemini)) {
    for my $value ([], {}, JSON::PP::true, " \n\t") {
        my @calls;
        my $client = Mediabot::AI::Client->new(conf => bless({}, 'MB870ShapeConf'),
            http_factory => sub {bless {reply => sub {
                push @calls, $_[1];
                return {success => 1, status => 200, content => encode_json(body_for($provider, $value))};
            }}, 'MB870ShapeHTTP'});
        my $result = $client->execute(build_request(provider => $provider,
            messages => [{role => 'user', content => 'probe'}]));
        ok(!$result->{ok}, "$provider: malformed or whitespace-only answer is not success");
        is($result->{error}, 'parse_error', "$provider: malformed success body is a parse error");
        is(scalar @calls, 1, "$provider: explicit routing never crosses to another company");
        unlike(encode_json($result), qr/(?:ARRAY|HASH)\(0x/, "$provider: returned envelope has no reference string");
    }
    my $client = Mediabot::AI::Client->new(conf => bless({}, 'MB870ShapeConf'),
        http_factory => sub {bless {reply => sub {
            return {success => 1, status => 200, content => encode_json(body_for($provider, '0'))};
        }}, 'MB870ShapeHTTP'});
    my $zero = $client->execute(build_request(provider => $provider,
        messages => [{role => 'user', content => 'probe'}]));
    ok($zero->{ok}, "$provider: the nonblank scalar zero stays a valid answer");
    is($zero->{answer}, '0', "$provider: zero answer preserved");
}

{
    my @calls;
    my $client = Mediabot::AI::Client->new(conf => bless({}, 'MB870ShapeConf'),
        provider_order => [qw(anthropic openai)],
        http_factory => sub {bless {reply => sub {
            my (undef, $url) = @_; push @calls, $url;
            my $provider = $url =~ /anthropic/ ? 'anthropic' : 'openai';
            return {success => 1, status => 200, content => encode_json(body_for($provider,
                $provider eq 'anthropic' ? [] : 'usable fallback'))};
        }}, 'MB870ShapeHTTP'});
    my $result = $client->execute(build_request(provider => 'auto',
        messages => [{role => 'user', content => 'probe'}]));
    ok($result->{ok}, 'auto recovers from malformed text through the authorized next provider');
    is($result->{answer}, 'usable fallback', 'auto returns the usable answer');
    is($result->{provider}, 'openai', 'auto identifies the provider actually used');
    is($result->{provider_fallback}, 1, 'auto records provider fallback');
    is(scalar @calls, 2, 'auto makes exactly two HTTP requests');
}

# The client enforces its own result contract even if an adapter regresses.
{
    no warnings 'redefine';
    local *Mediabot::AI::Provider::OpenAI::extract_answer = sub {[]};
    my $client = Mediabot::AI::Client->new(conf => bless({}, 'MB870ShapeConf'),
        http_factory => sub {bless {reply => sub {{success => 1, status => 200, content => '{}'}}}, 'MB870ShapeHTTP'});
    my $result = $client->execute(build_request(provider => 'openai',
        messages => [{role => 'user', content => 'probe'}]));
    ok(!$result->{ok}, 'common client rejects an adapter returning a reference');
    is($result->{error}, 'parse_error', 'adapter contract failure stays a parse error');
}
done_testing();
