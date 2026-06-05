#!/usr/bin/env perl
# =============================================================================
# tools/check_schema_drift.pl
# =============================================================================
# Compares a live MariaDB/MySQL schema against install/mediabot.sql.
#
# Safe by default:
#   - never modifies the database
#   - never prints the DB password
#   - never generates DROP statements
#
# Typical usage:
#   perl tools/check_schema_drift.pl --conf=mediabot.conf
#   perl tools/check_schema_drift.pl --conf=mediabot.conf --strict
#   perl tools/check_schema_drift.pl --conf=mediabot.conf --generate-migration
# =============================================================================

use strict;
use warnings;
use Getopt::Long qw(GetOptions);
use DBI;
use FindBin qw($Bin);
use File::Spec;
use Cwd qw(abs_path);

my $base_dir = abs_path(File::Spec->catdir($Bin, '..')) || File::Spec->catdir($Bin, '..');

my %opt = (
    driver             => $ENV{MEDIABOT_DB_DRIVER} // 'auto',
    host               => $ENV{MEDIABOT_DB_HOST}   // 'localhost',
    port               => $ENV{MEDIABOT_DB_PORT}   // 3306,
    socket             => $ENV{MEDIABOT_DB_SOCKET} // '',
    db                 => $ENV{MEDIABOT_DB}        // '',
    user               => $ENV{MEDIABOT_DB_USER}   // 'mediabot',
    pass               => $ENV{MEDIABOT_DB_PASS}   // '',
    conf               => '',
    schema             => File::Spec->catfile($base_dir, 'install', 'mediabot.sql'),
    charset            => 'utf8mb4',
    strict             => 0,
    types              => 0,
    generate_migration => 0,
    ignore_extra       => 0,
    quiet              => 0,
    help               => 0,
);

GetOptions(
    'driver=s'           => \$opt{driver},
    'host=s'             => \$opt{host},
    'port=i'             => \$opt{port},
    'socket=s'           => \$opt{socket},
    'db=s'               => \$opt{db},
    'user=s'             => \$opt{user},
    'pass=s'             => \$opt{pass},
    'conf=s'             => \$opt{conf},
    'schema=s'           => \$opt{schema},
    'charset=s'          => \$opt{charset},
    'strict'             => \$opt{strict},
    'types'              => \$opt{types},
    'generate-migration' => \$opt{generate_migration},
    'ignore-extra'       => \$opt{ignore_extra},
    'quiet'              => \$opt{quiet},
    'help'               => \$opt{help},
) or die usage();

if ($opt{help}) {
    print usage();
    exit 0;
}

load_db_options_from_conf($opt{conf}, \%opt) if $opt{conf};

$opt{schema} = File::Spec->rel2abs($opt{schema});

die "Error: --db is required, or use --conf, or set MEDIABOT_DB\n" unless defined_non_empty($opt{db});
die "Error: schema file not found: $opt{schema}\n" unless -f $opt{schema};

my $ref      = parse_schema_file($opt{schema});
my $ref_data = parse_reference_data_from_schema($opt{schema});
my $dbh      = connect_db(\%opt);
my $live     = fetch_live_schema($dbh, $opt{db});
my $live_data = fetch_live_reference_data($dbh, $opt{db}, $ref_data, $live);
$dbh->disconnect;

my (@issues, @clean);

for my $t (sort keys %$ref) {
    if (!exists $live->{$t}) {
        push @issues, issue('missing_table', $t, undef, "MISSING TABLE    $t  (in schema, absent from DB)");
        next;
    }

    my @t_issues;

    for my $c (sort keys %{ $ref->{$t}{columns} }) {
        if (!exists $live->{$t}{columns}{$c}) {
            push @t_issues, issue('missing_column', $t, $c, "  MISSING COLUMN  $t.$c");
            next;
        }

        if ($opt{types}) {
            my $expected = normalize_column_def($ref->{$t}{columns}{$c}{definition});
            my $actual   = normalize_live_column_def($live->{$t}{columns}{$c});
            if ($expected ne $actual) {
                push @t_issues, {
                    kind     => 'type_drift',
                    table    => $t,
                    column   => $c,
                    expected => $expected,
                    actual   => $actual,
                    text     => "  TYPE DRIFT      $t.$c  expected=[$expected] live=[$actual]",
                };
            }
        }
    }

    if (!$opt{ignore_extra}) {
        for my $c (sort keys %{ $live->{$t}{columns} }) {
            push @t_issues, issue('extra_column', $t, $c, "  EXTRA COLUMN    $t.$c  (in DB, not in schema)")
                unless exists $ref->{$t}{columns}{$c};
        }
    }

    if (@t_issues) {
        push @issues, @t_issues;
    } else {
        push @clean, $t;
    }
}

