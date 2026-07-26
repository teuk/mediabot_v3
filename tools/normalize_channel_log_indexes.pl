#!/usr/bin/perl
# =============================================================================
#  tools/normalize_channel_log_indexes.pl — Met CHANNEL_LOG d'equerre (mb569)
# =============================================================================
#  Quatrieme outil de la famille CHANNEL_LOG (measure / analyze / archive /
#  normalize). Compare les index reels de CHANNEL_LOG au JEU CANONIQUE et
#  propose (dry-run par defaut) puis applique (--execute) les corrections en
#  online DDL. Lance-le avec la conf de CHAQUE instance pour que toutes les
#  bases soient identiques en termes d'index.
#
#  JEU CANONIQUE (couvre toutes les requetes chaudes du bot) :
#    PRIMARY                              (id_channel_log)      — jamais touche
#    idx_chanlog_chan_nick_evt_ts (id_channel, nick, event_type, ts)
#        -> checks achievements msg_count/hour_band, m check, leaderboard
#    idx_channel_log_channel_ts   (id_channel, ts)
#        -> requetes a plage (stats, chronos, onthisday)
#    idx_chanlog_nick_type        (nick, event_type)
#        -> check polyphony toutes-chaines (mb558)
#    idx_chanlog_ts               (ts)  [ou tout index existant commencant
#        par ts] -> purge, archivage quotidien, outil archive
#
#  REGLES :
#    - Un index canonique manquant  -> ADD (online DDL).
#    - Un index secondaire dont les colonnes sont un PREFIXE STRICT d'un
#      autre index (doublons exacts dedoublonnes) -> DROP (online DDL).
#    - Un index hors canon et non redondant (ex: userhost) -> SIGNALE
#      seulement, jamais droppe automatiquement : verifier son usage avec
#      tools/measure_channel_log.pl avant de decider.
#
#  Usage :
#    perl tools/normalize_channel_log_indexes.pl --conf=mbundernet.conf
#    perl tools/normalize_channel_log_indexes.pl --conf=mbundernet.conf --execute
# =============================================================================

use strict;
use warnings;
use Getopt::Long;
use DBI;

my $opt_conf    = 'mediabot.conf';
my $opt_execute = 0;
my $opt_quiet   = 0;

GetOptions(
    'conf=s'  => \$opt_conf,
    'execute' => \$opt_execute,
    'quiet'   => \$opt_quiet,
) or die "Invalid options.\n";

sub say_out  { print "$_[0]\n" }
sub say_info { print "$_[0]\n" unless $opt_quiet }

# --- Conf + DSN : meme moule que les trois outils freres -------------------
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
die "Missing [mysql] DB config in $opt_conf\n" unless defined $dbname && defined $dbuser;

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

# --- Etat reel -------------------------------------------------------------
my %by_index;
{
    my $sth = $dbh->prepare(q{SHOW INDEX FROM CHANNEL_LOG})
        or die "SHOW INDEX failed\n";
    $sth->execute or die "SHOW INDEX failed: " . ($dbh->errstr // '?') . "\n";
    while (my $r = $sth->fetchrow_hashref) {
        push @{ $by_index{ $r->{Key_name} } }, [ $r->{Seq_in_index}, lc $r->{Column_name} ];
    }
    $sth->finish;
}
my %cols_of;
for my $n (keys %by_index) {
    $cols_of{$n} = [ map { $_->[1] } sort { $a->[0] <=> $b->[0] } @{ $by_index{$n} } ];
}

say_info('Index presents:');
say_info(sprintf('  %-36s (%s)', $_, join(', ', @{ $cols_of{$_} }))) for sort keys %cols_of;

# --- Canon -----------------------------------------------------------------
my @canon = (
    { name => 'idx_chanlog_chan_nick_evt_ts', cols => [ 'id_channel', 'nick', 'event_type', 'ts' ] },
    { name => 'idx_channel_log_channel_ts',   cols => [ 'id_channel', 'ts' ] },
    { name => 'idx_chanlog_nick_type',        cols => [ 'nick', 'event_type' ] },
    { name => 'idx_chanlog_ts',               cols => [ 'ts' ] },
);

my @actions;   # [ 'ADD'|'DROP'|'KEEP'|'REVIEW', detail, sql? ]

# 1) Canon manquant -> ADD. "Present" = un index existant commence exactement
#    par ces colonnes (l'egalite stricte n'est pas exigee: un index plus long
#    qui prefixe le canon le couvre).
for my $c (@canon) {
    my $covered;
    for my $n (keys %cols_of) {
        my @have = @{ $cols_of{$n} };
        next if @have < @{ $c->{cols} };
        my $ok = 1;
        for my $i (0 .. $#{ $c->{cols} }) {
            do { $ok = 0; last } unless $have[$i] eq lc $c->{cols}[$i];
        }
        do { $covered = $n; last } if $ok;
    }
    if ($covered) {
        push @actions, [ 'KEEP', sprintf('(%s) couvert par %s', join(',', @{ $c->{cols} }), $covered) ];
    }
    else {
        push @actions, [ 'ADD', sprintf('(%s) manquant', join(',', @{ $c->{cols} })),
            sprintf('ALTER TABLE CHANNEL_LOG ADD INDEX %s (%s), ALGORITHM=INPLACE, LOCK=NONE',
                $c->{name}, join(', ', @{ $c->{cols} })) ];
    }
}

# 2) Redondants (prefixe strict d'un autre, doublons exacts dedoublonnes)
#    -> DROP. Evalue sur l'etat PROJETE (existant + ADDs du canon), pour que
#    `nick` tombe des que (nick,event_type) est planifie.
my %projected = %cols_of;
for my $a_row (@actions) {
    next unless $a_row->[0] eq 'ADD';
    my ($cols_txt) = $a_row->[1] =~ /\(([^)]+)\)/;
    my ($name) = $a_row->[2] =~ /ADD INDEX (\S+)/;
    $projected{$name} = [ split /,/, $cols_txt ];
}
for my $name_a (sort keys %cols_of) {
    next if $name_a eq 'PRIMARY';
    my @ca = @{ $cols_of{$name_a} };
    for my $name_b (sort keys %projected) {
        next if $name_a eq $name_b;
        my @cb = @{ $projected{$name_b} };
        next if @ca > @cb;
        my $prefix = 1;
        for my $i (0 .. $#ca) {
            do { $prefix = 0; last } unless $ca[$i] eq $cb[$i];
        }
        next unless $prefix;
        next if @ca == @cb && exists $cols_of{$name_b} && $name_a lt $name_b;
        push @actions, [ 'DROP', sprintf('%s (%s) redondant, couvert par %s',
                $name_a, join(',', @ca), $name_b),
            sprintf('ALTER TABLE CHANNEL_LOG DROP INDEX `%s`, ALGORITHM=INPLACE, LOCK=NONE', $name_a) ];
        last;
    }
}

