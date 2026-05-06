# t/cases/133_radio_icecast_num_parsing.t
# =============================================================================
# Regression checks for Mediabot::Radio::Icecast numeric parsing.
#
# Icecast JSON values can be strings or numbers, and some fields may appear as
# decimal-looking values. _num() should not turn harmless numeric values into 0.
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

    $assert->is(
        Mediabot::Radio::Icecast::_num(undef),
        0,
        '_num undef returns 0'
    );

    $assert->is(
        Mediabot::Radio::Icecast::_num(''),
        0,
        '_num empty string returns 0'
    );

    $assert->is(
        Mediabot::Radio::Icecast::_num('42'),
        42,
        '_num parses integer strings'
    );

    $assert->is(
        Mediabot::Radio::Icecast::_num(42),
        42,
        '_num parses numeric scalars'
    );

    $assert->is(
        Mediabot::Radio::Icecast::_num(' 42 '),
        42,
        '_num trims surrounding whitespace'
    );

    $assert->is(
        Mediabot::Radio::Icecast::_num('128.9'),
        128,
        '_num accepts decimal numeric strings and truncates with int()'
    );

    $assert->is(
        Mediabot::Radio::Icecast::_num('44,100'),
        44100,
        '_num accepts simple comma-separated numeric strings'
    );

    $assert->is(
        Mediabot::Radio::Icecast::_num('-1'),
        0,
        '_num rejects negative values'
    );

    $assert->is(
        Mediabot::Radio::Icecast::_num('12abc'),
        0,
        '_num rejects non-numeric values'
    );
};
