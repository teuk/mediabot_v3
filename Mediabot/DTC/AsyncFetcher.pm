package Mediabot::DTC::AsyncFetcher;

use strict;
use warnings;

use Mediabot::AsyncWorker ();

sub new {
    my ($class, %args) = @_;
    die 'loop is required' unless $args{loop};
    return bless {
        loop => $args{loop},
        worker_class => $args{worker_class} || 'Mediabot::AsyncWorker',
        fetch_cb => ref($args{fetch_cb}) eq 'CODE' ? $args{fetch_cb} : sub {
            require Mediabot::DTC::Source;
            return Mediabot::DTC::Source::fetch_random();
        },
        worker => undef,
        request => undef,
    }, $class;
}

sub inflight { return $_[0]{request} ? 1 : 0 }

sub fetch {
    my ($self, %args) = @_;
    my $done = $args{on_done};
    return 0 unless ref($done) eq 'CODE' && !$self->{request};
    my $worker_class = $self->{worker_class};
    return 0 unless eval { $worker_class->can('start') };
    # Reserve before entering the launcher. It may complete synchronously or
    # reenter fetch(); the returned handle belongs only to this request.
    my $request = $self->{request} = {};
    my $finished = 0;
    my $finish = sub {
        my ($result) = @_;
        return if $finished++;
        return unless $self->{request} && $self->{request} == $request;
        $self->{request} = undef;
        $self->{worker} = undef;
        my $value = ref($result) eq 'HASH' && $result->{ok}
            && ref($result->{value}) eq 'HASH'
                ? $result->{value} : { ok => 0, error => 'worker_error' };
        eval { $done->($value); 1 };
    };
    my $fetch_cb = $self->{fetch_cb};
    my $worker = eval { $worker_class->start(
        loop => $self->{loop}, label => 'dtc random', timeout => 15,
        max_output => 64 * 1024,
        child => sub { $fetch_cb->() },
        on_done => $finish,
    ) };
    unless ($worker) {
        $finish->({ ok => 0, error => 'worker_setup' });
        return 0;
    }
    $self->{worker} = $worker
        if $self->{request} && $self->{request} == $request;
    return 1;
}

1;
