# t/cases/623_mb405_url_extract_balanced_parens.t
# =============================================================================
# mb405 — _extract_url ne coupe plus la parenthèse finale des URLs Wikipédia.
#
# L'ancien strip retirait aveuglément ')' et ']' finaux avec la ponctuation :
# "https://fr.wikipedia.org/wiki/Talos_(mythologie)" collé sur un canal
# devenait ".../Talos_(mythologie" -> mauvaise page / 404. mb405 : la
# ponctuation pure est toujours retirée, mais une fermante finale n'est
# consommée que si elle est EN EXCÈS par rapport aux ouvrantes de l'URL.
#
# Le test extrait la sub réelle et l'exécute.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_623 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

return sub {
    my ($assert) = @_;

    my $src = _slurp_623(File::Spec->catfile('.', 'Mediabot', 'External', 'URL.pm'));
    my ($body) = $src =~ /(sub _extract_url \{.*?\n\}\n)/s;
    $assert->ok(defined $body && $body ne '', '_extract_url extraite');

    my $fn;
    { no strict; no warnings;
      $fn = eval "package T623; $body; \\&T623::_extract_url"; }
    $assert->ok(ref($fn) eq 'CODE', 'compilée en isolation');

    my @cases = (
        # [ message IRC, URL attendue ]
        [ 'regarde https://fr.wikipedia.org/wiki/Talos_(mythologie)',
          'https://fr.wikipedia.org/wiki/Talos_(mythologie)',
          'paren Wikipédia préservée' ],
        [ '(voir https://example.org/foo).',
          'https://example.org/foo',
          'paren de phrase retirée' ],
        [ 'https://example.org/foo,', 'https://example.org/foo', 'virgule retirée' ],
        [ 'lien https://example.org/bar]', 'https://example.org/bar', 'crochet non apparié retiré' ],
        [ 'https://en.wikipedia.org/wiki/AS/400_(disambiguation), non ?',
          'https://en.wikipedia.org/wiki/AS/400_(disambiguation)',
          'paren + virgule : paren gardée, virgule retirée' ],
        [ '(https://fr.wikipedia.org/wiki/Talos_(mythologie))',
          'https://fr.wikipedia.org/wiki/Talos_(mythologie)',
          'double wrap : seule la fermante en excès tombe' ],
        [ 'https://example.org/x?a=(1)', 'https://example.org/x?a=(1)', 'paren en query gardée' ],
        [ 'fin https://example.org/plain.', 'https://example.org/plain', 'point final retiré' ],
    );
    for my $c (@cases) {
        my ($msg, $want, $name) = @$c;
        $assert->is($fn->($msg), $want, $name);
    }

    $assert->like($src, qr/mb405-B1/, 'tag mb405-B1');
};
