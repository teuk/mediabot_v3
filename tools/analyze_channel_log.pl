#!/usr/bin/perl
# =============================================================================
#  tools/analyze_channel_log.pl — Analyse de CHANNEL_LOG et de la base (mb565)
# =============================================================================
#  Outil ops en LECTURE SEULE. Repond a deux questions :
#    « que contient CHANNEL_LOG, annee par annee ? » et
#    « dans quel etat general est la base du bot ? »
#
#  Complementaire de tools/measure_channel_log.pl (qui, lui, rejoue les
#  requetes chaudes avec EXPLAIN/ANALYZE) : meme lecture de conf, meme DSN,
#  meme discipline — rien n'est ecrit, aucun contenu de message ni mot de
#  passe n'est affiche, uniquement des agregats.
#
#  Sections :
#    [1] CHANNEL_LOG — volume : total, periode couverte, lignes par ANNEE
#        (avec part du total et delta vs annee precedente), 12 derniers mois,
#        rythme recent (lignes/jour sur 30 j vs moyenne de vie).
#    [2] CHANNEL_LOG — repartition : par event_type, top canaux, top nicks
#        (agregats seulement).
#    [3] CHANNEL_LOG — sante physique : engine, tailles data/index,
#        fragmentation (data_free), avg_row_length, auto_increment et marge
#        restante du type de la cle.
#    [4] CHANNEL_LOG — index : liste SHOW INDEX + verdict sur les index
#        recommandes (mb558 : (id_channel,nick,event_type) et
#        (nick,event_type) ; A4 : (id_channel,ts)). Le SQL manquant est
#        affiche pret a copier, il n'est JAMAIS execute.
#    [5] Base entiere : version serveur, taille totale, top tables par
#        taille (data+index), lignes estimees, collations en presence.
#
#  Usage :
#    perl tools/analyze_channel_log.pl --conf=mediabot.conf [options]
#
#    --conf FILE   Fichier de conf du bot (defaut: mediabot.conf).
#    --top N       Nombre d'entrees des classements (defaut 10, max 50).
#    --months N    Profondeur du detail mensuel (defaut 12, max 60).
#    --json        Sortie JSON (agregats machine) au lieu du texte.
#    --quiet       Supprime les intertitres decoratifs.
# =============================================================================

use strict;
use warnings;
use Getopt::Long;
use DBI;

my $opt_conf   = 'mediabot.conf';
my $opt_top    = 10;
my $opt_months = 12;
my $opt_json   = 0;
my $opt_quiet  = 0;

GetOptions(
    'conf=s'   => \$opt_conf,
    'top=i'    => \$opt_top,
    'months=i' => \$opt_months,
    'json'     => \$opt_json,
    'quiet'    => \$opt_quiet,
) or die "Invalid options.\n";

$opt_top    = 1  if $opt_top < 1;
$opt_top    = 50 if $opt_top > 50;
$opt_months = 1  if $opt_months < 1;
$opt_months = 60 if $opt_months > 60;

sub say_out  { print "$_[0]\n" }
sub say_info { print "$_[0]\n" unless $opt_quiet || $opt_json }
sub hr { say_info('-' x 74) }

# ---------------------------------------------------------------------------
# Lecture minimale de la conf (meme moule que measure_channel_log.pl) :
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

# ---------------------------------------------------------------------------
# Helpers de requete (SELECT/SHOW uniquement — cet outil n'ecrit jamais).
# ---------------------------------------------------------------------------
sub rows {
    my ($sql, @bind) = @_;
    my $sth = $dbh->prepare($sql) or return [];
    $sth->execute(@bind) or return [];
    my @all;
    while (my $r = $sth->fetchrow_hashref) { push @all, $r }
    $sth->finish;
    return \@all;
}

sub one {
    my ($sql, @bind) = @_;
    my $r = rows($sql, @bind);
    return @$r ? $r->[0] : undef;
}

