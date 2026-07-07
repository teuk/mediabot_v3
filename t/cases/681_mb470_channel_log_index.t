# t/cases/681_mb470_channel_log_index.t
# =============================================================================
# mb470 — Index composite CHANNEL_LOG (id_channel, ts) + harnais de mesure.
#         Direction 3.3 §2.4 / Phase A / A4.
#
# On ne dispose pas d'un vrai MariaDB dans le conteneur : ce test valide par
# scan/parsing que
#   [1] le schéma de référence (install/mediabot.sql) déclare bien l'index
#       composite idx_channel_log_channel_ts (id_channel, ts), SANS supprimer
#       les index existants ;
#   [2] la migration 20260706_channel_log_channel_ts.sql est idempotente
#       (procédure gardée par information_schema.STATISTICS, aucun ADD INDEX
#       nu, nettoyage de la procédure), et n'ajoute NI table NI colonne ;
#   [3] le harnais tools/measure_channel_log.pl compile, est en LECTURE SEULE
#       (aucun INSERT/UPDATE/DELETE/ALTER/CREATE/DROP hors EXPLAIN/ANALYZE),
#       lit la conf [mysql] du bot et rejoue les requêtes chaudes attendues.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_681 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

return sub {
    my ($assert) = @_;

    # -------------------------------------------------------------------------
    # [1] Schéma de référence
    # -------------------------------------------------------------------------
    my $sql = _slurp_681(File::Spec->catfile('.', 'install', 'mediabot.sql'));

    $assert->like($sql,
        qr/KEY\s+`idx_channel_log_channel_ts`\s*\(`id_channel`,\s*`ts`\)/,
        '[1] mediabot.sql déclare l\'index composite (id_channel, ts)');
    # Les index existants ne doivent PAS avoir disparu.
    $assert->like($sql, qr/KEY\s+`idx_channel_log_id_channel`\s*\(`id_channel`\)/,
        '[1] index id_channel simple conservé');
    $assert->like($sql, qr/KEY\s+`ts`\s+\(`ts`\)/,
        '[1] index ts conservé');
    $assert->like($sql, qr/KEY\s+`nick`\s+\(`nick`\(191\)\)/,
        '[1] index nick conservé');

    # -------------------------------------------------------------------------
    # [2] Migration idempotente
    # -------------------------------------------------------------------------
    my $mig_path = File::Spec->catfile('.', 'install', 'migrations',
                                       '20260706_channel_log_channel_ts.sql');
    $assert->ok(-f $mig_path, '[2] migration présente');
    my $mig = -f $mig_path ? _slurp_681($mig_path) : '';

    $assert->like($mig, qr/information_schema\.STATISTICS/,
        '[2] garde d\'idempotence via information_schema.STATISTICS');
    $assert->like($mig, qr/index_name\s*=\s*'idx_channel_log_channel_ts'/,
        '[2] teste la présence de l\'index par son nom');
    $assert->like($mig, qr/ADD INDEX `idx_channel_log_channel_ts` \(`id_channel`, `ts`\)/,
        '[2] ajoute bien (id_channel, ts)');
    $assert->like($mig, qr/DROP PROCEDURE IF EXISTS/,
        '[2] nettoie la procédure temporaire');
    # Idempotence réelle : l'ADD INDEX doit être DANS la procédure gardée,
    # jamais nu au niveau top-level.
    my $mig_no_proc = $mig;
    $mig_no_proc =~ s/CREATE PROCEDURE.*?END\s*\/\///s;
    $assert->unlike($mig_no_proc, qr/ALTER TABLE `CHANNEL_LOG`\s+ADD INDEX/s,
        '[2] aucun ADD INDEX nu hors de la procédure gardée');
    # Périmètre : pas de nouvelle table/colonne.
    $assert->unlike($mig, qr/CREATE TABLE/i, '[2] aucune table créée');
    $assert->unlike($mig, qr/ADD COLUMN/i,   '[2] aucune colonne ajoutée');
    $assert->unlike($mig, qr/DROP INDEX/i,   '[2] aucun index supprimé');

    # -------------------------------------------------------------------------
    # [3] Harnais de mesure
    # -------------------------------------------------------------------------
    my $tool_path = File::Spec->catfile('.', 'tools', 'measure_channel_log.pl');
    $assert->ok(-f $tool_path, '[3] harnais présent');
    my $tool = -f $tool_path ? _slurp_681($tool_path) : '';

    # Compile (avec les stubs du conteneur dans @INC via PERL5LIB du runner).
    my $compile = system("perl -c \"$tool_path\" >/dev/null 2>&1");
    $assert->is($compile, 0, '[3] measure_channel_log.pl : perl -c OK');

    # Lecture seule : aucune écriture SQL hors EXPLAIN/ANALYZE.
    $assert->unlike($tool, qr/\b(?:INSERT|UPDATE|DELETE|REPLACE|TRUNCATE|CREATE\s+TABLE|DROP\s+TABLE|ALTER\s+TABLE)\b/i,
        '[3] harnais en LECTURE SEULE (aucune écriture SQL)');
    $assert->like($tool, qr/EXPLAIN /,  '[3] émet des EXPLAIN');
    $assert->like($tool, qr/ANALYZE/,   '[3] tente ANALYZE/EXPLAIN ANALYZE');

    # Lit la conf [mysql] du bot avec les bonnes clés.
    $assert->like($tool, qr/mysql\.MAIN_PROG_DBUSER/, '[3] lit MAIN_PROG_DBUSER');
    $assert->like($tool, qr/mysql\.MAIN_PROG_DDBNAME/, '[3] lit MAIN_PROG_DDBNAME (double D)');
    $assert->like($tool, qr/localhost.*127\.0\.0\.1/s,
        '[3] force TCP comme le bot (localhost -> 127.0.0.1)');

    # Rejoue les requêtes chaudes attendues (mêmes cibles que la direction).
    $assert->like($tool, qr/m check .{1,3} user aggregate/,   '[3] mesure m check user aggregate');
    $assert->like($tool, qr/m check .{1,3} channel total/,    '[3] mesure m check channel total');
    $assert->like($tool, qr/hourband/,                   '[3] mesure achievements hourband');
    $assert->like($tool, qr/polyphony/,                  '[3] mesure achievements polyphony');
    $assert->like($tool, qr/over period/,                '[3] mesure une requête à plage temporelle');

    # Détecte la présence de l'index composite pour interpréter le plan.
    $assert->like($tool, qr/idx_channel_log_channel_ts/,
        '[3] vérifie la présence de l\'index composite');
};
