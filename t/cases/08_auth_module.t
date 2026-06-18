# t/cases/08_auth_module.t
# =============================================================================
# Current Mediabot::Auth contract checks.
#
# Password verification and hostmask/cloak autologin are deliberately separate:
# - verify_credentials() validates a stored password only;
# - maybe_autologin() handles #AUTOLOGIN# after hostmask/cloak validation.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use Mediabot::Auth;
use Mediabot::Log;

{
    package MB300::AuthStmt;

    sub new {
        my ($class, %args) = @_;
        return bless {
            row          => $args{row},
            execute_ok   => exists $args{execute_ok} ? $args{execute_ok} : 1,
            rows         => exists $args{rows} ? $args{rows} : 1,
            execute_args => [],
            finished     => 0,
        }, $class;
    }

    sub execute {
        my ($self, @args) = @_;
        $self->{execute_args} = \@args;
        return $self->{execute_ok};
    }

    sub fetchrow_hashref { return $_[0]{row}; }
    sub rows             { return $_[0]{rows}; }
    sub finish           { $_[0]{finished} = 1; return 1; }
}

{
    package MB300::AuthDBH;

    sub new {
        my ($class, %args) = @_;
        return bless {
            select_row    => $args{select_row},
            prepared_sql  => [],
            statements    => [],
        }, $class;
    }

    sub prepare {
        my ($self, $sql) = @_;
        push @{ $self->{prepared_sql} }, $sql;

        my $stmt = MB300::AuthStmt->new(
            row  => ($sql =~ /^SELECT\b/i ? $self->{select_row} : undef),
            rows => 1,
        );
        push @{ $self->{statements} }, $stmt;
        return $stmt;
    }
}

return sub {
    my ($assert) = @_;

    my $logger = Mediabot::Log->new(debug_level => -1);

    my $no_db = Mediabot::Auth->new(logger => $logger, dbh => undef);
    $assert->ok($no_db, 'Mediabot::Auth object can be created without DB handle');
    $assert->ok($no_db->can('verify_credentials'), 'Auth exposes verify_credentials');
    $assert->ok($no_db->can('maybe_autologin'), 'Auth exposes maybe_autologin');

    $assert->ok(
        !$no_db->verify_credentials(1, 'teuk', 'anything'),
        'verify_credentials fails closed without a database handle'
    );

    my ($no_auto, $no_auto_reason) = $no_db->maybe_autologin(
        { id_user => 1, nickname => 'teuk' },
        'teuk!ident@trusted.example',
    );
    $assert->ok(!$no_auto, 'maybe_autologin fails closed without a database handle');
    $assert->is($no_auto_reason, 'no_dbh', 'missing DB handle returns explicit autologin reason');

    my $password_db = MB300::AuthDBH->new(
        select_row => {
            id_user => 7,
            nickname => 'teuk',
            password => 'correct-horse',
        },
    );
    my $password_auth = Mediabot::Auth->new(logger => $logger, dbh => $password_db);

    $assert->ok(
        $password_auth->verify_credentials(7, 'teuk', 'correct-horse'),
        'verify_credentials accepts the correct stored plaintext password'
    );
    $assert->ok(
        !$password_auth->verify_credentials(7, 'teuk', 'wrong-password'),
        'verify_credentials rejects an incorrect password'
    );

    my $autologin_db = MB300::AuthDBH->new();
    my $autologin_auth = Mediabot::Auth->new(logger => $logger, dbh => $autologin_db);

    {
        no warnings 'redefine';
        local *Mediabot::Auth::_resolve_user = sub {
            return ({
                id_user  => 42,
                nickname => 'TeuK',
                username => '#AUTOLOGIN#',
                auth     => 0,
            }, undef);
        };
        local *Mediabot::Auth::hostmask_matches = sub {
            return (1, '*!*@trusted.example', undef, 10);
        };

        my ($ok, $reason) = $autologin_auth->maybe_autologin(
            42,
            'TeuK!ident@trusted.example',
        );

        $assert->ok($ok, '#AUTOLOGIN# succeeds only through maybe_autologin hostmask validation');
        $assert->is(
            $reason,
            'flag+hostmask:*!*@trusted.example',
            'autologin reports the matched hostmask'
        );
        $assert->ok(
            $autologin_auth->{sessions}{teuk}{auth},
            'successful autologin records the in-memory authenticated session'
        );
        $assert->like(
            join("\n", @{ $autologin_db->{prepared_sql} }),
            qr/UPDATE USER SET auth=1, last_login=NOW\(\) WHERE id_user=\?/,
            'successful autologin updates database auth state'
        );
    }

    {
        no warnings 'redefine';
        local *Mediabot::Auth::_resolve_user = sub {
            return ({
                id_user  => 43,
                nickname => 'Other',
                username => '#AUTOLOGIN#',
                auth     => 0,
            }, undef);
        };
        local *Mediabot::Auth::hostmask_matches = sub {
            return (0, undef, undef, -1);
        };

        my ($ok, $reason) = $autologin_auth->maybe_autologin(
            43,
            'Other!ident@untrusted.example',
        );

        $assert->ok(!$ok, '#AUTOLOGIN# does not bypass a failed hostmask check');
        $assert->is($reason, 'no_mask_matched', 'failed hostmask returns explicit reason');
    }
};
