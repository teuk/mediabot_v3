package Mediabot::VDM::AsyncFetcher;

use strict;
use warnings;
use utf8;

use Mediabot::VDM::Source qw(fetch_vdm_once fetch_vdm_by_id vdm_article_url);

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
        fetch_cb     => ref($args{fetch_cb}) eq 'CODE' ? $args{fetch_cb} : sub {
            my (%opts) = @_;
            return defined($opts{id}) ? fetch_vdm_by_id($opts{id}) : fetch_vdm_once();
        },
        max_workers  => 4,
        jobs         => {},
    }, $class;
}

sub inflight {
    my ($self) = @_;
    return keys(%{ $self->{jobs} }) ? 1 : 0;
}

sub waiter_count {
    my ($self) = @_;
    my $count = 0;
    $count += @{ $_->{waiters} } for values %{ $self->{jobs} };
    return $count;
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
    my ($self, $key, $job, $result) = @_;
    return 0 unless $self->{jobs}{$key} && $self->{jobs}{$key} == $job;
    delete $self->{jobs}{$key};
    my $waiters = $job->{waiters};

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
    my $id = $args{id};
    return 0 if exists($args{id}) && !defined vdm_article_url($id);
    my $key = defined($id) ? "id:$id" : 'feed';
    return 0 if $self->waiter_count >= $self->{max_waiters};

    # Only callers asking for the same source may share a worker result.
    if (my $job = $self->{jobs}{$key}) {
        push @{ $job->{waiters} }, $done;
        return 1;
    }
    return 0 if keys(%{ $self->{jobs} }) >= $self->{max_workers};

    my $worker_class = $self->{worker_class};
    return 0 unless defined($worker_class) && !ref($worker_class)
        && eval { $worker_class->can('start') };

    my $job = { waiters => [ $done ] };
    $self->{jobs}{$key} = $job;
    my $fetch_cb = $self->{fetch_cb};
    my $worker = eval { $worker_class->start(
        loop       => $self->{loop},
        label      => defined($id) ? "vdm article $id" : 'vdm feed',
        timeout    => $self->{timeout},
        max_output => 256 * 1024,
        child      => sub { $fetch_cb->(defined($id) ? (id => $id) : ()) },
        on_done    => sub {
            my ($result) = @_;
            $self->_finish($key, $job, $result);
        },
    ) };

    unless ($worker) {
        $self->_finish($key, $job, { ok => 0, error => 'worker_setup' });
        return 0;
    }
    $job->{worker} = $worker if exists $self->{jobs}{$key};
    return 1;
}

sub cancel {
    my ($self, $reason) = @_;
    my $cancelled = 0;
    for my $job (values %{ $self->{jobs} }) {
        my $worker = $job->{worker} or next;
        next unless eval { $worker->can('cancel') };
        $cancelled++ if $worker->cancel($reason // 'vdm request cancelled');
    }
    return $cancelled ? 1 : 0;
}

1;
