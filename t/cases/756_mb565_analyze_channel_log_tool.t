# t/cases/756_mb565_analyze_channel_log_tool.t
# =============================================================================
# mb565 — outil ops tools/analyze_channel_log.pl (analyse de CHANNEL_LOG et
# de la base). Gardes statiques :
#   [1] l'outil existe, compile, et lit la conf avec le MEME moule que
#       measure_channel_log.pl (section [mysql] MAIN_PROG_*, localhost ->
#       127.0.0.1, DSN MariaDB avec repli mysql) ;
#   [2] LECTURE SEULE prouvee : toutes les requetes preparees sont des
#       SELECT ou SHOW — aucun INSERT/UPDATE/DELETE/ALTER/DROP/CREATE
#       execute (les ALTER recommandes ne sont que des chaines affichees,
#       jamais passees a prepare/do) ;
#   [3] confidentialite : le mot de passe n'est jamais imprime, aucun
#       contenu de message (colonne de texte) n'est selectionne — agregats
#       COUNT/MIN/MAX/information_schema uniquement ;
#   [4] les trois index recommandes (mb558 x2 + A4) sont verifies et leur
#       SQL online (INPLACE, LOCK=NONE) est fourni ;
#   [5] les options documentees existent (--conf --top --months --json
#       --quiet) et les bornes top<=50 months<=60 sont appliquees.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_756 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

return sub {
    my ($assert) = @_;

    my $path = File::Spec->catfile('tools', 'analyze_channel_log.pl');
    $assert->ok(-f $path, 'l\'outil existe');

    my $rc = system($^X, '-c', $path) == 0 ? 1 : 0;
    $assert->ok($rc, 'perl -c passe');

    my $src = _slurp_756($path);

    # [1] Moule conf/DSN identique a l'outil frere
    $assert->like($src, qr/mysql\.MAIN_PROG_DDBNAME/, 'conf: DDBNAME (cle du bot)');
    $assert->like($src, qr/mysql\.MAIN_PROG_DBUSER/, 'conf: DBUSER');
    $assert->like($src, qr/\(\$dbhost eq 'localhost'\) \? '127\.0\.0\.1'/,
        'DSN: localhost force en TCP comme le bot');
    $assert->like($src, qr/DBI:MariaDB:database=/, 'DSN: driver MariaDB');
    $assert->like($src, qr/DBI:mysql:database=/, 'DSN: repli driver mysql');

    # [2] Lecture seule : les verbes d'ecriture n'apparaissent au debut
    # d'aucune requete SQL (les ALTER recommandes vivent dans des chaines
    # sql => '...' jamais executees).
    my @prepared = $src =~ /prepare\(\s*(?:qq?\{|')\s*([A-Za-z]+)/g;
    my @sql_heads = $src =~ /rows\(\s*qq?\{\s*\n?\s*([A-Za-z]+)/g;
    push @sql_heads, $src =~ /one\(\s*q\{\s*\n?\s*([A-Za-z]+)/g;
    my @bad = grep { $_ !~ /^(SELECT|SHOW)$/i } (@prepared, @sql_heads);
    $assert->is(join(',', @bad), '', 'toutes les requetes executees sont SELECT/SHOW');
    $assert->unlike($src, qr/\$dbh->do\(/, 'aucun $dbh->do');
    $assert->like($src, qr/rien n\\'est execute par cet outil/,
        'les ALTER recommandes sont annonces comme non executes');

    # [3] Confidentialite
    $assert->unlike($src, qr/say_out\([^)]*\$dbpass/, 'mot de passe jamais imprime');
    $assert->unlike($src, qr/SELECT[^;]*\bmessage\b/is,
        'aucune colonne de contenu de message selectionnee');

    # [4] Les trois index recommandes
    for my $cols ('id_channel.{0,3}nick.{0,3}event_type',
                  "'nick', 'event_type'",
                  "'id_channel', 'ts'") {
        $assert->like($src, qr/$cols/s, "index recommande: $cols");
    }
    # mb568-B1: restreint aux ADD INDEX — le template de DROP suggere par le
    # detecteur de redondance utilise aussi l'online DDL.
    my $inplace = () = $src =~ /ADD INDEX [^;]*ALGORITHM=INPLACE, LOCK=NONE/g;
    $assert->ok($inplace == 3, 'les 3 SQL recommandes sont en online DDL');

    # [5] Options et bornes
    for my $opt ('conf=s', 'top=i', 'months=i', 'json', 'quiet') {
        $assert->like($src, qr/'\Q$opt\E'/, "option $opt");
    }
    $assert->like($src, qr/\$opt_top\s+= 50 if \$opt_top > 50/, 'borne top');
    $assert->like($src, qr/\$opt_months = 60 if \$opt_months > 60/, 'borne months');

    # L'outil frere reste reference dans l'entete (complementarite explicite)
    $assert->like($src, qr/measure_channel_log\.pl/, 'outil frere reference');
};
