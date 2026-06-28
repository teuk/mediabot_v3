# t/cases/564_mb345_claude_history_user_first.t
# =============================================================================
# mb345 — L'historique de conversation !ai doit toujours commencer par role=user.
#
# L'API Anthropic exige que le 1er message de `messages` soit role=user (et
# l'alternance user/assistant). claudeAI() tronquait l'historique par l'avant
# avec `splice @$history, 0, @$history - $max_history`. Comme max_history est
# forcé pair et que le push du message user rend la longueur impaire, le
# débordement retiré était impair : la troncature enlevait le 'user' de tête et
# laissait l'historique COMMENÇANT par 'assistant' -> l'appel suivant renvoyait
# HTTP 400 et !ai cassait après ~4 échanges (jusqu'au reset persona).
#
# mb345 ajoute, après la troncature :
#     shift @$history while @$history && ($history->[0]{role} // '') ne 'user';
#
# Ce test :
#   1. reproduit le cycle push-user / trim / push-assistant et vérifie que, sur
#      de nombreux échanges, l'historique reste user-first ET alterné ;
#   2. prouve que SANS le garde-fou le bug se produit (témoin) ;
#   3. scan de source : claudeAI porte bien le garde-fou.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

# Simule N échanges. $guard = applique le correctif mb345.
# Retourne (broken, $trace) où broken=1 si un appel partirait avec un non-user
# en tête ou une alternance cassée.
sub _simulate {
    my ($max_history, $exchanges, $guard) = @_;
    my @h;
    my $broken = 0;
    for my $ex (1 .. $exchanges) {
        push @h, { role => 'user' };
        splice @h, 0, (@h - $max_history) if @h > $max_history;
        if ($guard) {
            shift @h while @h && ($h[0]{role} // '') ne 'user';
        }
        # état "envoyé à l'API"
        my $first_ok = (@h && $h[0]{role} eq 'user') ? 1 : 0;
        my $alt = 1;
        for my $i (1 .. $#h) { $alt = 0 if $h[$i]{role} eq $h[$i-1]{role}; }
        $broken = 1 unless $first_ok && $alt;
        push @h, { role => 'assistant' };
        splice @h, 0, (@h - $max_history) if @h > $max_history;
    }
    return $broken;
}

sub _slurp_564 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    # --- 1. Témoin : SANS le garde-fou, le bug se produit ----------------
    $assert->is(_simulate(6, 8, 0), 1,
        'sans le garde-fou : historique non user-first (bug reproduit)');

    # --- 2. AVEC le garde-fou : jamais cassé, plusieurs max_history -------
    for my $mh (2, 4, 6, 8, 10) {
        $assert->is(_simulate($mh, 30, 1), 0,
            "avec garde-fou (max_history=$mh, 30 échanges) : toujours user-first + alterné");
    }

    # --- 3. Scan de source ------------------------------------------------
    my $src = _slurp_564(File::Spec->catfile('.', 'Mediabot', 'External', 'Claude.pm'));
    my ($claude) = $src =~ /(sub claudeAI \{.*?\n\}\n)/s;
    $claude //= '';
    $assert->ok($claude ne '', 'sub claudeAI extraite');
    $assert->like($claude,
        qr/shift\s+\@\$history\s+while\s+\@\$history\s+&&\s+\(\$history->\[0\]\{role\}\s*\/\/\s*''\)\s*ne\s*'user'/,
        'garde-fou user-first présent dans claudeAI');
    $assert->like($claude, qr/mb345-B1/, 'tag mb345-B1 présent');
};
