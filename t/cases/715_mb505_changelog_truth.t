# t/cases/715_mb505_changelog_truth.t
# =============================================================================
# mb505 — Vérité documentaire du CHANGELOG pour la release 3.3.
#
# Prérequis du "go 3.3" : aucune incohérence version/documentation. Ce test
# garantit durablement que :
#   [1] CHANGELOG.md existe et contient une section 3.3 ;
#   [2] les commandes phares livrées pour 3.3 y sont mentionnées ;
#   [3] toute migration .sql citée dans le CHANGELOG existe réellement sur
#       disque (pas de référence fantôme) ;
#   [4] la ligne de versionnage du README reste cohérente (3.3 = cible stable).
# Purement documentaire : aucun runtime métier, aucun schéma.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_715 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

return sub {
    my ($assert) = @_;

    # --- [1] le CHANGELOG existe et couvre 3.3 -----------------------------
    my $cl_path = File::Spec->catfile('.', 'CHANGELOG.md');
    $assert->ok(-f $cl_path, '[1] CHANGELOG.md présent');
    my $cl = -f $cl_path ? _slurp_715($cl_path) : '';
    $assert->like($cl, qr/^##\s*\[3\.3\]/m, '[1] section [3.3] présente');

    # --- [2] commandes phares de 3.3 documentées ---------------------------
    for my $cmd (qw(tell learn whatis factoids factoid convert onthisday topquote milestone seen mood recap)) {
        $assert->like($cl, qr/\b\Q$cmd\E\b/, "[2] CHANGELOG mentionne $cmd");
    }
    # les grands axes
    $assert->like($cl, qr/hall of fame/i,     '[2] hall of fame décrit');
    $assert->like($cl, qr/digest/i,           '[2] digest décrit');
    $assert->like($cl, qr/OnThisDayDigest/,   '[2] chanset digest cité');

    # --- [3] chaque migration .sql citée existe réellement -----------------
    my @required_recent = qw(
        20260706_channel_log_channel_ts.sql
        20260707_channel_report_chanset.sql
        20260707_didyoumean_chanset.sql
        20260707_factoid.sql
        20260707_factoids_chanset.sql
        20260708_onthisday_chanset.sql
        20260708_onthisday_digest_chanset.sql
        20260710_quotes_hits.sql
    );
    my @cited = ($cl =~ /([0-9]{8}_[a-z0-9_]+\.sql)/g);
    my %cited = map { $_ => 1 } @cited;
    for my $mig (@required_recent) {
        $assert->ok($cited{$mig}, "[3] migration récente citée: $mig");
        $assert->ok(
            -f File::Spec->catfile('.', 'install', 'migrations', $mig),
            "[3] migration citée existe: $mig");
    }
    $assert->like($cl, qr{install/migrations/README\.md},
        '[3] CHANGELOG renvoie vers l’ordre complet autoritatif');

    # --- [4] cohérence versionnage README ----------------------------------
    my $readme = _slurp_715(File::Spec->catfile('.', 'README.md'));
    $assert->like($readme, qr/3\.3\s+next stable target/i, '[4] README: 3.3 = cible stable');
    $assert->like($readme, qr/3\.2dev/, '[4] README: ligne de dev 3.2dev citée');
};
