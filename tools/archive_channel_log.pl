#!/usr/bin/perl
# =============================================================================
#  tools/archive_channel_log.pl — Archivage et allegement de CHANNEL_LOG (mb566)
# =============================================================================
#  Troisieme outil de la famille CHANNEL_LOG :
#    - tools/measure_channel_log.pl : EXPLAIN/ANALYZE des requetes chaudes ;
#    - tools/analyze_channel_log.pl : inventaire (volume, annees, sante) ;
#    - tools/archive_channel_log.pl : CE fichier — exporte puis supprime des
#      tranches choisies, par lots, sans jamais bloquer le serveur.
#
#  PHILOSOPHIE DE SECURITE :
#    - DRY-RUN PAR DEFAUT : sans --execute, l'outil ne fait que compter et
#      montrer un echantillon de ce qui serait touche. AUCUNE ecriture.
#    - ARCHIVE AVANT SUPPRESSION : avec --execute, les lignes selectionnees
#      sont d'abord exportees en TSV compresse (gzip), le compte exporte est
#      verifie contre le compte selectionne, et SEULEMENT ENSUITE le DELETE
#      commence — par lots bornes, avec pause entre chaque lot.
#    - AUCUN VIDAGE ACCIDENTEL : --execute exige au moins un filtre
#      (--before / --month / --events / --channel).
#    - --no-archive existe pour du bruit avere (ex: un storm d'avril) mais
#      doit etre demande explicitement.
#
#  MODES :
#    Enquete   : --analyze-month YYYY-MM
#                Decompose un mois par jour, event_type, canal et top nicks
#                (agregats seulement) — pour QUALIFIER une anomalie avant de
#                toucher quoi que ce soit.
#    Selection : --before YYYY[-MM-DD]   lignes strictement anterieures
#                --month  YYYY-MM        lignes de ce mois exactement
#                --events a,b,c          event_type dans cette liste
#                --channel '#chan'       un canal precis
#                (filtres cumulables en AND)
#    Action    : (rien)      -> dry-run : comptes + echantillon
#                --execute   -> export gzip puis DELETE par lots
#
#  OPTIONS :
#    --conf FILE     Conf du bot (defaut mediabot.conf) — section [mysql].
#    --outdir DIR    Destination des archives (defaut var/archives).
#    --batch N       Taille des lots DELETE (defaut 50000, 1000..500000).
#    --sleep MS      Pause entre lots en millisecondes (defaut 200).
#    --no-archive    Supprime sans exporter (bruit avere uniquement).
#    --quiet         Moins de bavardage.
#
#  EXEMPLES (plan d'allegement type) :
#    # 1. Qualifier l'anomalie d'avril :
#    perl tools/archive_channel_log.pl --conf=mediabot.conf --analyze-month 2026-04
#    # 2. La purger (apres lecture du rapport, ex: bruit de presence) :
#    perl tools/archive_channel_log.pl --conf=mediabot.conf \
#         --month 2026-04 --events join,quit,mode,part --execute
#    # 3. Purger la vieille presence partout (le !seen vit sur USER_SEEN) :
#    perl tools/archive_channel_log.pl --conf=mediabot.conf \
#         --before 2026-04-01 --events join,quit,mode,part,nick,kick --execute
#
#  Apres un gros allegement, recuperer l'espace disque :
#    OPTIMIZE TABLE CHANNEL_LOG;   -- rebuild InnoDB, online sur MariaDB
# =============================================================================

use strict;
use warnings;
use Getopt::Long;
use DBI;
use POSIX qw(strftime);
use Time::Piece ();
use Encode ();

my $opt_conf    = 'mediabot.conf';
my $opt_outdir  = 'var/archives';
my $opt_before  = '';
my $opt_month   = '';
my $opt_events  = '';
my $opt_channel = '';
my $opt_analyze = '';
my $opt_execute = 0;
my $opt_noarch  = 0;
my $opt_batch   = 50000;
my $opt_sleep   = 200;
my $opt_quiet   = 0;

