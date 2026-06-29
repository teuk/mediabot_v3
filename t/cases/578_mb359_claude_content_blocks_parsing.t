# t/cases/578_mb359_claude_content_blocks_parsing.t
# =============================================================================
# mb359 — Lecture robuste de la réponse Anthropic (tableau content[]).
#
# _claude_send_and_parse ne lisait que content[0] et exigeait
# content[0]{type} eq 'text'. Or l'API Anthropic peut renvoyer plusieurs blocs
# et placer un bloc NON-text en tête (p.ex. 'thinking' si le raisonnement étendu
# est actif, ou 'tool_use') : l'ancien code répondait alors "Could not read
# Claude response" à tort, alors qu'un bloc texte existait plus loin.
#
# mb359 parcourt TOUS les blocs et concatène ceux de type 'text'.
#
# Validation : (a) sémantique de l'extraction, (b) scan de source.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

# Reproduction fidèle de l'extraction mb359.
sub _extract {
    my ($data) = @_;
    return undef unless ref($data) eq 'HASH' && ref($data->{content}) eq 'ARRAY';
    my @texts;
    for my $blk (@{ $data->{content} }) {
        next unless ref($blk) eq 'HASH'
                 && (($blk->{type} // '') eq 'text')
                 && defined $blk->{text};
        push @texts, $blk->{text};
    }
    my $joined = join('', @texts);
    return length($joined) > 0 ? $joined : undef;
}

sub _slurp_578 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    # --- 1. Sémantique ----------------------------------------------------
    $assert->is(_extract({ content => [ { type => 'text', text => 'hello' } ] }),
                'hello', 'bloc texte seul');

    # Cas qui ÉCHOUAIT avant mb359 : bloc 'thinking' en tête, texte ensuite.
    $assert->is(_extract({ content => [
                    { type => 'thinking', thinking => 'hmm' },
                    { type => 'text',     text     => 'the answer' },
                ] }),
                'the answer', 'thinking en tête + texte -> on trouve le texte');

    # tool_use en tête, texte ensuite.
    $assert->is(_extract({ content => [
                    { type => 'tool_use', id => 'x' },
                    { type => 'text',     text => 'done' },
                ] }),
                'done', 'tool_use en tête + texte');

    # Plusieurs blocs texte -> concaténation.
    $assert->is(_extract({ content => [
                    { type => 'text', text => 'foo' },
                    { type => 'text', text => 'bar' },
                ] }),
                'foobar', 'multi-blocs texte concaténés');

    # Aucun bloc texte -> undef (le code appelant affichera l'erreur).
    $assert->ok(!defined _extract({ content => [ { type => 'thinking', thinking => 'x' } ] }),
                'aucun bloc texte -> undef');
    # content vide / absent / non-hash -> undef (défensif).
    $assert->ok(!defined _extract({ content => [] }),        'content vide -> undef');
    $assert->ok(!defined _extract({ foo => 1 }),             'pas de content -> undef');
    $assert->ok(!defined _extract('not a hash'),             'donnée non-HASH -> undef');
    # bloc texte vide ignoré.
    $assert->ok(!defined _extract({ content => [ { type => 'text', text => '' } ] }),
                'texte vide -> undef');

    # --- 2. Scan source ---------------------------------------------------
    my $src = _slurp_578(File::Spec->catfile('.', 'Mediabot', 'External', 'Claude.pm'));
    my ($fn) = $src =~ /(sub _claude_send_and_parse \{.*?\n\}\n)/s; $fn //= '';
    $assert->ok($fn ne '', 'sub _claude_send_and_parse extraite');

    # On itère sur les blocs (boucle) plutôt que de lire seulement content[0].
    $assert->like($fn, qr/for my \$blk \(\@\{ \$data->\{content\} \}\)/,
                  'itère sur tous les blocs de content');
    $assert->like($fn, qr/\(\$blk->\{type\} \/\/ ''\) eq 'text'/,
                  'sélectionne les blocs type text');
    # L'ancien motif "content[0]{type} eq 'text'" comme seule condition a disparu.
    (my $fn_code = $fn) =~ s/^\s*#.*$//mg;
    $assert->unlike($fn_code, qr/\$data->\{content\}\[0\]\{type\}\s*eq\s*'text'/,
                    'ne dépend plus uniquement de content[0]');
    $assert->like($src, qr/mb359-B1/, 'tag mb359-B1 présent');
};
