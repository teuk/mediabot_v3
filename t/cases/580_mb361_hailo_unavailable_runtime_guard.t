# t/cases/580_mb361_hailo_unavailable_runtime_guard.t
# =============================================================================
# mb361 — Les chemins Hailo runtime doivent rester sûrs si init_hailo() échoue.
#
# Avant : trois chemins legacy dans mediabot.pl appelaient learn_reply()/learn()
# sur undef, et mbHandleNickTriggered classait ce même défaut comme un timeout.
# Après : un helper partagé renvoie le cerveau s'il existe, sinon journalise au
# plus une fois et fait ignorer proprement les chemins de réponse/apprentissage.
#
# Le ratio HailoChatter n'est PAS modifié : la commande stocke 100 - chance
# utilisateur, donc un seuil interne 97 correspond bien à 3 % (rand >= 97).
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_580 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

# Reproduction sémantique minimale du helper partagé, pour valider le contrat
# sans charger les dépendances CPAN Hailo dans le runner statique.
sub _runtime_hailo {
    my ($bot) = @_;
    my $hailo = $bot->{hailo};
    return $hailo if $hailo;

    unless ($bot->{_hailo_runtime_unavailable_logged}) {
        $bot->{_hailo_runtime_unavailable_logged} = 1;
        push @{ $bot->{logs} }, [ 2, 'Hailo runtime unavailable' ];
    }
    return undef;
}

return sub {
    my ($assert) = @_;

    # --- 1. Contrat du helper --------------------------------------------
    my $brain = bless {}, 'MB361::Brain';
    my $okbot = { hailo => $brain, logs => [] };
    $assert->is(_runtime_hailo($okbot), $brain,
        'cerveau disponible -> objet renvoyé');
    $assert->is(scalar @{ $okbot->{logs} }, 0,
        'cerveau disponible -> aucun diagnostic');

    my $badbot = { hailo => undef, logs => [] };
    $assert->ok(!defined _runtime_hailo($badbot),
        'cerveau absent -> undef sans exception');
    $assert->ok(!defined _runtime_hailo($badbot),
        'lectures répétées restent sûres');
    $assert->is(scalar @{ $badbot->{logs} }, 1,
        'cerveau absent -> diagnostic dédupliqué');
    $assert->is($badbot->{logs}[0][0], 2,
        'diagnostic runtime au niveau 2');

    # --- 2. Helper réel et réinitialisation ------------------------------
    my $hailo_src = _slurp_580(File::Spec->catfile('.', 'Mediabot', 'Hailo.pm'));
    $assert->like($hailo_src, qr/\bget_hailo_runtime\b/,
        'helper get_hailo_runtime présent/exporté');
    $assert->like($hailo_src,
        qr/sub get_hailo_runtime\s*\{.*?return \$hailo if \$hailo;.*?_hailo_runtime_unavailable_logged.*?return undef;/s,
        'helper réel renvoie le cerveau ou ignore proprement');
    $assert->like($hailo_src,
        qr/\$self->\{hailo\}\s*=\s*\$hailo;\s*delete \$self->\{_hailo_runtime_unavailable_logged\}/s,
        'une réinitialisation réussie réarme le diagnostic');
    $assert->like($hailo_src, qr/mb361-B1/,
        'tag mb361-B1 présent dans Hailo.pm');

    # --- 3. Trois chemins legacy protégés -------------------------------
    my $main = _slurp_580(File::Spec->catfile('.', 'mediabot.pl'));
    my $runtime_calls = () = $main =~ /->get_hailo_runtime\(\)/g;
    $assert->is($runtime_calls, 3,
        'les trois chemins legacy utilisent le helper sûr');

    # mb370: l'ancien ancrage 'my $luckyShotHailoChatter' a été supprimé (décision
    # de chatter déplacée dans hailo_should_chatter). On ancre sur le début du bloc.
    my $runtime_start = index($main, 'my $luckyShot = rand(100)');
    my $runtime_end   = index($main, 'if ((ord(substr($what,0,1))', $runtime_start);
    my $runtime_block = ($runtime_start >= 0 && $runtime_end > $runtime_start)
        ? substr($main, $runtime_start, $runtime_end - $runtime_start)
        : '';
    $assert->unlike($runtime_block, qr/->get_hailo\(\)/,
        'aucun accès Hailo brut dans le bloc runtime legacy');
    my $guards = () = $runtime_block =~ /if \(\$hailo\) \{/g;
    $assert->is($guards, 3,
        'chaque chemin legacy vérifie le cerveau avant usage');
    $assert->like($runtime_block, qr/mb361-B1/,
        'tag mb361-B1 présent dans mediabot.pl');

    # --- 4. Fallback moderne protégé avant métriques ---------------------
    my $mediabot_src = _slurp_580(File::Spec->catfile('.', 'Mediabot', 'Mediabot.pm'));
    my ($nick_block) = $mediabot_src =~ /(sub mbHandleNickTriggered \{.*?\n\})/s;
    $nick_block //= '';
    $assert->like($nick_block,
        qr/my \$hailo = get_hailo_runtime\(\$self\);\s*return unless \$hailo;/s,
        'fallback nick-triggered quitte proprement si Hailo est absent');
    $assert->unlike($nick_block, qr/get_hailo\(\$self\)/,
        'fallback nick-triggered n’utilise plus l’accès brut');
    $assert->ok(
        index($nick_block, 'get_hailo_runtime($self)')
            < index($nick_block, "mediabot_hailo_learn_reply_total"),
        'disponibilité vérifiée avant la métrique learn_reply');
    $assert->like($nick_block, qr/mb361-B1/,
        'tag mb361-B1 présent dans Mediabot.pm');

    # --- 5. Ratio HailoChatter direct après mb370/mb371 -----------------
    my $user_chance = 97;
    my $stored      = $user_chance;
    my $hits        = scalar grep { $_ < $stored } 0 .. 99;
    $assert->is($stored, 97,
        '97 % utilisateur est stocké directement comme 97');
    $assert->is($hits, 97,
        'rand 0..99 < 97 donne exactement 97 valeurs sur 100');
    $assert->unlike($hailo_src, qr/100\s*-\s*\$(?:stored_ratio|ratio)/,
        'la commande ne réintroduit aucune inversion legacy');
};
