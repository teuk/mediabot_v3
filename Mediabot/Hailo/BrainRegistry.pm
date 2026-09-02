package Mediabot::Hailo::BrainRegistry;

use strict;
use warnings;

use Carp qw(croak);
use Digest::SHA qw(sha256_hex);
use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Spec;

our $VERSION = '1.0';

sub _plain_scalar {
    my ($value) = @_;
    return defined($value) && !ref($value);
}

sub _safe_network {
    my ($network) = @_;
    croak 'network must be a non-empty scalar string'
        unless _plain_scalar($network) && length("$network");
    croak 'network contains control characters'
        if "$network" =~ /[\x00-\x1f\x7f]/;
    return lc "$network";
}

sub _channel_key {
    my ($channel) = @_;
    croak 'channel must be a public IRC channel'
        unless _plain_scalar($channel)
            && "$channel" =~ /^[#&+!][^\s,\x00-\x1f\x7f]{1,79}\z/;

    my $key = "$channel";
    $key =~ tr/A-Z[]\\^/a-z{}|~/;
    return $key;
}

sub _positive_int {
    my ($value, $default, $max) = @_;
    return $default unless _plain_scalar($value) && "$value" =~ /^\d+\z/;
    $value = int($value);
    return $default if $value < 1;
    return $max if $value > $max;
    return $value;
}

sub new {
    my ($class, %args) = @_;

    my $root = $args{root};
    croak 'root must be a non-empty scalar path'
        unless _plain_scalar($root) && length("$root");
    croak 'root contains a NUL byte' if "$root" =~ /\x00/;

    my $factory = $args{factory};
    croak 'factory must be a code reference' unless ref($factory) eq 'CODE';

    my $self = bless {
        root         => File::Spec->canonpath("$root"),
        network      => _safe_network($args{network}),
        legacy_brain => $args{legacy_brain},
        max_open     => _positive_int($args{max_open}, 32, 256),
        factory      => $factory,
        logger       => $args{logger},
        brains       => {},
        sequence     => 0,
        seeded       => 0,
    }, $class;

    $self->_prepare_root;
    return $self;
}

sub _log {
    my ($self, $level, $message) = @_;
    my $logger = $self->{logger};
    return unless $logger && eval { $logger->can('log') };
    eval { $logger->log($level, $message) };
}

sub _prepare_root {
    my ($self) = @_;
    my $root = $self->{root};

    croak "Hailo brain root must not be a symbolic link: $root" if -l $root;
    if (!-e $root) {
        make_path($root, { mode => 0700 });
    }
    croak "Hailo brain root is not a directory: $root" unless -d $root;
    croak "Hailo brain root must not be a symbolic link: $root" if -l $root;
    chmod 0700, $root or croak "cannot protect Hailo brain root $root: $!";
    return 1;
}

sub canonical_channel {
    my ($self, $channel) = @_;
    croak 'registry object is required' unless ref($self);
    return _channel_key($channel);
}

sub brain_id_for {
    my ($self, $channel) = @_;
    croak 'registry object is required' unless ref($self);
    my $key = _channel_key($channel);
    return sha256_hex(join "\x00", $self->{network}, $key);
}

sub brain_path_for {
    my ($self, $channel) = @_;
    my $id = $self->brain_id_for($channel);
    return File::Spec->catfile($self->{root}, "$id.brn");
}

sub _copy_legacy_seed {
    my ($self, $target) = @_;
    my $source = $self->{legacy_brain};
    return 0 unless _plain_scalar($source) && length("$source");
    return 0 unless -f $source && !-l $source;
    return 0 if -e $target || -l $target;

    my $tmp = "$target.seed.$$.$self->{sequence}";
    croak "refusing pre-existing Hailo seed path: $tmp" if -e $tmp || -l $tmp;

    my $old_umask = umask 0077;
    my $ok = eval {
        copy($source, $tmp) or die "copy failed: $!";
        chmod 0600, $tmp or die "chmod failed: $!";
        rename($tmp, $target) or die "rename failed: $!";
        1;
    };
    my $error = $@;
    umask $old_umask;
    unlink $tmp if -e $tmp && !-l $tmp;
    croak "cannot seed per-channel Hailo brain: $error" unless $ok;

    $self->{seeded}++;
    return 1;
}

sub _save_entry {
    my ($self, $entry) = @_;
    return 1 unless $entry && $entry->{brain};

    my $brain = $entry->{brain};
    my $ok = eval {
        $brain->save if $brain->can('save');
        1;
    };
    if (!$ok) {
        my $error = $@ || 'unknown Hailo save error';
        $error =~ s/[\r\n]+/ /g;
        $self->_log(1, "Hailo per-channel brain save failed: $error");
        return 0;
    }

    chmod 0600, $entry->{path} if -f $entry->{path} && !-l $entry->{path};
    return 1;
}

sub _evict_one {
    my ($self) = @_;
    return 1 if keys(%{ $self->{brains} }) < $self->{max_open};

    my ($oldest_key) = sort {
        $self->{brains}{$a}{used} <=> $self->{brains}{$b}{used}
    } keys %{ $self->{brains} };

    my $entry = $self->{brains}{$oldest_key};
    return 0 unless $self->_save_entry($entry);
    delete $self->{brains}{$oldest_key};
    return 1;
}

sub brain_for {
    my ($self, $channel) = @_;
    croak 'registry object is required' unless ref($self);

    my $key = _channel_key($channel);
    if (my $entry = $self->{brains}{$key}) {
        $entry->{used} = ++$self->{sequence};
        return $entry->{brain};
    }

    croak 'cannot evict a per-channel Hailo brain safely'
        unless $self->_evict_one;
    my $path = $self->brain_path_for($channel);
    croak "Hailo brain path must not be a symbolic link: $path" if -l $path;
    croak "Hailo brain path is not a regular file: $path" if -e $path && !-f $path;

    $self->_copy_legacy_seed($path);

    my $old_umask = umask 0077;
    my $brain = eval { $self->{factory}->($path, $channel, $key) };
    my $error = $@;
    umask $old_umask;
    croak "cannot open per-channel Hailo brain: $error" if $error || !$brain;

    chmod 0600, $path if -f $path && !-l $path;
    $self->{brains}{$key} = {
        brain   => $brain,
        path    => $path,
        channel => "$channel",
        used    => ++$self->{sequence},
    };
    return $brain;
}

sub save_all {
    my ($self) = @_;
    croak 'registry object is required' unless ref($self);

    my $ok = 1;
    for my $key (sort keys %{ $self->{brains} }) {
        $ok = 0 unless $self->_save_entry($self->{brains}{$key});
    }
    return $ok;
}

sub stats {
    my ($self) = @_;
    croak 'registry object is required' unless ref($self);
    return {
        open_brains  => scalar(keys %{ $self->{brains} }),
        seeded_brains => int($self->{seeded}),
        max_open     => int($self->{max_open}),
    };
}

1;