# 3) Hors canon, non redondant -> REVIEW seulement.
{
    my %dropping = map { ($_->[2] // '') =~ /DROP INDEX `([^`]+)`/ ? ($1 => 1) : () } @actions;
    my %canon_cols = map { join(',', map { lc } @{ $_->{cols} }) => 1 } @canon;
    for my $n (sort keys %cols_of) {
        next if $n eq 'PRIMARY' || $dropping{$n};
        my $sig = join(',', @{ $cols_of{$n} });
        next if $canon_cols{$sig};
        my $is_canon_prefix_holder = 0;
        for my $c (@canon) {
            my @cc = map { lc } @{ $c->{cols} };
            next if @cc > @{ $cols_of{$n} };
            my $ok = 1;
            for my $i (0 .. $#cc) { do { $ok = 0; last } unless $cols_of{$n}[$i] eq $cc[$i]; }
            do { $is_canon_prefix_holder = 1; last } if $ok;
        }
        next if $is_canon_prefix_holder;
        push @actions, [ 'REVIEW', sprintf('%s (%s) hors canon — verifier son usage'
            . ' avec tools/measure_channel_log.pl avant de decider', $n, $sig) ];
    }
}

# --- Rapport / application -------------------------------------------------
say_out('');
say_out($opt_execute ? 'Plan (EXECUTION):' : 'Plan (DRY-RUN — rien ne sera modifie):');
my $changes = 0;
my ($applied, $failed, $skipped) = (0, 0, 0);
my $add_failed = 0;
for my $a_row (@actions) {
    my ($verb, $detail, $sql) = @$a_row;
    say_out(sprintf('  %-7s %s', $verb, $detail));
    say_out("          $sql;") if $sql && !$opt_execute;
    next unless $sql;
    $changes++;
    next unless $opt_execute;

    # mb571-B1: DROP decisions are computed against the PROJECTED state. If
    # any prerequisite ADD failed, executing a projected DROP could remove the
    # only usable index. Continue trying independent ADDs, but skip every DROP.
    if ($verb eq 'DROP' && $add_failed) {
        $skipped++;
        say_out('          SKIP: at least one prerequisite ADD failed; no projected DROP is safe');
        next;
    }

    my $ok = eval { $dbh->do($sql); 1 };
    if ($ok) {
        $applied++;
        say_out('          OK');
    }
    else {
        $failed++;
        $add_failed = 1 if $verb eq 'ADD';
        say_out('          ECHEC: ' . ($dbh->errstr // 'unknown'));
    }
}
say_out('');
if (!$changes) {
    say_out("Rien a faire: la table est deja d'equerre.");
}
elsif (!$opt_execute) {
    say_out("$changes changement(s) proposes. Rejouer avec --execute pour appliquer.");
}
else {
    say_out("Termine: $applied applique(s), $failed echec(s), $skipped drop(s) saute(s).");
}
$dbh->disconnect;
exit($failed ? 2 : 0);
