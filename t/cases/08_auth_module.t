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
use utf8;
use DBI;
use JSON::PP ();

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use Mediabot::Auth;
use Mediabot::ChannelBan;
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
    $assert->ok($no_db && $no_db->can('verify_credentials') && $no_db->can('maybe_autologin'),
        'Auth can be created without DB and exposes password and autologin APIs');

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
    # Exercise native mask selection and autologin with real SQLite writes.
    # A generous test-only alarm detects a regressed matcher without hanging
    # the suite. The application has no added timeout or mask rejection cap.
    my $bounded = sub {
        my ($cb)=@_;my ($result,$expired,$error)=(undef,0,'');
        local $SIG{ALRM}=sub {$expired=1;die "auth matching budget\n"};
        my $ok=eval {alarm 5;$result=$cb->();1};
        $error=$@ unless $ok;alarm 0;
        return {expired=>$expired,error=>$error,result=>$result};
    };
    my $db=DBI->connect('dbi:SQLite:dbname=:memory:','','',{
        RaiseError=>1,PrintError=>0,sqlite_unicode=>1});
    $db->sqlite_create_function('NOW',0,sub {'2026-11-02 12:00:00'});
    $db->do('CREATE TABLE USER(id_user INTEGER PRIMARY KEY,nickname TEXT,auth INTEGER,last_login TEXT)');
    $db->do("INSERT INTO USER VALUES(91,'Registered',0,NULL),(92,'Other',0,NULL)");
    my $native=Mediabot::Auth->new(dbh=>$db,logger=>$logger);
    my $host='a'x70;
    my $hard='*!*@'.('*a'x25).'b';
    my $specific='Live!ident@'.$host;
    my $user={id_user=>91,nickname=>'Registered',username=>'#AUTOLOGIN#',auth=>0,
        hostmasks=>join(',', $hard,'*!*@'.$host,$specific,'LIVE!IDENT@'.$host)};
    my $json=JSON::PP->new->canonical;
    my $match=$bounded->(sub {
        my ($ok,$mask,$rx,$score)=$native->hostmask_matches($user,'Live!~ident@'.$host);
        my $literal=Mediabot::Auth::_glob_to_re('N[ic]k!*@host.example');
        my $question=Mediabot::Auth::_glob_to_re('?ser!*@host');
        my $strict=Mediabot::Auth::_glob_to_re('*!*@host');
        my $ban=Mediabot::ChannelBan->new(dbh=>$db);
        return [$ok,$mask,$score,('LiVe!ident@'.$host)=~$rx?1:0,
            'n[IC]K!x@HOST.EXAMPLE'=~$literal?1:0,'nick!x@host.example'=~$literal?1:0,
            'Éser!x@host'=~$question?1:0,'ssÉser!x@host'=~$question?1:0,
            "nick!x\@host\n"=~$strict?1:0,$ban->_mask_matches_irc('*!*@host',"nick!x\@host\n")];
    });
    $assert->is($json->encode($match),$json->encode({expired=>0,error=>'',
        result=>[1,$specific,91,1,1,0,1,0,0,1]}),
        'native Auth skips the hostile non-match, retains specificity/ties and legacy candidates, literals and caller-specific anchors');
    my $login=$bounded->(sub {
        my ($ok,$reason)=$native->maybe_autologin($user,'Live!~ident@'.$host);
        my ($denied,$why)=$native->maybe_autologin({id_user=>92,nickname=>'Other',
            username=>'#AUTOLOGIN#',auth=>0,hostmasks=>$hard},'Other!ident@'.$host);
        my $row=$db->selectall_arrayref('SELECT id_user,auth,last_login FROM USER ORDER BY id_user');
        return [$ok,$reason,$native->{sessions}{live}{id_user},$native->is_logged_in_id(91),
            $denied,$why,exists($native->{sessions}{other})?1:0,$row];
    });
    $assert->is($json->encode($login),$json->encode({expired=>0,error=>'',
        result=>[1,'flag+hostmask:'.$specific,91,1,0,'no_mask_matched',0,
            [[91,1,'2026-11-02 12:00:00'],[92,0,undef]]]}),
        'native autologin still authenticates the matching account and leaves a nonmatching account and session untouched');
    $db->disconnect;
};
