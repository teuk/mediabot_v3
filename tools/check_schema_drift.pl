#!/usr/bin/perl
# =============================================================================
# tools/check_schema_drift.pl
# =============================================================================
# Compares the live MariaDB schema against install/mediabot.sql and reports
# any drift: missing tables, extra tables, missing columns, extra columns.
#
# Usage:
#   perl tools/check_schema_drift.pl [options]
#
# Options:
#   --host    <host>    DB host     (default: localhost)
#   --db      <name>    DB name     (required, or set $MEDIABOT_DB)
#   --user    <user>    DB user     (default: mediabot)
#   --pass    <pass>    DB password (default: $MEDIABOT_DB_PASS)
#   --schema  <file>    Schema SQL  (default: install/mediabot.sql)
#   --strict            Exit 1 on any drift
#   --help
# =============================================================================

use strict;
use warnings;
use Getopt::Long qw(GetOptions);
use DBI;
use File::Basename qw(dirname);

my $base_dir = dirname(__FILE__) . '/..';

# ── Options ──────────────────────────────────────────────────────────────────
my %opt = (
    host   => 'localhost',
    db     => $ENV{MEDIABOT_DB}      // '',
    user   => $ENV{MEDIABOT_DB_USER} // 'mediabot',
    pass   => $ENV{MEDIABOT_DB_PASS} // '',
    schema => "$base_dir/install/mediabot.sql",
    strict => 0,
);
GetOptions(\%opt,
    'host=s', 'db=s', 'user=s', 'pass=s',
    'schema=s', 'strict', 'generate-migration', 'help',
) or die "Error parsing options\n";

if ($opt{help}) {
    print "Usage: $0 [--host H] [--db DB] [--user U] [--pass P] [--schema FILE] [--strict]\n";
    exit 0;
}

die "Error: --db is required (or set \$MEDIABOT_DB)\n" unless $opt{db};
die "Error: schema file not found: $opt{schema}\n"     unless -f $opt{schema};

# ── Parse reference schema ────────────────────────────────────────────────────
sub parse_schema_file {
    my ($file) = @_;
    open my $fh, '<', $file or die "Cannot open $file: $!\n";
    my $content = do { local $/; <$fh> };
    close $fh;

    my %tables;

    while ($content =~ /CREATE\s+TABLE\s+`?(\w+)`?\s*\((.*?)\)\s*ENGINE/gsi) {
        my ($tname, $body) = ($1, $2);
        my %cols;
        for my $line (split /\n/, $body) {
            $line =~ s/^\s+//;
            $line =~ s/,\s*$//;
            next unless length $line;
            next if $line =~ /^(PRIMARY|UNIQUE|KEY|INDEX|CONSTRAINT|FOREIGN)\b/i;
            if ($line =~ /^`?(\w+)`?\s+(.+)/i) {
                my ($col, $def) = ($1, $2);
                $def =~ s/\s+/ /g;
                $def =~ s/^\s+|\s+$//g;
                $cols{$col} = $def;
            }
        }
        $tables{$tname} = \%cols;
    }
    return \%tables;
}

# ── Fetch live schema ─────────────────────────────────────────────────────────
sub fetch_live_schema {
    my ($dbh, $db) = @_;
    my %tables;

    my $sth = $dbh->prepare(
        "SELECT TABLE_NAME FROM information_schema.TABLES
         WHERE TABLE_SCHEMA = ? AND TABLE_TYPE = 'BASE TABLE'
         ORDER BY TABLE_NAME"
    );
    $sth->execute($db);
    my @tnames = map { $_->[0] } @{ $sth->fetchall_arrayref };
    $sth->finish;

    for my $t (@tnames) {
        my $csth = $dbh->prepare(
            "SELECT COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_DEFAULT, EXTRA
             FROM information_schema.COLUMNS
             WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ?
             ORDER BY ORDINAL_POSITION"
        );
        $csth->execute($db, $t);
        my %cols;
        while (my $row = $csth->fetchrow_hashref) {
            $cols{ $row->{COLUMN_NAME} } = {
                type     => uc($row->{COLUMN_TYPE}),
                nullable => $row->{IS_NULLABLE},
                default  => $row->{COLUMN_DEFAULT} // '(NULL)',
                extra    => $row->{EXTRA},
            };
        }
        $csth->finish;
        $tables{$t} = \%cols;
    }
    return \%tables;
}

