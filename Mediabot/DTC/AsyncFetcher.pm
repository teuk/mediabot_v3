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
    }, $class;
}

sub inflight { return $_[0]{worker} ? 1 : 0 }

sub fetch {
    my ($self, %args) = @_;
    my $done = $args{on_done};
    return 0 unless ref($done) eq 'CODE' && !$self->{worker};
    my $worker_class = $self->{worker_class};
    return 0 unless eval { $worker_class->can('start') };
    my $fetch_cb = $self->{fetch_cb};
    my $worker = $worker_class->start(
        loop => $self->{loop}, label => 'dtc random', timeout => 15,
        max_output => 64 * 1024,
        child => sub { $fetch_cb->() },
        on_done => sub {
            my ($result) = @_;
            $self->{worker} = undef;
            my $value = ref($result) eq 'HASH' && $result->{ok}
                && ref($result->{value}) eq 'HASH'
                    ? $result->{value} : { ok => 0, error => 'worker_error' };
            eval { $done->($value); 1 };
        },
    );
    return 0 unless $worker;
    $self->{worker} = $worker;
    return 1;
}

1;
