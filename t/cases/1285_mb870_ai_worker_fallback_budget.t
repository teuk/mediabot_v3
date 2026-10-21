use strict;
use warnings;
use Test::More;
use JSON::PP qw(encode_json decode_json);
use Mediabot::AI::Client;
use Mediabot::AI::Request qw(build_request);

{
    package MB870BudgetConf;
    sub get {$_[0]{$_[1]}}
    package MB870BudgetLoop;
    sub add {1}
    sub remove {1}
    sub watch_process {1}
    package MB870BudgetHTTP;
    sub request {$_[0]{reply}->(@_[1 .. $#_])}
}
sub conf_for {
    my (%extra) = @_;
    return bless {
        'anthropic.API_KEY' => 'fixture', 'anthropic.MODEL' => 'claude-primary',
        'anthropic.API_URL' => 'https://anthropic.example.test/messages',
        'openai.API_KEY' => 'fixture', 'openai.MODEL' => 'gpt-primary',
        'openai.FALLBACK_MODEL' => 'gpt-backup',
        'openai.API_URL' => 'https://openai.example.test/chat/completions',
        'gemini.API_KEY' => 'fixture', 'gemini.MODEL' => 'gemini-primary',
        'gemini.API_URL' => 'https://gemini.example.test/v1beta/models',
        %extra,
    }, 'MB870BudgetConf';
}
for my $case (
    ['one Anthropic attempt', 'anthropic', {}, {}, undef, 33],
    ['two OpenAI models', 'openai', {}, {}, undef, 43],
    ['explicit OpenAI model disables model fallback', 'openai', {}, {model => 'gpt-explicit'}, undef, 23],
    ['auto, three providers and two OpenAI models', 'auto', {}, {}, undef, 103],
    ['auto with a narrowed provider order', 'auto', {}, {}, [qw(openai anthropic)], 73],
    ['auto skips unconfigured OpenAI', 'auto', {'openai.API_KEY' => ''}, {}, undef, 63],
    ['request timeout applies to every planned attempt', 'auto', {}, {timeout_seconds => 5}, undef, 23],
    ['maximum validated per-attempt timeout remains finite', 'auto', {}, {timeout_seconds => 300}, undef, 1203],
    ['Gemini internal retry shares its attempt deadline', 'gemini', {'gemini.FALLBACK_MODEL' => 'gemini-backup'}, {purpose => 'meta_probe'}, undef, 33],
) {
    my ($label, $provider, $config, $extra, $order, $expected) = @$case;
    my @workers;
    my $client = Mediabot::AI::Client->new(conf => conf_for(%$config),
        loop_owner => {loop => bless({}, 'MB870BudgetLoop')},
        worker_start => sub {my %args = @_; push @workers, \%args; bless {}, 'MB870BudgetWorker'});
    my $request = build_request(provider => $provider,
        messages => [{role => 'user', content => 'probe'}], %$extra);
    ok($client->submit($request, ($order ? (provider_order => $order) : ()), on_done => sub {}), "$label: accepted");
    is(scalar @workers, 1, "$label: one bounded worker owns the complete plan");
    is($workers[0]{timeout}, $expected, "$label: watchdog covers the sequential HTTP budgets plus the existing margin");
    is($workers[0]{max_output}, 256 * 1024, "$label: output ceiling is unchanged");
    is($workers[0]{term_grace}, 0.2, "$label: termination grace is unchanged");
}

# Execute the real plan through submit, adapter payloads and shared transport;
# HTTP alone is local. No wall-clock sleep or remote API call is required.
{
    my (@calls, @results, $worker);
    my $client = Mediabot::AI::Client->new(conf => conf_for(),
        loop_owner => {loop => bless({}, 'MB870BudgetLoop')},
        http_factory => sub {
            my %options = @_;
            return bless {reply => sub {
                my (undef, $url, $request) = @_;
                my $payload = decode_json($request->{content});
                push @calls, {url => $url, model => $payload->{model}, %options};
                return {status => 503, success => 0, content => '{}'} if $url =~ /anthropic/;
                return {status => 404, success => 0, content => encode_json({error => {
                    type => 'invalid_request_error', code => 'model_not_found'}})} if $payload->{model} eq 'gpt-primary';
                return {status => 200, success => 1, content => encode_json({choices => [{message => {content => 'recovered'}}]})};
            }}, 'MB870BudgetHTTP';
        },
        worker_start => sub {$worker = {@_}; bless {}, 'MB870BudgetWorker'});
    ok($client->submit(build_request(provider => 'auto', messages => [{role => 'user', content => 'probe'}]),
        on_done => sub {push @results, shift}), 'sequential async fallback is submitted');
    my $value = $worker->{child}->();
    $worker->{on_done}->({ok => 1, value => $value});
    $worker->{on_done}->({ok => 0, error => 'duplicate'});
    is(scalar @results, 1, 'terminal callback remains exactly once');
    ok($results[0]{ok}, 'async fallback returns a usable answer');
    is($results[0]{answer}, 'recovered', 'recovered answer delivered');
    is($results[0]{provider}, 'openai', 'actual provider retained');
    is($results[0]{model}, 'gpt-backup', 'actual fallback model retained');
    is($results[0]{provider_fallback}, 1, 'provider fallback metadata retained');
    is($results[0]{model_fallback}, 1, 'model fallback metadata retained');
    is_deeply([map {$_->{model}} @calls], ['claude-primary', 'gpt-primary', 'gpt-backup'], 'only eligible attempts are executed');
    my $spent = 0; $spent += $_->{timeout} for @calls;
    ok($worker->{timeout} >= $spent + 3, 'worker deadline accommodates every reached attempt at its allowed HTTP deadline');
    is_deeply([map {$_->{timeout}} @calls], [30, 20, 20], 'individual HTTP deadlines are unchanged');
    ok(!(grep {!$_->{verify_SSL}} @calls), 'all attempted transports retain TLS verification');
}

for my $provider (qw(anthropic openai)) {
    my (@calls, @results, $worker);
    my $client = Mediabot::AI::Client->new(conf => conf_for(),
        loop_owner => {loop => bless({}, 'MB870BudgetLoop')},
        http_factory => sub {bless {reply => sub {
            push @calls, $_[1];
            return {success => 0, status => 429, content => encode_json({error => {
                type => 'insufficient_quota', code => 'insufficient_quota'}})};
        }}, 'MB870BudgetHTTP'},
        worker_start => sub {$worker = {@_}; bless {}, 'MB870BudgetWorker'});
    $client->submit(build_request(provider => $provider, messages => [{role => 'user', content => 'probe'}]),
        on_done => sub {push @results, shift});
    $worker->{on_done}->({ok => 1, value => $worker->{child}->()});
    ok(!$results[0]{ok}, "$provider: explicit failure remains failure");
    is(scalar @calls, 1, "$provider: neither cross-provider routing nor quota model retry is added");
}
done_testing();
