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
#   perl tools/check_schema_drift.pl --conf=mediabot.conf --strict --types --indexes
#   perl tools/check_schema_drift.pl --conf=mediabot.conf --generate-migration --types --indexes
# =============================================================================

use strict;
use warnings;
use Getopt::Long qw(GetOptions);
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
    indexes            => 0,
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
    'indexes'            => \$opt{indexes},
    'generate-migration' => \$opt{generate_migration},
    'ignore-extra'       => \$opt{ignore_extra},
    'quiet'              => \$opt{quiet},
    'help'               => \$opt{help},
) or die usage();

if ($opt{help}) {
    print usage();
    exit 0;
}

# DBI is only needed to talk to the live database, never for --help. Load it
# lazily so `--help` works on a machine where CPAN modules aren't installed yet
# (fresh checkout), with a clear message if it's genuinely missing.
eval { require DBI; DBI->import; 1 }
    or die "Error: DBI is required to query the database "
          . "(install it via CPAN, e.g. `cpanm DBI`).\n";

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

    compare_required_indexes($ref->{$t}{indexes}, $live->{$t}{indexes}, $t, \@t_issues)
        if $opt{indexes};

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
    print "  Check again  : perl tools/check_schema_drift.pl --conf=mediabot.conf --strict --types --indexes\n";
    print "  SQL preview  : perl tools/check_schema_drift.pl --conf=mediabot.conf --generate-migration --types --indexes\n";
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
  --indexes              Verify required reference indexes (extra live indexes ignored)
  --strict               Exit 1 on drift
  --ignore-extra         Ignore extra tables/columns in live DB
  --generate-migration   Print reviewable SQL for missing tables/columns/indexes/reference rows
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
        or do { no warnings 'once'; die "DB connect failed using DBD::$driver: $DBI::errstr\n"; };

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
        my %indexes;

        for my $item (split_create_table_items($body)) {
            $item =~ s/^\s+//;
            $item =~ s/\s+\z//;
            $item =~ s/,\s*\z//;
            next unless length $item;

            if (my $index = parse_index_item($item)) {
                $indexes{ lc $index->{name} } = $index;
                next;
            }

            # Other table constraints are not columns.
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
            indexes => \%indexes,
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
    while ($content =~ /INSERT\s+(?:IGNORE\s+)?INTO\s+`?CHANSET_LIST`?\s*[(]([^)]*)[)]\s*VALUES\s*(.*?);/gsi) {
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

    if ($ref_data->{CHANSET_LIST} && !$live_schema->{CHANSET_LIST}) {
        $data{CHANSET_LIST}{table_missing} = 1;
    }
    elsif ($ref_data->{CHANSET_LIST} && $live_schema->{CHANSET_LIST}) {
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
        return if $live_data->{CHANSET_LIST}{table_missing};

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

        # mb120-B1: SQL line comment outside any string (-- ... \n)
        # MySQL/MariaDB requires a whitespace (or EOL) after `--` for it to
        # count as a comment. We follow that rule to avoid eating legitimate
        # `--` in expressions like `a--b` (which is invalid SQL anyway, but
        # keeps the parser conservative).
        if ($ch eq '-' && $next eq '-') {
            my $third = $i + 2 < $len ? substr($body, $i + 2, 1) : "\n";
            if ($third =~ /\s/ || $third eq '') {
                # Skip until end of line (or end of body)
                my $nl = index($body, "\n", $i + 2);
                if ($nl < 0) {
                    $i = $len;  # consume rest of body
                } else {
                    $i = $nl;   # next iteration will start at \n
                }
                next;
            }
        }

        # MySQL also accepts # comments. Treat them like line comments outside
        # quoted strings/backticks, but preserve # inside strings or identifiers.
        if ($ch eq '#') {
            $i++;
            $i++ while $i < $len && substr($body, $i, 1) ne "\n";
            $buf .= "\n";
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

sub parse_index_item {
    my ($item) = @_;
    return undef unless defined $item;

    my ($unique, $name, $cols_raw);
    if ($item =~ /^\s*PRIMARY\s+KEY\s*\((.+)\)\s*\z/is) {
        ($unique, $name, $cols_raw) = (1, 'PRIMARY', $1);
    }
    elsif ($item =~ /^\s*(UNIQUE\s+)?(?:KEY|INDEX)\s+`?([A-Za-z0-9_]+)`?\s*\((.+)\)\s*\z/is) {
        ($unique, $name, $cols_raw) = ($1 ? 1 : 0, $2, $3);
    }
    else {
        return undef;
    }

    my @columns;
    for my $part (split_create_table_items($cols_raw)) {
        $part =~ s/^\s+|\s+\z//g;
        return undef unless $part =~ /^`?([A-Za-z0-9_]+)`?(?:\s*\(\s*(\d+)\s*\))?(?:\s+(ASC|DESC))?\s*\z/i;
        push @columns, {
            name   => $1,
            prefix => defined($2) ? 0 + $2 : undef,
            order  => uc($3 // ''),
        };
    }
    return undef unless @columns;

    return {
        name    => $name,
        unique  => $unique ? 1 : 0,
        columns => \@columns,
    };
}

sub normalize_index_signature {
    my ($index) = @_;
    return '' unless ref($index) eq 'HASH';
    my @cols = map {
        my $s = lc($_->{name} // '');
        $s .= '(' . $_->{prefix} . ')' if defined $_->{prefix};
        $s .= ':' . lc($_->{order}) if defined_non_empty($_->{order});
        $s;
    } @{ $index->{columns} || [] };
    return (($index->{unique} // 0) ? 'unique|' : 'nonunique|') . join(',', @cols);
}

sub compare_required_indexes {
    my ($ref_indexes, $live_indexes, $table, $issues) = @_;
    $ref_indexes  = {} unless ref($ref_indexes) eq 'HASH';
    $live_indexes = {} unless ref($live_indexes) eq 'HASH';

    for my $key (sort keys %$ref_indexes) {
        my $expected = $ref_indexes->{$key};
        if (!exists $live_indexes->{$key}) {
            push @$issues, {
                kind     => 'missing_index',
                table    => $table,
                index    => $expected->{name},
                expected => normalize_index_signature($expected),
                text     => "  MISSING INDEX   $table.$expected->{name}  (in schema, absent from DB)",
            };
            next;
        }
        my $actual = $live_indexes->{$key};
        my $want = normalize_index_signature($expected);
        my $have = normalize_index_signature($actual);
        if ($want ne $have) {
            push @$issues, {
                kind     => 'index_drift',
                table    => $table,
                index    => $expected->{name},
                expected => $want,
                actual   => $have,
                text     => "  INDEX DRIFT     $table.$expected->{name}  expected=[$want] live=[$have]",
            };
        }
    }
}

sub render_add_index_sql {
    my ($table, $index) = @_;
    return undef unless ref($index) eq 'HASH';
    return undef if uc($index->{name} // '') eq 'PRIMARY';
    my @cols = map {
        my $s = '`' . ($_->{name} // '') . '`';
        $s .= '(' . $_->{prefix} . ')' if defined $_->{prefix};
        $s .= ' ' . $_->{order} if defined_non_empty($_->{order});
        $s;
    } @{ $index->{columns} || [] };
    return undef unless @cols;
    my $kind = ($index->{unique} // 0) ? 'UNIQUE INDEX' : 'INDEX';
    return sprintf('ALTER TABLE `%s` ADD %s `%s` (%s);',
        $table, $kind, $index->{name}, join(', ', @cols));
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

        my $isth = $dbh->prepare(
            q{SELECT INDEX_NAME, NON_UNIQUE, SEQ_IN_INDEX, COLUMN_NAME, SUB_PART, COLLATION
              FROM information_schema.STATISTICS
              WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ?
              ORDER BY INDEX_NAME, SEQ_IN_INDEX}
        );
        $isth->execute($db, $t);
        my %indexes;
        while (my $row = $isth->fetchrow_hashref) {
            my $name = $row->{INDEX_NAME};
            next unless defined_non_empty($name);
            my $key = lc $name;
            my $index = ($indexes{$key} //= {
                name => $name,
                unique => ($row->{NON_UNIQUE} // 1) ? 0 : 1,
                columns => [],
            });
            push @{ $index->{columns} }, {
                name   => $row->{COLUMN_NAME} // '',
                prefix => defined($row->{SUB_PART}) ? 0 + $row->{SUB_PART} : undef,
                order  => (($row->{COLLATION} // '') eq 'D') ? 'DESC' : '',
            };
        }
        $isth->finish;

        $tables{$t} = { columns => \%cols, indexes => \%indexes };
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
    print $opt->{indexes} ? ", required-index checks" : ", indexes not checked";
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
        } elsif ($issue->{kind} eq 'missing_index') {
            my ($t, $name) = ($issue->{table}, $issue->{index});
            my $index = $ref->{$t}{indexes}{lc $name};
            my $sql = render_add_index_sql($t, $index);
            if (defined $sql) {
                print "$sql\n";
            }
            else {
                print "-- Missing index `$t`.`$name` requires manual review. No SQL generated.\n";
            }
        } elsif ($issue->{kind} eq 'index_drift') {
            print "-- Index drift `$issue->{table}`.`$issue->{index}`: expected [$issue->{expected}], live [$issue->{actual}]\n";
            print "-- No DROP/REPLACE generated. Review manually to avoid destructive changes.\n";
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
