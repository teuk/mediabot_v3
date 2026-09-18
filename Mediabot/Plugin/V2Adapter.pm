package Mediabot::Plugin::V2Adapter;

use strict;
use warnings;
use utf8;

use JSON::PP ();

sub describe_entry {
    my ($class, $entry) = @_;
    die "V2Adapter: plugin entry must be a HASH\n"
        unless ref($entry) eq 'HASH';
    my $api = ref($entry->{metadata}) eq 'HASH'
        ? ($entry->{metadata}{api} // 1) : 1;
    die "V2Adapter: only API v1/v2 entries may be described\n"
        unless $api == 1 || $api == 2;

    my $manifest = ref($entry->{manifest}) eq 'HASH'
        ? $entry->{manifest} : {};
    return {
        compatibility => 'v2-runtime-unchanged',
        api           => $api,
        name          => $entry->{name},
        version       => $entry->{version},
        enabled       => $entry->{enabled} ? JSON::PP::true : JSON::PP::false,
        commands      => ref($manifest->{commands}) eq 'HASH'
            ? [ sort keys %{ $manifest->{commands} } ] : [],
        events        => ref($manifest->{events}) eq 'ARRAY'
            ? [ @{ $manifest->{events} } ] : [],
    };
}

1;
