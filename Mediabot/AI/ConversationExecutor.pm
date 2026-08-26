package Mediabot::AI::ConversationExecutor;

use strict;
use warnings;

use Carp qw(croak);
use Exporter 'import';

use Mediabot::AI::Client;
use Mediabot::AI::ConversationDecision qw(parse_model_decision);
use Mediabot::AI::ConversationRequest qw(build_wit_request);

our $VERSION = '1.0';
our @EXPORT_OK = qw(
    execution_summary
);

my %ALLOWED_RUN_ARG = map { $_ => 1 } qw(
    provider
    language
    message
);

sub _plain_scalar {
    my ($value) = @_;
    return defined($value) && !ref($value);
}

sub _safe_short {
    my ($value, $max) = @_;
    return undef unless _plain_scalar($value);

    my $text = "$value";
    $text =~ s/^\s+|\s+$//g;
    return undef unless length($text);
    return undef if length($text) > $max;
    return undef if $text =~ /[\x00-\x1f\x7f]/;

    return $text;
}

sub _bool {
    return $_[0] ? 1 : 0;
}

sub new {
    my ($class, %args) = @_;

    my $client = $args{client};
    if (defined $client) {
        croak 'client must provide execute() and submit()'
            unless ref($client)
                && eval { $client->can('execute') }
                && eval { $client->can('submit') };
    }
    else {
        my $conf = $args{conf};
        croak 'conf is required when client is not injected'
            unless $conf && ref($conf) && eval { $conf->can('get') };

        $client = Mediabot::AI::Client->new(
            conf       => $conf,
            loop_owner => $args{loop_owner},
        );
    }

    return bless {
        client => $client,
    }, $class;
}

sub _request_from_args {
    my (%args) = @_;

    for my $key (keys %args) {
        croak "unknown Wit executor field: $key"
            unless $ALLOWED_RUN_ARG{$key};
    }

    return build_wit_request(
        provider => exists($args{provider}) ? $args{provider} : 'auto',
        language => $args{language},
        message  => $args{message},
    );
}

sub _provider_failure {
    my ($client_result) = @_;

    my %out = (
        ok     => 0,
        action => 'no_reply',
        reason => 'provider_error',
    );

    if (ref($client_result) eq 'HASH') {
        for my $key (qw(provider model error)) {
            my $value = _safe_short($client_result->{$key}, 160);
            $out{$key} = $value if defined $value;
        }

        $out{provider_fallback} = _bool($client_result->{provider_fallback});
        $out{model_fallback}    = _bool($client_result->{model_fallback});
    }

    return \%out;
}

sub _consume_client_result {
    my ($client_result) = @_;

    return _provider_failure($client_result)
        unless ref($client_result) eq 'HASH' && $client_result->{ok};

    my $decision = parse_model_decision($client_result->{answer});

    my %out = (
        ok                => 1,
        action            => $decision->{action},
        reason            => $decision->{reason},
        provider_fallback => _bool($client_result->{provider_fallback}),
        model_fallback    => _bool($client_result->{model_fallback}),
    );

    for my $key (qw(provider model)) {
        my $value = _safe_short($client_result->{$key}, 160);
        $out{$key} = $value if defined $value;
    }

    $out{text} = $decision->{text}
        if $decision->{action} eq 'reply' && defined($decision->{text});

    return \%out;
}

sub execute_dryrun {
    my ($self, %args) = @_;
    croak 'executor object is required' unless ref($self);

    my $request = _request_from_args(%args);
    my $client_result;

    my $ok = eval {
        $client_result = $self->{client}->execute($request);
        1;
    };
    return _provider_failure({ error => 'client_exception' }) unless $ok;

    return _consume_client_result($client_result);
}

sub submit_dryrun {
    my ($self, %args) = @_;
    croak 'executor object is required' unless ref($self);

    my $on_done = delete $args{on_done};
    croak 'on_done must be a code reference' unless ref($on_done) eq 'CODE';

    my $request = _request_from_args(%args);
    my $started;

    my $ok = eval {
        $started = $self->{client}->submit(
            $request,
            on_done => sub {
                my ($client_result) = @_;
                my $result = _consume_client_result($client_result);
                $on_done->($result);
            },
        );
        1;
    };

    unless ($ok) {
        $on_done->(_provider_failure({ error => 'client_exception' }));
        return 0;
    }

    return $started ? 1 : 0;
}

sub execution_summary {
    my ($result) = @_;
    return undef unless ref($result) eq 'HASH';

    my $action = $result->{action};
    my $reason = $result->{reason};
    return undef unless _plain_scalar($action) && _plain_scalar($reason);
    return undef unless $action eq 'reply' || $action eq 'no_reply';

    my %out = (
        ok     => $result->{ok} ? 1 : 0,
        action => "$action",
        reason => "$reason",
    );

    for my $key (qw(provider model error)) {
        my $value = _safe_short($result->{$key}, 160);
        $out{$key} = $value if defined $value;
    }

    $out{provider_fallback} = _bool($result->{provider_fallback});
    $out{model_fallback}    = _bool($result->{model_fallback});

    if ($action eq 'reply') {
        return undef unless _plain_scalar($result->{text});
        $out{reply_chars} = length("$result->{text}");
    }

    return \%out;
}

1;
