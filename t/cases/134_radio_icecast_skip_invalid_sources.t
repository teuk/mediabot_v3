# t/cases/134_radio_icecast_skip_invalid_sources.t
# =============================================================================
# Regression checks for Mediabot::Radio::Icecast source normalization.
#
# Icecast normally returns HASH or ARRAY data for icestats.source, but defensive
# code should not die if an ARRAY contains undef or non-HASH values.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

return sub {
    my ($assert) = @_;

    require Mediabot::Radio::Icecast;

    my $radio = Mediabot::Radio::Icecast->new(
        base_url => 'http://127.0.0.1:8000',
        timeout  => 1,
    );

    no warnings 'redefine';
    local *Mediabot::Radio::Icecast::_fetch_icestats = sub {
        return {
            ok       => 1,
            icestats => {
                source => [
                    {
                        listenurl => 'http://127.0.0.1:8000/radio160.mp3',
                        title     => 'Valid mount 160',
                        listeners => '4',
                    },
                    undef,
                    'not a hash',
                    [],
                    {
                        listenurl => 'http://127.0.0.1:8000/radio320.mp3',
                        title     => 'Valid mount 320',
                        listeners => '8',
                    },
                ],
            },
        };
    };

    my $mounts;
    my $error;

    eval {
        $mounts = $radio->get_mounts();
        1;
    } or do {
        $error = $@ || 'unknown error';
    };

    $assert->is(
        $error // '',
        '',
        'get_mounts does not die on non-HASH source entries'
    );

    $assert->ok(
        $mounts->{ok},
        'get_mounts still returns ok'
    );

    $assert->is(
        scalar @{ $mounts->{mounts} },
        2,
        'get_mounts keeps only valid HASH mount entries'
    );

    $assert->is(
        $mounts->{mounts}[0]{mount},
        '/radio160.mp3',
        'first valid mount is normalized'
    );

    $assert->is(
        $mounts->{mounts}[1]{mount},
        '/radio320.mp3',
        'second valid mount is normalized'
    );

    my $defensive = $radio->_normalize_mount('bad source');

    $assert->is(
        $defensive->{mount},
        '',
        '_normalize_mount returns an empty mount for non-HASH input'
    );

    $assert->is(
        $defensive->{title},
        '',
        '_normalize_mount returns an empty title for non-HASH input'
    );
};
