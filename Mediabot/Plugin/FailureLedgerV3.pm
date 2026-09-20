package Mediabot::Plugin::FailureLedgerV3;

use strict;
use warnings;
use utf8;

use Digest::SHA qw(sha256_hex);

my %RUNTIME_KIND = map { $_ => 1 } qw(
    command
    event
    http_callback
    job
);

sub new {
    my ($class, %args) = @_;

    my $max_recent = exists($args{max_recent}) ? $args{max_recent} : 16;
    my $max_resources = exists($args{max_resources})
        ? $args{max_resources} : 128;
    die "FailureLedgerV3: max_recent must be between 1 and 64\n"
        unless defined($max_recent) && !ref($max_recent)
            && "$max_recent" =~ /\A[0-9]+\z/
            && $max_recent >= 1 && $max_recent <= 64;
    die "FailureLedgerV3: max_resources must be between 4 and 256\n"
        unless defined($max_resources) && !ref($max_resources)
            && "$max_resources" =~ /\A[0-9]+\z/
            && $max_resources >= 4 && $max_resources <= 256;
    die "FailureLedgerV3: clock must be CODE\n"
        if exists($args{clock}) && ref($args{clock}) ne 'CODE';

    my $salt = '';
    if (open my $random, '<:raw', '/dev/urandom') {
        read($random, $salt, 32);
        close $random;
    }
    $salt = join("\x00", $$, time(), rand(), $class)
        unless length($salt) == 32;

    return bless {
        max_recent    => int($max_recent),
        max_resources => int($max_resources),
        clock         => $args{clock} || sub { time() },
        sequence      => 0,
        total_failures => 0,
        total_successes => 0,
        recent        => [],
        resources     => {},
        fingerprint_salt => sha256_hex($salt),
    }, $class;
}

sub _runtime_kind {
    my ($kind) = @_;
    die "FailureLedgerV3: unsupported runtime kind\n"
        unless defined($kind) && !ref($kind) && $RUNTIME_KIND{$kind};
    return "$kind";
}

sub _resource {
    my ($resource) = @_;
    die "FailureLedgerV3: invalid resource name\n"
        unless defined($resource) && !ref($resource)
            && length($resource) >= 1 && length($resource) <= 128
            && $resource =~ /\A[a-zA-Z0-9][a-zA-Z0-9_.:-]*\z/;
    return "$resource";
}

sub _channel {
    my ($channel) = @_;
    return '' unless defined($channel) && !ref($channel) && length($channel);
    die "FailureLedgerV3: invalid channel\n"
        unless length($channel) >= 2 && length($channel) <= 128
            && $channel =~ /\A[#&+!][^\x00\x07\r\n ,:]+\z/;
    return "$channel";
}

sub _error_fingerprint {
    my ($self, $error) = @_;
    my $text = !defined($error) || ref($error) ? 'runtime failure' : "$error";
    $text =~ s/[\r\n\0]+/ /g;
    $text =~ s/\s+/ /g;
    $text =~ s/^\s+|\s+$//g;
    $text = 'runtime failure' unless length($text);
    $text = substr($text, 0, 512);
    return substr(sha256_hex($self->{fingerprint_salt} . "\x00" . $text),
        0, 16);
}

sub _timestamp {
    my ($self, $value) = @_;
    $value = $self->{clock}->() unless defined($value);
    die "FailureLedgerV3: invalid timestamp\n"
        unless defined($value) && !ref($value)
            && "$value" =~ /\A[0-9]+(?:\.[0-9]+)?\z/;
    return int($value);
}

sub _state_key {
    my ($kind, $resource, $channel) = @_;
    return join("\x00", $kind, $resource, $channel);
}

sub _resource_state {
    my ($self, $kind, $resource, $channel) = @_;
    my $key = _state_key($kind, $resource, $channel);
    return $self->{resources}{$key} if $self->{resources}{$key};

    my $exact_limit = $self->{max_resources} - scalar(keys %RUNTIME_KIND);
    if (keys(%{ $self->{resources} }) >= $exact_limit) {
        # Keep the runtime kind truthful while collapsing attacker-controlled
        # resource/channel cardinality into one bounded bucket per kind.
        ($resource, $channel) = ('other', '');
        $key = _state_key($kind, $resource, $channel);
        return $self->{resources}{$key} if $self->{resources}{$key};
    }

    return $self->{resources}{$key} = {
        kind                 => $kind,
        resource             => $resource,
        channel              => $channel,
        failure_total        => 0,
        success_total        => 0,
        consecutive_failures => 0,
        last_failure_at      => 0,
        last_success_at      => 0,
        last_fingerprint     => '',
    };
}

sub record_failure {
    my ($self, %args) = @_;
    my $kind = _runtime_kind($args{kind});
    my $resource = _resource($args{resource});
    my $channel = _channel($args{channel});
    my $occurred_at = $self->_timestamp($args{occurred_at});
    my $fingerprint = $self->_error_fingerprint($args{error});
    my $state = $self->_resource_state($kind, $resource, $channel);

    $self->{total_failures}++;
    $state->{failure_total}++;
    $state->{consecutive_failures}++;
    $state->{last_failure_at} = $occurred_at;
    $state->{last_fingerprint} = $fingerprint;

    my $record = {
        sequence    => ++$self->{sequence},
        occurred_at => $occurred_at,
        kind        => $state->{kind},
        resource    => $state->{resource},
        channel     => $state->{channel},
        fingerprint => $fingerprint,
        streak      => $state->{consecutive_failures},
    };
    push @{ $self->{recent} }, $record;
    shift @{ $self->{recent} }
        while @{ $self->{recent} } > $self->{max_recent};
    return { %$record };
}

sub record_success {
    my ($self, %args) = @_;
    my $kind = _runtime_kind($args{kind});
    my $resource = _resource($args{resource});
    my $channel = _channel($args{channel});
    my $occurred_at = $self->_timestamp($args{occurred_at});
    my $state = $self->_resource_state($kind, $resource, $channel);

    $self->{total_successes}++;
    $state->{success_total}++;
    $state->{consecutive_failures} = 0;
    $state->{last_success_at} = $occurred_at;
    return 1;
}

sub report {
    my ($self) = @_;
    my @states = values %{ $self->{resources} };
    my @failed = grep { $_->{failure_total} > 0 } @states;
    my @active = sort {
           $b->{consecutive_failures} <=> $a->{consecutive_failures}
        || $a->{kind} cmp $b->{kind}
        || $a->{resource} cmp $b->{resource}
        || $a->{channel} cmp $b->{channel}
    } grep { $_->{consecutive_failures} > 0 } @failed;
    my @recent = map { { %$_ } } @{ $self->{recent} };

    return {
        total_failures    => $self->{total_failures},
        total_successes   => $self->{total_successes},
        recent_count      => scalar(@recent),
        max_recent        => $self->{max_recent},
        max_resources     => $self->{max_resources},
        affected_resources => scalar(@failed),
        active_streaks    => [ map {
            {
                kind                 => $_->{kind},
                resource             => $_->{resource},
                channel              => $_->{channel},
                consecutive_failures => $_->{consecutive_failures},
                last_failure_at      => $_->{last_failure_at},
                fingerprint          => $_->{last_fingerprint},
            }
        } @active ],
        recent => \@recent,
    };
}

1;
