# t/cases/135_radio_icecast_timeout_sanitizing.t
# =============================================================================
# Regression checks for Mediabot::Radio::Icecast timeout sanitizing.
#
# IRC commands should not be able to hang for a ridiculous amount of time
# because of a bad RADIO_ICECAST_TIMEOUT value.
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

    my $default = Mediabot::Radio::Icecast->new(
        base_url => 'http://127.0.0.1:8000',
    );

    $assert->is(
        $default->{timeout},
        5,
        'default timeout is 5 seconds'
    );

    my $explicit = Mediabot::Radio::Icecast->new(
        base_url => 'http://127.0.0.1:8000',
        timeout  => 7,
    );

    $assert->is(
        $explicit->{timeout},
        7,
        'explicit integer timeout is preserved'
    );

    my $trimmed = Mediabot::Radio::Icecast->new(
        base_url => 'http://127.0.0.1:8000',
        timeout  => ' 8 ',
    );

    $assert->is(
        $trimmed->{timeout},
        8,
        'timeout trims surrounding whitespace'
    );

    my $decimal = Mediabot::Radio::Icecast->new(
        base_url => 'http://127.0.0.1:8000',
        timeout  => '2.5',
    );

    $assert->is(
        $decimal->{timeout},
        '2.5',
        'positive decimal timeout is accepted'
    );

    my $zero = Mediabot::Radio::Icecast->new(
        base_url => 'http://127.0.0.1:8000',
        timeout  => 0,
    );

    $assert->is(
        $zero->{timeout},
        5,
        'zero timeout falls back to default'
    );

    my $bad = Mediabot::Radio::Icecast->new(
        base_url => 'http://127.0.0.1:8000',
        timeout  => 'abc',
    );

    $assert->is(
        $bad->{timeout},
        5,
        'non-numeric timeout falls back to default'
    );

    my $tiny = Mediabot::Radio::Icecast->new(
        base_url => 'http://127.0.0.1:8000',
        timeout  => '0.5',
    );

    $assert->is(
        $tiny->{timeout},
        1,
        'timeout lower than 1 is clamped to 1'
    );

    my $huge = Mediabot::Radio::Icecast->new(
        base_url => 'http://127.0.0.1:8000',
        timeout  => 999999,
    );

    $assert->is(
        $huge->{timeout},
        30,
        'huge timeout is clamped to 30 seconds'
    );

    my $negative = Mediabot::Radio::Icecast->new(
        base_url => 'http://127.0.0.1:8000',
        timeout  => -1,
    );

    $assert->is(
        $negative->{timeout},
        5,
        'negative timeout falls back to default'
    );
};
