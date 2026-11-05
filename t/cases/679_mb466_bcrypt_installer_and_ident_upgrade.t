use strict;
use warnings;
use Test::More;
use Digest::SHA qw(sha1 sha1_hex);
use File::Spec;
use File::Temp qw(tempdir);
use Mediabot::Auth;
use Mediabot::LoginCommands ();

{
    open my $fh, '<', 'install/cpan_install.sh' or die $!;
    local $/;
    my ($modules) = <$fh> =~ /PERL_MODULES=\((.*?)\)/s;
    like($modules // '', qr/"Crypt::Bcrypt"/, 'CPAN installer provisions bcrypt');
}

SKIP: {
    skip 'SQLite and bcrypt required for the native migration fixture', 8
        unless eval { require DBI; require DBD::SQLite; require Crypt::Bcrypt; 1 };

    my $dir = tempdir(CLEANUP => 1);
    my $dsn = 'dbi:SQLite:dbname=' . File::Spec->catfile($dir, 'auth.sqlite');
    my $opts = { RaiseError => 1, PrintError => 0 };
    my $dbh = DBI->connect($dsn, '', '', $opts);
    my $writer = DBI->connect($dsn, '', '', $opts);
    $dbh->do('CREATE TABLE USER (id_user INTEGER PRIMARY KEY, nickname TEXT, password TEXT COLLATE NOCASE)');
    $dbh->do('CREATE TABLE USER_HOSTMASK (id_user_hostmask INTEGER PRIMARY KEY, id_user INTEGER, hostmask TEXT)');
    $dbh->do('INSERT INTO USER (id_user, nickname) VALUES (1, ?)', undef, 'fixture');

    my $log = bless [], 'MB466Log';
    my $auth = Mediabot::Auth->new(dbh => $dbh, logger => $log);
    my $bot = { dbh => $dbh, auth => $auth, logger => $log };
    my $message = bless {}, 'MB466Message';
    my $seed = sub { $writer->do('UPDATE USER SET password = ? WHERE id_user = 1', undef, $_[0]) };
    my $stored = sub { $dbh->selectrow_array('SELECT password FROM USER WHERE id_user = 1') };
    my $login = sub { $auth->verify_credentials(1, 'caller', $_[0]) };
    my $ident = sub { [Mediabot::LoginCommands::checkAuthByUser($bot, $message, 'fixture', $_[0])] };
    my $migrated = sub { scalar grep { /password hash upgraded to bcrypt/ } @$log };
    my $rehash = sub { Crypt::Bcrypt::bcrypt($_[0], '2b', 4, '0123456789abcdef') };
    my ($race, $hash_calls);
    no warnings 'redefine';
    local *Mediabot::Helpers::make_password_hash = sub {
        ++$hash_calls;
        $race->() if $race;
        return $rehash->($_[0]);
    };

    my $legacy = '*' . uc(sha1_hex(sha1('legacy-fixture')));
    $seed->($legacy);
    ok($login->('legacy-fixture') && Crypt::Bcrypt::bcrypt_check('legacy-fixture', $stored->())
            && $migrated->() == 1,
        'login upgrades an unchanged MySQL hash and confirms the write');
    my $calls = $hash_calls;
    ok($login->('legacy-fixture') && $hash_calls == $calls,
        'login does not rehash an account that already uses bcrypt');

    $seed->('legacy-ident');
    is_deeply($ident->('legacy-ident'), [1, 0], 'ident inserts the expected hostmask');
    ok(Crypt::Bcrypt::bcrypt_check('legacy-ident', $stored->())
            && $migrated->() == 2 && join(',', @{$ident->('legacy-ident')}) eq '1,1',
        'ident upgrades the verified value and preserves duplicate hostmask behavior');

    $seed->($legacy);
    $calls = $hash_calls;
    ok(!$login->('incorrect-fixture') && join(',', @{$ident->('incorrect-fixture')}) eq '0,0'
            && $hash_calls == $calls && $stored->() eq $legacy,
        'failed credentials never attempt a lazy write');

    my $before = $migrated->();
    my $reset = $rehash->('reset-fixture');
    $race = sub { $seed->($reset) };
    ok($login->('legacy-fixture') && $stored->() eq $reset && $migrated->() == $before,
        'login cannot overwrite a concurrent password reset or report an upgrade');

    $before = $migrated->();
    $seed->('case-fixture');
    $race = sub { $seed->('CASE-fixture') };
    ok(join(',', @{$ident->('case-fixture')}) eq '1,1'
            && $stored->() eq 'CASE-fixture' && $migrated->() == $before,
        'ident refuses a stale value even under a case-insensitive password collation');

    $seed->($legacy);
    $race = undef;
    $before = $migrated->();
    $dbh->do(q{CREATE TRIGGER refuse_upgrade BEFORE UPDATE OF password ON USER
        BEGIN SELECT RAISE(ABORT, 'private-fixture-driver-detail'); END});
    ok($login->('legacy-fixture') && $stored->() eq $legacy && $migrated->() == $before
            && !(grep { /private-fixture-driver-detail/ } @$log),
        'database failure leaves verified login and stored hash intact without raw driver details');
}

done_testing;

package MB466Log;
sub log { push @{$_[0]}, $_[2]; return }
package MB466Message;
sub prefix { 'caller!~ident@example.invalid' }
