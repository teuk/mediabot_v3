package Mediabot::AI::Client;

use strict;
use warnings;

use Carp qw(croak);
use HTTP::Tiny;
use Time::HiRes ();
use JSON::PP qw(decode_json);

use Mediabot::AI qw(known_providers normalize_provider provider_configured);
use Mediabot::AI::Request qw(validate_request);
use Mediabot::AI::Transport ();
use Mediabot::AI::Provider::Anthropic ();
use Mediabot::AI::Provider::OpenAI ();
use Mediabot::AI::Provider::Gemini ();

our $VERSION = '1.0';

my %DEFAULT = (
    anthropic => {
        api_url     => 'https://api.anthropic.com/v1/messages',
        api_version => '2023-06-01',
        model       => 'claude-haiku-4-5-20251001',
        max_tokens  => 400,
        temperature => 1.0,
        timeout     => 30,
    },
    openai => {
        api_url        => 'https://api.openai.com/v1/chat/completions',
        model          => 'gpt-4o-mini',
        fallback_model => '',
        max_tokens     => 400,
        temperature    => 0.7,
        timeout        => 20,
    },
    gemini => {
        api_url     => 'https://generativelanguage.googleapis.com/v1beta/models',
        model       => 'gemini-3.8-flash',
        max_tokens  => 1024,
        temperature => 0.7,
        timeout     => 30,
        thinking_level => 'LOW',
    },
);

sub new {
    my ($class, %args) = @_;

    my $conf = $args{conf};
    croak 'conf is required and must provide get()'
        unless $conf && ref($conf) && eval { $conf->can('get') };

    my $http_factory = $args{http_factory};
    croak 'http_factory must be a code reference'
        if defined($http_factory) && ref($http_factory) ne 'CODE';

    my $worker_start = $args{worker_start};
    croak 'worker_start must be a code reference'
        if defined($worker_start) && ref($worker_start) ne 'CODE';

    my $overrides = $args{config_overrides};
    croak 'config_overrides must be a hash reference'
        if defined($overrides) && ref($overrides) ne 'HASH';

    my %safe_overrides;
    if ($overrides) {
        for my $key (keys %$overrides) {
            croak 'config_overrides may not contain credentials'
                if $key =~ /(?:API_KEY|TOKEN|PASSWORD|SECRET)\z/i;
            my $value = $overrides->{$key};
            croak 'config_overrides values must be plain scalars'
                if defined($value) && ref($value);
            $safe_overrides{$key} = $value;
        }
    }

    my @order = _normalize_order($args{provider_order});

    return bless {
        conf             => $conf,
        loop_owner       => $args{loop_owner},
        http_factory     => $http_factory || \&_default_http_factory,
        worker_start     => $worker_start,
        provider_order   => \@order,
        config_overrides => \%safe_overrides,
    }, $class;
}

sub _normalize_order {
    my ($order) = @_;
    my @raw = ref($order) eq 'ARRAY' && @$order
        ? @$order
        : known_providers();

    my (%seen, @out);
    for my $raw (@raw) {
        my $name = normalize_provider($raw);
        next unless defined($name) && $name ne 'auto' && !$seen{$name}++;
        push @out, $name;
    }

    return @out ? @out : known_providers();
}

sub _conf_raw {
    my ($self, $key) = @_;
    return $self->{config_overrides}{$key}
        if exists $self->{config_overrides}{$key};
    return eval { $self->{conf}->get($key) };
}

sub _conf_string {
    my ($self, $key, $default) = @_;
    my $value = $self->_conf_raw($key);
    return $default unless defined($value) && !ref($value);

    $value = "$value";
    $value =~ s/^\s+|\s+$//g;
    return length($value) ? $value : $default;
}

sub _conf_int {
    my ($self, $key, $default, $min, $max) = @_;
    my $value = $self->_conf_raw($key);
    return $default unless defined($value) && !ref($value) && "$value" =~ /^\d+\z/;

    $value = int($value);
    return $default if defined($min) && $value < $min;
    return $default if defined($max) && $value > $max;
    return $value;
}

sub _conf_float {
    my ($self, $key, $default, $min, $max) = @_;
    my $value = $self->_conf_raw($key);
    return $default unless defined($value) && !ref($value)
        && "$value" =~ /^\d+(?:\.\d+)?\z/;

    $value = 0 + $value;
    return $default if defined($min) && $value < $min;
    return $default if defined($max) && $value > $max;
    return $value;
}

