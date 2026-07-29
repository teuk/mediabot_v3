#!/usr/bin/perl
# =============================================================================
# tools/archive_channel_log_once.pl — archivage PONCTUEL de CHANNEL_LOG,
# strictement identique a ce que fait la tache quotidienne du bot
# (Mediabot::archive_channel_log, mb569/mb570/mb571), mais lance a la main
# avec la conf d'une instance. mb579-B1.
#
#   perl tools/archive_channel_log_once.pl --conf /path/mbundernet.conf
#       -> DRY-RUN (defaut) : compte ce qui serait deplace, ne touche a rien.
#   perl tools/archive_channel_log_once.pl --conf ... --execute
#       -> UN run identique au bot (borne par MAX_PER_RUN).
#   perl tools/archive_channel_log_once.pl --conf ... --execute --loop
#       -> enchaine les runs (pause --sleep entre chaque, defaut 2 s)
#          jusqu'a ce qu'un run ne deplace plus rien : rattrapage complet.
#
# Fidelite au bot (memes cles [mysql], memes bornes, meme flux) :
#   - CHANNEL_LOG_ARCHIVE_DBNAME valide \A[A-Za-z0-9_]{1,64}\z, sinon refus ;
#   - PRESENCE_DAYS borne [1..3650] defaut 7 ; EVENTS defaut presence ;
#   - CONTENT_DAYS borne [0..36500] defaut 0 (opt-in) ; CONTENT_EVENTS ;
#   - MAX_PER_RUN borne [5000..2000000] defaut 200000 ;
#   - CREATE TABLE IF NOT EXISTS <adb>.CHANNEL_LOG_ARCHIVE LIKE CHANNEL_LOG ;
#   - par lots de 5000 ids (ORDER BY id_channel_log), plafond STRICT ;
#   - INSERT IGNORE -> VERIFY d'identite (BINARY sur chaque champ, jamais la
#     seule PK : une archive partagee mal configuree pourrait contenir une
#     ligne etrangere avec le meme id) -> DELETE ; toute anomalie stoppe le
#     lot AVANT le delete : rien n'est perdu, rejouable.
#
# Aucun backtick d'identifiant (audit securite) ; le mot de passe n'est
# jamais imprime.
# =============================================================================

use strict;
use warnings;
use DBI;
use Getopt::Long qw(GetOptions);
use Time::HiRes qw(time sleep);

my $opt_conf    = '';
my $opt_diag    = 0;
my $opt_align   = 0;
my $opt_execute = 0;
my $opt_loop    = 0;
my $opt_sleep   = 2;
my $opt_max     = 0;   # 0 = valeur de la conf
my $opt_quiet   = 0;

GetOptions(
    'conf=s'        => \$opt_conf,
    'diagnose'      => \$opt_diag,
    'align-archive-channel-ids' => \$opt_align,
    'execute'       => \$opt_execute,
    'loop'          => \$opt_loop,
    'sleep=f'       => \$opt_sleep,
    'max-per-run=i' => \$opt_max,
    'quiet'         => \$opt_quiet,
) or die "Invalid options.\n";

die "Usage: $0 --conf /path/instance.conf [--execute [--loop] [--sleep N] [--max-per-run N]]\n"
    unless length $opt_conf;
die "--loop requires --execute (a dry-run has nothing to repeat).\n"
    if $opt_loop && !$opt_execute;
die "--diagnose is read-only and cannot be combined with --execute.\n"
    if $opt_diag && $opt_execute;
die "--align-archive-channel-ids cannot be combined with --diagnose or --loop.\n"
    if $opt_align && ($opt_diag || $opt_loop);
$opt_sleep = 0  if $opt_sleep < 0;
$opt_sleep = 60 if $opt_sleep > 60;

sub say_out  { print "$_[0]\n" }
sub say_info { print "$_[0]\n" unless $opt_quiet }

# ---------------------------------------------------------------------------
# Lecture minimale de la conf (meme moule que analyze/measure_channel_log) :
# format INI [section] key=value, seule la section [mysql] est utilisee.
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

# ---------------------------------------------------------------------------
# Politiques : memes cles, memes defauts, memes bornes que le bot.
# ---------------------------------------------------------------------------
my $adb = $conf->{'mysql.CHANNEL_LOG_ARCHIVE_DBNAME'} // '';
die "CHANNEL_LOG_ARCHIVE_DBNAME is empty in $opt_conf: archiving is disabled for this instance.\n"
    unless length $adb;
