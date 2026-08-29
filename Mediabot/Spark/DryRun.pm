package Mediabot::Spark::DryRun;

use strict;
use warnings;

use Carp qw(croak);

use Mediabot::Spark::Event qw(spark_event_profile);
use Mediabot::Spark::Generator qw(spark_generation_summary);

our $VERSION = '1.0';

my $MAX_GENERATION = 999_999_999_999_999;

sub _plain_scalar {
    my ($value) = @_;
    return defined($value) && !ref($value);
}

sub _channel_key {
    my ($channel) = @_;
    croak 'channel must be a public IRC channel'
        unless _plain_scalar($channel)
            && "$channel" =~ /^#[^\s,:\x00-\x1f\x7f]{1,79}\z/;
    return lc "$channel";
}

sub _safe_token {
    my ($value, $max) = @_;
    return undef unless _plain_scalar($value);
    my $text = "$value";
    $text =~ s/^\s+|\s+$//g;
    return undef unless length($text) && length($text) <= $max;
    return undef if $text =~ /[\s\x00-\x1f\x7f]/;
    return $text;
}

sub _notify {
    my ($callback, $payload) = @_;
    return eval { $callback->($payload); 1 } ? 1 : 0;
}

sub new {
    my ($class, %args) = @_;

    my $generator = $args{generator};
    croak 'generator must provide submit()'
        unless ref($generator) && eval { $generator->can('submit') };

    return bless {
        generator       => $generator,
        next_generation => 0,
        inflight        => {},
    }, $class;
}

sub _next_generation {
    my ($self) = @_;
    croak 'Spark dry-run generation exhausted'
        if $self->{next_generation} >= $MAX_GENERATION;
    return ++$self->{next_generation};
}

sub channel_inflight {
    my ($self, $channel) = @_;
    croak 'dry-run object is required' unless ref($self);
    my $key = _channel_key($channel);
    return ref($self->{inflight}{$key}) eq 'HASH' ? 1 : 0;
}

