package Mediabot::Plugin::ChannelRepositoryV3;

use strict;
use warnings;
use utf8;
use Cwd qw(abs_path);
use Digest::SHA qw(sha256_hex);
use Encode qw(encode);
use Fcntl qw(:DEFAULT :flock);
use File::Spec;
use File::Basename qw(dirname);
use File::Temp qw(tempfile);
use JSON::PP ();

# The core supplies the directory, package and policy channel. Plugins never
# supply a path. This larger channel collection leaves the small legacy KV
# repository and all existing plugin documents unchanged.
our $MAX_VALUES = 1024;
our $MAX_BYTES = 2 * 1024 * 1024;

sub new {
    my ($class, %args) = @_;
    die "channel_storage_identity\n" unless ($args{plugin} // '') =~ /\A[a-z0-9][a-z0-9-]{0,47}\z/
        && defined($args{channel}) && !ref($args{channel}) && $args{channel} =~ /\A[#&+!][^\s\x00-\x1f\x7f]{1,127}\z/;
    my $channel = lc $args{channel}; $channel =~ tr/[]\\^/{}|~/;
    return bless { directory => $args{directory}, plugin => $args{plugin}, channel => $channel }, $class;
}

sub _directory {
    my ($self, $create) = @_;
    my $base = File::Spec->rel2abs($self->{directory});
    my @parts = File::Spec->splitdir($base);
    my $path = File::Spec->rootdir;
    for my $part (@parts) {
        next unless length $part;
        die "channel_storage_path\n" if $part eq '..';
        $path = File::Spec->catdir($path, $part);
        die "channel_storage_symlink\n" if -l $path;
    }
    my $dir = File::Spec->catdir($base, 'v3-collections', $self->{plugin});
    for my $p ($base, File::Spec->catdir($base, 'v3-collections'), $dir) {
        die "channel_storage_symlink\n" if -l $p;
        if (!-e $p) {
            return undef unless $create;
            mkdir $p, 0700 or die "channel_storage_directory\n";
        }
        die "channel_storage_directory\n" unless -d $p && (stat($p))[4] == $<;
    }
    return $dir;
}

sub _path {
    my ($self, $create) = @_;
    my $dir = $self->_directory($create) or return;
    return File::Spec->catfile($dir, sha256_hex(encode('UTF-8', $self->{channel})) . '.json');
}

sub _validate {
    my ($self, $doc) = @_;
    die "channel_storage_document\n" unless ref($doc) eq 'HASH'
        && ($doc->{plugin} // '') eq $self->{plugin} && ($doc->{channel} // '') eq $self->{channel}
        && defined($doc->{revision}) && !ref($doc->{revision}) && "$doc->{revision}" =~ /\A(?:0|[1-9][0-9]{0,14})\z/
        && ref($doc->{values}) eq 'HASH' && keys(%{$doc->{values}}) <= $MAX_VALUES;
    require Mediabot::Plugin::RepositoryV3;
    for my $key (keys %{$doc->{values}}) {
        die "channel_storage_key\n" unless Mediabot::Plugin::RepositoryV3::_valid_key($key);
        $doc->{values}{$key} = Mediabot::Plugin::RepositoryV3::_validate_value($doc->{values}{$key});
    }
    return $doc;
}

sub _read {
    my ($self, $path) = @_;
    return { plugin => $self->{plugin}, channel => $self->{channel}, revision => 0, values => {} }
        unless defined($path) && (-e $path || -l $path);
    die "channel_storage_symlink\n" if -l $path;
    sysopen my $fh, $path, O_RDONLY | O_NOFOLLOW or die "channel_storage_read\n";
    my @stat = stat($fh);
    die "channel_storage_permissions\n" unless -f $fh && $stat[4] == $< && !($stat[2] & 0077)
        && $stat[7] <= $MAX_BYTES;
    local $/; my $raw = <$fh>; close $fh;
    die "channel_storage_size\n" unless defined($raw) && length($raw) <= $MAX_BYTES;
    my $doc = eval { JSON::PP->new->utf8->decode($raw) };
    return $self->_validate($doc);
}

sub snapshot {
    my ($self) = @_;
    my $doc = $self->_read($self->_path(0));
    return { revision => $doc->{revision}, values => { %{$doc->{values}} } };
}

sub commit {
    my ($self, %args) = @_;
    die "channel_storage_revision\n" unless defined($args{expected_revision}) && !ref($args{expected_revision})
        && "$args{expected_revision}" =~ /\A(?:0|[1-9][0-9]{0,14})\z/;
    die "channel_storage_changes\n" unless ref($args{changes} // {}) eq 'HASH' && ref($args{delete} // []) eq 'ARRAY';
    require Mediabot::Plugin::RepositoryV3;
    my $path = $self->_path(1);
    sysopen my $lock, "$path.lock", O_RDWR | O_CREAT | O_NOFOLLOW, 0600 or die "channel_storage_lock\n";
    die "channel_storage_lock\n" unless -f $lock && (stat($lock))[4] == $< && !((stat($lock))[2] & 0077);
    return { ok => 0, error => 'busy' } unless flock($lock, LOCK_EX | LOCK_NB);
    my $doc = $self->_read($path);
    return { ok => 0, error => 'conflict', revision => $doc->{revision} }
        unless $args{expected_revision} == $doc->{revision};
    $doc->{values}{$_} = $args{changes}{$_} for keys %{$args{changes} // {}};
    for my $key (@{$args{delete} // []}) {
        die "channel_storage_key\n" unless Mediabot::Plugin::RepositoryV3::_valid_key($key);
        delete $doc->{values}{$key};
    }
    $doc->{revision}++;
    $self->_validate($doc);
    my $raw = JSON::PP->new->canonical->utf8->encode($doc);
    die "channel_storage_size\n" if length($raw) > $MAX_BYTES;
    my ($fh, $tmp) = tempfile('.commit-XXXXXXXX', DIR => dirname($path));
    my $ok = eval {
        chmod(0600, $tmp) or die "channel_storage_write\n";
        binmode $fh;
        print {$fh} $raw or die "channel_storage_write\n";
        close($fh) or die "channel_storage_write\n";
        die "channel_storage_symlink\n" if -l $path;
        rename($tmp, $path) or die "channel_storage_write\n";
        1;
    };
    unless ($ok) { my $err = $@; close $fh; unlink $tmp; die $err }
    return { ok => 1, revision => $doc->{revision} };
}

# Owner cleanup derives the package directory in the core. Keep lock files:
# removing a lock inode while another process holds it would break exclusion.
sub clear_plugin {
    my ($class, %args) = @_;
    my $self = $class->new(%args, channel => '#cleanup');
    my $dir = $self->_directory(0) or return 0;
    opendir my $dh, $dir or die "channel_storage_read\n";
    my @names = grep { $_ ne '.' && $_ ne '..' } readdir $dh;
    closedir $dh;
    my @locks;
    my @paths;
    for my $name (sort @names) {
        die "channel_storage_foreign_file\n" unless $name =~ /\A[a-f0-9]{64}\.json(?:\.lock)?\z/;
        my $path = File::Spec->catfile($dir, $name);
        die "channel_storage_symlink\n" if -l $path;
        die "channel_storage_permissions\n" unless -f $path && (stat($path))[4] == $<;
        next if $name =~ /\.lock\z/;
        sysopen my $lock, "$path.lock", O_RDWR | O_CREAT | O_NOFOLLOW, 0600 or die "channel_storage_lock\n";
        die "channel_storage_busy\n" unless flock($lock, LOCK_EX | LOCK_NB);
        push @locks, $lock; push @paths, $path;
    }
    my $removed = 0;
    for my $path (@paths) {
        unlink $path or die "channel_storage_clear\n";
        $removed++;
    }
    return $removed;
}

1;