GetOptions(
    'conf=s'          => \$opt_conf,
    'outdir=s'        => \$opt_outdir,
    'before=s'        => \$opt_before,
    'month=s'         => \$opt_month,
    'events=s'        => \$opt_events,
    'channel=s'       => \$opt_channel,
    'analyze-month=s' => \$opt_analyze,
    'execute'         => \$opt_execute,
    'no-archive'      => \$opt_noarch,
    'batch=i'         => \$opt_batch,
    'sleep=i'         => \$opt_sleep,
    'quiet'           => \$opt_quiet,
) or die "Invalid options.\n";

$opt_batch = 1000   if $opt_batch < 1000;
$opt_batch = 500000 if $opt_batch > 500000;
$opt_sleep = 0      if $opt_sleep < 0;
$opt_sleep = 5000   if $opt_sleep > 5000;

sub say_out  { print "$_[0]\n" }
sub say_info { print "$_[0]\n" unless $opt_quiet }
sub hr { say_info('-' x 74) }

# ---------------------------------------------------------------------------
# Conf + connexion : meme moule que les deux outils freres.
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

my $tcp_host = ($dbhost eq 'localhost') ? '127.0.0.1' : $dbhost;
my $dsn = "DBI:MariaDB:database=$dbname;host=$tcp_host;port=$dbport";

my $dbh = eval { DBI->connect($dsn, $dbuser, $dbpass,
    { RaiseError => 0, PrintError => 0, AutoCommit => 1 }) };
