package Mediabot::Version::Local;

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Basename qw(dirname);
use File::Spec;
use Mediabot::Version::Format ();

# Standalone users anchor the source tree when this component loads. Helpers
# supplies its own historical anchor, preserving symlink and load-time behavior.
my $SOURCE_FILE = abs_path(__FILE__) || File::Spec->rel2abs(__FILE__);
my $LOCAL_VERSION_FILE = File::Spec->catfile(dirname(dirname(dirname($SOURCE_FILE))), 'VERSION');

sub cached {
    my ($self, $normalize) = @_;
    $normalize ||= \&Mediabot::Version::Format::_usable_local_version;
    return 'Undefined' unless ref($self);
    return $normalize->($self->{main_prog_version}) // 'Undefined';
}

sub read {
    my ($self, $path, $normalize) = @_;
    $path //= $LOCAL_VERSION_FILE;
    $normalize ||= \&Mediabot::Version::Format::_usable_local_version;
    if (open my $fh, '<', $path) {
        my $value = <$fh>;
        close $fh;
        return $normalize->($value) // 'Undefined';
    }
    $self->{logger}->log(1, "Unable to read local VERSION file '$path': $!")
        if $self && $self->{logger};
    return 'Undefined';
}

sub getLocalVersion {
    my ($self, $path, %hooks) = @_;
    $path //= $LOCAL_VERSION_FILE;
    my $normalize = $hooks{normalize} || \&Mediabot::Version::Format::_usable_local_version;
    $self->{logger}->log(1, "Reading local version from $path...")
        if $self && $self->{logger};
    my $local_version = $hooks{read} ? $hooks{read}->($self)
        : Mediabot::Version::Local::read($self, $path, $normalize);
    my $usable = $normalize->($local_version)
        // $normalize->($self->{main_prog_version});
    if (defined $usable) {
        $self->{main_prog_version} = $usable if ref($self);
        return $usable;
    }
    return 'Undefined';
}

1;
