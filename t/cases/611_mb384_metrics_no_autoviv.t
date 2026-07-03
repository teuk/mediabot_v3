# t/cases/611_mb384_metrics_no_autoviv.t
# =============================================================================
# mb384 — Ne pas autovivifier $obj->{metrics} en {} non blessé.
#
# Un accès HASH `$obj->{metrics}->{started}` sur un metrics UNDEF autovivifie
# $obj->{metrics} en {} (ref non blessée, truthy). Ensuite les gardes
# "if $obj->{metrics}" passaient et `$obj->{metrics}->inc(...)` plantait avec
# "Can't call method inc on unblessed reference" (dispatch privé, botNotice…).
# mb384 garde l'accès (metrics ? ->{started} : undef) aux 3 sites (Helpers,
# Partyline, mediabot.pl), à l'image de Partyline:5081 déjà correct.
#
# Validation : (a) sémantique autoviv, (b) scan source (plus d'accès nu).
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_611 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die $!; local $/; <$fh> }

return sub {
    my ($assert) = @_;

    # --- 1. Sémantique : l'accès nu autovivifie, le garde non -------------
    my $bad  = {};                      # metrics undef
    my $x = eval { $bad->{metrics}->{started} };   # accès NU
    $assert->ok(ref $bad->{metrics} eq 'HASH', 'témoin: accès nu ->{started} autovivifie metrics en {}');

    my $good = {};
    my $y = eval { $good->{metrics} ? $good->{metrics}->{started} : undef };  # accès GARDÉ
    $assert->ok(!exists $good->{metrics}, 'garde: metrics reste absent (pas d\'autoviv)');
    $assert->ok(!defined $y, 'garde: renvoie undef proprement');

    # Conséquence : après le garde, "if metrics" est faux -> pas d'appel ->inc.
    $assert->ok(!$good->{metrics}, 'garde: le guard "if metrics" reste faux');

    # --- 2. Scan source : plus d'accès nu ->{started} --------------------
    for my $rel (['Mediabot','Helpers.pm'], ['Mediabot','Partyline.pm']) {
        my $src = _slurp_611(File::Spec->catfile('.', @$rel));
        my @nu = grep { /\{metrics\}->\{started\}/ && !/metrics\}\s*\?/ && !/metrics\}\s*&&/ }
                 split /\n/, $src;
        # on retire les lignes de commentaire
        @nu = grep { $_ !~ /^\s*#/ } @nu;
        $assert->is(scalar(@nu), 0, "$rel->[1]: plus d'accès nu \$…{metrics}->{started}");
    }
    my $main = _slurp_611(File::Spec->catfile('.', 'mediabot.pl'));
    my @nu = grep { /\{metrics\}->\{started\}/ && !/metrics\}\s*\?/ && $_ !~ /^\s*#/ } split /\n/, $main;
    $assert->is(scalar(@nu), 0, "mediabot.pl: plus d'accès nu metrics->{started}");

    $assert->like(_slurp_611(File::Spec->catfile('.','Mediabot','Helpers.pm')), qr/mb384-B1/, 'tag mb384-B1');
};