if (!$opt{ignore_extra}) {
    for my $t (sort keys %$live) {
        push @issues, issue('extra_table', $t, undef, "EXTRA TABLE      $t  (in DB, absent from schema)")
            unless exists $ref->{$t};
    }
}

compare_reference_data($ref_data, $live_data, \@issues);

print_header(\%opt) unless $opt{quiet};
print_generated_migration($ref, \@issues) if $opt{generate_migration} && @issues;

if (@clean && !$opt{quiet}) {
    printf "=== CLEAN (%d table(s)) ===\n", scalar @clean;
    print "  $_\n" for @clean;
    print "\n";
}

if (@issues) {
    printf "=== DRIFT DETECTED (%d issue(s)) ===\n", scalar @issues;
    print $_->{text}, "\n" for @issues;
    print "\n";
    print "Hints:\n";
    print "  Fresh install: apply install/mediabot.sql during setup.\n";
    print "  Existing DB  : apply the missing migrations from install/migrations/.\n";
    print "  Check again  : perl tools/check_schema_drift.pl --conf=mediabot.conf --strict\n";
    print "  SQL preview  : perl tools/check_schema_drift.pl --conf=mediabot.conf --generate-migration\n";
    exit 1 if $opt{strict};
} else {
    print "Schema is in sync with the live database. No drift detected.\n" unless $opt{quiet};
}

exit 0;

sub issue {
    my ($kind, $table, $column, $text) = @_;
    return { kind => $kind, table => $table, column => $column, text => $text };
}

sub usage {
    return <<'USAGE';
Usage:
  perl tools/check_schema_drift.pl --conf=mediabot.conf [options]
  perl tools/check_schema_drift.pl --db mediabot --user mediabot --pass 'secret' [options]

Options:
  --conf <file>          Read DB settings from a Mediabot config file
  --driver <name>        DBI driver: auto, mysql, or MariaDB (default: auto)
  --host <host>          DB host (default: localhost)
  --port <port>          DB port (default: 3306)
  --socket <path>        DB Unix socket, optional
  --db <name>            DB name, or MEDIABOT_DB
  --user <user>          DB user, or MEDIABOT_DB_USER
  --pass <pass>          DB password, or MEDIABOT_DB_PASS
  --schema <file>        Reference schema, default install/mediabot.sql
  --charset <charset>    Connection charset, default utf8mb4
  --types                Also compare normalized column definitions
  --strict               Exit 1 on drift
  --ignore-extra         Ignore extra tables/columns in live DB
  --generate-migration   Print reviewable SQL for missing tables/columns only
  --quiet                Reduce output when schema is clean
  --help                 Show this help

Config keys read from --conf:
  mysql.MAIN_PROG_DBHOST
  mysql.MAIN_PROG_DBPORT
  mysql.MAIN_PROG_DBUSER
  mysql.MAIN_PROG_DBPASS
  mysql.MAIN_PROG_DDBNAME
  mysql.CHARSET_MODE
USAGE
}

sub load_db_options_from_conf {
    my ($file, $opt) = @_;
    die "Error: config file not found: $file\n" unless -f $file;

    my %vars = parse_simple_ini($file);

    $opt->{host}    = $vars{'mysql.MAIN_PROG_DBHOST'}  if defined_non_empty($vars{'mysql.MAIN_PROG_DBHOST'});
    $opt->{port}    = $vars{'mysql.MAIN_PROG_DBPORT'}  if defined_non_empty($vars{'mysql.MAIN_PROG_DBPORT'});
    $opt->{user}    = $vars{'mysql.MAIN_PROG_DBUSER'}  if defined_non_empty($vars{'mysql.MAIN_PROG_DBUSER'});
    $opt->{pass}    = $vars{'mysql.MAIN_PROG_DBPASS'}  if defined $vars{'mysql.MAIN_PROG_DBPASS'};
    $opt->{db}      = $vars{'mysql.MAIN_PROG_DDBNAME'} if defined_non_empty($vars{'mysql.MAIN_PROG_DDBNAME'});
    $opt->{charset} = $vars{'mysql.CHARSET_MODE'}      if defined_non_empty($vars{'mysql.CHARSET_MODE'});

    $opt->{charset} = 'utf8mb4'
        if !defined_non_empty($opt->{charset}) || $opt->{charset} eq 'off';
}

