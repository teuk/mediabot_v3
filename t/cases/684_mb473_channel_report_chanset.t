# t/cases/684_mb473_channel_report_chanset.t
# =============================================================================
# mb473 — Chanset ChannelReport : opt-out par canal des rapports automatiques.
#
# Les tâches daily_channel_report et weekly_channel_report postaient sur TOUS
# les canaux joints, sans possibilité de désactiver par canal. mb473 ajoute un
# chanset ChannelReport (default ON pour rétrocompat) qui gate les deux.
#
# Vérifié par scan (pas de vrai scheduler ni DB dans le conteneur) :
#   [1] schéma de référence : ChannelReport dans CHANSET_LIST (id 17) ;
#   [2] migration idempotente présente et data-only ;
#   [3] les DEUX cb de rapport gatent via chanset_enabled(..., default => 1) ;
#   [4] rétrocompat : default => 1 (les canaux existants gardent leurs rapports) ;
#   [5] chanset documenté dans l'aide.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_684 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

return sub {
    my ($assert) = @_;

    # -------------------------------------------------------------------------
    # [1] Schéma de référence : ChannelReport dans CHANSET_LIST
    # -------------------------------------------------------------------------
    my $sql = _slurp_684(File::Spec->catfile('.', 'install', 'mediabot.sql'));
    $assert->like($sql, qr/\(17,\s*'ChannelReport'\)/,
        '[1] ChannelReport (id 17) dans CHANSET_LIST du schéma');

    # -------------------------------------------------------------------------
    # [2] Migration idempotente, data-only
    # -------------------------------------------------------------------------
    my $mig_path = File::Spec->catfile('.', 'install', 'migrations',
                                       '20260707_channel_report_chanset.sql');
    $assert->ok(-f $mig_path, '[2] migration présente');
    my $mig = -f $mig_path ? _slurp_684($mig_path) : '';
    $assert->like($mig, qr/INSERT INTO CHANSET_LIST/i, '[2] insère dans CHANSET_LIST');
    $assert->like($mig, qr/WHERE NOT EXISTS/i, '[2] idempotente (WHERE NOT EXISTS)');
    $assert->like($mig, qr/'ChannelReport'/, '[2] cible le chanset ChannelReport');
    $assert->unlike($mig, qr/CREATE TABLE|ALTER TABLE|ADD COLUMN|DROP/i,
        '[2] data-only (aucun changement de structure)');

    # Migration déclarée dans les deux docs (garde 662).
    my $dbdoc = _slurp_684(File::Spec->catfile('.', 'docs', 'DB_MIGRATIONS.md'));
    my $rmdoc = _slurp_684(File::Spec->catfile('.', 'install', 'migrations', 'README.md'));
    $assert->like($dbdoc, qr/20260707_channel_report_chanset\.sql/,
        '[2] déclarée dans DB_MIGRATIONS.md');
    $assert->like($rmdoc, qr/20260707_channel_report_chanset\.sql/,
        '[2] déclarée dans migrations/README.md');

    # -------------------------------------------------------------------------
    # [3]+[4] Les deux rapports gatent via chanset_enabled(..., default => 1)
    # -------------------------------------------------------------------------
    my $main = _slurp_684(File::Spec->catfile('.', 'mediabot.pl'));

    # weekly report cb — fenêtre de 2000 car après le nom de la tâche
    my ($weekly) = $main =~ /(name\s*=>\s*'weekly_channel_report'.{0,2000})/s;
    $weekly //= '';
    $assert->like($weekly, qr/chanset_enabled\([^)]*'ChannelReport'[^)]*default\s*=>\s*1/s,
        '[3] weekly report gaté par ChannelReport (default 1)');

    # daily report cb
    my ($daily) = $main =~ /(name\s*=>\s*'daily_channel_report'.{0,2000})/s;
    $daily //= '';
    $assert->like($daily, qr/chanset_enabled\([^)]*'ChannelReport'[^)]*default\s*=>\s*1/s,
        '[3] daily report gaté par ChannelReport (default 1)');

    # Rétrocompat explicite : default => 1 partout où ChannelReport est testé.
    my @gates = ($main =~ /chanset_enabled\([^;]*?'ChannelReport'[^;]*?\)/gs);
    $assert->ok(scalar(@gates) >= 2, '[4] les deux tâches gatent ChannelReport');
    my $all_default_on = 1;
    for my $g (@gates) { $all_default_on = 0 unless $g =~ /default\s*=>\s*1/; }
    $assert->ok($all_default_on, '[4] rétrocompat : default => 1 sur tous les gates');

    # -------------------------------------------------------------------------
    # [5] Chanset documenté dans l'aide
    # -------------------------------------------------------------------------
    my $med = _slurp_684(File::Spec->catfile('.', 'Mediabot', 'Mediabot.pm'));
    $assert->like($med, qr/\+ChannelReport\b/,
        '[5] ChannelReport documenté dans l\'aide des chansets');
};
