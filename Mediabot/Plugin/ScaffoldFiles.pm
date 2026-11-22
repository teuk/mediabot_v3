package Mediabot::Plugin::ScaffoldFiles;

use strict;
use warnings;
use Fcntl qw(O_WRONLY O_CREAT O_EXCL);
use File::Path qw(remove_tree);
use File::Spec;

sub write_package {
    my ($parent, $name, $files, @directories) = @_;
    die "Existing directory required\n"
        unless defined($parent) && !ref($parent) && -d $parent;
    $parent = File::Spec->rel2abs($parent);
    my $walk = File::Spec->rootdir;
    for my $part (File::Spec->splitdir($parent)) {
        next unless length($part);
        die "Unsafe parent path\n" if $part eq '..';
        $walk = File::Spec->catdir($walk, $part);
        die "Symlink parent refused\n" if -l $walk;
    }

    my $destination = File::Spec->catdir($parent, $name);
    # The exclusive mkdir makes a pre-existing package a refusal, not a merge.
    mkdir($destination, 0700) or die "Destination exists or cannot be created\n";
    my $created = eval {
        for my $directory (@directories) {
            mkdir(File::Spec->catdir($destination, $directory), 0755) or die $!;
        }
        for my $relative (sort keys %$files) {
            my $file = File::Spec->catfile($destination, $relative);
            sysopen(my $handle, $file, O_WRONLY | O_CREAT | O_EXCL, 0600) or die $!;
            print {$handle} $files->{$relative} or die $!;
            close($handle) or die $!;
            chmod(0644, $file) or die $!;
        }
        chmod(0755, $destination) or die $!;
        1;
    };
    unless ($created) {
        remove_tree($destination);
        die "Package creation failed\n";
    }
    return $destination;
}

1;