sub parse_simple_ini {
    my ($file) = @_;
    open my $fh, '<', $file or die "Cannot open config $file: $!\n";

    my %vars;
    my $section = '';

    while (my $line = <$fh>) {
        chomp $line;
        $line =~ s/\r\z//;

        next if $line =~ /^\s*\z/;
        next if $line =~ /^\s*#/;
        next if $line =~ /^\s*;/;

        if ($line =~ /^\s*\[([^\]]+)\]\s*\z/) {
            $section = $1;
            $section =~ s/^\s+|\s+\z//g;
            next;
        }

        next unless $line =~ /^\s*([^=]+?)\s*=\s*(.*)\z/;

        my ($key, $value) = ($1, $2);
        $key   =~ s/^\s+|\s+\z//g;
        $value =~ s/^\s+|\s+\z//g;

        # Do not strip inline comments: full-line comments only.
        # This preserves legitimate values like MAIN_PROG_CMD_CHAR=#.
        my $full_key = $section ne '' ? "$section.$key" : $key;
        $vars{$full_key} = $value;
    }

    close $fh;
    return %vars;
}

sub defined_non_empty {
    return defined $_[0] && $_[0] ne '';
}

sub connect_db {
    my ($opt) = @_;

    my $driver = resolve_dbi_driver($opt->{driver});

    my @dsn = (
        "DBI:$driver:database=" . $opt->{db},
    );

    if (defined_non_empty($opt->{socket})) {
        push @dsn, 'mysql_socket=' . $opt->{socket};
    }
    else {
        push @dsn, 'host=' . $opt->{host};

        # DBD::MariaDB treats host=localhost as a local socket connection and
        # refuses an explicit port in that mode:
        #   "port cannot be specified when host is localhost or embedded"
        #
        # Keep the port for TCP hosts such as 127.0.0.1 or remote DB hosts.
        my $is_localhost = !defined_non_empty($opt->{host}) || $opt->{host} eq 'localhost';
        push @dsn, 'port=' . $opt->{port}
            unless $driver eq 'MariaDB' && $is_localhost;
    }

    my %attrs = (
        RaiseError => 1,
        PrintError => 0,
        AutoCommit => 1,
    );

    my $dbh = DBI->connect(join(';', @dsn), $opt->{user}, $opt->{pass}, \%attrs)
        or die "DB connect failed using DBD::$driver: $DBI::errstr\n";

    # Keep charset handling driver-neutral.
    # DBD::mysql and DBD::MariaDB do not support the same connect attributes
    # on every Debian/Perl version, so use SET NAMES after connection.
    if (($opt->{charset} // '') =~ /\A(?:utf8mb4|utf8|latin1)\z/i) {
        $dbh->do('SET NAMES ' . $opt->{charset});
    }

    $opt->{resolved_driver} = $driver;

    return $dbh;
}

sub resolve_dbi_driver {
    my ($wanted) = @_;
    $wanted //= 'auto';

    my %available = map { $_ => 1 } DBI->available_drivers(0);

    if ($wanted ne 'auto') {
        return $wanted if $available{$wanted};

        my @drivers = sort keys %available;
        die "Error: requested DBD::$wanted is not installed. Available DBI drivers: "
          . join(', ', @drivers) . "\n";
    }

    return 'mysql'   if $available{mysql};
    return 'MariaDB' if $available{MariaDB};

    my @drivers = sort keys %available;
    die "Error: neither DBD::mysql nor DBD::MariaDB is installed. Available DBI drivers: "
      . join(', ', @drivers) . "\n";
}

sub parse_schema_file {
    my ($file) = @_;

    open my $fh, '<', $file or die "Cannot open schema $file: $!\n";
    my $content = do { local $/; <$fh> };
    close $fh;

    $content =~ s{/[*].*?[*]/}{}gs;
    $content =~ s/^\s*--.*$//gm;
    $content =~ s/^\s*#.*$//gm;

    my %tables;

    while ($content =~ /(CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?`?([A-Za-z0-9_]+)`?\s*[(](.*?)[)]\s*ENGINE\s*=\s*[^;]+;)/gsi) {
        my ($create_sql, $tname, $body) = ($1, $2, $3);
        my %cols;

        for my $item (split_create_table_items($body)) {
            $item =~ s/^\s+//;
            $item =~ s/\s+\z//;
            $item =~ s/,\s*\z//;
            next unless length $item;

            # Table constraints/indexes are not columns.
            next if is_table_constraint($item);

            if ($item =~ /^`([^`]+)`\s+(.+)\z/si || $item =~ /^([A-Za-z_][A-Za-z0-9_]*)\s+(.+)\z/si) {
                my ($col, $def) = ($1, $2);

                # Guard against parser mistakes: COMMENT/DEFAULT/KEY/etc. are
                # attributes or constraint keywords, never valid missing columns
                # in our schema reference.
                next if is_reserved_or_attribute_identifier($col);

                $def =~ s/\s+/ /g;
                $def =~ s/^\s+|\s+\z//g;

                $cols{$col} = {
                    definition => $def,
                    raw        => "`$col` $def",
                };
            }
        }

        $tables{$tname} = {
            columns => \%cols,
            create  => normalize_create_table($create_sql),
        };
    }

    return \%tables;
}


sub parse_reference_data_from_schema {
    my ($file) = @_;

    open my $fh, '<', $file or die "Cannot open schema $file: $!\n";
    my $content = do { local $/; <$fh> };
    close $fh;

    $content =~ s{/[*].*?[*]/}{}gs;
    $content =~ s/^\s*--.*$//gm;
    $content =~ s/^\s*#.*$//gm;

    my %data;

    # Reference-data drift is intentionally limited. We only compare seed rows
    # that are operational settings, not user/content tables.
    #
    # CHANSET_LIST is static reference data used by runtime gates such as
    # +AchievementAnnounce and +Games. Missing rows do not show up as structure
    # drift, but they break feature gates at runtime.
    while ($content =~ /INSERT\s+INTO\s+`?CHANSET_LIST`?\s*[(]([^)]*)[)]\s*VALUES\s*(.*?);/gsi) {
        my ($cols_raw, $values_raw) = ($1, $2);

        my @cols = map {
            my $c = $_;
            $c =~ s/`//g;
            $c =~ s/^\s+|\s+\z//g;
            $c;
        } split /,/, $cols_raw;

        my %pos;
        for my $i (0 .. $#cols) {
            $pos{ $cols[$i] } = $i;
        }

        next unless exists $pos{id_chanset_list} && exists $pos{chanset};

        for my $row (split_values_rows($values_raw)) {
            my @vals = split_sql_values($row);
            next unless @vals > $pos{chanset};

            my $id      = clean_sql_scalar($vals[ $pos{id_chanset_list} ]);
            my $chanset = clean_sql_scalar($vals[ $pos{chanset} ]);

            next unless defined_non_empty($id) && defined_non_empty($chanset);
            next unless $id =~ /\A\d+\z/;

            $data{CHANSET_LIST}{by_name}{lc $chanset} = {
                id      => 0 + $id,
                chanset => $chanset,
            };
        }
    }

    return \%data;
}