# ── Connect ───────────────────────────────────────────────────────────────────
my $dsn = "DBI:mysql:database=$opt{db};host=$opt{host};mysql_enable_utf8=1";
my $dbh = DBI->connect($dsn, $opt{user}, $opt{pass},
    { RaiseError => 1, PrintError => 0, AutoCommit => 1 })
    or die "DB connect failed: $DBI::errstr\n";

print "Connected  : $opt{db}\@$opt{host}\n";
print "Schema ref : $opt{schema}\n\n";

my $ref  = parse_schema_file($opt{schema});
my $live = fetch_live_schema($dbh, $opt{db});
$dbh->disconnect;

# ── Compare ───────────────────────────────────────────────────────────────────
my (@issues, @clean);

for my $t (sort keys %$ref) {
    if (!exists $live->{$t}) {
        push @issues, "MISSING TABLE    $t  (in schema, absent from DB)";
        next;
    }
    my @t_issues;
    for my $c (sort keys %{ $ref->{$t} }) {
        push @t_issues, "  MISSING COLUMN  $t.$c" unless exists $live->{$t}{$c};
    }
    for my $c (sort keys %{ $live->{$t} }) {
        push @t_issues, "  EXTRA COLUMN    $t.$c  (in DB, not in schema)"
            unless exists $ref->{$t}{$c};
    }
    if (@t_issues) {
        push @issues, @t_issues;
    } else {
        push @clean, $t;
    }
}

for my $t (sort keys %$live) {
    push @issues, "EXTRA TABLE      $t  (in DB, absent from schema)"
        unless exists $ref->{$t};
}

# ── Generate migration SQL ───────────────────────────────────────────────────
if ($opt{'generate-migration'} && @issues) {
    print "=== GENERATED MIGRATION SQL ===\n";
    print "-- Auto-generated by check_schema_drift.pl on " . scalar(localtime) . "\n";
    print "-- Review carefully before applying!\n\n";

    for my $issue (@issues) {
        if ($issue =~ /^MISSING TABLE\s+(\w+)/) {
            my $t = $1;
            print "-- TODO: CREATE TABLE `$t` (see install/mediabot.sql)\n";
        }
        elsif ($issue =~ /^EXTRA TABLE\s+(\w+)/) {
            my $t = $1;
            print "-- DROP TABLE IF EXISTS `$t`;  -- DANGEROUS: verify before running\n";
        }
        elsif ($issue =~ /^  MISSING COLUMN\s+(\w+)\.(\w+)/) {
            my ($t, $c) = ($1, $2);
            # Look up the column definition from the reference schema
            my $def = $ref->{$t}{$c} // 'VARCHAR(255) DEFAULT NULL';
            print "ALTER TABLE `$t` ADD COLUMN `$c` $def;\n";
        }
        elsif ($issue =~ /^  EXTRA COLUMN\s+(\w+)\.(\w+)/) {
            my ($t, $c) = ($1, $2);
            print "-- ALTER TABLE `$t` DROP COLUMN `$c`;  -- DANGEROUS: verify before running\n";
        }
    }
    print "\n";
}

# ── Report ────────────────────────────────────────────────────────────────────
if (@clean) {
    printf "=== CLEAN (%d table(s)) ===\n", scalar @clean;
    print "  $_\n" for @clean;
    print "\n";
}

if (@issues) {
    printf "=== DRIFT DETECTED (%d issue(s)) ===\n", scalar @issues;
    print "$_\n" for @issues;
    print "\n";
    print "Hint: run install/mediabot.sql or create a migration in install/migrations/\n";
    exit 1 if $opt{strict};
} else {
    print "Schema is in sync with the live database. No drift detected.\n";
}

exit 0;
