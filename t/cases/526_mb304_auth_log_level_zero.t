# t/cases/526_mb304_auth_log_level_zero.t
# =============================================================================
# MB304: authentication errors logged at level 0 must remain level 0.
# `||=` treats numeric zero as false and previously promoted those messages to
# DEBUG3, making important authentication failures disappear at normal levels.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use Mediabot::Auth;

{
    package MB304::CaptureLogger;

    sub new {
        return bless { entries => [] }, shift;
    }

    sub log {
        my ($self, $level, $message) = @_;
        push @{ $self->{entries} }, {
            level   => $level,
            message => $message,
        };
        return 1;
    }
}

return sub {
    my ($assert) = @_;

    my $logger = MB304::CaptureLogger->new;
    my $auth   = Mediabot::Auth->new(logger => $logger, dbh => undef);

    $auth->_log(0, 'level-zero-auth-error');
    $auth->_log(undef, 'default-auth-debug');

    $assert->is(
        scalar @{ $logger->{entries} },
        2,
        'Auth logger captured both messages'
    );

    $assert->is(
        $logger->{entries}[0]{level},
        0,
        'explicit authentication level 0 is preserved'
    );

    $assert->is(
        $logger->{entries}[0]{message},
        'level-zero-auth-error',
        'level-zero authentication message is preserved'
    );

    $assert->is(
        $logger->{entries}[1]{level},
        3,
        'undefined authentication level still defaults to DEBUG3'
    );

    $assert->ok(
        !$auth->verify_credentials(1, 'teuk', 'anything'),
        'credential verification still fails closed without a DB handle'
    );

    $assert->is(
        $logger->{entries}[-1]{level},
        0,
        'real no-database authentication failure is logged at level 0'
    );

    $assert->like(
        $logger->{entries}[-1]{message},
        qr/no database handle/,
        'real authentication failure keeps its diagnostic message'
    );
};
