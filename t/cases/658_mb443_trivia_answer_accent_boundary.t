# t/cases/658_mb443_trivia_answer_accent_boundary.t
# =============================================================================
# mb443 — Les frontières de mot du matching de réponse trivia sont byte-safe.
#
# publictext et réponses arrivent en OCTETS UTF-8. Les frontières ASCII seules
# [A-Za-z0-9] traitaient un octet d'accent (>= 0x80) comme un séparateur : une
# réponse courte comme "on" était validée à tort par "garçon" (l'octet 0xA7 de
# ç avant "on" passait pour une frontière). mb443 inclut \x80-\xFF dans les
# classes de frontière : "garçon" ne valide plus "on", mais "... is on" / "on!"
# restent valides.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_658 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

return sub {
    my ($assert) = @_;

    my $matched = sub {
        my ($text, $answer) = @_;
        $answer = lc $answer;
        return ( lc($text) eq $answer
            || lc($text) =~ /(?<![A-Za-z0-9\x80-\xFF])\Q$answer\E(?![A-Za-z0-9\x80-\xFF])/ ) ? 1 : 0;
    };

    # ç = C3 A7, é = C3 A9 (octets UTF-8 explicites)
    my $garcon = "gar" . chr(0xC3) . chr(0xA7) . "on";
    my $beton  = "b" . chr(0xC3) . chr(0xA9) . "ton";   # béton

    $assert->is($matched->($garcon, 'on'),          0, 'garçon ne valide plus "on" (faux positif corrigé)');
    $assert->is($matched->('the answer is on', 'on'),1, '"on" délimité par espaces -> valide');
    $assert->is($matched->('on!', 'on'),             1, '"on!" -> valide');
    $assert->is($matched->('onze', 'on'),            0, '"onze" -> rejet (in-word)');
    $assert->is($matched->($beton, 'ton'),           0, 'béton ne valide pas "ton" (t alnum avant)');

    # Réponse accentuée exacte / bornée
    my $cafe = "caf" . chr(0xC3) . chr(0xA9);
    $assert->is($matched->("un $cafe.", $cafe),      1, '"café" délimité -> valide');
    $assert->is($matched->("${cafe}s", $cafe),       0, '"cafés" -> rejet (s après)');

    # --- Câblage réel ------------------------------------------------------
    my $src = _slurp_658(File::Spec->catfile('.', 'Mediabot', 'UserCommands.pm'));
    $assert->like($src,
        qr/\(\?<!\[A-Za-z0-9\\x80-\\xFF\]\)\\Q\$answer\\E\(\?!\[A-Za-z0-9\\x80-\\xFF\]\)/,
        'checkTrivia utilise des frontières byte-safe');
    $assert->like($src, qr/mb443-B1/, 'tag mb443-B1');
};
