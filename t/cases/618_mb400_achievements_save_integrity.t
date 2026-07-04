# t/cases/618_mb400_achievements_save_integrity.t
# =============================================================================
# mb400 — La chaîne de perte de données achievements est cassée.
#
# Avant : save() faisait `print $fh $json; close $fh;` SANS vérifier les
# retours, puis rename. Sur disque plein (ENOSPC), le tmp TRONQUÉ était promu
# par-dessus var/achievements.json -> JSON invalide -> au redémarrage _load()
# échouait -> data={} -> le save() suivant écrasait définitivement tout
# l'historique. mb400 :
#   (a) save() vérifie print ET close ; un tmp incomplet est supprimé, jamais
#       renommé — le fichier principal reste intact ;
#   (b) _load() préserve un fichier illisible en .corrupt-<ts> avant qu'un
#       futur save() ne puisse l'écraser.
#
# Validation : exécution réelle du module sur un FS temporaire + scan source.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;
use File::Temp qw(tempdir);

sub _slurp_618 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

return sub {
    my ($assert) = @_;

    require Mediabot::Achievements;

    my $dir  = tempdir(CLEANUP => 1);
    my $path = File::Spec->catfile($dir, 'ach.json');

    # --- 1. save/reload nominal -------------------------------------------
    my $a = Mediabot::Achievements->new(path => $path, bot => undef);
    $a->{data}  = { "teuk\x00#teuk" => { first_msg => 1751500000 } };
    $a->{dirty} = 1;
    $a->save(1);
    $assert->ok(-s $path, 'save nominal écrit le fichier');

    my $b = Mediabot::Achievements->new(path => $path, bot => undef);
    $assert->ok(exists $b->{data}{"teuk\x00#teuk"}, 'reload nominal relit les données');

    # --- 2. fichier corrompu : préservé, plus écrasable --------------------
    { open my $fh, '>', $path or die $!; print {$fh} '{corrupt'; close $fh; }
    my $c = Mediabot::Achievements->new(path => $path, bot => undef);
    my @corrupt = glob("$path.corrupt-*");
    $assert->ok(scalar(@corrupt) == 1, 'fichier corrompu préservé en .corrupt-<ts>');
    $assert->ok(!-e $path, 'le fichier corrompu n\'est plus en place (plus écrasable)');

    # un save ultérieur repart proprement sans toucher au backup.
    $c->{data} = { fresh => 1 }; $c->{dirty} = 1; $c->save(1);
    $assert->ok(-s $path,        'save post-corruption écrit un nouveau fichier');
    $assert->ok(-s $corrupt[0],  'le backup .corrupt reste intact');

    # --- 3. scan source : write vérifié avant promotion --------------------
    my $src = _slurp_618(File::Spec->catfile('.', 'Mediabot', 'Achievements.pm'));
    my ($save) = $src =~ /(sub save \{.*?\n\}\n)/s; $save //= '';
    $assert->like($save, qr/print \{\$fh\} \$json or do/, 'print vérifié');
    $assert->like($save, qr/close \$fh or do/,            'close vérifié');
    $assert->like($save, qr/unlink \$tmp/,                'tmp incomplet supprimé, jamais renommé');
    my ($load) = $src =~ /(sub _load \{.*?\n\}\n)/s; $load //= '';
    $assert->like($load, qr/\.corrupt-/,                  '_load préserve le fichier illisible');
    $assert->like($src, qr/mb400-B1/, 'tag mb400-B1');
};
