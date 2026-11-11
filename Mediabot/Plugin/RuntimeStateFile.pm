package Mediabot::Plugin::RuntimeStateFile;

use strict;
use warnings;
use Fcntl qw(O_CREAT O_EXCL O_WRONLY);
use JSON::PP ();

# Core-owned file persistence only. The manager supplies the path resolver,
# size bound and document validator; no plugin lifecycle or authority lives here.
# Resolve paths lazily to retain encoding/size failures before directory creation.
sub store {
    my ($document, %args) = @_;
    # Raw files need byte JSON. ASCII escapes preserve Unicode with the
    # historical reader and make the existing byte limit count written bytes.
    my $json = eval { JSON::PP->new->canonical->ascii->encode($document) };
    return (0, 'API v3 state is not JSON-serializable') unless defined $json;
    return (0, 'API v3 state exceeds the byte limit')
        if length($json) > $args{max_bytes};

    my ($path, $path_error) = $args{path}->(create => 1);
    return (0, $path_error) unless defined $path;
    return (0, 'API v3 state path is a symlink') if -l $path;

    my $temporary = "$path.tmp.$$";
    sysopen my $fh, $temporary, O_WRONLY | O_CREAT | O_EXCL, 0600
        or return (0, "cannot write API v3 state: $!");
    binmode $fh, ':raw';
    unless (chmod 0600, $temporary) {
        my $error = $!;
        close $fh;
        unlink $temporary;
        return (0, "cannot protect API v3 state: $error");
    }
    unless (print {$fh} $json) {
        my $error = $!;
        close $fh;
        unlink $temporary;
        return (0, "cannot write API v3 state: $error");
    }
    close $fh or do {
        my $error = $!;
        unlink $temporary;
        return (0, "cannot close API v3 state: $error");
    };
    rename $temporary, $path or do {
        my $error = $!;
        unlink $temporary;
        return (0, "cannot publish API v3 state: $error");
    };
    return (1, undef);
}

sub read {
    my (%args) = @_;
    my ($path, $path_error) = $args{path}->();
    return (undef, $path_error, 0)
        if defined($path_error) && length($path_error);
    return (undef, undef, 1) unless defined($path) && -e $path;
    return (undef, 'API v3 state path is not a regular file', 0)
        unless -f $path && !-l $path;
    return (undef, 'API v3 state exceeds the byte limit', 0)
        if (-s $path) > $args{max_bytes};

    open my $fh, '<:raw', $path
        or return (undef, "cannot read API v3 state: $!", 0);
    local $/;
    my $raw = <$fh>;
    close $fh;
    return (undef, 'API v3 state exceeds the byte limit', 0)
        unless defined($raw) && length($raw) <= $args{max_bytes};
    my $document = eval { JSON::PP->new->decode($raw) };
    return (undef, 'API v3 state is not valid JSON', 0)
        unless $document;
    my ($valid, $why) = $args{validate}->($document);
    return (undef, "invalid API v3 state: $why", 0) unless $valid;
    return ($document, undef, 0);
}

1;
