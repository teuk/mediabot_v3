package Mediabot::VDM::AsyncFetcher;

use strict;
use warnings;
use utf8;

use Mediabot::VDM::Source qw(fetch_vdm_once);

sub new {
    my ($class, %args) = @_;
    my $loop = $args{loop} or die "loop is required";

    my $timeout = 0 + ($args{timeout} // 15);
    $timeout = 1 if $timeout < 1;
    $timeout = 60 if $timeout > 60;

    my $max_waiters = int($args{max_waiters} // 16);
    $max_waiters = 1 if $max_waiters < 1;
    $max_waiters = 64 if $max_waiters > 64;

    return bless {
        loop         => $loop,
        timeout      => $timeout,
        max_waiters  => $max_waiters,
        worker_class => $args{worker_class} || 'Mediabot::AsyncWorker',
        fetch_cb     => ref($args{fetch_cb}) eq 'CODE' ? $args{fetch_cb} : \&fetch_vdm_once,
        worker       => undef,
        waiters      => [],
    }, $class;
}

sub inflight {
    my ($self) = @_;
    return $self->{worker} ? 1 : 0;
}

sub waiter_count {
    my ($self) = @_;
    return scalar @{ $self->{waiters} || [] };
}

sub _clean_detail {
    my ($text) = @_;
    $text = '' unless defined($text) && !ref($text);
    $text =~ s/[\r\n\0]+/ /g;
    return substr($text, 0, 240);
}

sub _normalize_worker_result {
    my ($result) = @_;

    unless (ref($result) eq 'HASH' && $result->{ok} && ref($result->{value}) eq 'HASH') {
        my $detail = ref($result) eq 'HASH'
            ? ($result->{detail} // $result->{error} // 'worker failure')
            : 'invalid worker result';
        return { ok => 0, error => 'worker_error', detail => _clean_detail($detail) };
    }

    my $value = $result->{value};
    return { %$value } if $value->{ok};

    return {
        %$value,
        ok     => 0,
        error  => $value->{error} || 'fetch_error',
        detail => _clean_detail($value->{detail}),
    };
}

sub _finish {
    my ($self, $result) = @_;
    $self->{worker} = undef;
    my $waiters = delete($self->{waiters}) || [];
    $self->{waiters} = [];

    my $normalized = _normalize_worker_result($result);
    for my $cb (@$waiters) {
        next unless ref($cb) eq 'CODE';
        eval { $cb->({ %$normalized }); 1 };
    }
    return scalar @$waiters;
}

sub fetch {
    my ($self, %args) = @_;
    my $done = $args{on_done};
    return 0 unless ref($done) eq 'CODE';

    return 0 if $self->waiter_count >= $self->{max_waiters};
    push @{ $self->{waiters} }, $done;

    # Coalesce simultaneous callers onto the one bounded feed request.
    return 1 if $self->{worker};

    my $worker_class = $self->{worker_class};
    unless (defined($worker_class) && !ref($worker_class) && eval { $worker_class->can('start') }) {
        pop @{ $self->{waiters} };
        return 0;
    }

    my $fetch_cb = $self->{fetch_cb};
    my $worker;
    $worker = $worker_class->start(
        loop       => $self->{loop},
        label      => 'vdm feed',
        timeout    => $self->{timeout},
        max_output => 256 * 1024,
        child      => sub { $fetch_cb->() },
        on_done    => sub {
            my ($result) = @_;
            $self->_finish($result);
        },
    );

    unless ($worker) {
        my $cb = pop @{ $self->{waiters} };
        eval { $cb->({ ok => 0, error => 'worker_setup' }); 1 } if $cb;
        return 0;
    }

    $self->{worker} = $worker;
    return 1;
}

sub cancel {
    my ($self, $reason) = @_;
    my $worker = $self->{worker} or return 0;
    return 0 unless eval { $worker->can('cancel') };
    return $worker->cancel($reason // 'vdm request cancelled') ? 1 : 0;
}

1;