sub _https_url {
    my ($url) = @_;
    return defined($url) && !ref($url) && $url =~ m{\Ahttps://[^\s/]+(?:/|\z)}i;
}

sub _default_http_factory {
    my (%opts) = @_;
    return HTTP::Tiny->new(
        timeout    => $opts{timeout},
        verify_SSL => 1,
        agent      => 'Mediabot-AI/1.0',
        max_size   => 1024 * 1024,
    );
}

sub _copy_request_for_provider {
    my ($request, $provider, %overrides) = @_;

    my %copy = %$request;
    $copy{provider} = $provider;
    $copy{model} = $overrides{model};
    $copy{max_output_tokens} = $overrides{max_output_tokens}
        unless exists $copy{max_output_tokens};
    $copy{temperature} = $overrides{temperature}
        unless exists $copy{temperature};
    $copy{timeout_seconds} = $overrides{timeout_seconds}
        unless exists $copy{timeout_seconds};

    $copy{messages} = [
        map { +{ role => "$_->{role}", content => "$_->{content}" } }
            @{ $request->{messages} }
    ];

    return \%copy;
}

sub _provider_plan {
    my ($self, $request, $provider) = @_;

    my $explicit_model = exists($request->{model}) && defined($request->{model});
    my $api_key = $self->_conf_string("$provider.API_KEY", '');
    return (undef, 'not_configured') unless length($api_key);

    if ($provider eq 'anthropic') {
        my $api_url = $self->_conf_string(
            'anthropic.API_URL', $DEFAULT{anthropic}{api_url}
        );
        return (undef, 'invalid_config') unless _https_url($api_url);

        my $api_version = $self->_conf_string(
            'anthropic.API_VERSION', $DEFAULT{anthropic}{api_version}
        );
        my $model = $explicit_model
            ? $request->{model}
            : $self->_conf_string('anthropic.MODEL', $DEFAULT{anthropic}{model});
        my $max_tokens = exists($request->{max_output_tokens})
            ? $request->{max_output_tokens}
            : $self->_conf_int('anthropic.MAX_TOKENS', $DEFAULT{anthropic}{max_tokens}, 1, 100_000);
        my $temperature = exists($request->{temperature})
            ? $request->{temperature}
            : $self->_conf_float('anthropic.TEMPERATURE', $DEFAULT{anthropic}{temperature}, 0, 2);
        my $timeout = exists($request->{timeout_seconds})
            ? $request->{timeout_seconds}
            : $DEFAULT{anthropic}{timeout};

        my $adapted = _copy_request_for_provider(
            $request, 'anthropic',
            model             => $model,
            max_output_tokens => $max_tokens,
            temperature       => $temperature,
            timeout_seconds   => $timeout,
        );
        my $error = validate_request($adapted);
        return (undef, 'invalid_request') if defined $error;

        my $payload = eval {
            Mediabot::AI::Provider::Anthropic::build_payload($adapted)
        };
        return (undef, 'provider_build_failed') unless defined($payload) && !$@;

        my $headers = eval {
            Mediabot::AI::Provider::Anthropic::build_headers({
                api_key     => $api_key,
                api_version => $api_version,
            })
        };
        return (undef, 'provider_build_failed') unless $headers && !$@;

        return ({
            provider => 'anthropic',
            attempts => [{
                model   => "$model",
                api_url => "$api_url",
                timeout => 0 + $timeout,
                headers => $headers,
                payload => $payload,
            }],
        }, undef);
    }

    if ($provider eq 'openai') {
        my $api_url = $self->_conf_string(
            'openai.API_URL', $DEFAULT{openai}{api_url}
        );
        return (undef, 'invalid_config') unless _https_url($api_url);

        my $model = $explicit_model
            ? $request->{model}
            : $self->_conf_string('openai.MODEL', $DEFAULT{openai}{model});
        my $fallback = $explicit_model
            ? ''
            : $self->_conf_string('openai.FALLBACK_MODEL', $DEFAULT{openai}{fallback_model});
        my $max_tokens = exists($request->{max_output_tokens})
            ? $request->{max_output_tokens}
            : $self->_conf_int('openai.MAX_TOKENS', $DEFAULT{openai}{max_tokens}, 1, 100_000);
        my $temperature = exists($request->{temperature})
            ? $request->{temperature}
            : $self->_conf_float('openai.TEMPERATURE', $DEFAULT{openai}{temperature}, 0, 2);
        my $timeout = exists($request->{timeout_seconds})
            ? $request->{timeout_seconds}
            : $self->_conf_int('openai.TIMEOUT', $DEFAULT{openai}{timeout}, 5, 60);

        my $headers = eval {
            Mediabot::AI::Provider::OpenAI::build_headers({ api_key => $api_key })
        };
        return (undef, 'provider_build_failed') unless $headers && !$@;

        my @models = ($model);
        push @models, $fallback
            if length($fallback) && $fallback ne $model;

        my @attempts;
        for my $candidate (@models) {
            my $adapted = _copy_request_for_provider(
                $request, 'openai',
                model             => $candidate,
                max_output_tokens => $max_tokens,
                temperature       => $temperature,
                timeout_seconds   => $timeout,
            );
            my $error = validate_request($adapted);
            return (undef, 'invalid_request') if defined $error;

            my $payload = eval {
                $api_url =~ m{/responses\z}
                ? Mediabot::AI::Provider::OpenAI::build_payload($adapted, {
                    api_style => 'responses',
                    web_search => ($request->{purpose} // '') eq 'meta_web'
                        && $self->_conf_int('openai.WEB_SEARCH', 0, 0, 1),
                })
                : Mediabot::AI::Provider::OpenAI::build_payload($adapted)
            };
            return (undef, 'provider_build_failed') unless defined($payload) && !$@;

            push @attempts, {
                model   => "$candidate",
                api_url => "$api_url",
                timeout => 0 + $timeout,
                headers => { %$headers },
                payload => $payload,
            };
        }

        return ({ provider => 'openai', attempts => \@attempts }, undef);
    }

    if ($provider eq 'gemini') {
        my $base_url = $self->_conf_string(
            'gemini.API_URL', $DEFAULT{gemini}{api_url}
        );
        return (undef, 'invalid_config') unless _https_url($base_url);

        my $model = $explicit_model
            ? $request->{model}
            : $self->_conf_string('gemini.MODEL', $DEFAULT{gemini}{model});
        my $max_tokens = exists($request->{max_output_tokens})
            ? $request->{max_output_tokens}
            : $self->_conf_int('gemini.MAX_TOKENS', $DEFAULT{gemini}{max_tokens}, 1, 100_000);
        my $temperature = exists($request->{temperature})
            ? $request->{temperature}
            : $self->_conf_float('gemini.TEMPERATURE', $DEFAULT{gemini}{temperature}, 0, 2);
        my $timeout = exists($request->{timeout_seconds})
            ? $request->{timeout_seconds}
            : $self->_conf_int('gemini.TIMEOUT', $DEFAULT{gemini}{timeout}, 5, 60);
        my $thinking_level = uc $self->_conf_string(
            'gemini.THINKING_LEVEL', $DEFAULT{gemini}{thinking_level}
        );
        return (undef, 'invalid_config')
            unless $thinking_level =~ /\A(?:LOW|MEDIUM|HIGH)\z/;

        my $adapted = _copy_request_for_provider(
            $request, 'gemini',
            model             => $model,
            max_output_tokens => $max_tokens,
            temperature       => $temperature,
            timeout_seconds   => $timeout,
        );
        my $error = validate_request($adapted);
        return (undef, 'invalid_request') if defined $error;

        my $payload = eval {
            Mediabot::AI::Provider::Gemini::build_payload(
                $adapted,
                { thinking_level => $thinking_level },
            )
        };
        return (undef, 'provider_build_failed') unless defined($payload) && !$@;

        my $headers = eval {
            Mediabot::AI::Provider::Gemini::build_headers({ api_key => $api_key })
        };
        return (undef, 'provider_build_failed') unless $headers && !$@;

        my $api_url = eval {
            Mediabot::AI::Provider::Gemini::build_url($base_url, $model)
        };
        return (undef, 'invalid_config') unless defined($api_url) && !$@;

        my $recover = ($request->{purpose}//'') =~ /\Ameta_(?:draft|synthesis|synthesis_web|citation_repair|synthesis_passages|passage_repair|probe)\z/ ? 1:0;
        my $fallback = $recover ? $self->_conf_string('gemini.FALLBACK_MODEL','') : '';
        my $fallback_attempt;
        if (length($fallback) && $fallback ne $model) {
            return (undef,'invalid_config') unless $fallback =~ /\Agemini-[A-Za-z0-9._-]{1,110}\z/;
            my $fallback_request = _copy_request_for_provider($adapted,'gemini',model=>$fallback);
            my $fallback_payload = eval {Mediabot::AI::Provider::Gemini::build_payload(
                $fallback_request,{thinking_level=>$thinking_level})};
            my $fallback_url = eval {Mediabot::AI::Provider::Gemini::build_url($base_url,$fallback)};
            return (undef,'provider_build_failed') unless defined($fallback_payload) && defined($fallback_url) && !$@;
            $fallback_attempt={model=>$fallback,payload=>$fallback_payload,api_url=>$fallback_url};
        }
        return ({
            provider => 'gemini',
            attempts => [{
                model   => "$model",
                api_url => "$api_url",
                timeout => 0 + $timeout,
                headers => $headers,
                payload => $payload,
                transient_retry => $recover,
                ($fallback_attempt ? (transient_fallback=>$fallback_attempt) : ()),
            }],
        }, undef);
    }

    return (undef, 'unknown_provider');
}

sub _prepare_plan {
    my ($self, $request, %opts) = @_;

    my $validation = validate_request($request);
    return { error => 'invalid_request' } if defined $validation;

    my $requested = normalize_provider(
        exists($request->{provider}) ? $request->{provider} : 'auto'
    );
    return { error => 'unknown_provider' } unless defined $requested;

    if ($requested eq 'auto' && exists($request->{model}) && defined($request->{model})) {
        return { error => 'auto_model_ambiguous' };
    }

    my @order = _normalize_order($opts{provider_order} || $self->{provider_order});
    my @providers = $requested eq 'auto' ? @order : ($requested);
    my (@plans, $last_error, $last_error_provider);
    my $configured_count = 0;

    for my $provider (@providers) {
        next unless provider_configured($self->{conf}, $provider);
        $configured_count++;

        my ($plan, $error) = $self->_provider_plan($request, $provider);
        if ($plan) {
            push @plans, $plan;
            next;
        }

        $last_error = $error || 'provider_build_failed';
        $last_error_provider = $provider;
        return { error => $last_error, provider => $provider }
            if $requested ne 'auto';
    }

    return {
        error    => $configured_count ? ($last_error || 'provider_build_failed') : 'not_configured',
        provider => $last_error_provider,
    } unless @plans;

    return {
        requested => $requested,
        providers => \@plans,
    };
}

sub _openai_fallback_worthy {
    my ($res, $body) = @_;
    return 0 unless ref($res) eq 'HASH' && !$res->{success};

    my $status = $res->{status} // 0;
    my ($type, $code) = Mediabot::AI::Provider::OpenAI::extract_error($body // '');
    my $quota = lc("$type $code") =~ /insufficient_quota/;

    return 1 if $status == 400 || $status == 403 || $status == 404;
    return 1 if $status == 429 && !$quota;
    return 0;
}

sub _attempt {
    my ($provider, $attempt, $http_factory) = @_;

    my $retry=$provider eq 'gemini' && $attempt->{transient_retry};
    my $deadline=Time::HiRes::time()+$attempt->{timeout};
    my ($res,$body,$first_category);my $retries=0;my $active=$attempt;
    for my $turn (0..($retry?1:0)) {
        my $remaining=$deadline-Time::HiRes::time();
        last if $turn && $remaining<0.2;
        my $timeout=$retry ? ($turn?$remaining:$remaining/2):$attempt->{timeout};
        $retries=$turn;
        $active={%$attempt,%{$attempt->{transient_fallback}}} if $turn && $attempt->{transient_fallback};
        $res = Mediabot::AI::Transport::post_json(
        api_url      => $active->{api_url},
        timeout      => $timeout,
        headers      => $active->{headers},
        payload      => $active->{payload},
        http_factory => $http_factory,
    );
        $body = Mediabot::AI::Transport::decode_content($res);
        last unless $retry && !$turn && !$res->{success};
        my ($type,$code)=Mediabot::AI::Provider::Gemini::extract_error($body);
        my $category=Mediabot::AI::Provider::Gemini::failure_category($res->{status},$type,$code,$res->{reason},$body);
        last unless $category =~ /\A(?:service_unavailable|server_error|timeout|connection)\z/;
        $first_category=$category;
        # This runs in the provider worker (or the explicit CLI probe), never
        # the IRC loop. Both attempts and the short backoff share one budget.
        my $delay=0.75 + rand(0.25);
        last if $deadline-Time::HiRes::time()<$delay+0.2;
        Time::HiRes::sleep($delay);
    }
    $res->{transient_retries}=$retries;
    $res->{effective_model}=$active->{model};
    $res->{model_fallback}=($active ne $attempt)?1:0;
    $res->{first_failure_category}=$first_category if defined($first_category);
    my $answer;
    if ($res->{success}) {
        $answer = $provider eq 'anthropic'
            ? Mediabot::AI::Provider::Anthropic::extract_answer($body)
            : $provider eq 'openai'
                ? Mediabot::AI::Provider::OpenAI::extract_answer($body)
                : Mediabot::AI::Provider::Gemini::extract_answer($body);
    }

    return ($res, $body, $answer);
}

sub _failure_result {
    my (%args) = @_;
    my $res = $args{response};

    my $result = {
        ok                => 0,
        provider          => $args{provider},
        model             => $args{model},
        error             => $args{error},
        status            => ref($res) eq 'HASH' ? 0 + ($res->{status} // 0) : 0,
        reason            => ref($res) eq 'HASH' ? ($res->{reason} // '') : '',
        provider_fallback => $args{provider_fallback} ? 1 : 0,
        model_fallback    => $args{model_fallback} ? 1 : 0,
        attempted         => $args{attempted} || [],
    };

    # Provider errors are already sanitized by their adapter. Expose only the
    # small diagnostic tuple required by legacy callers; never return raw HTTP
    # bodies, request headers or credentials in the common result envelope.
    for my $key (qw(error_type error_code error_message)) {
        $result->{$key} = $args{$key}
            if defined($args{$key}) && !ref($args{$key}) && length($args{$key});
    }
    if (($args{provider}//'') eq 'gemini') {
        $result->{failure_category}=Mediabot::AI::Provider::Gemini::failure_category(
            $result->{status},$args{error_type},$args{error_code},$result->{reason},$args{failure_body});
        $result->{transient_retries}=0+($res->{transient_retries}//0);
        $result->{first_failure_category}=$res->{first_failure_category}//'none';
    }

    return $result;
}

sub _run_plan {
    my ($plan, $http_factory) = @_;

    return { ok => 0, error => $plan->{error} || 'invalid_plan', attempted => [] }
        unless ref($plan) eq 'HASH' && ref($plan->{providers}) eq 'ARRAY';

    my @attempted;
    my $provider_index = 0;
    my $last_failure;

    for my $provider_plan (@{ $plan->{providers} }) {
        my $provider = $provider_plan->{provider};
        my $attempt_index = 0;

        for my $attempt (@{ $provider_plan->{attempts} || [] }) {
            push @attempted, "$provider:$attempt->{model}";

            my ($res, $body, $answer) = _attempt(
                $provider, $attempt, $http_factory
            );

            push @attempted, "$provider:$res->{effective_model}"
                if $res->{model_fallback};
            if ($res->{success} && defined($answer) && length($answer)) {
                return {
                    ok                => 1,
                    provider          => $provider,
                    model             => $res->{effective_model}//$attempt->{model},
                    answer            => $answer,
                    status            => 0 + ($res->{status} // 0),
                    provider_fallback => $provider_index ? 1 : 0,
                    model_fallback    => ($attempt_index || $res->{model_fallback}) ? 1 : 0,
                    attempted         => [@attempted],
                    ($provider eq 'gemini' ? (transient_retries=>0+($res->{transient_retries}//0),
                        first_failure_category=>$res->{first_failure_category}//'none'):()),
                    ($provider eq 'openai' && @{
                        Mediabot::AI::Provider::OpenAI::extract_sources($body)
                    } ? (sources => Mediabot::AI::Provider::OpenAI::extract_sources($body)) : ()),
                };
            }

            my $error = $res->{success} ? 'parse_error' : 'http_error';
            my ($error_type, $error_code, $error_message) = ('', '', '');
            if (!$res->{success} && $provider eq 'openai') {
                ($error_type, $error_code, $error_message) =
                    Mediabot::AI::Provider::OpenAI::extract_error($body);
            }
            elsif (!$res->{success} && $provider eq 'gemini') {
                ($error_type, $error_code, $error_message) =
                    Mediabot::AI::Provider::Gemini::extract_error($body);
            }
            elsif ($res->{success} && $provider eq 'gemini') {
                ($error_type, $error_code, $error_message) =
                    Mediabot::AI::Provider::Gemini::extract_diagnostic($body);
            }

            $last_failure = _failure_result(
                provider          => $provider,
                model             => $res->{effective_model}//$attempt->{model},
                error             => $error,
                response          => $res,
                provider_fallback => $provider_index,
                model_fallback    => $attempt_index || $res->{model_fallback},
                attempted         => [@attempted],
                error_type        => $error_type,
                error_code        => $error_code,
                error_message     => $error_message,
                failure_body      => $provider eq 'gemini'?$body:undef,
            );

            my $has_more_models = $attempt_index < $#{ $provider_plan->{attempts} };
            if ($provider eq 'openai' && $has_more_models) {
                last unless _openai_fallback_worthy($res, $body);
            }
            elsif ($has_more_models) {
                last;
            }

            $attempt_index++;
        }

        # An explicit provider is a strict privacy/routing choice: never cross
        # to another company. Auto explicitly grants the dispatcher that choice.
        last if ($plan->{requested} // '') ne 'auto';
        $provider_index++;
    }

    return $last_failure || {
        ok        => 0,
        error     => 'provider_failed',
        attempted => [@attempted],
    };
}

sub execute {
    my ($self, $request, %opts) = @_;
    my $plan = $self->_prepare_plan($request, %opts);
    return { ok => 0, error => $plan->{error}, provider => $plan->{provider}, attempted => [] }
        if $plan->{error};

    return _run_plan($plan, $self->{http_factory});
}

sub _start_worker {
    my ($self, %args) = @_;
    return $self->{worker_start}->(%args) if $self->{worker_start};

    require Mediabot::AsyncWorker;
    return Mediabot::AsyncWorker->start(%args);
}

sub submit {
    my ($self, $request, %opts) = @_;
    my $on_done = delete $opts{on_done};
    croak 'on_done must be a code reference' unless ref($on_done) eq 'CODE';

    my $plan = $self->_prepare_plan($request, %opts);
    if ($plan->{error}) {
        $on_done->({
            ok        => 0,
            error     => $plan->{error},
            provider  => $plan->{provider},
            attempted => [],
        });
        return 1;
    }

    my $loop = Mediabot::AI::Transport::usable_loop($self->{loop_owner});
    unless ($loop) {
        $on_done->({ ok => 0, error => 'async_unavailable', attempted => [] });
        return 0;
    }

    my $max_timeout = 1;
    for my $provider (@{ $plan->{providers} }) {
        for my $attempt (@{ $provider->{attempts} || [] }) {
            $max_timeout = $attempt->{timeout}
                if $attempt->{timeout} > $max_timeout;
        }
    }

    my $http_factory = $self->{http_factory};
    my $completed = 0;
    my $complete = sub {
        my ($result) = @_;
        return if $completed++;
        $on_done->($result);
    };

    my $worker_done = sub {
        my ($result) = @_;
        unless (ref($result) eq 'HASH' && $result->{ok}
            && ref($result->{value}) eq 'HASH') {
            $complete->({
                ok        => 0,
                error     => 'worker_failed',
                attempted => [],
            });
            return;
        }
        $complete->($result->{value});
    };

    my $worker;
    my $launch_ok = eval {
        $worker = $self->_start_worker(
            loop        => $loop,
            label       => 'provider-neutral AI request',
            timeout     => $max_timeout + 3,
            term_grace  => 0.2,
            force_grace => 2.0,
            max_output  => 256 * 1024,
            child       => sub { _run_plan($plan, $http_factory) },
            on_done     => $worker_done,
        );
        1;
    };

    if (!$launch_ok || !$worker) {
        $complete->({
            ok        => 0,
            error     => 'worker_launch_failed',
            attempted => [],
        });
        return 0;
    }

    return 1;
}

1;
