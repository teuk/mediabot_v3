package Mediabot::RSS::Pacing;
use strict;
use warnings;
use Fcntl qw(:DEFAULT :flock);
use File::Basename qw(dirname);
use File::Spec;
use File::Temp qw(tempfile);
use IO::Handle;
use JSON::PP;

# Core-owned instance state in the directory preserved by deploy_update.
# Every decision rereads state under one lock; workers never cache it.
sub new {
    my ($class, %args) = @_;
    my $bot = $args{bot} || {};
    my $dir = eval { $bot->{conf}->get('plugins.DATA_DIR') };
    $dir = 'plugin-data' unless defined($dir) && !ref($dir) && length($dir);
    my $path = $args{path} // File::Spec->catfile($dir, '.rss-pacing.json');
    die 'invalid RSS pacing path' if ref($path) || $path =~ /[\x00-\x1f\x7f]/;
    return bless {path => File::Spec->rel2abs($path), now => $args{now} || sub {time()}}, $class;
}
sub _channel {
    my ($channel) = @_;
    die 'invalid RSS channel' unless defined($channel) && !ref($channel)
        && $channel =~ /\A[#&!+][^\x00-\x20\x7f,]{1,199}\z/;
    return lc $channel;
}
sub _number {
    my ($value, $max) = @_;
    return defined($value) && !ref($value) && "$value" =~ /\A[0-9]{1,10}\z/ && $value <= $max;
}
sub _validate {
    my ($state) = @_;
    die 'invalid RSS pacing document' unless ref($state) eq 'HASH'
        && _number($state->{schema}, 1) && $state->{schema} == 1
        && ref($state->{channels}) eq 'HASH' && keys(%{$state->{channels}}) <= 1000;
    for my $key (keys %{$state->{channels}}) {
        die 'invalid RSS pacing channel key' unless _channel($key) eq $key;
        my $row = $state->{channels}{lc $key};
        die 'invalid RSS pacing policy' unless ref($row) eq 'HASH'
            && _number($row->{gap}, 10080) && (!$row->{gap} || $row->{gap} >= 5)
            && _number($row->{daily}, 24) && ref($row->{history}) eq 'ARRAY'
            && @{$row->{history}} <= 300;
        for my $stamp (@{$row->{history}}) {
            die 'invalid RSS pacing history' unless _number($stamp, 9999999999);
        }
        # Optional in schema 1: existing quota histories need no migration.
        die 'invalid RSS rotation cursor' if exists($row->{last_feed})
            && (!_number($row->{last_feed}, 4294967295) || !$row->{last_feed});
    }
    return $state;
}
sub _safe_path {
    my ($path) = @_;
    my $current = File::Spec->rootdir;
    for my $part (File::Spec->splitdir($path)) {
        next unless length($part);
        $current = File::Spec->catfile($current, $part);
        die 'RSS pacing symlink refused' if -l $current;
    }
}
sub _locked {
    my ($self, $write, $cb) = @_;
    my $path = $self->{path};
    _safe_path($path); _safe_path("$path.lock");
    my $dir = dirname($path);
    die 'RSS pacing state missing while its lock exists' if !-e $path && -e "$path.lock";
    # A read of an unconfigured instance creates nothing.
    if (!$write && !-e $path && !-e "$path.lock") {
        my ($result) = $cb->({schema => 1, channels => {}});
        return $result;
    }
    mkdir($dir, 0700) or die 'cannot create RSS pacing directory' unless -d $dir;
    sysopen(my $lock, "$path.lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0600)
        or die 'cannot open RSS pacing lock';
    die 'RSS pacing lock is not a regular file' unless -f $lock;
    flock($lock, LOCK_EX | LOCK_NB) or die 'RSS pacing state is busy';
    chmod(0600, "$path.lock") or die 'cannot protect RSS pacing lock';
    my $state = {schema => 1, channels => {}};
    if (-e $path) {
        sysopen(my $fh, $path, O_RDONLY | O_NOFOLLOW) or die 'cannot read RSS pacing state';
        die 'RSS pacing state is not a regular file' unless -f $fh;
        die 'RSS pacing state too large' if -s $fh > 262144;
        local $/; my $raw = <$fh>; close $fh;
        $state = _validate(JSON::PP->new->utf8->decode($raw));
    }
    my ($result, $dirty) = $cb->($state);
    if ($dirty || ($write && !-e $path)) {
        _validate($state);
        my $bytes = JSON::PP->new->utf8->canonical->encode($state);
        die 'RSS pacing state too large' if length($bytes) > 262144;
        my ($fh, $tmp) = tempfile('.rss-pacing-XXXXXX', DIR => $dir, UNLINK => 0);
        my $ok = eval {
            chmod(0600, $tmp) or die 'cannot protect RSS pacing state';
            print {$fh} $bytes or die 'cannot write RSS pacing state';
            $fh->flush or die 'cannot flush RSS pacing state';
            $fh->sync or die 'cannot sync RSS pacing state';
            close($fh) or die 'cannot close RSS pacing state';
            rename($tmp, $path) or die 'cannot publish RSS pacing state';
            1;
        };
        my $err = $@; unlink $tmp if -e $tmp; die $err unless $ok;
    }
    close $lock; return $result;
}
sub _status {
    my ($self, $row) = @_;
    $row ||= {gap => 0, daily => 0, history => []};
    my $now = int($self->{now}->());
    my @recent = sort {$a <=> $b} grep {$_ > $now - 86400} @{$row->{history}};
    my $last = @{$row->{history}} ? (sort {$b <=> $a} @{$row->{history}})[0] : undef;
    my $wait = defined($last) && $row->{gap} ? $last + $row->{gap} * 60 - $now : 0;
    if ($row->{daily} && @recent >= $row->{daily}) {
        my $quota_wait = $recent[@recent - $row->{daily}] + 86400 - $now;
        $wait = $quota_wait if $quota_wait > $wait;
    }
    $wait = 0 if $wait < 0;
    return {gap => $row->{gap}, daily => $row->{daily}, active => ($row->{gap} || $row->{daily}) ? 1 : 0,
        used => scalar(@recent), wait => $wait};
}
sub status {
    my ($self, $channel) = @_; my $key = _channel($channel);
    return $self->_locked(0, sub {return $self->_status($_[0]{channels}{lc $key})});
}
sub configure {
    my ($self, $channel, %args) = @_; my $key = _channel($channel);
    die 'RSS gap must be 0 or between 5 and 10080 minutes' if exists($args{gap})
        && (!_number($args{gap}, 10080) || ($args{gap} && $args{gap} < 5));
    die 'RSS daily must be between 0 and 24' if exists($args{daily}) && !_number($args{daily}, 24);
    die 'unknown RSS limit setting' if grep {$_ ne 'gap' && $_ ne 'daily'} keys %args;
    return $self->_locked(1, sub {
        my ($state) = @_;
        my $row = ($state->{channels}{lc $key} ||= {gap => 0, daily => 0, history => []});
        $row->{$_} = 0 + $args{$_} for keys %args;
        # Reconfiguration never resets the last sends or the rolling quota.
        return ($self->_status($row), 1);
    });
}
sub rotation_order {
    my ($self, $channel, $ids) = @_; my $key = _channel($channel);
    die 'invalid RSS rotation candidates' unless ref($ids) eq 'ARRAY' && @$ids <= 1000;
    my %seen;
    for my $id (@$ids) {
        die 'invalid RSS rotation feed' unless _number($id, 4294967295) && $id;
        $seen{0 + $id} = 1;
    }
    return $self->_locked(0, sub {
        my ($state) = @_;
        my $row = $state->{channels}{lc $key} || {};
        my $last = $row->{last_feed} // 0;
        my @sorted = sort {$a <=> $b} keys %seen;
        return [(grep {$_ > $last} @sorted), (grep {$_ <= $last} @sorted)];
    });
}
sub reserve {
    my ($self, $channel, %args) = @_; my $key = _channel($channel);
    die 'invalid RSS reservation option' if grep {$_ ne 'feed_id'} keys %args;
    die 'invalid RSS reservation feed' if exists($args{feed_id})
        && (!_number($args{feed_id}, 4294967295) || !$args{feed_id});
    return $self->_locked(1, sub {
        my ($state) = @_; my $row = $state->{channels}{lc $key};
        my $status = $self->_status($row);
        return ({%$status, allowed => 1}, 0) unless $status->{active};
        return ({%$status, allowed => 0}, 0) if $status->{wait};
        my $now = int($self->{now}->());
        $row->{history} = [grep {$_ > $now - 604800} @{$row->{history}}];
        push @{$row->{history}}, $now;
        splice @{$row->{history}}, 0, @{$row->{history}} - 300 if @{$row->{history}} > 300;
        # The turn and the quota are committed together, before the IRC attempt.
        $row->{last_feed} = 0 + $args{feed_id} if exists $args{feed_id};
        return ({%$status, allowed => 1}, 1);
    });
}
1;
