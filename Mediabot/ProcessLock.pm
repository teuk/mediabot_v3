package Mediabot::ProcessLock;

use strict;
use warnings;
use Fcntl qw(O_RDWR O_CREAT LOCK_EX LOCK_NB SEEK_SET);

sub new {
    my ($class, %args) = @_;
    return bless {
        path  => $args{path},
        pid   => defined $args{pid} ? $args{pid} : $$,
        fh    => undef,
        error => undef,
    }, $class;
}

sub error { return $_[0]->{error}; }
sub path  { return $_[0]->{path}; }
sub pid   { return $_[0]->{pid}; }

sub _read_pid_from_fh {
    my ($fh) = @_;
    return undef unless defined sysseek($fh, 0, SEEK_SET);

    my $buffer = '';
    my $read = sysread($fh, $buffer, 64);
    return undef unless defined $read;

    $buffer =~ s/\s+\z//;
    return $buffer;
}

sub _path_matches_handle {
    my ($path,$fh,$entry)=@_;
    return 0 unless ref($entry) eq 'ARRAY' && @$entry==2;
    my @current=lstat($path);
    my @held=stat($fh);
    my @target=stat($path);
    return @current && @held && @target
        && $current[0]==$entry->[0] && $current[1]==$entry->[1]
        && $target[0]==$held[0] && $target[1]==$held[1] ? 1:0;
}

sub acquire {
    my ($self) = @_;
    return 1 if $self->{fh};

    my $path = $self->{path};
    unless (defined $path && $path ne '') {
        $self->{error} = 'PID file path is not configured';
        return 0;
    }

    sysopen(my $fh, $path, O_RDWR | O_CREAT, 0644) or do {
        $self->{error} = "cannot open PID file '$path': $!";
        return 0;
    };
    my @entry=lstat($path);
    my $identity=@entry ? [@entry[0,1]] : undef;
    unless (_path_matches_handle($path,$fh,$identity)) {
        $self->{error} = 'PID file path changed while opening';
        close $fh;
        return 0;
    }

    unless (flock($fh, LOCK_EX | LOCK_NB)) {
        my $owner = _read_pid_from_fh($fh);
        $owner = '' unless defined $owner;
        $owner =~ s/\s+\z//;
        $owner = 'unknown' unless $owner =~ /^\d+$/;
        $self->{error} = "PID file is locked by process $owner";
        close $fh;
        return 0;
    }

    # Compatibility with a legacy process that wrote a PID but did not retain
    # an advisory lock.  A live PID must still block the new process.
    my $existing = _read_pid_from_fh($fh);
    $existing = '' unless defined $existing;
    $existing =~ s/\s+\z//;
    if ($existing =~ /^\d+$/ && $existing != $self->{pid}) {
        my $alive = kill 0, $existing;
        $alive = 1 if !$alive && $!{EPERM};
        if ($alive) {
            $self->{error} = "PID file belongs to live process $existing";
            close $fh;
            return 0;
        }
    }

    defined sysseek($fh, 0, SEEK_SET) or do {
        $self->{error} = "cannot seek PID file '$path': $!";
        close $fh;
        return 0;
    };
    truncate($fh, 0) or do {
        $self->{error} = "cannot truncate PID file '$path': $!";
        close $fh;
        return 0;
    };
    my $payload = $self->{pid} . "\n";
    my $written = syswrite($fh, $payload);
    unless (defined $written && $written == length($payload)) {
        $self->{error} = "cannot write PID file '$path': $!";
        close $fh;
        return 0;
    }
    chmod 0644, $fh;
    unless (_path_matches_handle($path,$fh,$identity)) {
        $self->{error} = 'PID file path changed while acquiring';
        close $fh;
        return 0;
    }

    $self->{fh}    = $fh;
    $self->{path_entry} = $identity;
    $self->{error} = undef;
    return 1;
}

sub release {
    my ($self) = @_;
    my $fh = delete $self->{fh};
    my $entry = delete $self->{path_entry};
    return 1 unless $fh;

    my $path  = $self->{path};
    my $owned = 0;

    if (defined $path && $path ne '') {
        my $stored = _read_pid_from_fh($fh);
        $stored = '' unless defined $stored;
        $stored =~ s/\s+\z//;
        $owned = 1 if $stored =~ /^\d+$/ && $stored == $self->{pid};
    }

    if ($owned) {
        my @current=lstat($path);
        if (@current) {
            # The descriptor may still contain our PID after an operator or
            # replacement process has published a different directory entry.
            unless (_path_matches_handle($path,$fh,$entry)) {
                $self->{error} = 'PID file path changed; replacement retained';
                close $fh;
                return 0;
            }
            if (!unlink($path)) {
                $self->{error} = "cannot remove PID file '$path': $!";
                close $fh;
                return 0;
            }
        }
    }

    close $fh;
    $self->{error} = undef;
    return 1;
}

1;
