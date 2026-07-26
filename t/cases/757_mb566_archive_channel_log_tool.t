# t/cases/757_mb566_archive_channel_log_tool.t
# =============================================================================
# mb566 — outil tools/archive_channel_log.pl (archivage/allegement de
# CHANNEL_LOG). Gardes statiques sur les disciplines de securite :
#   [1] existe, compile, meme moule conf/DSN que les deux outils freres
#       (references en entete) ;
#   [2] DRY-RUN PAR DEFAUT : le DELETE vit derriere --execute ; sans filtre,
#       l'outil refuse (aucun vidage accidentel) ;
#   [3] ARCHIVE AVANT SUPPRESSION : l'export gzip precede le DELETE dans le
#       flux, le compte exporte est verifie == selectionne (ABORT sinon,
#       archive conservee), --no-archive est explicite ;
#   [4] DELETE PAR LOTS uniquement : le seul DELETE du fichier porte un
#       LIMIT borne (jamais de DELETE monolithique), pause entre lots ;
#   [5] confidentialite : mot de passe jamais imprime ; le dry-run
#       n'affiche jamais le contenu des messages (ts/event/nick seulement) ;
#   [6] --analyze-month : agregats seulement (COUNT), aucun contenu.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_757 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

return sub {
    my ($assert) = @_;

    my $path = File::Spec->catfile('tools', 'archive_channel_log.pl');
    $assert->ok(-f $path, 'l\'outil existe');
    $assert->ok(system($^X, '-c', $path) == 0, 'perl -c passe');

    my $src = _slurp_757($path);

    # [1] Famille et moule
    $assert->like($src, qr/measure_channel_log\.pl/, 'frere measure reference');
    $assert->like($src, qr/analyze_channel_log\.pl/, 'frere analyze reference');
    $assert->like($src, qr/mysql\.MAIN_PROG_DDBNAME/, 'conf: cles du bot');
    $assert->like($src, qr/DBI:MariaDB:database=/, 'DSN MariaDB');
    $assert->like($src, qr/DBI:mysql:database=/, 'repli mysql');

    # [2] Dry-run par defaut, refus sans filtre
    $assert->like($src, qr/if \(!\$opt_execute\) \{/, 'branche dry-run presente');
    $assert->like($src, qr/DRY-RUN: rien n\\'a ete modifie/, 'message dry-run explicite');
    $assert->like($src, qr/die "Nothing selected: use --analyze-month/,
        'refus sans filtre (aucun vidage accidentel)');

    # [3] Archive avant suppression, verification, abort conservateur
    my $pos_export = index($src, 'IO::Compress::Gzip->new');
    my $pos_delete = index($src, 'DELETE FROM CHANNEL_LOG');
    $assert->ok($pos_export > -1 && $pos_delete > $pos_export,
        'l\'export gzip precede le DELETE dans le flux');
    $assert->like($src, qr/exported == \$selected/, 'compte exporte verifie');
    $assert->like($src, qr/ABORT: exported .* nothing deleted, archive kept/,
        'divergence -> abort, rien supprime, archive gardee');
    $assert->like($src, qr/'no-archive'\s+=> \\\$opt_noarch/, '--no-archive explicite');
    $assert->like($src, qr/SHOW COLUMNS FROM CHANNEL_LOG/,
        'colonnes decouvertes dynamiquement (schema non fige)');

    # [4] Un seul DELETE, toujours par lots bornes
    my @deletes = $src =~ /(DELETE FROM CHANNEL_LOG[^"]*)/g;
    $assert->ok(@deletes == 1, 'un seul site DELETE dans l\'outil');
    $assert->like($deletes[0], qr/LIMIT \$opt_batch/, 'le DELETE porte un LIMIT');
    $assert->like($src, qr/\$opt_batch = 1000\s+if \$opt_batch < 1000/, 'batch borne bas');
    $assert->like($src, qr/\$opt_batch = 500000 if \$opt_batch > 500000/, 'batch borne haut');
    $assert->like($src, qr/select\(undef, undef, undef, \$opt_sleep \/ 1000\)/,
        'pause entre lots');

    # [5] Confidentialite
    $assert->unlike($src, qr/say_(?:out|info)\([^)]*\$dbpass/, 'mot de passe jamais imprime');
    $assert->like($src, qr/SELECT ts, event_type, nick FROM CHANNEL_LOG/,
        'apercu dry-run: ts/event/nick');
    $assert->like($src, qr/jamais le contenu/, 'apercu annonce sans contenu');

    # [6] Enquete en agregats
    my ($analyze_block) = $src =~ /(if \(\$opt_analyze\) \{.*?exit 0;\n\})/s;
    $assert->ok(defined $analyze_block, 'bloc analyze isole');
    $assert->unlike($analyze_block, qr/publictext|last_msg/,
        'enquete: aucun contenu de message selectionne');

    # mb567-B1: le contenu exporte est encode en octets UTF-8 avant gzip
    # (le driver rend des chaines de caracteres; sans encode: "Wide
    # character in write" et archive corrompue — incident du 2026-07-25).
    my ($export_loop) = $src =~ /(while \(my \$r = \$exp->fetchrow_arrayref\).*?\$exported\+\+;)/s;
    $assert->ok(defined $export_loop, 'boucle d\'export isolee');
    $assert->like($export_loop, qr/Encode::encode\('UTF-8', \$v\) if utf8::is_utf8\(\$v\)/,
        'export: encodage UTF-8 avant la couche gzip');

    # mb571-B1: snapshot high-water, dates indexables, archives privees,
    # NULL TSV distinct d'une chaine litterale \N.
    $assert->like($src, qr/COUNT\(\*\), MAX\(id_channel_log\)/,
        'selection figee par high-water dans une seule requete');
    $assert->like($src, qr/id_channel_log <= \?/,
        'export et delete bornes par le high-water');
    $assert->unlike($src, qr/DATE_FORMAT\((?:cl\.)?ts/,
        'filtres de mois indexables: aucune fonction DATE_FORMAT sur ts');
    $assert->like($src, qr/chmod 0700, \$opt_outdir/,
        'repertoire archive prive 0700');
    $assert->like($src, qr/chmod 0600, \$archive_file/,
        'archive privee 0600');
    $assert->like($src, qr/if \(!defined \$_\)/,
        'NULL SQL encode separement des chaines');

    # OPTIMIZE recommande mais jamais execute
    $assert->like($src, qr/OPTIMIZE TABLE CHANNEL_LOG;/, 'OPTIMIZE recommande');
    $assert->unlike($src, qr/do\(\s*["']OPTIMIZE/i, 'OPTIMIZE jamais execute');
};
