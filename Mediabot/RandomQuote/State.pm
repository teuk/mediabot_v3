package Mediabot::RandomQuote::State;
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
    my $path = $args{path} // File::Spec->catfile($dir, '.randomquote.json');
    die 'invalid RandomQuote path' if ref($path) || $path =~ /[\x00-\x1f\x7f]/;
    return bless {path => File::Spec->rel2abs($path), now => $args{now} || sub {time()}}, $class;
}
sub _channel {
    my ($channel) = @_;
    die 'invalid RandomQuote channel' unless defined($channel) && !ref($channel)
        && $channel =~ /\A#[^\x00-\x20\x7f,:]{1,79}\z/;
    return lc $channel;
}
sub _number {
    my ($value, $max) = @_;
    return defined($value) && !ref($value) && "$value" =~ /\A[0-9]{1,10}\z/ && $value <= $max;
}
sub _validate {
    my ($state) = @_;
    die 'invalid RandomQuote document' unless ref($state) eq 'HASH'
        && _number($state->{schema}, 1) && $state->{schema} == 1
        && ref($state->{channels}) eq 'HASH' && keys(%{$state->{channels}}) <= 1000;
    for my $key (keys %{$state->{channels}}) {
        die 'invalid RandomQuote channel key' unless _channel($key) eq $key;
        my $row = $state->{channels}{lc($key)};
        die 'invalid RandomQuote policy' unless ref($row) eq 'HASH'
            && _number($row->{interval}, 604800) && (!$row->{interval} || $row->{interval} >= 900)
            && _number($row->{next_at}, 9999999999)
            && _number($row->{revision}, 9999999999)
            && _number($row->{pending}, 1)
            && defined($row->{last_id}) && !ref($row->{last_id})
            && "$row->{last_id}" =~ /\A[0-9]{1,15}\z/;
    }
    return $state;
}
sub _safe_path {
    my ($path) = @_;
    my $current = File::Spec->rootdir;
    for my $part (File::Spec->splitdir($path)) {
        next unless length($part);
        $current = File::Spec->catfile($current, $part);
        die 'RandomQuote symlink refused' if -l $current;
    }
}
sub _locked {
    my ($self, $write, $cb) = @_;
    my $path = $self->{path};
    _safe_path($path); _safe_path("$path.lock");
    my $dir = dirname($path);
    die 'RandomQuote state missing while its lock exists' if !-e $path && -e "$path.lock";
    # A read of an unconfigured instance creates nothing.
    if (!$write && !-e $path && !-e "$path.lock") {
        my ($result) = $cb->({schema => 1, channels => {}});
        return $result;
    }
    mkdir($dir, 0700) or die 'cannot create RandomQuote directory' unless -d $dir;
    sysopen(my $lock, "$path.lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0600)
        or die 'cannot open RandomQuote lock';
    die 'RandomQuote lock is not a regular file' unless -f $lock;
    flock($lock, LOCK_EX | LOCK_NB) or die 'RandomQuote state is busy';
    chmod(0600, "$path.lock") or die 'cannot protect RandomQuote lock';
    my $state = {schema => 1, channels => {}};
    if (-e $path) {
        sysopen(my $fh, $path, O_RDONLY | O_NOFOLLOW) or die 'cannot read RandomQuote state';
        die 'RandomQuote state is not a regular file' unless -f $fh;
        die 'RandomQuote state too large' if -s $fh > 262144;
        local $/; my $raw = <$fh>; close $fh;
        $state = _validate(JSON::PP->new->utf8->decode($raw));
    }
    my ($result, $dirty) = $cb->($state);
    if ($dirty || ($write && !-e $path)) {
        _validate($state);
        my $bytes = JSON::PP->new->utf8->canonical->encode($state);
        die 'RandomQuote state too large' if length($bytes) > 262144;
        my ($fh, $tmp) = tempfile('.randomquote-XXXXXX', DIR => $dir, UNLINK => 0);
        my $ok = eval {
            chmod(0600, $tmp) or die 'cannot protect RandomQuote state';
            print {$fh} $bytes or die 'cannot write RandomQuote state';
            $fh->flush or die 'cannot flush RandomQuote state';
            $fh->sync or die 'cannot sync RandomQuote state';
            close($fh) or die 'cannot close RandomQuote state';
            rename($tmp, $path) or die 'cannot publish RandomQuote state';
            1;
        };
        my $err = $@; unlink $tmp if -e $tmp; die $err unless $ok;
    }
    close $lock; return $result;
}
sub _status {
    my ($self, $row, $default) = @_;
    die 'invalid RandomQuote default interval' unless _number($default, 604800) && $default >= 900;
    my $interval = $row && $row->{interval} ? $row->{interval} : $default;
    return {interval => $interval, custom => $row && $row->{interval} ? 1 : 0,
        next_at => $row ? $row->{next_at} : undef,
        wait => $row ? ($row->{next_at} > $self->{now}->() ? $row->{next_at} - $self->{now}->() : 0) : $interval,
        last_id => $row ? $row->{last_id} : 0,
        revision => $row ? $row->{revision} : 0};
}
sub status {
    my ($self, $channel, $default) = @_; my $key = _channel($channel);
    return $self->_locked(0, sub {return $self->_status($_[0]{channels}{lc($key)}, $default)});
}
sub configure {
    my ($self, $channel, $interval, $default) = @_; my $key = _channel($channel);
    die 'RandomQuote interval must be 0 or 900..604800 seconds'
        unless _number($interval,604800) && (!$interval || $interval >= 900);
    return $self->_locked(1, sub {
        my ($state) = @_; my $row = $state->{channels}{lc($key)};
        return ($self->_status($row,$default),0) if $row && $row->{interval} == $interval;
        $row ||= {last_id=>0,revision=>0};
        $row->{interval}=0+$interval; $row->{next_at}=int($self->{now}->())+($interval || $default);
        $row->{revision}++; $row->{pending}=0; $state->{channels}{lc($key)}=$row;
        return ($self->_status($row,$default),1);
    });
}
sub claim {
    my ($self,$channel,$default)=@_;my $key=_channel($channel);
    return $self->_locked(1,sub {
        my ($state)=@_;my $row=$state->{channels}{lc($key)};
        my $status=$self->_status($row,$default);my $now=int($self->{now}->());
        if (!$row) {
            $state->{channels}{lc($key)}={interval=>0,next_at=>$now+$status->{interval},revision=>0,pending=>0,last_id=>0};
            return (undef,1); # First joined observation waits a full interval.
        }
        return (undef,0) if $row->{next_at}>$now;
        $row->{next_at}=$now+$status->{interval};$row->{revision}++;$row->{pending}=1;
        return ($self->_status($row,$default),1); # One attempt, never catch up missed intervals.
    });
}
sub consume {
    my ($self,$channel,$revision)=@_;my $key=_channel($channel);
    return $self->_locked(1,sub {
        my ($state)=@_;my $row=$state->{channels}{lc($key)};
        return (0,0) unless $row && $row->{pending} && $row->{revision} == $revision;
        $row->{pending}=0;return (1,1);
    });
}
sub note_sent {
    my ($self,$channel,$revision,$id)=@_;my $key=_channel($channel);
    die 'invalid RandomQuote id' unless defined($id) && !ref($id) && "$id" =~ /\A[1-9][0-9]{0,14}\z/;
    return $self->_locked(1,sub {
        my ($state)=@_;my $row=$state->{channels}{lc($key)};
        return (0,0) unless $row && $row->{revision} == $revision;
        $row->{last_id}=0+$id;return (1,1);
    });
}
1;
