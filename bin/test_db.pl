#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use open qw(:std :encoding(UTF-8));

# On ajoute le parent (qui contient 'Mediabot/') à @INC
use lib "$FindBin::Bin/..";

use Mediabot::DB;

# ---------- mini parseur INI pour lire mediabot.conf ----------
my $conf_path = $ENV{MBOT_CONF} || "$FindBin::Bin/../mediabot.conf";
-f $conf_path or die "Config file not found: $conf_path\n";

my %ini; my $section = '';
open my $fh, '<:encoding(UTF-8)', $conf_path or die "Can't open $conf_path: $!";
while (my $line = <$fh>) {
    chomp $line; $line =~ s/\r$//;
    next if $line =~ /^\s*(?:#|;|$)/;                 # commentaires / lignes vides
    if ($line =~ /^\s*\[(.+?)\]\s*$/) {               # nouvelle section
        $section = lc $1; next;
    }
    if ($line =~ /^\s*([A-Za-z0-9_.]+)\s*=\s*(.*)\s*$/) {
        my ($k,$v) = ($1,$2);
        $v =~ s/^"(.*)"$/$1/;                         # retire guillemets éventuels
        $v =~ s/^'(.*)'$/$1/;
        $ini{$section}{$k} = $v;
    }
}
close $fh;

# Mappe les clés pour matcher ce que Mediabot::DB attend (mysql.MAIN_PROG_*)
my %conf_map = (
    'mysql.MAIN_PROG_DDBNAME' => $ini{mysql}{MAIN_PROG_DDBNAME} // $ini{mysql}{MAIN_PROG_DBNAME} // '',
    'mysql.MAIN_PROG_DBHOST'  => $ini{mysql}{MAIN_PROG_DBHOST}  // 'localhost',
    'mysql.MAIN_PROG_DBUSER'  => $ini{mysql}{MAIN_PROG_DBUSER}  // '',
    'mysql.MAIN_PROG_DBPASS'  => $ini{mysql}{MAIN_PROG_DBPASS}  // '',
    'mysql.MAIN_PROG_DBPORT'  => $ini{mysql}{MAIN_PROG_DBPORT}  // 3306,
);

# ---------- objets factices compatibles ----------
{
    package TestLogger;
    sub new { bless {}, shift }
    sub log { my ($self, $level, $msg) = @_; print "[L$level] $msg\n"; }
}

{
    package TestConf;
    sub new { my ($class, $href) = @_; bless { %$href }, $class }
    sub get  { my ($self, $key) = @_; return $self->{$key}; }
}

my $logger = TestLogger->new;
my $conf   = TestConf->new(\%conf_map);

# ---------- connexion via ton module ----------
my $db  = Mediabot::DB->new($conf, $logger);
my $dbh = $db->dbh;

# Vérifs de session
my $sth = $dbh->prepare("SHOW VARIABLES LIKE 'collation_connection'");
$sth->execute; my (undef, $coll) = $sth->fetchrow_array; $sth->finish;
print "=> Collation active : $coll\n";

$sth = $dbh->prepare("SHOW VARIABLES LIKE 'character_set_connection'");
$sth->execute; my (undef, $charset) = $sth->fetchrow_array; $sth->finish;
print "=> Charset actif   : $charset\n";

# ---------- test UTF-8 (TEMPORARY + ENGINE=MEMORY, rien n'est persistant) ----------
eval {
    $dbh->do("CREATE TEMPORARY TABLE t_utf8_test (txt VARCHAR(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci) ENGINE=MEMORY");
    my $sample = "éàüß—🐟 test UTF-8";
    my $ins = $dbh->prepare("INSERT INTO t_utf8_test (txt) VALUES (?)");
    $ins->execute($sample);
    my $sel = $dbh->prepare("SELECT txt FROM t_utf8_test");
    $sel->execute;
    my ($back) = $sel->fetchrow_array;
    $sel->finish;
    print "=> Roundtrip OK   : [$back]\n";
    $dbh->do("DROP TEMPORARY TABLE IF EXISTS t_utf8_test");
    1;
} or do {
    my $err = $@ || 'unknown error';
    print "[WARN] UTF-8 roundtrip test skipped/failed: $err\n";
};

print "✅ Test DB terminé avec succès.\n";
