package Mediabot::Version::Format;

use strict;
use warnings;
use utf8;
use Exporter 'import';

our @EXPORT_OK = qw(
    _usable_local_version
    _version_parts
    _compare_digit_strings
    _compare_mediabot_versions
    getDetailedVersion
);

# Mediabot's historical stable/development grammar and ordering, without I/O.
# Preserve Helpers overrides at call time when that compatibility API is loaded.
# getDetailedVersion retains its historical ($self, $version) signature.

sub _usable_local_version {
    my ($value) = @_;

    return undef unless defined($value) && !ref($value);

    $value = "$value";
    $value =~ s/^\s+|\s+$//g;

    return undef if $value eq '' || lc($value) eq 'undefined';
    return $value;
}

sub _version_parts {
    my ($value) = @_;
    $value = defined &Mediabot::Helpers::_usable_local_version
        ? Mediabot::Helpers::_usable_local_version($value)
        : _usable_local_version($value);
    return undef unless defined $value;

    if ($value =~ /\A(\d+)\.(\d+)\z/) {
        return {
            major => 0 + $1,
            minor => 0 + $2,
            stage => 1,       # stable is newer than devel at the same base
            type  => 'stable',
            dev   => undef,
        };
    }

    if ($value =~ /\A(\d+)\.(\d+)dev[-_]?(\d[\d_]*)\z/) {
        my ($major, $minor, $dev) = ($1, $2, $3);
        $dev =~ s/_//g;
        $dev =~ s/\A0+(?=\d)//;

        return {
            major => 0 + $major,
            minor => 0 + $minor,
            stage => 0,
            type  => 'devel',
            dev   => $dev,
        };
    }

    return undef;
}

sub _compare_digit_strings {
    my ($left, $right) = @_;
    $left  = '0' unless defined($left)  && $left  ne '';
    $right = '0' unless defined($right) && $right ne '';

    return length($left) <=> length($right)
        if length($left) != length($right);
    return $left cmp $right;
}

sub _compare_mediabot_versions {
    my ($left, $right) = @_;

    my $l = defined &Mediabot::Helpers::_version_parts
        ? Mediabot::Helpers::_version_parts($left)
        : _version_parts($left);
    my $r = defined &Mediabot::Helpers::_version_parts
        ? Mediabot::Helpers::_version_parts($right)
        : _version_parts($right);
    return undef unless $l && $r;

    return $l->{major} <=> $r->{major} if $l->{major} != $r->{major};
    return $l->{minor} <=> $r->{minor} if $l->{minor} != $r->{minor};
    return $l->{stage} <=> $r->{stage} if $l->{stage} != $r->{stage};

    return 0 if $l->{stage} == 1;
    return defined &Mediabot::Helpers::_compare_digit_strings
        ? Mediabot::Helpers::_compare_digit_strings($l->{dev}, $r->{dev})
        : _compare_digit_strings($l->{dev}, $r->{dev});
}

sub getDetailedVersion {
    my ($self, $version_string) = @_;

    my $parts = defined &Mediabot::Helpers::_version_parts
        ? Mediabot::Helpers::_version_parts($version_string)
        : _version_parts($version_string);
    return (undef, undef, undef, undef) unless $parts;

    return (
        $parts->{major},
        $parts->{minor},
        $parts->{type},
        $parts->{dev},
    );
}

1;
