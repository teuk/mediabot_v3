# t/cases/662_mb447_release_doc_truth.t
# =============================================================================
# mb447 — Vérité documentaire de release (roadmap 3.3, P0.2 / Jalon B).
#
# 1. Aucun document public ne recommande un exécutable absent : ./start et
#    ./daemon n'existent pas dans le dépôt ; README.md et
#    install/deploy_update.sh doivent pointer vers les chemins réellement
#    supportés (perl mediabot.pl --conf=... en foreground, systemd en prod).
# 2. La liste des migrations est unique, complète et ordonnée : chaque fichier
#    .sql présent dans install/migrations/ doit apparaître dans
#    docs/DB_MIGRATIONS.md ET dans install/migrations/README.md (autorité).
# Ce test est purement documentaire : aucun runtime métier, aucun schéma.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_662 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

return sub {
    my ($assert) = @_;

    # --- 1. Les wrappers historiques n'existent pas (et ne reviennent pas en douce)
    $assert->ok(!-e File::Spec->catfile('.', 'start'),  './start absent du dépôt');
    $assert->ok(!-e File::Spec->catfile('.', 'daemon'), './daemon absent du dépôt');

    # --- 2. README : plus de ./start, la commande foreground réelle est là ---
    my $readme = _slurp_662('README.md');
    $assert->unlike($readme, qr/^\.\/start\b/m, 'README ne recommande plus ./start');
    $assert->unlike($readme, qr/^\.\/daemon\b/m, 'README ne recommande plus ./daemon');
    $assert->like($readme, qr/perl mediabot\.pl --conf=/, 'README documente le foreground réel');
    $assert->like($readme, qr/systemctl (?:re)?start mediabot\@/, 'README documente systemd');
    $assert->like($readme, qr/tools\/systemd\/README\.md/, 'README pointe vers la doc systemd');

    # --- 3. deploy_update.sh : messages de fin alignés sur la réalité --------
    my $deploy = _slurp_662(File::Spec->catfile('install', 'deploy_update.sh'));
    $assert->unlike($deploy, qr/\.\/start\b/,  'deploy_update.sh n\'affiche plus ./start');
    $assert->unlike($deploy, qr/\.\/daemon\b/, 'deploy_update.sh n\'affiche plus ./daemon');
    $assert->like($deploy, qr/perl mediabot\.pl --conf=/, 'deploy_update.sh affiche le foreground réel');
    $assert->like($deploy, qr/systemctl restart mediabot\@/, 'deploy_update.sh affiche systemd');

    # --- 4. Migrations : listes complètes et cohérentes ----------------------
    my $mig_dir = File::Spec->catdir('install', 'migrations');
    opendir(my $dh, $mig_dir) or die "cannot open $mig_dir: $!";
    my @sql = sort grep { /\.sql\z/ } readdir($dh);
    closedir($dh);
    $assert->ok(scalar(@sql) >= 8, 'au moins les 8 migrations connues présentes');

    my $docm = _slurp_662(File::Spec->catfile('docs', 'DB_MIGRATIONS.md'));
    my $migr = _slurp_662(File::Spec->catfile('install', 'migrations', 'README.md'));

    for my $f (@sql) {
        $assert->ok(index($docm, $f) >= 0, "docs/DB_MIGRATIONS.md liste $f");
        $assert->ok(index($migr, $f) >= 0, "install/migrations/README.md liste $f");
    }

    # docs/DB_MIGRATIONS.md désigne l'autorité et distingue fresh/upgrade.
    $assert->like($docm, qr/install\/migrations\/README\.md/,
        'DB_MIGRATIONS.md désigne install/migrations/README.md comme autorité');
    $assert->like($docm, qr/fresh install.*mediabot\.sql/is,
        'DB_MIGRATIONS.md précise que la fresh install utilise mediabot.sql');
};