die "Invalid ARCHIVE_DBNAME '$adb' (expected [A-Za-z0-9_]{1,64}).\n"
    unless $adb =~ /\A[A-Za-z0-9_]{1,64}\z/;

my $p_days = int($conf->{'mysql.CHANNEL_LOG_ARCHIVE_PRESENCE_DAYS'} // 7);
$p_days = 1    if $p_days < 1;
$p_days = 3650 if $p_days > 3650;

my @p_events = grep { /\A[a-z_]{1,16}\z/ } map { lc } grep { length }
    split /\s*,\s*/, ($conf->{'mysql.CHANNEL_LOG_ARCHIVE_EVENTS'} // 'join,quit,mode,part,nick,kick');
die "No valid event in CHANNEL_LOG_ARCHIVE_EVENTS.\n" unless @p_events;

my $c_days = int($conf->{'mysql.CHANNEL_LOG_ARCHIVE_CONTENT_DAYS'} // 0);
$c_days = 0     if $c_days < 0;
$c_days = 36500 if $c_days > 36500;

my @c_events = grep { /\A[a-z_]{1,16}\z/ } map { lc } grep { length }
    split /\s*,\s*/, ($conf->{'mysql.CHANNEL_LOG_ARCHIVE_CONTENT_EVENTS'} // 'public,action,notice,topic,invite');
die "CONTENT_DAYS is enabled but CHANNEL_LOG_ARCHIVE_CONTENT_EVENTS has no valid event.\n"
    if $c_days > 0 && !@c_events;

my $max_run = $opt_max > 0 ? $opt_max
    : int($conf->{'mysql.CHANNEL_LOG_ARCHIVE_MAX_PER_RUN'} // 200000);
$max_run = 5000    if $max_run < 5000;
$max_run = 2000000 if $max_run > 2000000;

# ---------------------------------------------------------------------------
# Connexion (comme le bot : localhost -> 127.0.0.1 pour forcer TCP).
# ---------------------------------------------------------------------------
my $tcp_host = ($dbhost eq 'localhost') ? '127.0.0.1' : $dbhost;
my $dsn = "DBI:MariaDB:database=$dbname;host=$tcp_host;port=$dbport";
my $dbh = eval { DBI->connect($dsn, $dbuser, $dbpass,
    { RaiseError => 0, PrintError => 0, AutoCommit => 1 }) };
unless ($dbh) {
    $dsn = "DBI:mysql:database=$dbname;host=$tcp_host;port=$dbport";
    $dbh = eval { DBI->connect($dsn, $dbuser, $dbpass,
        { RaiseError => 0, PrintError => 0, AutoCommit => 1 }) };
    die "Cannot connect to $dbname\@$tcp_host:$dbport as $dbuser"
      . " (tried DBD::MariaDB then DBD::mysql).\n" unless $dbh;
}
eval { $dbh->do("SET NAMES utf8mb4") };

my $atable = "$adb.CHANNEL_LOG_ARCHIVE";

say_info("archive_channel_log_once — instance conf: $opt_conf");
say_info("  live table : $dbname.CHANNEL_LOG");
say_info("  archive    : $atable");
say_info("  presence   : > $p_days day(s), events " . join(',', @p_events));
say_info($c_days > 0
    ? "  content    : > $c_days day(s), events " . join(',', @c_events)
    : "  content    : DISABLED (CONTENT_DAYS=0)");
say_info("  max/run    : $max_run" . ($opt_loop ? " (loop until drained)" : ""));
say_info("  mode       : " . ($opt_execute ? "EXECUTE" : "DRY-RUN (nothing will be written)"));
say_info('-' x 74);

my @policies = ( [ 'presence', $p_days, \@p_events ] );
push @policies, [ 'content', $c_days, \@c_events ] if $c_days > 0 && @c_events;

# ---------------------------------------------------------------------------
# mb581-B1: --align-archive-channel-ids — repare le SEUL cas prouve par le
# diagnose Undernet : memes evenements (meme PK, ts/event/nick/host/texte
# identiques a l'octet) mais id_channel divergent — l'archive porte un
# referentiel de canaux d'une autre epoque. Le vif joint la table CHANNEL
# COURANTE et fait autorite : chaque ligne d'archive par ailleurs IDENTIQUE
# est realignee sur l'id_channel du vif. ECRIT UNIQUEMENT L'ARCHIVE — le
# vif n'est jamais modifie. Dry-run par defaut (compte) ; --execute pour
# agir, par lots de 5000 PK, budget max-per-run par invocation. Une ligne
# qui differe par AUTRE CHOSE que id_channel n'est JAMAIS touchee.
# ---------------------------------------------------------------------------
if ($opt_align) {
    my $ident =
        " arch.ts <=> live.ts"
      . " AND BINARY COALESCE(arch.event_type,'') = BINARY COALESCE(live.event_type,'')"
      . " AND BINARY COALESCE(arch.nick,'') = BINARY COALESCE(live.nick,'')"
      . " AND BINARY COALESCE(arch.userhost,'') = BINARY COALESCE(live.userhost,'')"
      . " AND BINARY COALESCE(arch.publictext,'') = BINARY COALESCE(live.publictext,'')";
    my ($n) = $dbh->selectrow_array(
        "SELECT COUNT(*) FROM $atable arch"
      . " JOIN CHANNEL_LOG live ON live.id_channel_log = arch.id_channel_log"
      . " WHERE NOT (arch.id_channel <=> live.id_channel) AND" . $ident);
    $n //= 0;
    say_out("[align] archive rows identical to live except id_channel: $n");
    unless ($opt_execute) {
        say_out("[align] dry-run — add --execute to realign these rows"
              . " (archive-only UPDATE, live table untouched).");
        exit 0;
    }
    my $fixed = 0;
    while ($fixed < $max_run) {
        my $ids = $dbh->selectcol_arrayref(
            "SELECT arch.id_channel_log FROM $atable arch"
          . " JOIN CHANNEL_LOG live ON live.id_channel_log = arch.id_channel_log"
          . " WHERE NOT (arch.id_channel <=> live.id_channel) AND" . $ident
          . " ORDER BY arch.id_channel_log LIMIT 5000");
        die "[align] select failed: " . ($dbh->errstr // 'unknown') . "\n"
            unless defined $ids;
        last unless @$ids;
        my $remaining = $max_run - $fixed;
        splice(@$ids, $remaining) if @$ids > $remaining;
        my $in_ids = join(',', ('?') x @$ids);
        my $rv = $dbh->do(
            "UPDATE $atable arch"
          . " JOIN CHANNEL_LOG live ON live.id_channel_log = arch.id_channel_log"
          . " SET arch.id_channel = live.id_channel"
          . " WHERE arch.id_channel_log IN ($in_ids)"
          . " AND NOT (arch.id_channel <=> live.id_channel) AND" . $ident,
            undef, @$ids);
        die "[align] update failed: " . ($dbh->errstr // 'unknown') . "\n"
            unless defined $rv;
        $fixed += @$ids;
        say_info("[align] realigned $fixed/$n row(s)");
        last if @$ids < 5000;
    }
    say_out("[align] DONE: $fixed archive row(s) realigned to the live channel ids"
          . ($fixed < $n ? " (budget reached — rerun to continue)" : "")
          . ". Rerun --diagnose then --execute to resume archiving.");
    exit 0;
}

# ---------------------------------------------------------------------------
# mb580-B1: --diagnose — LECTURE SEULE. Quand un run --execute s'arrete sur
# « verify failed: N/5000 », ce mode explique POURQUOI sans rien modifier :
# le premier lot eligible est reparti en absent / identique / divergent,
# le champ fautif est identifie, un echantillon est montre en HEX (les
# problemes d'encodage sautent aux yeux), et les definitions des deux
# tables (charset/collation) sont comparees. Le VERIFY qui a bloque est
# une PROTECTION : il a refuse de supprimer du vif — ce mode sert a
# decider de la suite en connaissance de cause, jamais a la contourner.
# ---------------------------------------------------------------------------
if ($opt_diag) {
    say_out("[diagnose] read-only analysis of the first eligible batch.");

    # 1. definitions des deux tables
    my %create;
    for my $t ('CHANNEL_LOG', $atable) {
        my (undef, $ddl) = eval { $dbh->selectrow_array("SHOW CREATE TABLE $t") };
        $create{$t} = $ddl // '(unavailable)';
        my ($cs)  = ($ddl // '') =~ /DEFAULT CHARSET=(\S+)/;
        # mb581-B1: collation de TABLE seulement (celle qui suit DEFAULT
        # CHARSET) — l'ancienne regex attrapait la collation d'une COLONNE.
        my ($col) = ($ddl // '') =~ /DEFAULT CHARSET=\S+ COLLATE[= ](\S+)/;
        say_out("[diagnose] $t: charset=" . ($cs // '?')
              . " collation=" . ($col // '(default)'));
    }
    my ($live_cs) = $create{'CHANNEL_LOG'} =~ /DEFAULT CHARSET=(\S+)/;
    my ($arch_cs) = $create{$atable}       =~ /DEFAULT CHARSET=(\S+)/;
    if (defined $live_cs && defined $arch_cs && $live_cs ne $arch_cs) {
        say_out("[diagnose] !! TABLE CHARSETS DIFFER ($live_cs vs $arch_cs):"
              . " BINARY comparisons convert before comparing — non-ASCII rows"
              . " will NEVER verify. Fix the archive table definition.");
    }

    # 2. premier lot de la premiere politique (memes criteres que le run)
    my ($label, $days, $events_ref) = @{ $policies[0] };
    my @events = @$events_ref;
    my $in_events = join(',', ('?') x @events);
    my $ids = $dbh->selectcol_arrayref(
        "SELECT id_channel_log FROM CHANNEL_LOG"
        . " WHERE ts < DATE_SUB(NOW(), INTERVAL ? DAY)"
        . " AND event_type IN ($in_events)"
        . " ORDER BY id_channel_log LIMIT 5000", undef, $days, @events) || [];
    unless (@$ids) { say_out("[diagnose] no eligible row — nothing to explain."); exit 0 }
    my $in_ids = join(',', ('?') x @$ids);
    say_out(sprintf("[diagnose] policy %s: %d row(s) in first batch (ids %d..%d)",
        $label, scalar(@$ids), $ids->[0], $ids->[-1]));

    # 3. repartition absent / identique / divergent + champ fautif
    my ($absent) = $dbh->selectrow_array(
        "SELECT COUNT(*) FROM CHANNEL_LOG live"
      . " LEFT JOIN $atable arch ON arch.id_channel_log = live.id_channel_log"
      . " WHERE live.id_channel_log IN ($in_ids) AND arch.id_channel_log IS NULL",
        undef, @$ids);
    my $row = $dbh->selectrow_hashref(
        "SELECT COUNT(*) AS present,"
      . " SUM(arch.id_channel <=> live.id_channel) AS ok_chan,"
      . " SUM(arch.id_channel IS NULL AND live.id_channel IS NULL) AS both_null_chan,"
      . " SUM(arch.ts <=> live.ts) AS ok_ts,"
      . " SUM(BINARY COALESCE(arch.event_type,'') = BINARY COALESCE(live.event_type,'')) AS ok_evt,"
      . " SUM(BINARY COALESCE(arch.nick,'') = BINARY COALESCE(live.nick,'')) AS ok_nick,"
      . " SUM(BINARY COALESCE(arch.userhost,'') = BINARY COALESCE(live.userhost,'')) AS ok_host,"
      . " SUM(BINARY COALESCE(arch.publictext,'') = BINARY COALESCE(live.publictext,'')) AS ok_text,"
      . " SUM(arch.id_channel <=> live.id_channel AND arch.ts <=> live.ts"
      . "   AND BINARY COALESCE(arch.event_type,'') = BINARY COALESCE(live.event_type,'')"
      . "   AND BINARY COALESCE(arch.nick,'') = BINARY COALESCE(live.nick,'')"
      . "   AND BINARY COALESCE(arch.userhost,'') = BINARY COALESCE(live.userhost,'')"
      . "   AND BINARY COALESCE(arch.publictext,'') = BINARY COALESCE(live.publictext,'')) AS ok_all"
      . " FROM $atable arch JOIN CHANNEL_LOG live ON live.id_channel_log = arch.id_channel_log"
      . " WHERE live.id_channel_log IN ($in_ids)", undef, @$ids) || {};
    my $present = $row->{present} // 0;
    say_out(sprintf("[diagnose] absent from archive : %d (INSERT IGNORE would copy these)",
        $absent // 0));
    say_out(sprintf("[diagnose] present in archive  : %d — identical: %d, DIVERGENT: %d",
        $present, $row->{ok_all} // 0, $present - ($row->{ok_all} // 0)));
    if ($present) {
        # mb582-B1: <=> partout — l'ancien SUM(a = b) ne comptait NI les
        # NULL<=>NULL (identiques !) ni ne les montrait : un lot de quits
        # reseau (id_channel NULL par design) semblait « divergent » alors
        # qu'il etait identique, et le verify du bot le rejetait pareil.
        say_out("[diagnose] field-level matches among present rows (NULL-safe):"
          . " id_channel=" . ($row->{ok_chan} // 0)
          . " (both-NULL=" . ($row->{both_null_chan} // 0) . ")"
          . " ts=" . ($row->{ok_ts} // 0)
          . " event_type=" . ($row->{ok_evt} // 0)
          . " nick=" . ($row->{ok_nick} // 0)
          . " userhost=" . ($row->{ok_host} // 0)
          . " publictext=" . ($row->{ok_text} // 0)
          . "  (lowest = the culprit field)");
    }

    # 4. echantillon de divergents avec HEX (l'encodage saute aux yeux)
    my $samples = $dbh->selectall_arrayref(
        "SELECT live.id_channel_log AS id,"
      . " live.ts AS live_ts, arch.ts AS arch_ts,"
      . " live.event_type AS live_evt, arch.event_type AS arch_evt,"
      . " live.nick AS live_nick, arch.nick AS arch_nick,"
      . " HEX(LEFT(COALESCE(live.userhost,''),16)) AS live_host_hex,"
      . " HEX(LEFT(COALESCE(arch.userhost,''),16)) AS arch_host_hex,"
      . " HEX(LEFT(COALESCE(live.publictext,''),16)) AS live_text_hex,"
      . " HEX(LEFT(COALESCE(arch.publictext,''),16)) AS arch_text_hex"
      . " FROM $atable arch JOIN CHANNEL_LOG live ON live.id_channel_log = arch.id_channel_log"
      . " WHERE live.id_channel_log IN ($in_ids)"
      . " AND NOT (arch.id_channel = live.id_channel AND arch.ts = live.ts"
      . "   AND BINARY COALESCE(arch.event_type,'') = BINARY COALESCE(live.event_type,'')"
      . "   AND BINARY COALESCE(arch.nick,'') = BINARY COALESCE(live.nick,'')"
      . "   AND BINARY COALESCE(arch.userhost,'') = BINARY COALESCE(live.userhost,'')"
      . "   AND BINARY COALESCE(arch.publictext,'') = BINARY COALESCE(live.publictext,''))"
      . " LIMIT 5", { Slice => {} }, @$ids);
    unless (defined $samples) {
        say_out("[diagnose] sample query failed: " . ($dbh->errstr // 'unknown'));
        $samples = [];
    }
    for my $s (@$samples) {
        say_out("[diagnose] divergent id=$s->{id}:");
        say_out("    ts   live=$s->{live_ts}  arch=$s->{arch_ts}"
          . ($s->{live_ts} eq $s->{arch_ts} ? "" : "   <-- DIFFERENT EPOCH? id reuse suspected"));
        say_out("    evt  live=$s->{live_evt}  arch=$s->{arch_evt}");
        say_out("    nick live=$s->{live_nick}  arch=$s->{arch_nick}");
        say_out("    host live_hex=$s->{live_host_hex}");
        say_out("         arch_hex=$s->{arch_host_hex}");
        say_out("    text live_hex=$s->{live_text_hex}");
        say_out("         arch_hex=$s->{arch_text_hex}");
    }

    # mb581-B1: quand id_channel est le champ fautif, montrer LA carte du
    # probleme — distribution des paires (live.id_channel -> arch.id_channel)
    # sur le lot, avec les noms resolus dans la table CHANNEL courante. Une
    # renumerotation systematique donne peu de paires nettes ; du bruit
    # donnerait un nuage (et interdirait tout alignement automatique).
    {
        my $pairs = $dbh->selectall_arrayref(
            "SELECT live.id_channel AS live_id, arch.id_channel AS arch_id,"
          . " COUNT(*) AS n, MIN(live.ts) AS first_ts, MAX(live.ts) AS last_ts"
          . " FROM $atable arch JOIN CHANNEL_LOG live"
          . "   ON live.id_channel_log = arch.id_channel_log"
          . " WHERE live.id_channel_log IN ($in_ids)"
          . "   AND NOT (arch.id_channel <=> live.id_channel)"
          . " GROUP BY live.id_channel, arch.id_channel"
          . " ORDER BY n DESC LIMIT 20", { Slice => {} }, @$ids);
        unless (defined $pairs) {
            say_out("[diagnose] mapping query failed: " . ($dbh->errstr // 'unknown'));
            $pairs = [];
        }
        if (@$pairs) {
            my %names;
            my @chan_ids = do { my %u; grep { !$u{$_}++ }
                map { ($_->{live_id}, $_->{arch_id}) } @$pairs };
            my $in_ch = join(',', ('?') x @chan_ids);
            my $rows = $dbh->selectall_arrayref(
                "SELECT id_channel, name FROM CHANNEL WHERE id_channel IN ($in_ch)",
                { Slice => {} }, @chan_ids) || [];
            $names{ $_->{id_channel} } = $_->{name} for @$rows;
            say_out("[diagnose] id_channel mapping (live -> archive) among divergent rows:");
            for my $p (@$pairs) {
                say_out(sprintf("    live %s(%s) <- archive says %s(%s) : %d row(s), ts %s .. %s",
                    $p->{live_id}, $names{ $p->{live_id} } // 'NOT IN CHANNEL',
                    $p->{arch_id}, $names{ $p->{arch_id} } // 'NOT IN CHANNEL',
                    $p->{n}, $p->{first_ts}, $p->{last_ts}));
            }
            say_out("[diagnose] the LIVE side joins today's CHANNEL table and is the");
            say_out("[diagnose] authority; archive rows carrying another id would poison");
            say_out("[diagnose] every per-channel archive read (onthisday, when, chronos).");
            say_out("[diagnose] if the mapping above is clean, run:");
            say_out("[diagnose]   --align-archive-channel-ids            (dry-run count)");
            say_out("[diagnose]   --align-archive-channel-ids --execute  (fix archive only)");
        }
    }

    say_out("[diagnose] reading the result:");
    say_out("  - both-NULL high, mapping empty -> network-wide events (quits) have NO");
    say_out("      channel by design; mb582 made every comparison NULL-safe (<=>).");
    say_out("      With the fixed tool these rows verify: rerun --execute.");
    say_out("  - ts differs wildly on same id  -> id_channel_log REUSE between epochs:");
    say_out("      the archive holds OLD unrelated rows under these ids. Do NOT merge;");
    say_out("      the archive table likely predates a live-table reset. Discuss before acting.");
    say_out("  - same text, different hex bytes -> charset/encoding mismatch between tables:");
    say_out("      recreate the archive table LIKE CHANNEL_LOG (after saving it) so bytes match.");
    say_out("  - absent rows only               -> nothing wrong; rerun --execute.");
    exit 0;
}

# ---------------------------------------------------------------------------
# DRY-RUN : compte par politique, ne touche a rien.
# ---------------------------------------------------------------------------
unless ($opt_execute) {
    my $arch_ok = eval { $dbh->do("SELECT 1 FROM $atable LIMIT 0"); 1 };
    say_out($arch_ok
        ? "[dry-run] archive table $atable exists."
        : "[dry-run] archive table $atable does NOT exist yet — --execute will CREATE it LIKE CHANNEL_LOG (needs CREATE on $adb).");
    my $grand = 0;
    for my $pol (@policies) {
        my ($label, $days, $ev) = @$pol;
        my $in = join(',', ('?') x @$ev);
        my ($n) = $dbh->selectrow_array(
            "SELECT COUNT(*) FROM CHANNEL_LOG"
          . " WHERE ts < DATE_SUB(NOW(), INTERVAL ? DAY)"
          . " AND event_type IN ($in)", undef, $days, @$ev);
        $n //= 0;
        $grand += $n;
        say_out(sprintf("[dry-run] policy %-8s : %d row(s) eligible", $label, $n));
    }
    my $runs = $grand ? int(($grand + $max_run - 1) / $max_run) : 0;
    say_out("[dry-run] total eligible : $grand row(s) — "
        . ($opt_loop || $runs <= 1
            ? "one --execute --loop session would drain it in ~$runs run(s) of $max_run."
            : "~$runs run(s) of $max_run needed (or use --execute --loop)."));
    exit 0;
}

# ---------------------------------------------------------------------------
# EXECUTE : reproduction stricte du flux du bot, run par run.
# ---------------------------------------------------------------------------
my $rv = $dbh->do("CREATE TABLE IF NOT EXISTS $atable LIKE CHANNEL_LOG");
die "Cannot ensure $atable (" . ($dbh->errstr // 'unknown')
    . ") — check GRANTs (SELECT,INSERT,CREATE) on $adb and that database $adb exists.\n"
    unless defined $rv;

my $grand_total = 0;
my $run_no      = 0;
my $t0          = time();

RUN: while (1) {
    $run_no++;
    my $total = 0;

    POLICY: for my $pol (@policies) {
        my ($label, $days, $events_ref) = @$pol;
        my @events = @$events_ref;
        my $in_events = join(',', ('?') x @events);
        my $sel = $dbh->prepare(
            "SELECT id_channel_log FROM CHANNEL_LOG"
            . " WHERE ts < DATE_SUB(NOW(), INTERVAL ? DAY)"
            . " AND event_type IN ($in_events)"
            . " ORDER BY id_channel_log LIMIT 5000")
            or die "SELECT prepare failed (" . ($dbh->errstr // 'unknown') . ")\n";

        while ($total < $max_run) {
            $sel->execute($days, @events)
                or die "SELECT execute failed (" . ($dbh->errstr // 'unknown') . ")\n";
            my @ids;
            while (my ($id) = $sel->fetchrow_array) { push @ids, $id }
            $sel->finish;
            last unless @ids;

            # plafond STRICT meme si MAX_PER_RUN n'est pas multiple de 5000
            my $remaining = $max_run - $total;
            splice(@ids, $remaining) if @ids > $remaining;

            my $in_ids = join(',', ('?') x @ids);
            my $inserted = $dbh->do(
                "INSERT IGNORE INTO $atable SELECT * FROM CHANNEL_LOG"
              . " WHERE id_channel_log IN ($in_ids)", undef, @ids);
            die "insert failed: " . ($dbh->errstr // 'unknown') . "\n"
                unless defined $inserted;
            my ($present) = $dbh->selectrow_array(
                "SELECT COUNT(*) FROM $atable arch"
              . " JOIN CHANNEL_LOG live ON live.id_channel_log = arch.id_channel_log"
              . " WHERE live.id_channel_log IN ($in_ids)"
              . " AND arch.id_channel <=> live.id_channel"
              . " AND arch.ts <=> live.ts"
              . " AND BINARY COALESCE(arch.event_type,'') = BINARY COALESCE(live.event_type,'')"
              . " AND BINARY COALESCE(arch.nick,'') = BINARY COALESCE(live.nick,'')"
              . " AND BINARY COALESCE(arch.userhost,'') = BINARY COALESCE(live.userhost,'')"
              . " AND BINARY COALESCE(arch.publictext,'') = BINARY COALESCE(live.publictext,'')",
                undef, @ids);
            die "verify failed: " . ($present // 'undef') . "/" . scalar(@ids)
              . " exact row(s) in archive — batch aborted BEFORE delete, nothing lost.\n"
                unless defined $present && $present == scalar(@ids);
            my $deleted = $dbh->do(
                "DELETE FROM CHANNEL_LOG WHERE id_channel_log IN ($in_ids)",
                undef, @ids);
            die "delete failed: " . ($dbh->errstr // 'unknown') . "\n"
                unless defined $deleted;

            $total += scalar(@ids);
            last if scalar(@ids) < 5000;
        }
    }

    $grand_total += $total;
    say_info(sprintf("[run %d] moved %d row(s) (cumulative %d, %.1fs elapsed)",
        $run_no, $total, $grand_total, time() - $t0));

    last RUN unless $opt_loop;
    last RUN unless $total;         # draine : plus rien d'eligible
    sleep($opt_sleep) if $opt_sleep > 0;
}

say_out(sprintf("DONE: moved %d row(s) to %s in %d run(s), %.1fs.",
    $grand_total, $atable, $run_no, time() - $t0));
say_out("Post-run suggestions: OPTIMIZE TABLE CHANNEL_LOG; then"
    . " tools/normalize_channel_log_indexes.pl and tools/analyze_channel_log.pl --conf $opt_conf")
    if $grand_total;
exit 0;