sub fmt_n {
    my ($n) = @_;
    return '?' unless defined $n;
    1 while $n =~ s/^(\d+)(\d{3})/$1 $2/;
    return $n;
}

sub fmt_bytes {
    my ($b) = @_;
    return '?' unless defined $b;
    my @u = ('B', 'KB', 'MB', 'GB', 'TB');
    my $i = 0;
    while ($b >= 1024 && $i < $#u) { $b /= 1024; $i++ }
    return sprintf('%.1f %s', $b, $u[$i]);
}

my %out;   # collecte pour --json

# ---------------------------------------------------------------------------
# [1] Volume et lignes par annee
# ---------------------------------------------------------------------------
hr(); say_info('[1] CHANNEL_LOG — volume'); hr();

my $span = one(q{
    SELECT COUNT(*) AS total, MIN(ts) AS first_ts, MAX(ts) AS last_ts
    FROM CHANNEL_LOG
});
my $total = $span ? ($span->{total} // 0) : 0;
$out{total}    = $total;
$out{first_ts} = $span ? $span->{first_ts} : undef;
$out{last_ts}  = $span ? $span->{last_ts}  : undef;
say_out(sprintf('Total: %s lignes | periode: %s -> %s',
    fmt_n($total), $span->{first_ts} // '?', $span->{last_ts} // '?'));

my $years = rows(q{
    SELECT YEAR(ts) AS y, COUNT(*) AS c
    FROM CHANNEL_LOG
    GROUP BY YEAR(ts)
    ORDER BY y
});
$out{per_year} = $years;
say_out('');
say_out('Lignes par annee:');
my $prev;
for my $r (@$years) {
    my $pct   = $total ? sprintf('%5.1f%%', 100 * $r->{c} / $total) : '    ?';
    my $delta = defined $prev
        ? sprintf(' (%+d%% vs %d)', $prev->{c} ? int(100 * ($r->{c} - $prev->{c}) / $prev->{c}) : 0, $prev->{y})
        : '';
    say_out(sprintf('  %4d : %12s  %s%s', $r->{y}, fmt_n($r->{c}), $pct, $delta));
    $prev = $r;
}

my $months = rows(q{
    SELECT DATE_FORMAT(ts, '%Y-%m') AS m, COUNT(*) AS c
    FROM CHANNEL_LOG
    WHERE ts >= DATE_SUB(NOW(), INTERVAL ? MONTH)
    GROUP BY DATE_FORMAT(ts, '%Y-%m')
    ORDER BY m
}, $opt_months);
$out{per_month} = $months;
say_out('');
say_out("Derniers mois ($opt_months):");
say_out(sprintf('  %s : %s', $_->{m}, fmt_n($_->{c}))) for @$months;

my $recent = one(q{
    SELECT COUNT(*) AS c FROM CHANNEL_LOG
    WHERE ts >= DATE_SUB(NOW(), INTERVAL 30 DAY)
});
if ($span && defined $span->{first_ts}) {
    my $life_days = one(q{
        SELECT GREATEST(DATEDIFF(MAX(ts), MIN(ts)), 1) AS d FROM CHANNEL_LOG
    });
    my $rate_recent = sprintf('%.0f', ($recent->{c} // 0) / 30);
    my $rate_life   = sprintf('%.0f', $total / ($life_days->{d} // 1));
    $out{rate_recent_per_day} = $rate_recent;
    $out{rate_life_per_day}   = $rate_life;
    say_out('');
    say_out("Rythme: $rate_recent lignes/jour (30 derniers jours) vs $rate_life en moyenne de vie");
}

# ---------------------------------------------------------------------------
# [2] Repartition
# ---------------------------------------------------------------------------
hr(); say_info('[2] CHANNEL_LOG — repartition'); hr();

my $types = rows(q{
    SELECT event_type, COUNT(*) AS c
    FROM CHANNEL_LOG
    GROUP BY event_type
    ORDER BY c DESC
});
$out{per_event_type} = $types;
say_out('Par event_type:');
say_out(sprintf('  %-12s : %12s  %s', $_->{event_type} // '(null)', fmt_n($_->{c}),
    $total ? sprintf('%5.1f%%', 100 * $_->{c} / $total) : '')) for @$types;

my $chans = rows(qq{
    SELECT c.name AS chan, COUNT(*) AS c
    FROM CHANNEL_LOG cl
    JOIN CHANNEL c ON c.id_channel = cl.id_channel
    GROUP BY c.name
    ORDER BY c DESC
    LIMIT $opt_top
});
$out{top_channels} = $chans;
say_out('');
say_out("Top $opt_top canaux:");
say_out(sprintf('  %-24s : %12s', $_->{chan}, fmt_n($_->{c}))) for @$chans;

my $nicks = rows(qq{
    SELECT nick, COUNT(*) AS c
    FROM CHANNEL_LOG
    WHERE event_type IN ('public','action')
    GROUP BY nick
    ORDER BY c DESC
    LIMIT $opt_top
});
$out{top_nicks} = $nicks;
say_out('');
say_out("Top $opt_top nicks (public/action):");
say_out(sprintf('  %-24s : %12s', $_->{nick} // '(null)', fmt_n($_->{c}))) for @$nicks;

# ---------------------------------------------------------------------------
# [3] Sante physique de la table
# ---------------------------------------------------------------------------
hr(); say_info('[3] CHANNEL_LOG — sante physique'); hr();

my $t = one(q{
    SELECT ENGINE, ROW_FORMAT, TABLE_ROWS, AVG_ROW_LENGTH,
           DATA_LENGTH, INDEX_LENGTH, DATA_FREE, AUTO_INCREMENT, TABLE_COLLATION
    FROM information_schema.TABLES
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'CHANNEL_LOG'
});
if ($t) {
    $out{table_health} = $t;
    say_out(sprintf('Engine: %s (%s, %s)', $t->{ENGINE} // '?', $t->{ROW_FORMAT} // '?', $t->{TABLE_COLLATION} // '?'));
    say_out(sprintf('Data: %s | Index: %s | Fragmentation (data_free): %s',
        fmt_bytes($t->{DATA_LENGTH}), fmt_bytes($t->{INDEX_LENGTH}), fmt_bytes($t->{DATA_FREE})));
    say_out(sprintf('Lignes estimees: %s | Taille moyenne de ligne: %s o',
        fmt_n($t->{TABLE_ROWS}), $t->{AVG_ROW_LENGTH} // '?'));

    my $col = one(q{
        SELECT COLUMN_NAME, DATA_TYPE, COLUMN_TYPE
        FROM information_schema.COLUMNS
        WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'CHANNEL_LOG'
          AND EXTRA LIKE '%auto_increment%'
        LIMIT 1
    });
    if ($col && defined $t->{AUTO_INCREMENT}) {
        my %cap = (
            tinyint   => 127,          smallint => 32767,
            mediumint => 8388607,      int      => 2147483647,
            bigint    => 9.22e18,
        );
        my $dt  = lc($col->{DATA_TYPE} // '');
        my $max = $cap{$dt};
        $max = 2 * $max + 1 if $max && ($col->{COLUMN_TYPE} // '') =~ /unsigned/;
        if ($max) {
            my $used = 100 * $t->{AUTO_INCREMENT} / $max;
            $out{auto_increment} = { column => $col->{COLUMN_NAME},
                type => $col->{COLUMN_TYPE}, next => $t->{AUTO_INCREMENT},
                used_pct => sprintf('%.4f', $used) };
            say_out(sprintf('Cle %s (%s): prochain id %s — %.4f%% de la capacite du type',
                $col->{COLUMN_NAME}, $col->{COLUMN_TYPE}, fmt_n($t->{AUTO_INCREMENT}), $used));
            say_out('  >> ATTENTION: plus de 50% de la capacite consommee.')
                if $used > 50;
        }
    }
}
else {
    say_out('information_schema indisponible pour CHANNEL_LOG (droits ?).');
}

# ---------------------------------------------------------------------------
# [4] Index presents et index recommandes
# ---------------------------------------------------------------------------
hr(); say_info('[4] CHANNEL_LOG — index'); hr();

my $idx = rows(q{SHOW INDEX FROM CHANNEL_LOG});
my %by_index;
for my $r (@$idx) {
    push @{ $by_index{ $r->{Key_name} } }, [ $r->{Seq_in_index}, $r->{Column_name} ];
}
$out{indexes} = {};
say_out('Index presents:');
for my $name (sort keys %by_index) {
    my @cols = map { $_->[1] } sort { $a->[0] <=> $b->[0] } @{ $by_index{$name} };
    $out{indexes}{$name} = \@cols;
    say_out(sprintf('  %-36s (%s)', $name, join(', ', @cols)));
}

# Verdicts : un index recommande est "couvert" si un index existant COMMENCE
# par exactement ces colonnes dans cet ordre.
my @wanted = (
    { cols => [ 'id_channel', 'nick', 'event_type' ],
      why  => 'checks achievements msg_count/hour_band (mb558)',
      sql  => 'ALTER TABLE CHANNEL_LOG ADD INDEX idx_chanlog_chan_nick_type (id_channel, nick, event_type), ALGORITHM=INPLACE, LOCK=NONE;' },
    { cols => [ 'nick', 'event_type' ],
      why  => 'check polyphony toutes-chaines (mb558)',
      sql  => 'ALTER TABLE CHANNEL_LOG ADD INDEX idx_chanlog_nick_type (nick, event_type), ALGORITHM=INPLACE, LOCK=NONE;' },
    { cols => [ 'id_channel', 'ts' ],
      why  => 'requetes a plage m check / stats (A4)',
      sql  => 'ALTER TABLE CHANNEL_LOG ADD INDEX idx_channel_log_channel_ts (id_channel, ts), ALGORITHM=INPLACE, LOCK=NONE;' },
);
# mb568-B1: detection des index REDONDANTS — un index secondaire dont les
# colonnes sont un prefixe strict d'un autre index n'apporte rien en
# lecture et coute a chaque ecriture. PRIMARY et doublons exacts inclus
# dans l'analyse ; le SQL de DROP est affiche, jamais execute.
{
    # mb569-B1: JAMAIS $a/$b comme variables de boucle — elles masquent les
    # globales du sort() interieur ("Can't use string as ARRAY ref", incident
    # du 2026-07-25 sur l'instance Undernet).
    my @redundant;
    my @names = sort keys %by_index;
    for my $name_a (@names) {
        next if $name_a eq 'PRIMARY';
        my @ca = map { lc $_->[1] } sort { $a->[0] <=> $b->[0] } @{ $by_index{$name_a} };
        for my $name_b (@names) {
            next if $name_a eq $name_b;
            my @cb = map { lc $_->[1] } sort { $a->[0] <=> $b->[0] } @{ $by_index{$name_b} };
            next if @ca > @cb;
            my $prefix = 1;
            for my $i (0 .. $#ca) {
                do { $prefix = 0; last } unless $ca[$i] eq $cb[$i];
            }
            next unless $prefix;
            # Doublon exact : on garde l'ordre alphabetique pour ne suggerer
            # qu'un seul des deux.
            next if @ca == @cb && $name_a lt $name_b;
            push @redundant, [ $name_a, $name_b ];
            last;
        }
    }
    if (@redundant) {
        say_out('');
        say_out('Index redondants (prefixe d\'un autre index — DROP suggere, jamais execute):');
        for my $r (@redundant) {
            say_out(sprintf('  %-36s couvert par %s', $r->[0], $r->[1]));
            say_out(sprintf('    ALTER TABLE CHANNEL_LOG DROP INDEX `%s`, ALGORITHM=INPLACE, LOCK=NONE;', $r->[0]));
        }
        $out{redundant_indexes} = [ map { { index => $_->[0], covered_by => $_->[1] } } @redundant ];
    }
}

say_out('');
say_out('Index recommandes:');
my @missing;
for my $w (@wanted) {
    my $covered = 0;
    NAME: for my $name (keys %by_index) {
        my @cols = map { $_->[1] } sort { $a->[0] <=> $b->[0] } @{ $by_index{$name} };
        next NAME if @cols < @{ $w->{cols} };
        for my $i (0 .. $#{ $w->{cols} }) {
            next NAME unless lc($cols[$i]) eq lc($w->{cols}[$i]);
        }
        $covered = $name;
        last;
    }
    if ($covered) {
        say_out(sprintf('  OK      (%s) — couvert par %s', join(',', @{ $w->{cols} }), $covered));
    }
    else {
        say_out(sprintf('  MANQUE  (%s) — %s', join(',', @{ $w->{cols} }), $w->{why}));
        push @missing, $w;
    }
}
$out{missing_indexes} = [ map { { cols => $_->{cols}, sql => $_->{sql} } } @missing ];
if (@missing) {
    say_out('');
    say_out('SQL pret a copier (online DDL, rien n\'est execute par cet outil):');
    say_out("  $_->{sql}") for @missing;
}

# ---------------------------------------------------------------------------
# [5] La base en general
# ---------------------------------------------------------------------------
hr(); say_info('[5] Base entiere'); hr();

my $ver = one(q{SELECT VERSION() AS v});
say_out('Serveur: ' . ($ver ? $ver->{v} : '?'));
$out{server_version} = $ver ? $ver->{v} : undef;

my $dbsize = one(q{
    SELECT SUM(DATA_LENGTH + INDEX_LENGTH) AS b, COUNT(*) AS tables
    FROM information_schema.TABLES
    WHERE TABLE_SCHEMA = DATABASE()
});
say_out(sprintf('Taille totale: %s sur %s tables',
    fmt_bytes($dbsize->{b}), $dbsize->{tables} // '?')) if $dbsize;
$out{db_bytes} = $dbsize ? $dbsize->{b} : undef;

my $tables = rows(qq{
    SELECT TABLE_NAME, ENGINE, TABLE_ROWS,
           DATA_LENGTH + INDEX_LENGTH AS total_b, DATA_FREE
    FROM information_schema.TABLES
    WHERE TABLE_SCHEMA = DATABASE()
    ORDER BY total_b DESC
    LIMIT $opt_top
});
$out{top_tables} = $tables;
say_out('');
say_out("Top $opt_top tables par taille:");
for my $r (@$tables) {
    say_out(sprintf('  %-28s %-8s %12s lignes  %10s%s',
        $r->{TABLE_NAME}, $r->{ENGINE} // '?', fmt_n($r->{TABLE_ROWS}),
        fmt_bytes($r->{total_b}),
        ($r->{DATA_FREE} && $r->{total_b} && $r->{DATA_FREE} > 0.2 * $r->{total_b})
            ? '  << fragmentation ' . fmt_bytes($r->{DATA_FREE}) : ''));
}

my $collations = rows(q{
    SELECT TABLE_COLLATION, COUNT(*) AS c
    FROM information_schema.TABLES
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_COLLATION IS NOT NULL
    GROUP BY TABLE_COLLATION
    ORDER BY c DESC
});
$out{collations} = $collations;
say_out('');
say_out('Collations en presence:');
say_out(sprintf('  %-28s : %s tables', $_->{TABLE_COLLATION}, $_->{c})) for @$collations;
say_out('  >> Plusieurs collations coexistent: les JOIN texte peuvent ignorer les index.')
    if @$collations > 1;

# ---------------------------------------------------------------------------
# Sortie JSON optionnelle
# ---------------------------------------------------------------------------
if ($opt_json) {
    my $ok = eval { require JSON::PP; 1 };
    die "JSON::PP unavailable for --json\n" unless $ok;
    print JSON::PP->new->canonical->pretty->encode(\%out);
}

$dbh->disconnect;
exit 0;