unless ($dbh) {
    $dsn = "DBI:mysql:database=$dbname;host=$tcp_host;port=$dbport";
    $dbh = eval { DBI->connect($dsn, $dbuser, $dbpass,
        { RaiseError => 0, PrintError => 0, AutoCommit => 1 }) };
}
die "DB connect failed: " . ($DBI::errstr // 'unknown') . "\n" unless $dbh;

# mb571-B1: date parsing and month ranges stay index-friendly and reject
# impossible calendar values instead of relying on MariaDB coercion.
sub _valid_date {
    my ($value) = @_;
    return 0 unless defined $value && $value =~ /\A\d{4}-\d{2}-\d{2}\z/;
    my $ok = eval {
        my $tp = Time::Piece->strptime($value, '%Y-%m-%d');
        $tp->strftime('%Y-%m-%d') eq $value;
    };
    return $ok ? 1 : 0;
}

sub _month_bounds {
    my ($value) = @_;
    die "month expects YYYY-MM\n" unless defined $value && $value =~ /\A(\d{4})-(\d{2})\z/;
    my ($year, $month) = (int($1), int($2));
    die "month expects a real calendar month\n" if $month < 1 || $month > 12;
    my ($ny, $nm) = $month == 12 ? ($year + 1, 1) : ($year, $month + 1);
    return (sprintf('%04d-%02d-01', $year, $month), sprintf('%04d-%02d-01', $ny, $nm));
}

# ---------------------------------------------------------------------------
# Validation des filtres
# ---------------------------------------------------------------------------
my @where;
my @bind;

my ($analyze_start, $analyze_end);
if ($opt_analyze) {
    ($analyze_start, $analyze_end) = _month_bounds($opt_analyze);
}

if ($opt_before) {
    $opt_before = "$opt_before-01-01" if $opt_before =~ /\A\d{4}\z/;
    die "--before expects a real YYYY or YYYY-MM-DD date\n"
        unless _valid_date($opt_before);
    push @where, 'ts < ?';
    push @bind, $opt_before;
}
if ($opt_month) {
    my ($month_start, $month_end) = _month_bounds($opt_month);
    push @where, 'ts >= ? AND ts < ?';
    push @bind, $month_start, $month_end;
}
my @events;
if ($opt_events) {
    @events = grep { length } split /\s*,\s*/, lc $opt_events;
    die "--events: invalid event name '$_'\n"
        for grep { !/\A[a-z_]{1,16}\z/ } @events;
    push @where, 'event_type IN (' . join(',', ('?') x @events) . ')';
    push @bind, @events;
}
if ($opt_channel) {
    die "--channel expects a #channel\n" unless $opt_channel =~ /\A[#&][^\s,]{1,63}\z/;
    push @where, 'id_channel = (SELECT id_channel FROM CHANNEL WHERE name = ?)';
    push @bind, $opt_channel;
}

my $where_sql = @where ? join(' AND ', @where) : '';

sub fmt_n {
    my ($n) = @_;
    return '?' unless defined $n;
    1 while $n =~ s/^(\d+)(\d{3})/$1 $2/;
    return $n;
}

# ---------------------------------------------------------------------------
# Mode enquete : --analyze-month
# ---------------------------------------------------------------------------
if ($opt_analyze) {
    hr(); say_out("[enquete] $opt_analyze — decomposition"); hr();

    my $run = sub {
        my ($label, $sql) = @_;
        my $sth = $dbh->prepare($sql) or return;
        $sth->execute($analyze_start, $analyze_end) or return;
        say_out('');
        say_out("$label:");
        while (my $r = $sth->fetchrow_arrayref) {
            say_out(sprintf('  %-24s : %12s', $r->[0] // '(null)', fmt_n($r->[1])));
        }
        $sth->finish;
    };

    $run->('Par jour', q{
        SELECT DATE(ts), COUNT(*) FROM CHANNEL_LOG
        WHERE ts >= ? AND ts < ?
        GROUP BY DATE(ts) ORDER BY 1
    });
    $run->('Par event_type', q{
        SELECT event_type, COUNT(*) FROM CHANNEL_LOG
        WHERE ts >= ? AND ts < ?
        GROUP BY event_type ORDER BY 2 DESC
    });
    $run->('Par canal', q{
        SELECT c.name, COUNT(*) FROM CHANNEL_LOG cl
        JOIN CHANNEL c ON c.id_channel = cl.id_channel
        WHERE cl.ts >= ? AND cl.ts < ?
        GROUP BY c.name ORDER BY 2 DESC LIMIT 15
    });
    $run->('Top nicks', q{
        SELECT nick, COUNT(*) FROM CHANNEL_LOG
        WHERE ts >= ? AND ts < ?
        GROUP BY nick ORDER BY 2 DESC LIMIT 15
    });

    say_out('');
    say_out('Quand le bruit est identifie, rejouez avec --month ' . $opt_analyze
          . ' --events ... (dry-run), puis ajoutez --execute.');
    $dbh->disconnect;
    exit 0;
}

# ---------------------------------------------------------------------------
# Selection : dry-run ou execution
# ---------------------------------------------------------------------------
die "Nothing selected: use --analyze-month, or at least one of --before/--month/--events/--channel.\n"
    unless $where_sql;

# mb571-B1: freeze the selected set at a primary-key high-water mark. Rows
# arriving while a long gzip export runs have higher ids and can never be
# deleted by this invocation without having been exported.
my $count_sth = $dbh->prepare(
    "SELECT COUNT(*), MAX(id_channel_log) FROM CHANNEL_LOG WHERE $where_sql")
    or die "prepare failed\n";
$count_sth->execute(@bind) or die "count failed: " . ($dbh->errstr // '?') . "\n";
my ($selected, $high_water) = $count_sth->fetchrow_array;
$count_sth->finish;
$selected //= 0;
$high_water = 0 unless defined $high_water;
my $snapshot_where = "($where_sql) AND id_channel_log <= ?";
my @snapshot_bind = (@bind, $high_water);

hr();
say_out(sprintf('Selection: %s ligne(s) — WHERE %s', fmt_n($selected), $where_sql));
hr();

if (!$opt_execute) {
    # DRY-RUN : un apercu, aucune ecriture.
    my $sample = $dbh->prepare(
        "SELECT ts, event_type, nick FROM CHANNEL_LOG WHERE $snapshot_where ORDER BY ts LIMIT 5");
    if ($sample && $sample->execute(@snapshot_bind)) {
        say_out('Apercu (5 premieres, ts/event/nick — jamais le contenu):');
        while (my $r = $sample->fetchrow_arrayref) {
            say_out(sprintf('  %s  %-8s  %s', $r->[0], $r->[1] // '?', $r->[2] // '?'));
        }
        $sample->finish;
    }
    say_out('');
    say_out('DRY-RUN: rien n\'a ete modifie. Ajoutez --execute pour archiver puis supprimer.');
    $dbh->disconnect;
    exit 0;
}

exit 0 unless $selected;

# ---------------------------------------------------------------------------
# EXECUTION : export gzip d'abord (sauf --no-archive), verification, DELETE
# par lots ensuite.
# ---------------------------------------------------------------------------
my $archive_file;
if (!$opt_noarch) {
    my $ok_gz = eval { require IO::Compress::Gzip; 1 };
    die "IO::Compress::Gzip unavailable (core module) — cannot archive\n" unless $ok_gz;

    unless (-d $opt_outdir) {
        mkdir $opt_outdir, 0700 or die "Cannot create $opt_outdir: $!\n";
    }
    chmod 0700, $opt_outdir or die "Cannot protect $opt_outdir: $!\n";
    my $stamp = strftime('%Y%m%d_%H%M%S', localtime);
    $archive_file = "$opt_outdir/channel_log_archive_${stamp}_$$.tsv.gz";
    die "Refusing to overwrite existing archive $archive_file\n" if -e $archive_file;

    # Colonnes decouvertes dynamiquement : l'archive suit le schema reel.
    my @cols;
    my $cols_sth = $dbh->prepare(q{SHOW COLUMNS FROM CHANNEL_LOG});
    if ($cols_sth && $cols_sth->execute) {
        while (my $r = $cols_sth->fetchrow_hashref) { push @cols, $r->{Field} }
        $cols_sth->finish;
    }
    die "Cannot discover CHANNEL_LOG columns\n" unless @cols;

    my $gz = IO::Compress::Gzip->new($archive_file)
        or die "Cannot open $archive_file for writing\n";
    chmod 0600, $archive_file or die "Cannot protect $archive_file: $!\n";
    $gz->print(join("\t", @cols) . "\n");

    my $col_list = join(', ', map { "`$_`" } @cols);
    my $exp = $dbh->prepare("SELECT $col_list FROM CHANNEL_LOG WHERE $snapshot_where")
        or die "export prepare failed\n";
    $exp->execute(@snapshot_bind) or die "export failed: " . ($dbh->errstr // '?') . "\n";

    my $exported = 0;
    while (my $r = $exp->fetchrow_arrayref) {
        my @vals = map {
            # TSV convention: an actual SQL NULL is the unescaped token \N;
            # a literal backslash-N string is escaped to \\N and remains distinct.
            if (!defined $_) {
                '\N';
            }
            else {
                my $v = $_;
                $v =~ s{\\}{\\\\}g; $v =~ s{\t}{\\t}g; $v =~ s{\n}{\\n}g; $v =~ s{\r}{\\r}g;
                # mb567-B1: the driver returns characters; encode bytes before gzip.
                $v = Encode::encode('UTF-8', $v) if utf8::is_utf8($v);
                $v;
            }
        } @$r;
        $gz->print(join("\t", @vals) . "\n");
        $exported++;
    }
    $exp->finish;
    $gz->close;

    say_out(sprintf('Archive: %s (%s ligne(s) exportee(s))', $archive_file, fmt_n($exported)));
    unless ($exported == $selected) {
        die sprintf("ABORT: exported %s != selected %s — nothing deleted, archive kept for inspection.\n",
            fmt_n($exported), fmt_n($selected));
    }
}
else {
    say_out('--no-archive: suppression SANS export (demande explicitement).');
}

# DELETE par lots : jamais un DELETE monolithique de plusieurs millions de
# lignes (verrous, undo log, replication). Chaque lot est borne et suivi
# d'une pause pour laisser le serveur respirer.
my $deleted = 0;
my $del = $dbh->prepare("DELETE FROM CHANNEL_LOG WHERE $snapshot_where LIMIT $opt_batch")
    or die "delete prepare failed\n";
while (1) {
    my $ok = $del->execute(@snapshot_bind);
    die "delete failed after $deleted rows: " . ($dbh->errstr // '?') . "\n" unless $ok;
    my $n = $del->rows // 0;
    last if $n <= 0;
    $deleted += $n;
    say_info(sprintf('  ... %s / %s', fmt_n($deleted), fmt_n($selected)));
    select(undef, undef, undef, $opt_sleep / 1000) if $opt_sleep && $n >= $opt_batch;
}
$del->finish;

hr();
say_out(sprintf('Termine: %s ligne(s) supprimee(s).', fmt_n($deleted)));
say_out("Archive conservee: $archive_file") if $archive_file;
say_out('Pour rendre l\'espace disque: OPTIMIZE TABLE CHANNEL_LOG; (rebuild online MariaDB)');
$dbh->disconnect;
exit 0;
