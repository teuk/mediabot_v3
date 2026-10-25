package Mediabot::Plugin::DictionaryServiceV3;

use strict;
use warnings;
use JSON::PP ();
use Time::HiRes ();
use Mediabot::Plugin::WordSolverV3;
use Mediabot::Plugin::DictionaryV3;

sub new {
    my ($class, %args) = @_;
    die "dictionary_settings_provider\n" unless ref($args{settings_provider}) eq 'CODE';
    return bless { %args, inflight => {}, cache => {}, sequence => 0,
        clock => $args{clock} || sub { Time::HiRes::time() } }, $class;
}

sub _copy { JSON::PP->new->decode(JSON::PP->new->encode($_[0])) }
sub _scope {
    my ($plugin, $channel) = @_;
    die "dictionary_scope\n" unless defined($plugin) && !ref($plugin)
        && $plugin =~ /\A[a-z0-9][a-z0-9-]{0,47}\z/
        && defined($channel) && !ref($channel) && length($channel) <= 128
        && $channel =~ /\A[#&+!][^\x00-\x20,:\x7f]+\z/;
    $channel = lc $channel; $channel =~ tr/[]\\^/{}|~/;
    return "$plugin:$channel";
}

sub solve {
    my ($self, $plugin, $channel, $letters, $callback) = @_;
    my $scope = _scope($plugin, $channel);
    $letters = Mediabot::Plugin::WordSolverV3->letters($letters);
    die "dictionary_callback\n" unless ref($callback) eq 'CODE';
    my $cache_key = "$plugin:$letters";
    if (my $cached = $self->{cache}{$cache_key}) {
        if ($cached->{expires} > $self->{clock}->()) {
            $callback->(_copy($cached->{data}));
            return { accepted => 1, cached => 1 };
        }
        delete $self->{cache}{$cache_key};
    }
    my @inflight = values %{ $self->{inflight} };
    if (@inflight >= 4 || (grep { $_->{plugin} eq $plugin } @inflight) >= 2) {
        $callback->({ ok => 0, error => 'busy' });
        return { accepted => 0, error => 'busy' };
    }
    my $id = ++$self->{sequence};
    my $finished = 0;
    my $finish = sub {
        my ($raw) = @_;
        return if $finished++;
        my $pending = delete $self->{inflight}{$id} or return;
        my $data;
        if (ref($raw) eq 'HASH' && $raw->{ok} && ref($raw->{value}) eq 'HASH'
                && $raw->{value}{ok} && ($raw->{value}{letters} // '') eq $letters) {
            $data = eval { Mediabot::Plugin::WordSolverV3->result($letters, $raw->{value}{words}) };
        }
        $data ||= { ok => 0, error => 'unavailable' };
        if ($data->{ok}) {
            # At most 32 complete racks, each <=4096 words of <=12 ASCII bytes.
            if (keys(%{ $self->{cache} }) >= 32) {
                my ($oldest) = sort { $self->{cache}{$a}{expires} <=> $self->{cache}{$b}{expires} }
                    keys %{ $self->{cache} };
                delete $self->{cache}{$oldest};
            }
            $self->{cache}{$cache_key} = { data => _copy($data), expires => $self->{clock}->() + 300 };
        }
        $callback->(_copy($data));
    };
    $self->{inflight}{$id} = { plugin => $plugin, scope => $scope };
    my %args = (
        loop => $self->{loop}, label => 'plugin-motlong', timeout => 10,
        max_output => 131072,
        child => sub {
            my $result = eval {
                my $settings = $self->{settings_provider}->();
                my $dbh = Mediabot::Plugin::DictionaryV3->connect($settings);
                my $data = Mediabot::Plugin::WordSolverV3->solve($dbh, $letters);
                $dbh->disconnect;
                $data;
            };
            return $result || { ok => 0, error => 'unavailable' };
        },
        on_done => $finish,
    );
    my $worker = eval {
        if (ref($self->{worker_factory}) eq 'CODE') { $self->{worker_factory}->(%args) }
        else { require Mediabot::AsyncWorker; Mediabot::AsyncWorker->start(%args) }
    };
    if (!$finished && !exists($self->{inflight}{$id})) {
        $finished = 1;
        eval { $worker->cancel('motlong scope revoked') } if ref($worker) && $worker->can('cancel');
        return { accepted => 0, error => 'cancelled' };
    }
    unless ($worker) {
        $finish->({ ok => 0 });
        return { accepted => 0, error => 'worker_setup' };
    }
    $self->{inflight}{$id}{worker} = $worker unless $finished;
    return { accepted => 1, request_id => $id };
}

sub cancel_scope {
    my ($self, $plugin, $channel) = @_;
    my $scope = _scope($plugin, $channel);
    for my $id (keys %{ $self->{inflight} }) {
        next unless $self->{inflight}{$id}{scope} eq $scope;
        my $pending = delete $self->{inflight}{$id};
        eval { $pending->{worker}->cancel('motlong scope revoked') } if $pending->{worker};
    }
    return 1;
}

sub cancel_plugin {
    my ($self, $plugin) = @_;
    my %scopes = map { $_->{scope} => 1 }
        grep { $_->{plugin} eq $plugin } values %{ $self->{inflight} };
    for my $scope (keys %scopes) {
        my $channel = substr($scope, length($plugin) + 1);
        $self->cancel_scope($plugin, $channel);
    }
    delete $self->{cache}{$_} for grep { index($_, "$plugin:") == 0 } keys %{ $self->{cache} };
    return 1;
}

1;
