# t/cases/659_mb444_horoscope_local_prng.t
# =============================================================================
# mb444 — !horoscope n'altère plus le RNG global du process.
#
# Pour rendre l'horoscope déterministe par (nick, date), le code faisait
# srand($seed) — ce qui reseede le générateur GLOBAL de Perl — puis srand()
# pour « restaurer ». Mais srand() ne restaure PAS la séquence : il reseed
# depuis l'horloge. Ce reseed répété (un par !horoscope) perturbe et dégrade le
# RNG partagé par les dés (!roll), le d20 des duels, le 8ball, la quote
# aléatoire, la proba Hailo, la sélection trivia... mb444 tire les index via un
# LCG LOCAL, sans jamais toucher srand()/le RNG global.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_659 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

# Reproduction du LCG local (doit rester synchrone avec mbHoroscope_ctx).
sub _picks {
    my ($seed, $n) = @_;
    my $rng  = $seed & 0x7FFFFFFF;
    my $next = sub { $rng = (($rng * 1103515245) + 12345) & 0x7FFFFFFF; return $rng; };
    return join(',', map { $next->() % 12 } 1 .. $n);
}

return sub {
    my ($assert) = @_;

    # --- 1. Déterminisme par seed -----------------------------------------
    $assert->is(_picks(12345, 6), _picks(12345, 6), 'même seed -> mêmes tirages (déterministe)');
    $assert->ok(_picks(12345, 6) ne _picks(99999, 6), 'seeds différents -> tirages différents');

    # --- 2. Le RNG global n'est PAS perturbé ------------------------------
    # Séquence de référence depuis srand(42).
    srand(42);
    my @ref = map { int(rand 1000) } 1 .. 6;

    # Rejouer en intercalant les tirages horoscope (LCG local) au milieu.
    srand(42);
    my @a = map { int(rand 1000) } 1 .. 3;
    _picks(12345, 8);                      # tirages horoscope — ne doivent rien changer
    my @b = map { int(rand 1000) } 1 .. 3;

    $assert->is("@a @b", "@ref",
        'le LCG local ne perturbe pas la séquence rand() globale');

    # --- 3. Câblage réel ---------------------------------------------------
    my $src = _slurp_659(File::Spec->catfile('.', 'Mediabot', 'UserCommands.pm'));
    my ($body) = $src =~ /(sub mbHoroscope_ctx \{.*?\n\}\n)/s; $body //= '';
    (my $code = $body) =~ s/^\s*#.*$//mg;

    $assert->unlike($code, qr/srand\(/, 'plus aucun appel srand() dans horoscope');
    $assert->unlike($code, qr/int\(rand\s/, 'plus de rand() global dans horoscope');
    $assert->like($code, qr/my \$next = sub \{ \$rng = \(\(\$rng \* 1103515245\)/,
        'LCG local présent');
    $assert->like($code, qr/my \$pick = sub \{/, 'sélecteur local présent');
    $assert->like($code, qr/\$chance   = 35 \+ \(\$next->\(\) % 60\)/, 'chance via LCG local');

    $assert->like($src, qr/mb444-B1/, 'tag mb444-B1');
};
