package Mediabot::Plugin::DictionaryV3;

use strict;
use warnings;

# Core-owned, read-only connection. Never reuse the bot's inherited DB handle
# in a fork, and never pass credentials or handles to a package.
sub settings {
    my ($class, $conf) = @_;
    die "dictionary_configuration\n" unless $conf && $conf->can('get');
    my %out;
    my %fallback = (HOST => 'MAIN_PROG_DBHOST', PORT => 'MAIN_PROG_DBPORT',
        USER => 'MAIN_PROG_DBUSER', PASS => 'MAIN_PROG_DBPASS');
    for my $key (keys %fallback) {
        my $value = $conf->get("dictionary.$key");
        $value = $conf->get('mysql.' . $fallback{$key}) unless defined $value;
        die "dictionary_configuration\n" if ref $value;
        $out{lc $key} = $value;
    }
    $out{database} = $conf->get('dictionary.DATABASE') // 'DICT';
    $out{socket} = $conf->get('dictionary.SOCKET') // '';
    $out{host} = '127.0.0.1' if !defined($out{host}) || $out{host} eq 'localhost';
    $out{port} //= 3306;
    $out{pass} //= '';
    die "dictionary_configuration\n" unless !ref($out{database})
        && $out{database} eq 'DICT'
        && !ref($out{socket}) && $out{socket} !~ /[;\x00-\x1f]/
        && (!length($out{socket}) || $out{socket} =~ m{\A/})
        && $out{host} =~ /\A[A-Za-z0-9_.:-]{1,253}\z/
        && "$out{port}" =~ /\A[0-9]{1,5}\z/
        && $out{port} > 0 && $out{port} <= 65535
        && defined($out{user}) && length($out{user}) <= 128
        && length($out{user}) && $out{user} !~ /[\x00-\x1f]/;
    return \%out;
}

sub connect {
    my ($class, $settings) = @_;
    require DBI;
    my $dsn = 'DBI:MariaDB:database=DICT;';
    $dsn .= length($settings->{socket} // '')
        ? 'mariadb_socket=' . $settings->{socket}
        : "host=$settings->{host};port=$settings->{port}";
    $dsn .= ';mariadb_connect_timeout=3;mariadb_read_timeout=3;mariadb_write_timeout=3';
    my $dbh = eval { DBI->connect($dsn, $settings->{user}, $settings->{pass}, {
        RaiseError => 1, PrintError => 0, AutoCommit => 1,
        mariadb_auto_reconnect => 0,
    }) };
    die "dictionary_connection\n" unless $dbh;
    my $ok = eval {
        $dbh->do('SET SESSION max_statement_time=2');
        $dbh->do('SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ');
        $dbh->do('SET SESSION TRANSACTION READ ONLY');
        1;
    };
    unless ($ok) { eval { $dbh->disconnect }; die "dictionary_connection\n" }
    return $dbh;
}

1;