sub capture_generation {
    my ($self, $channel) = @_;
    croak 'dry-run object is required' unless ref($self);
    my $key = _channel_key($channel);
    my $row = $self->{inflight}{$key};
    return undef unless ref($row) eq 'HASH';
    return int($row->{generation} // 0) || undef;
}

sub capture_kind {
    my ($self, $channel) = @_;
    croak 'dry-run object is required' unless ref($self);
    my $key = _channel_key($channel);
    my $row = $self->{inflight}{$key};
    return undef unless ref($row) eq 'HASH';
    my $profile = eval { spark_event_profile($row->{kind}) };
    return $profile ? $profile->{kind} : undef;
}

sub generation_is_current {
    my ($self, $channel, $generation) = @_;
    croak 'dry-run object is required' unless ref($self);
    return 0 unless _plain_scalar($generation) && "$generation" =~ /^[1-9]\d{0,14}\z/;
    my $current = $self->capture_generation($channel);
    return defined($current) && $current == int($generation) ? 1 : 0;
}

sub invalidate_channel {
    my ($self, $channel) = @_;
    croak 'dry-run object is required' unless ref($self);
    my $key = _channel_key($channel);
    return delete($self->{inflight}{$key}) ? 1 : 0;
}

sub clear_all {
    my ($self) = @_;
    croak 'dry-run object is required' unless ref($self);
    my $count = scalar keys %{ $self->{inflight} };
    $self->{inflight} = {};
    return $count;
}

sub _result_for_log {
    my ($kind, $generation, $result) = @_;

    my $summary = spark_generation_summary($result);
    $summary = {
        action => 'no_content',
        reason => 'invalid_generator_result',
    } unless ref($summary) eq 'HASH';

    return {
        %$summary,
        kind       => $kind,
        generation => int($generation),
    };
}

sub submit_candidate {
    my ($self, %args) = @_;
    croak 'dry-run object is required' unless ref($self);

    my $channel = _channel_key($args{channel});
    my $kind = spark_event_profile($args{kind})->{kind};
    my $on_result = delete $args{on_result};
    croak 'on_result must be a code reference' unless ref($on_result) eq 'CODE';
    my $on_candidate = delete $args{on_candidate};
    croak 'on_candidate must be a code reference'
        if defined($on_candidate) && ref($on_candidate) ne 'CODE';

    return 0 if ref($self->{inflight}{$channel}) eq 'HASH';

    my $generation = $self->_next_generation();
    $self->{inflight}{$channel} = {
        generation => $generation,
        kind       => $kind,
    };

    my $completed = 0;
    my $finish = sub {
        my ($result) = @_;
        return if $completed++;

        my $current = $self->{inflight}{$channel};
        unless (ref($current) eq 'HASH'
            && int($current->{generation} // 0) == $generation) {
            _notify($on_result, {
                action     => 'revoked',
                reason     => 'stale_generation',
                kind       => $kind,
                generation => $generation,
            });
            return;
        }

        delete $self->{inflight}{$channel};

        # Keep generated content on a private in-memory boundary only. Logs
        # continue to receive the redacted metadata summary below. A future or
        # armed sender must still re-authorize every mutable runtime gate.
        if (ref($on_candidate) eq 'CODE'
            && ref($result) eq 'HASH'
            && ($result->{action} // '') eq 'ready') {
            _notify($on_candidate, {
                generation => $generation,
                kind       => $kind,
                generated  => $result,
            });
        }

        _notify($on_result, _result_for_log($kind, $generation, $result));
    };

    my %submit = (
        kind     => $kind,
        language => $args{language},
        context  => $args{context},
        provider => exists($args{provider}) ? $args{provider} : 'auto',
        on_done  => $finish,
    );
    $submit{contributions} = $args{contributions}
        if exists $args{contributions};

    my $started;
    my $ok = eval {
        $started = $self->{generator}->submit(%submit);
        1;
    };

    unless ($ok) {
        $finish->({ action => 'no_content', reason => 'generator_exception' });
        return 0;
    }

    # Generator/AI::Client may report an async-unavailable failure through the
    # callback synchronously and then return false. If it did not, fail closed.
    $finish->({ action => 'no_content', reason => 'async_unavailable' })
        unless $started || $completed;

    return $started ? $generation : 0;
}

sub format_ai_dryrun_log {
    my ($channel, $summary) = @_;
    return undef unless _plain_scalar($channel) && "$channel" =~ /^#/;
    return undef unless ref($summary) eq 'HASH';

    my $action = _safe_token($summary->{action}, 32);
    my $reason = _safe_token($summary->{reason}, 64);
    my $kind = _safe_token($summary->{kind}, 32);
    return undef unless defined($action) && defined($reason) && defined($kind);
    return undef unless $action eq 'ready'
        || $action eq 'no_content'
        || $action eq 'revoked';
    return undef unless $kind =~ /^(?:fork|portal|callback|reaction|mosaic|stage_cue)\z/;

    my @parts = (
        '[SPARK_AI_DRYRUN]',
        'channel=' . $channel,
        'action=' . $action,
        'reason=' . $reason,
        'kind=' . $kind,
    );

    if (_plain_scalar($summary->{generation})
        && "$summary->{generation}" =~ /^[1-9]\d{0,14}\z/) {
        push @parts, 'generation=' . int($summary->{generation});
    }

    for my $key (qw(provider model)) {
        my $value = _safe_token($summary->{$key}, 160);
        push @parts, "$key=$value" if defined $value;
    }

    for my $key (qw(provider_fallback model_fallback)) {
        push @parts, "$key=" . ($summary->{$key} ? 1 : 0)
            if exists $summary->{$key};
    }

    if (_plain_scalar($summary->{content_fields})
        && "$summary->{content_fields}" =~ /^\d+\z/) {
        push @parts, 'content_fields=' . int($summary->{content_fields});
    }

    return join ' ', @parts;
}

1;
