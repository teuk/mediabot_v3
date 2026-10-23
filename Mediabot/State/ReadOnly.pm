package Mediabot::State::ReadOnly;
use strict;
use warnings;
use Exporter 'import';
use Errno qw(ENOENT EWOULDBLOCK EAGAIN);
use Fcntl qw(:DEFAULT :flock :mode);
use File::Spec;
use JSON::PP;
our @EXPORT_OK = qw(read_json_snapshot);

# Observe the existing lock protocol without creating, repairing or chmodding
# anything. The existing writer lock is held briefly in shared mode; a busy
# writer is reported immediately instead of waiting in the event loop.
sub _fail { die "$_[0]\n" }
sub _stat {
    my ($path) = @_;
    my @s = lstat($path);
    return \@s if @s;
    return if $! == ENOENT;
    _fail('unreadable');
}
sub _safe_path {
    my ($path) = @_;
    _fail('unsafe_path') unless defined($path) && !ref($path)
        && File::Spec->file_name_is_absolute($path) && $path !~ /[\x00-\x1f\x7f]/;
    my $current = File::Spec->rootdir;
    for my $part (File::Spec->splitdir($path)) {
        next unless length($part);
        $current = File::Spec->catfile($current, $part);
        my $s = _stat($current);
        _fail('unsafe_path') if $s && S_ISLNK($s->[2]);
    }
}
sub _read {
    my ($path) = @_;
    _safe_path($path); _safe_path("$path.lock");
    my $state_stat = _stat($path);
    my $lock_stat = _stat("$path.lock");
    return {state => 'absent'} unless $state_stat || $lock_stat;
    _fail('missing_lock') unless $lock_stat;
    _fail('not_regular') unless S_ISREG($lock_stat->[2]);
    sysopen(my $lock, "$path.lock", O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        or _fail('unreadable');
    my @opened = stat($lock);
    _fail('changed') unless @opened && S_ISREG($opened[2])
        && $opened[0] == $lock_stat->[0] && $opened[1] == $lock_stat->[1];
    unless (flock($lock, LOCK_SH | LOCK_NB)) {
        _fail($! == EWOULDBLOCK || $! == EAGAIN ? 'busy' : 'unreadable');
    }
    my $current = _stat("$path.lock");
    _fail('changed') unless $current && $current->[0] == $opened[0] && $current->[1] == $opened[1];
    _fail('missing_state') unless _stat($path);
    sysopen(my $fh, $path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        or _fail('unreadable');
    my @file = stat($fh);
    _fail('not_regular') unless @file && S_ISREG($file[2]);
    _fail('too_large') if $file[7] > 262144;
    my $raw = '';
    while (1) {
        my $n = sysread($fh, my $chunk, 262145 - length($raw));
        _fail('unreadable') unless defined $n;
        last unless $n;
        $raw .= $chunk;
        _fail('too_large') if length($raw) > 262144;
    }
    close($fh) or _fail('unreadable');
    my $document = eval { JSON::PP->new->utf8->decode($raw) };
    _fail('invalid_json') if $@ || ref($document) ne 'HASH';
    close($lock) or _fail('unreadable');
    return {state => 'fresh', document => $document, file_modified_at => $file[9]};
}
sub read_json_snapshot {
    my ($path) = @_;
    my $result = eval { _read($path) };
    return $result if $result;
    my $reason = $@;
    $reason =~ s/\n\z//;
    $reason = 'unreadable' unless $reason =~ /\A(?:unsafe_path|unreadable|missing_lock|missing_state|not_regular|changed|busy|too_large|invalid_json)\z/;
    return {state => $reason eq 'busy' ? 'busy'
        : $reason eq 'too_large' || $reason eq 'invalid_json' ? 'invalid' : 'unavailable', reason => $reason};
}
1;