sub split_values_rows {
    my ($values) = @_;

    my @rows;
    my $buf = '';
    my $quote = '';
    my $paren = 0;
    my $len = length($values);

    for (my $i = 0; $i < $len; $i++) {
        my $ch = substr($values, $i, 1);
        my $next = $i + 1 < $len ? substr($values, $i + 1, 1) : '';

        if ($quote) {
            $buf .= $ch;
            if ($ch eq $quote) {
                if ($next eq $quote) {
                    $buf .= $next;
                    $i++;
                }
                else {
                    $quote = '';
                }
            }
            elsif ($ch eq '\\' && $next ne '') {
                $buf .= $next;
                $i++;
            }
            next;
        }

        if ($ch eq "'" || $ch eq '"') {
            $quote = $ch;
            $buf .= $ch;
            next;
        }

        if ($ch eq '(') {
            $paren++;
            $buf .= $ch;
            next;
        }

        if ($ch eq ')') {
            $paren-- if $paren > 0;
            $buf .= $ch;

            if ($paren == 0 && $buf =~ /\S/) {
                push @rows, $buf;
                $buf = '';
            }
            next;
        }

        next if $paren == 0 && $ch =~ /[,\s]/;

        $buf .= $ch;
    }

    return @rows;
}

sub split_sql_values {
    my ($row) = @_;
    $row =~ s/^\s*[(]\s*//;
    $row =~ s/\s*[)]\s*\z//;

    my @vals;
    my $buf = '';
    my $quote = '';
    my $paren = 0;
    my $len = length($row);

    for (my $i = 0; $i < $len; $i++) {
        my $ch = substr($row, $i, 1);
        my $next = $i + 1 < $len ? substr($row, $i + 1, 1) : '';

        if ($quote) {
            $buf .= $ch;
            if ($ch eq $quote) {
                if ($next eq $quote) {
                    $buf .= $next;
                    $i++;
                }
                else {
                    $quote = '';
                }
            }
            elsif ($ch eq '\\' && $next ne '') {
                $buf .= $next;
                $i++;
            }
            next;
        }

        if ($ch eq "'" || $ch eq '"') {
            $quote = $ch;
            $buf .= $ch;
            next;
        }

        if ($ch eq '(') {
            $paren++;
            $buf .= $ch;
            next;
        }

        if ($ch eq ')') {
            $paren-- if $paren > 0;
            $buf .= $ch;
            next;
        }

        if ($ch eq ',' && $paren == 0) {
            push @vals, $buf;
            $buf = '';
            next;
        }

        $buf .= $ch;
    }

    push @vals, $buf if length $buf || @vals;
    return @vals;
}

