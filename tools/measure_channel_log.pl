#!/usr/bin/perl
# =============================================================================
#  tools/measure_channel_log.pl — Mesure des requêtes CHANNEL_LOG (A4 / mb470)
# =============================================================================
#  Direction 3.3 §2.4 / Phase A / A4 : « appliquer et vérifier l'index composite
#  prévu pour CHANNEL_LOG ; exécuter EXPLAIN ANALYZE sur les requêtes lentes ;
#  mesurer m check, achievements et stats sur la vraie base ; décider seulement
#  si les scans restent coûteux. » Aucune nouvelle table de compteurs sans
#  preuve que les index et caches existants restent insuffisants.
#
#  Ce script, en LECTURE SEULE :
#    1. lit la conf du bot ([mysql] MAIN_PROG_*) pour se connecter comme lui ;
#    2. rejoue les requêtes CHAUDES réellement émises sur CHANNEL_LOG
#       (m check, total canal, hourband achievements, polyphony, période) ;
#    3. pour chacune : EXPLAIN (plan + index choisi) et, si le serveur le
#       supporte (MariaDB >= 10.1 / MySQL >= 8.0.18), ANALYZE/EXPLAIN ANALYZE
#       (temps réel + lignes lues) ;
#    4. indique si l'index composite idx_channel_log_channel_ts est présent et
#       s'il est effectivement choisi par l'optimiseur.
#
#  Il ne CRÉE ni ne MODIFIE aucun index : lancez-le AVANT puis APRÈS la
#  migration 20260706_channel_log_channel_ts.sql pour comparer les plans.
#
#  Usage :
#    perl tools/measure_channel_log.pl --conf=mediabot.conf [options]
#
#    --conf FILE        Fichier de conf du bot (défaut: mediabot.conf).
#    --channel '#chan'  Canal réel à mesurer (sinon : le plus actif détecté).
#    --nick NICK        Nick réel à mesurer (sinon : le plus actif du canal).
#    --days N           Fenêtre de période pour la requête à plage (défaut 30).
#    --no-analyze       Ne pas tenter ANALYZE (EXPLAIN seul).
#    --quiet            Moins de bavardage.
#
#  Rien n'est écrit dans la base. Aucune donnée sensible n'est affichée
#  (ni mot de passe, ni contenu de messages).
# =============================================================================

use strict;
use warnings;
use Getopt::Long;
use DBI;

my $opt_conf    = 'mediabot.conf';
my $opt_channel = '';
my $opt_nick    = '';
my $opt_days    = 30;
my $opt_no_anal = 0;
my $opt_quiet   = 0;

GetOptions(
    'conf=s'    => \$opt_conf,
    'channel=s' => \$opt_channel,
    'nick=s'    => \$opt_nick,
    'days=i'    => \$opt_days,
    'no-analyze'=> \$opt_no_anal,
    'quiet'     => \$opt_quiet,
) or die "Invalid options.\n";

sub say_info { print "$_[0]\n" unless $opt_quiet }
sub say_out  { print "$_[0]\n" }
sub hr { say_out('-' x 74) }

