# t/cases/753_mb562_no_mojibake.t
# =============================================================================
# mb562 — les réponses FR/ES du 8ball étaient à DOUBLE encodage UTF-8
# (é stocké « Ã© ») : elles sortaient cassées sur IRC dès main.LANG=fr|es.
# Réparé par ré-encodage unique. Ce garde interdit toute séquence mojibake
# dans les modules livrés — la signature du double encodage est un « Ã »
# (U+00C3) suivi d'un caractère de la plage U+0080-U+00BF une fois le
# fichier décodé en UTF-8.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;
use File::Find qw(find);

sub _slurp_753 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

return sub {
    my ($assert) = @_;

    my @modules;
    find({
        no_chdir => 1,
        wanted   => sub { push @modules, $File::Find::name if -f $_ && /\.pm\z/ },
    }, 'Mediabot');
    push @modules, 'mediabot.pl';
    @modules = sort @modules;
    $assert->ok(scalar(@modules) >= 30, 'modules et sous-modules trouves');
    $assert->ok(scalar(grep { m{Mediabot/Plugin/} } @modules) >= 1,
        'le garde inspecte aussi les sous-modules');

    my @dirty;
    for my $file (@modules) {
        my $src = _slurp_753($file);
        # Claude.pm documents mojibake repair with deliberately broken examples
        # in comments. Ignore full-line comments; executable strings and code
        # remain covered recursively.
        $src =~ s/^\s*#.*$//mg;
        my $hits = () = $src =~ /\x{00C3}[\x{0080}-\x{00BF}]/g;
        push @dirty, "$file($hits)" if $hits;
    }
    $assert->is(join(', ', @dirty), '',
        'aucune sequence de double encodage UTF-8 dans les modules');

    # Le pool FR du 8ball est bien reparé et non vide
    my $uc = _slurp_753(File::Spec->catfile('Mediabot', 'UserCommands.pm'));
    $assert->like($uc, qr/C\\'est absolument \x{00E7}a\./,
        '8ball FR: accents simples corrects');
    $assert->like($uc, qr/Definitivamente s\x{00ED}\./,
        '8ball ES: accents simples corrects');
    $assert->like($uc, qr/mb562-B1/, 'marqueur mb562 present');
};
