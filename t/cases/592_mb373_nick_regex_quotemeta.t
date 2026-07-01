# t/cases/592_mb373_nick_regex_quotemeta.t
# =============================================================================
# mb373 — La détection de mention du pseudo ne doit plus traiter le pseudo
# comme une regex.
#
# Dans mediabot.pl (branche Hailo « on me mentionne »), le pseudo courant servait
# de motif regex NON échappé :
#     elsif ($what =~ /$sCurrentNick/i) { ... $what =~ s/$sCurrentNick//g; ... }
# Or un pseudo IRC peut contenir des métacaractères ( [ ] \ ` ^ { } | ) :
#   - "bot|x"   => /bot|x/  matche "x" N'IMPORTE OÙ (faux positifs) ;
#   - "Med[bot" => /Med[bot/ est une regex INVALIDE => die dans le handler.
# mb373 échappe le pseudo (\Q..\E) pour un match LITTÉRAL (détection ET retrait),
# et aligne le retrait sur la casse-insensibilité de la détection (/gi).
#
# Validation : (a) sémantique du match littéral, (b) scan de source.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

# match littéral (nouveau comportement).
sub _match_literal { my ($nick, $msg) = @_; return ($msg =~ /\Q$nick\E/i) ? 1 : 0; }

sub _slurp_592 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    # --- 1. Pseudo normal : comportement inchangé ------------------------
    $assert->is(_match_literal('Mediabot', 'salut Mediabot ça va ?'), 1, 'pseudo normal détecté');
    $assert->is(_match_literal('Mediabot', 'un message sans mention'), 0, 'pas de mention -> non détecté');
    $assert->is(_match_literal('Mediabot', 'MEDIABOT en majuscules'),  1, 'insensible à la casse');

    # --- 2. Pseudo avec métacaractères : plus de faux positif ------------
    # "bot|x" ne doit PAS matcher un message contenant juste "x".
    $assert->is(_match_literal('bot|x', 'hello x there'),  0, 'alternation neutralisée (pas de match sur "x")');
    $assert->is(_match_literal('bot|x', 'coucou bot|x !'), 1, 'match littéral du pseudo "bot|x"');

    # --- 3. Pseudo à regex invalide : plus de crash ----------------------
    my $ok = eval { _match_literal('Med[bot', 'un message'); 1 };
    $assert->ok($ok, 'pseudo "Med[bot" ne fait plus planter la regex');
    $assert->is(_match_literal('Med[bot', 'yo Med[bot'), 1, 'match littéral du pseudo "Med[bot"');

    # --- 4. Retrait littéral du pseudo -----------------------------------
    my $strip = sub { my ($nick, $msg) = @_; $msg =~ s/\Q$nick\E//gi; return $msg; };
    is_like($assert, $strip->('bot|x', 'bot|x salut'), qr/^\s*salut$/, 'retrait littéral de "bot|x"');

    # --- 5. Scan de source : les deux usages échappent le pseudo ---------
    my $main = _slurp_592(File::Spec->catfile('.', 'mediabot.pl'));
    $assert->like($main, qr/\$what =~ \/\\Q\$sCurrentNick\\E\/i/,
                  'détection: match littéral \Q$sCurrentNick\E');
    $assert->like($main, qr/\$what =~ s\/\\Q\$sCurrentNick\\E\/\/gi/,
                  'retrait: s/\Q$sCurrentNick\E//gi');
    # plus aucun usage NON échappé du pseudo comme motif.
    $assert->unlike($main, qr/=~ \/\$sCurrentNick\/i/,   'plus de détection non échappée');
    $assert->unlike($main, qr/s\/\$sCurrentNick\/\/g/,   'plus de retrait non échappé');
    $assert->like($main, qr/mb373-B1/, 'tag mb373-B1 présent');
};

# petit helper local (le harness custom n'a pas de like sur valeur calculée + regex
# distincte, mais $assert->like existe ; on l'utilise directement).
sub is_like {
    my ($assert, $got, $re, $name) = @_;
    $assert->like($got, $re, $name);
}