# ---------------------------------------------------------------------------
# Lecture minimale de la conf (format INI [section] key=value).
# On ne charge pas tout le bot : on lit juste la section [mysql].
# ---------------------------------------------------------------------------
sub read_conf {
    my ($file) = @_;
    open my $fh, '<', $file or die "Cannot read conf $file: $!\n";
    my %kv;
    my $section = '';
    while (my $l = <$fh>) {
        chomp $l; $l =~ s/\r$//;
        next if $l =~ /^\s*[#;]/ || $l =~ /^\s*$/;
        if ($l =~ /^\s*\[(.+?)\]\s*$/) { $section = $1; next }
        if ($l =~ /^\s*([^=]+?)\s*=\s*(.*?)\s*$/) {
            my ($k, $v) = ($1, $2);
            $v =~ s/^"(.*)"$/$1/;
            $kv{"$section.$k"} = $v;
        }
    }
    close $fh;
    return \%kv;
}

my $conf = read_conf($opt_conf);

my $dbhost = $conf->{'mysql.MAIN_PROG_DBHOST'} // 'localhost';
my $dbport = $conf->{'mysql.MAIN_PROG_DBPORT'} // 3306;
my $dbname = $conf->{'mysql.MAIN_PROG_DDBNAME'} // $conf->{'mysql.MAIN_PROG_DBNAME'};
my $dbuser = $conf->{'mysql.MAIN_PROG_DBUSER'};
my $dbpass = $conf->{'mysql.MAIN_PROG_DBPASS'} // '';

die "Missing [mysql] DB config (DDBNAME/DBUSER) in $opt_conf\n"
    unless defined $dbname && defined $dbuser;

# Comme le bot : localhost -> 127.0.0.1 pour forcer TCP.
my $tcp_host = ($dbhost eq 'localhost') ? '127.0.0.1' : $dbhost;
my $dsn = "DBI:MariaDB:database=$dbname;host=$tcp_host;port=$dbport";

my $dbh = eval { DBI->connect($dsn, $dbuser, $dbpass,
    { RaiseError => 0, PrintError => 0, AutoCommit => 1 }) };
unless ($dbh) {
    # Repli sur le driver mysql si MariaDB n'est pas dispo.
    $dsn = "DBI:mysql:database=$dbname;host=$tcp_host;port=$dbport";
    $dbh = eval { DBI->connect($dsn, $dbuser, $dbpass,
        { RaiseError => 0, PrintError => 0, AutoCommit => 1 }) };
}
die "DB connect failed: " . ($DBI::errstr // 'unknown') . "\n" unless $dbh;

say_info("=" x 74);
say_info("CHANNEL_LOG query measurement (A4)");
say_info("  db: $dbname\@$tcp_host:$dbport  user: $dbuser");
say_info("=" x 74);

# ---------------------------------------------------------------------------
# Contexte serveur + présence de l'index composite.
# ---------------------------------------------------------------------------
my ($ver) = $dbh->selectrow_array("SELECT VERSION()");
say_info("  server version: " . ($ver // '?'));

my $has_analyze = 0;
if (defined $ver) {
    # MariaDB >= 10.1 : ANALYZE <stmt> ; MySQL >= 8.0.18 : EXPLAIN ANALYZE.
    if ($ver =~ /MariaDB/i && $ver =~ /(\d+)\.(\d+)/) {
        $has_analyze = ($1 > 10 || ($1 == 10 && $2 >= 1));
    }
    elsif ($ver =~ /^(\d+)\.(\d+)\.(\d+)/) {
        $has_analyze = ($1 > 8 || ($1 == 8 && ($2 > 0 || $3 >= 18)));
    }
}
$has_analyze = 0 if $opt_no_anal;

# L'index composite est-il présent ?
my $idx_present = $dbh->selectrow_array(q{
    SELECT COUNT(*) FROM information_schema.STATISTICS
    WHERE table_schema = ? AND table_name = 'CHANNEL_LOG'
      AND index_name = 'idx_channel_log_channel_ts'
}, undef, $dbname) ? 1 : 0;

say_info("  composite index idx_channel_log_channel_ts: "
         . ($idx_present ? "PRESENT" : "ABSENT (run the migration to add it)"));
say_info("  ANALYZE timing available: " . ($has_analyze ? "yes" : "no (EXPLAIN only)"));

# Lister les index actuels de CHANNEL_LOG (diagnostic).
say_info("\nCurrent CHANNEL_LOG indexes:");
my $sth_idx = $dbh->prepare(q{
    SELECT index_name, seq_in_index, column_name
    FROM information_schema.STATISTICS
    WHERE table_schema = ? AND table_name = 'CHANNEL_LOG'
    ORDER BY index_name, seq_in_index
});
if ($sth_idx && $sth_idx->execute($dbname)) {
    my %cols;
    while (my ($iname, $seq, $col) = $sth_idx->fetchrow_array) {
        push @{ $cols{$iname} }, $col;
    }
    for my $iname (sort keys %cols) {
        say_info("  - $iname (" . join(', ', @{ $cols{$iname} }) . ")");
    }
}

# ---------------------------------------------------------------------------
# Choix du canal et du nick de mesure (le plus actif si non fourni).
# ---------------------------------------------------------------------------
if ($opt_channel eq '') {
    ($opt_channel) = $dbh->selectrow_array(q{
        SELECT c.name
        FROM CHANNEL_LOG cl JOIN CHANNEL c ON c.id_channel = cl.id_channel
        WHERE c.name LIKE '#%'
        GROUP BY c.name ORDER BY COUNT(*) DESC LIMIT 1
    });
}
die "No channel found to measure (empty CHANNEL_LOG?).\n" unless defined $opt_channel;

if ($opt_nick eq '') {
    ($opt_nick) = $dbh->selectrow_array(q{
        SELECT cl.nick
        FROM CHANNEL_LOG cl JOIN CHANNEL c ON c.id_channel = cl.id_channel
        WHERE c.name = ? AND cl.event_type IN ('public','action')
        GROUP BY cl.nick ORDER BY COUNT(*) DESC LIMIT 1
    }, undef, $opt_channel);
}
$opt_nick //= 'nobody';

say_info("\n  measuring channel: $opt_channel   nick: $opt_nick   period: ${opt_days}d");

# ---------------------------------------------------------------------------
# Les requêtes CHAUDES à mesurer (extraites du code réel).
#   Chaque entrée : nom, SQL, binds.
# ---------------------------------------------------------------------------
my @queries = (
    # NB: les requêtes m check du code ajoutent un filtre REGEXP anti « m stats »
    # sur publictext. Il est volontairement OMIS ici : il n'influe pas sur le
    # choix d'index (non SARGable, appliqué après l'accès par nick+canal) et
    # alourdirait la lecture du plan. Le cœur WHERE (nick + c.name / c.name)
    # est identique au code réel.
    {
        name => 'm check — user aggregate (COUNT/MAX/MIN ts, per nick+channel)',
        sql  => q{
            SELECT COUNT(*) AS msg_count, MAX(ts) AS last_msg, MIN(ts) AS first_seen
            FROM CHANNEL_LOG cl
            JOIN CHANNEL c ON c.id_channel = cl.id_channel
            WHERE LOWER(cl.nick) = LOWER(?) AND c.name = ?
        },
        binds => [ $opt_nick, $opt_channel ],
    },
    {
        name => 'm check — channel total (COUNT, per channel)',
        sql  => q{
            SELECT COUNT(*) AS total
            FROM CHANNEL_LOG cl
            JOIN CHANNEL c ON c.id_channel = cl.id_channel
            WHERE c.name = ?
        },
        binds => [ $opt_channel ],
    },
    {
        name => 'achievements — hourband (GROUP BY HOUR(ts), per nick+channel)',
        sql  => q{
            SELECT HOUR(cl.ts) AS h, COUNT(*) AS c
            FROM CHANNEL_LOG cl
            JOIN CHANNEL c ON c.id_channel = cl.id_channel
            WHERE c.name = ? AND cl.nick = ?
              AND cl.event_type IN ('public','action')
            GROUP BY HOUR(cl.ts)
        },
        binds => [ $opt_channel, $opt_nick ],
    },
    {
        name => 'achievements — polyphony (COUNT DISTINCT channels, per nick)',
        sql  => q{
            SELECT COUNT(DISTINCT c.name) AS n
            FROM CHANNEL_LOG cl
            JOIN CHANNEL c ON c.id_channel = cl.id_channel
            WHERE cl.nick = ?
              AND cl.event_type IN ('public','action')
              AND c.name LIKE '#%'
        },
        binds => [ $opt_nick ],
    },
    {
        name => "report — channel activity over period (id_channel + ts range)",
        sql  => qq{
            SELECT COUNT(*) AS c
            FROM CHANNEL_LOG cl
            JOIN CHANNEL c ON c.id_channel = cl.id_channel
            WHERE c.name = ?
              AND cl.ts >= DATE_SUB(NOW(), INTERVAL ? DAY)
        },
        binds => [ $opt_channel, $opt_days ],
    },
);

# ---------------------------------------------------------------------------
# Exécuteur : EXPLAIN (+ ANALYZE si dispo) pour une requête.
# ---------------------------------------------------------------------------
sub explain_query {
    my ($q) = @_;
    hr();
    say_out("QUERY: $q->{name}");

    # EXPLAIN classique : type d'accès, clé choisie, rows estimées.
    my $sth = $dbh->prepare("EXPLAIN " . $q->{sql});
    if ($sth && $sth->execute(@{ $q->{binds} })) {
        say_out("  EXPLAIN:");
        while (my $r = $sth->fetchrow_hashref) {
            my $tbl  = $r->{table}        // '?';
            my $type = $r->{type}         // '?';
            my $key  = $r->{key}          // 'NULL';
            my $keys = $r->{possible_keys}// 'NULL';
            my $rows = $r->{rows}         // '?';
            my $extra= $r->{Extra}        // '';
            say_out(sprintf("    table=%-6s type=%-8s key=%-28s rows=%-8s %s",
                            $tbl, $type, $key, $rows, $extra));
        }
        $sth->finish;
    }
    else {
        say_out("  EXPLAIN failed: " . ($dbh->errstr // 'unknown'));
    }

    # ANALYZE / EXPLAIN ANALYZE : temps réel + lignes réellement lues.
    if ($has_analyze) {
        my $prefix = ($ver =~ /MariaDB/i) ? "ANALYZE " : "EXPLAIN ANALYZE ";
        my $sth2 = $dbh->prepare($prefix . $q->{sql});
        if ($sth2 && $sth2->execute(@{ $q->{binds} })) {
            say_out("  " . ($ver =~ /MariaDB/i ? "ANALYZE" : "EXPLAIN ANALYZE") . ":");
            while (my @row = $sth2->fetchrow_array) {
                # MariaDB ANALYZE renvoie les colonnes d'EXPLAIN + r_rows/r_total_time_ms.
                # MySQL EXPLAIN ANALYZE renvoie une seule colonne texte multi-lignes.
                my $line = join('  ', map { defined $_ ? $_ : 'NULL' } @row);
                say_out("    $line");
            }
            $sth2->finish;
        }
        else {
            say_out("  ANALYZE failed: " . ($dbh->errstr // 'unknown'));
        }
    }
}

for my $q (@queries) {
    explain_query($q);
}

hr();
say_out("\nInterpretation guide:");
say_out("  - Before the migration, per-channel queries typically show");
say_out("    key=idx_channel_log_id_channel (or ts) and larger rows scanned.");
say_out("  - After it, queries filtering by channel then time should pick");
say_out("    key=idx_channel_log_channel_ts with fewer rows examined.");
say_out("  - If EXPLAIN still ignores the composite index and ANALYZE times");
say_out("    stay high, THEN consider further work (per the 3.3 direction,");
say_out("    a counters table is justified only once indexes prove insufficient).");
say_out("  - Run this BEFORE and AFTER applying the migration and compare.");

$dbh->disconnect;
exit 0;