sub clean_sql_scalar {
    my ($v) = @_;
    return undef unless defined $v;

    $v =~ s/^\s+|\s+\z//g;
    return undef if $v =~ /\ANULL\z/i;

    if ($v =~ /\A'(.*)'\z/s) {
        $v = $1;
        $v =~ s/''/'/g;
        $v =~ s/\\'/'/g;
        $v =~ s/\\\\/\\/g;
    }
    elsif ($v =~ /\A"(.*)"\z/s) {
        $v = $1;
        $v =~ s/""/"/g;
        $v =~ s/\\"/"/g;
        $v =~ s/\\\\/\\/g;
    }

    return $v;
}

sub fetch_live_reference_data {
    my ($dbh, $db, $ref_data, $live_schema) = @_;

    my %data;

    if ($ref_data->{CHANSET_LIST} && $live_schema->{CHANSET_LIST}) {
        my $sth = $dbh->prepare(
            q{SELECT id_chanset_list, chanset
              FROM CHANSET_LIST
              ORDER BY id_chanset_list}
        );

        eval {
            $sth->execute;
            while (my $row = $sth->fetchrow_hashref) {
                my $name = $row->{chanset};
                next unless defined_non_empty($name);
                $data{CHANSET_LIST}{by_name}{lc $name} = {
                    id      => 0 + ($row->{id_chanset_list} // 0),
                    chanset => $name,
                };
            }
            $sth->finish;
            1;
        } or do {
            $data{CHANSET_LIST}{error} = $@ || 'unknown CHANSET_LIST read error';
        };
    }

    return \%data;
}

sub compare_reference_data {
    my ($ref_data, $live_data, $issues) = @_;

    if ($ref_data->{CHANSET_LIST}) {
        my $live_by_name = $live_data->{CHANSET_LIST}{by_name} // {};

        for my $lc_name (sort {
            ($ref_data->{CHANSET_LIST}{by_name}{$a}{id} // 0)
                <=>
            ($ref_data->{CHANSET_LIST}{by_name}{$b}{id} // 0)
        } keys %{ $ref_data->{CHANSET_LIST}{by_name} }) {
            next if exists $live_by_name->{$lc_name};

            my $row = $ref_data->{CHANSET_LIST}{by_name}{$lc_name};
            push @$issues, {
                kind    => 'missing_chanset',
                table   => 'CHANSET_LIST',
                column  => undef,
                id      => $row->{id},
                chanset => $row->{chanset},
                text    => sprintf(
                    "  MISSING DATA    CHANSET_LIST.%s  (id %d in schema seed, absent from DB)",
                    $row->{chanset},
                    $row->{id},
                ),
            };
        }
    }
}

sub sql_quote {
    my ($s) = @_;
    $s //= '';
    $s =~ s/'/''/g;
    return "'$s'";
}


sub split_create_table_items {
    my ($body) = @_;

    my @items;
    my $buf = '';
    my $quote = '';
    my $paren = 0;
    my $len = length($body);

    for (my $i = 0; $i < $len; $i++) {
        my $ch = substr($body, $i, 1);
        my $next = $i + 1 < $len ? substr($body, $i + 1, 1) : '';

        if ($quote) {
            $buf .= $ch;

            # SQL escapes quotes as doubled quotes inside strings.
            if ($ch eq $quote) {
                if ($next eq $quote) {
                    $buf .= $next;
                    $i++;
                }
                else {
                    $quote = '';
                }
            }
            elsif ($ch eq '\\' && $next ne '') {
                # Keep escaped character with the string.
                $buf .= $next;
                $i++;
            }

            next;
        }

        if ($ch eq "'" || $ch eq '"' || $ch eq '`') {
            $quote = $ch;
            $buf .= $ch;
            next;
        }

        if ($ch eq '(') {
            $paren++;
            $buf .= $ch;
            next;
        }

        if ($ch eq ')') {
            $paren-- if $paren > 0;
            $buf .= $ch;
            next;
        }

        if ($ch eq ',' && $paren == 0) {
            push @items, $buf if $buf =~ /\S/;
            $buf = '';
            next;
        }

        $buf .= $ch;
    }

    push @items, $buf if $buf =~ /\S/;
    return @items;
}

sub is_table_constraint {
    my ($item) = @_;
    return $item =~ /^\s*(?:PRIMARY|UNIQUE|KEY|INDEX|FULLTEXT|SPATIAL|CONSTRAINT|FOREIGN|CHECK)\b/i;
}

sub is_reserved_or_attribute_identifier {
    my ($name) = @_;
    return 0 unless defined $name;

    my %reserved = map { $_ => 1 } qw(
        ADD ALTER AND AS BY CHARACTER CHARSET CHECK COLLATE COLUMN COMMENT CONSTRAINT
        CREATE DEFAULT DELETE DROP ENGINE ENUM FOREIGN FROM INDEX INSERT INT INTEGER
        KEY NOT NULL ON PRIMARY REFERENCES SELECT SET TABLE TIMESTAMP UNIQUE UPDATE
        VALUES VARCHAR WHERE
    );

    return $reserved{ uc $name } ? 1 : 0;
}

sub normalize_create_table {
    my ($sql) = @_;
    $sql =~ s/^\s+|\s+\z//g;
    $sql .= ';' unless $sql =~ /;\s*\z/;
    return $sql;
}

sub fetch_live_schema {
    my ($dbh, $db) = @_;
    my %tables;

    my $sth = $dbh->prepare(
        q{SELECT TABLE_NAME
          FROM information_schema.TABLES
          WHERE TABLE_SCHEMA = ?
            AND TABLE_TYPE = 'BASE TABLE'
          ORDER BY TABLE_NAME}
    );
    $sth->execute($db);
    my @tnames = map { $_->[0] } @{ $sth->fetchall_arrayref };
    $sth->finish;

    for my $t (@tnames) {
        my $csth = $dbh->prepare(
            q{SELECT COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_DEFAULT, EXTRA,
                     CHARACTER_SET_NAME, COLLATION_NAME
              FROM information_schema.COLUMNS
              WHERE TABLE_SCHEMA = ?
                AND TABLE_NAME = ?
              ORDER BY ORDINAL_POSITION}
        );
        $csth->execute($db, $t);

        my %cols;
        while (my $row = $csth->fetchrow_hashref) {
            $cols{ $row->{COLUMN_NAME} } = {
                type      => $row->{COLUMN_TYPE} // '',
                nullable  => $row->{IS_NULLABLE} // '',
                default   => $row->{COLUMN_DEFAULT},
                extra     => $row->{EXTRA} // '',
                charset   => $row->{CHARACTER_SET_NAME} // '',
                collation => $row->{COLLATION_NAME} // '',
            };
        }
        $csth->finish;
        $tables{$t} = { columns => \%cols };
    }

    return \%tables;
}

sub normalize_column_def {
    my ($def) = @_;
    $def //= '';
    $def = lc $def;
    $def =~ s/`//g;
    $def =~ s/\s+/ /g;
    $def =~ s/\s*,\s*/,/g;
    $def =~ s/current_timestamp[(][)]/current_timestamp/g;
    $def =~ s/\s+\z//;
    return $def;
}

sub normalize_live_column_def {
    my ($col) = @_;
    my $def = lc($col->{type} // '');

    $def .= ' not null' if ($col->{nullable} // '') eq 'NO';

    if (defined $col->{default}) {
        my $d = $col->{default};
        if ($d =~ /\Acurrent_timestamp[(][)]\z/i) {
            $def .= ' default current_timestamp';
        } elsif ($d =~ /\Anull\z/i) {
            $def .= ' default null';
        } elsif ($d =~ /\A-?\d+(?:[.]\d+)?\z/) {
            $def .= " default $d";
        } else {
            $d =~ s/'/''/g;
            $def .= " default '$d'";
        }
    }

    $def .= ' ' . lc($col->{extra}) if defined_non_empty($col->{extra});
    $def =~ s/\s+/ /g;
    $def =~ s/current_timestamp[(][)]/current_timestamp/g;
    $def =~ s/\s+\z//;
    return $def;
}

sub print_header {
    my ($opt) = @_;
    print "Connected  : $opt->{db}\@$opt->{host}:$opt->{port}\n";
    print "DBI driver : " . ($opt->{resolved_driver} // $opt->{driver} // 'auto') . "\n";
    print "User       : $opt->{user}\n";
    print "Charset    : $opt->{charset}\n";
    print "Schema ref : $opt->{schema}\n";
    print "Mode       : ";
    print $opt->{strict} ? "strict" : "report-only";
    print $opt->{types} ? ", type-checks" : ", structure-only";
    print $opt->{ignore_extra} ? ", ignoring extras" : ", reporting extras";
    print "\n\n";
}

sub print_generated_migration {
    my ($ref, $issues) = @_;
    print "-- === GENERATED MIGRATION SQL ===\n";
    print "-- Auto-generated by tools/check_schema_drift.pl on " . scalar(localtime) . "\n";
    print "-- Review carefully before applying.\n";
    print "-- This output intentionally avoids DROP statements.\n";
    print "SET NAMES utf8mb4;\n\n";

    for my $issue (@$issues) {
        if ($issue->{kind} eq 'missing_table') {
            my $t = $issue->{table};
            print "-- Missing table: `$t`\n";
            print $ref->{$t}{create}, "\n\n";
        } elsif ($issue->{kind} eq 'missing_column') {
            my ($t, $c) = ($issue->{table}, $issue->{column});

            if (is_reserved_or_attribute_identifier($c)) {
                print "-- Skipped suspicious missing column `$t`.`$c`: looks like a SQL keyword/attribute; review parser/schema manually.\n";
                next;
            }

            my $def = $ref->{$t}{columns}{$c}{raw} // "`$c` VARCHAR(255) DEFAULT NULL";
            print "ALTER TABLE `$t` ADD COLUMN $def;\n";
        } elsif ($issue->{kind} eq 'missing_chanset') {
            my $id = 0 + ($issue->{id} // 0);
            my $name = $issue->{chanset} // '';
            print "-- Missing CHANSET_LIST row: $name\n";
            print "INSERT INTO `CHANSET_LIST` (`id_chanset_list`, `chanset`)\n";
            print "SELECT $id, " . sql_quote($name) . "\n";
            print "WHERE NOT EXISTS (\n";
            print "  SELECT 1 FROM `CHANSET_LIST` WHERE `chanset` = " . sql_quote($name) . "\n";
            print ");\n";
        } elsif ($issue->{kind} eq 'extra_table') {
            print "-- Extra table `$issue->{table}` exists in DB only. No DROP generated.\n";
        } elsif ($issue->{kind} eq 'extra_column') {
            print "-- Extra column `$issue->{table}`.`$issue->{column}` exists in DB only. No DROP generated.\n";
        } elsif ($issue->{kind} eq 'type_drift') {
            print "-- Type drift `$issue->{table}`.`$issue->{column}`: expected [$issue->{expected}], live [$issue->{actual}]\n";
        }
    }

    print "\n";
}
