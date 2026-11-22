package Mediabot::Plugin::WorkshopFixture;

use strict;
use warnings;
use JSON::PP ();

sub read_steps {
    my ($path, %limits) = @_;
    open my $handle, '<:raw', $path or die "Cannot read test fixture '$path': $!\n";
    my $bytes;
    if (my $max = $limits{max_bytes}) {
        my $read = read($handle, $bytes, $max + 1);
        die "Cannot read test fixture '$path': $!\n" unless defined $read;
        die "Test fixture exceeds $max bytes\n" if $read > $max;
    } else {
        local $/;
        $bytes = <$handle>;
    }
    close $handle or die "Cannot close test fixture '$path': $!\n";
    my $fixture = eval { JSON::PP->new->utf8->decode($bytes) };
    die "Test fixture must be a JSON object with a non-empty steps array\n"
        unless ref($fixture) eq 'HASH' && ref($fixture->{steps}) eq 'ARRAY'
            && @{ $fixture->{steps} };
    if (my $max = $limits{max_steps}) {
        die "Test fixture must contain at most $max steps\n" if @{ $fixture->{steps} } > $max;
    }
    return $fixture->{steps};
}

sub assert_replies {
    my ($step, $expected, $actual) = @_;
    my $json = JSON::PP->new->canonical->ascii;
    my $want = $json->encode($expected);
    my $got = $json->encode($actual);
    die "Step $step reply mismatch\nExpected: $want\nCaptured: $got\n" unless $got eq $want;
    return;
}

1;
