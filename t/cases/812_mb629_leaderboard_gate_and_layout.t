# t/cases/812_mb629_leaderboard_gate_and_layout.t
# =============================================================================
# mb629 — le palmares passe Administrateur, et cesse d'etre un mur.
#
# DEMANDE teuk : « m lb, je pense qu'il faut pas laisser ca aux utilisateurs de
# niveau User, et mettre ca a Administrator+ ; ameliore la fonction en general,
# il faut pas que ce soit trop lourd comme bloc pour les ames sensibles, mais
# fais aussi en sorte que ce soit colore et sympa. Pareil pour m dashboard mais
# pas de regression, c'est pas mal tel que c'est. »
#
#   [1] la porte Administrateur est posee AVANT le fork (un refus ne coute
#       pas un worker) et sur les DEUX alias.
#   [2] mise en page compacte par defaut : les categories sont groupees par
#       ligne au lieu d'une ligne chacune ; 'full' rend l'ancienne forme.
#   [3] le compactage compte les OCTETS (emoji = 4 octets pour une case) et
#       tient sous la limite IRC — une ligne coupee casserait une couleur.
#   [4] couleurs : une par categorie, aucune illisible (ni blanc, ni noir),
#       chaque sequence est REFERMEE.
#   [5] separateur : le caractere litteral, pas la sequence \x{...} qui
#       s'imprimerait telle quelle entre apostrophes.
#   [6] dashboard : couleurs ajoutees, contenu STRICTEMENT inchange (mots,
#       ordre, valeurs) — c'est la demande explicite.
# =============================================================================

use strict;
use warnings;
use utf8;   # meme monde de chaines que le module teste
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }

return sub {
    my ($assert) = @_;

    require Mediabot::UserCommands;
    my $src = do { open my $fh, '<:encoding(UTF-8)', 'Mediabot/SocialHistory.pm'
        or die $!; local $/; <$fh> };
    my $disp = do { open my $fh, '<:encoding(UTF-8)', 'Mediabot/Mediabot.pm'
        or die $!; local $/; <$fh> };

    # [1] la porte
    my $gated = () = $disp =~ /require_level\('Administrator'\)\s*\n\s*&& Mediabot::CommandAsync::run_ctx_async\(\$ctx->bot, \$ctx, 'leaderboard'/g;
    $assert->is($gated, 2,
        'mb629-812: les DEUX alias (leaderboard, lb) sont gardes');
    my ($lb_line) = $disp =~ /^(lb\|lb [^\n]*)$/m;
    $assert->like($lb_line, qr/Administrator\+/,
        'mb629-812: l aide annonce le niveau requis');
    my ($lead_line) = $disp =~ /^(leaderboard\|leaderboard [^\n]*)$/m;
    $assert->like($lead_line, qr/Administrator\+/,
        'mb629-812: ... sur les deux entrees d aide');
    # la porte precede le fork : le && garantit que run_ctx_async n est pas
    # atteint quand require_level rend faux.
    $assert->ok($disp !~ /run_ctx_async\([^\n]*'leaderboard'[^\n]*\)\s*\n\s*&&\s*\$ctx->require_level/,
        'mb629-812: la porte est AVANT le worker, jamais apres');

    # [2] compact par defaut, full sur demande
    $assert->like($src, qr/if \(\$a eq 'full' \|\| \$a eq 'long'\)\s*\{ \$full_out = 1/,
        'mb629-812: le mot-cle full est reconnu');
    $assert->like($src, qr/if \(\$a eq 'compact' \|\| \$a eq 'short'\)\s*\{ \$full_out = 0/,
        'mb629-812: ... et compact aussi, pour revenir au defaut');
    $assert->like($src, qr/my \$full_out = 0;/,
        'mb629-812: le DEFAUT est compact');
    $assert->like($src, qr/if \(\$full_out\) \{[^}]*botPrivmsg\(\$self, \$channel, '  ' \. \$_->\[1\]\) for \@segments;/s,
        'mb629-812: full rend une ligne par categorie (forme historique)');

    # [3] compactage en OCTETS
    my $B = Mediabot::UserCommands->can('_irc_bytes');
    $assert->ok($B, 'mb629-812: la mesure en octets est exposee');
    $assert->is($B->('abc'), 3, 'mb629-812: ASCII = 1 octet par caractere');
    $assert->is($B->("\x{1F3C6}"), 4, 'mb629-812: un emoji pese 4 octets');
    $assert->is($B->("\x{B7}"), 2, 'mb629-812: le point median en pese 2');
    $assert->is($B->(undef), 0, 'mb629-812: undef ne meurt pas');
    $assert->like($src, qr/my \$budget = 190;/,
        'mb629-812: le budget par ligne est borne');
    $assert->like($src, qr/_irc_bytes\(\$cur \. \$sep \. \$piece\) > \$budget/,
        'mb629-812: c est bien la taille OCTETS qui decide du passage a la ligne');

    # simulation du compactage sur cinq categories realistes
    {
        my @segs = (
            "\x0311\x{1F4AC} msgs\x0f \x{1F947} \x02SlaY\x02 12k · aur 9.0k · bob 5.1k",
            "\x0308\x{1F31F} karma\x0f \x{1F947} \x02teuk\x02 41 · SaYa 33 · sky 12",
            "\x0313\x{1F9E0} trivia\x0f \x{1F947} \x02aur\x02 137 · SlaY 88 · bob 40",
            "\x0304\x{2694}\x{FE0F} duels\x0f \x{1F947} \x02bob\x02 12 · teuk 9 · aur 4",
            "\x0309\x{1F3C6} achievs\x0f \x{1F947} \x02SlaY\x02 7 · aur 5 · teuk 3",
        );
        my ($budget, @lines, $cur) = (190, (), '');
        for my $piece (@segs) {
            my $sep = $B->($cur) ? '   ' : '  ';
            if ($B->($cur) && $B->($cur . $sep . $piece) > $budget) { push @lines, $cur; $cur = '  ' . $piece }
            else { $cur .= $sep . $piece }
        }
        push @lines, $cur if length $cur;
        $assert->ok(scalar @lines < scalar @segs,
            'mb629-812: cinq categories tiennent sur moins de cinq lignes');
        $assert->ok(scalar @lines >= 2,
            'mb629-812: ... sans tout entasser sur une seule ligne interminable');
        my $worst = (sort { $b <=> $a } map { $B->($_) } @lines)[0];
        $assert->ok($worst <= 420,
            'mb629-812: aucune ligne ne s approche de la limite du protocole');
        # aucune ligne ne doit finir sur une couleur ouverte
        my $dangling = grep { /\x03\d{2}[^\x0f]*$/ && !/\x0f[^\x03]*$/ } @lines;
        $assert->is($dangling, 0,
            'mb629-812: aucune ligne ne se termine sur une couleur restee ouverte');
    }

    # [4] couleurs sures et refermees
    my ($style_block) = $src =~ /my %cat_style = \((.*?)\);/s;
    $assert->ok(defined $style_block, 'mb629-812: la table des styles existe');
    my @codes = $style_block =~ /"\\x03(\d{2})"/g;
    $assert->is(scalar @codes, 5, 'mb629-812: une couleur par categorie');
    my %forbidden = map { $_ => 1 } qw(00 01);   # blanc et noir : illisibles selon le theme
    $assert->is(scalar(grep { $forbidden{$_} } @codes), 0,
        'mb629-812: ni blanc ni noir — lisible sur fond clair comme sombre');
    my %seen; $seen{$_}++ for @codes;
    $assert->is(scalar(grep { $seen{$_} > 1 } keys %seen), 0,
        'mb629-812: deux categories n ont jamais la meme couleur');
    $assert->like($src, qr/return "\$colour\$emoji \$label\\x0f "/,
        'mb629-812: le libelle referme sa couleur juste apres lui');

    # [5] separateur litteral
    $assert->like($src, qr/join\(' · ', \@parts\)/,
        'mb629-812: le point median est un CARACTERE');
    $assert->ok($src !~ /join\(' \\x\{B7\} ', \@parts\)/,
        'mb629-812: ... et non la sequence qui s imprimerait telle quelle');

    # [6] dashboard : couleur oui, contenu non
    for my $keep (
        [ qr/%s\\x02 msgs from %s nicks/,                        'compte des messages et des nicks' ],
        [ qr/%d active in last 60min/,                      'actifs sur 60 minutes' ],
        [ qr/\\x\{1F451\}[^"]*top:/,                        'ligne du top' ],
        [ qr/7d:\\x0f %s.*?24h:\\x0f %s  peak/,                     'sparklines 7d/24h et le pic' ],
        [ qr/karma 7d:.*?giver: %s.*?receiver: %s/,     'karma 7j, donneur et receveur' ],
        [ qr/achievements unlocked on \$channel: .*?catalogue: %d available/, 'ligne achievements' ],
        [ qr/since \$since_s .*?\$days days .*?avg \$\{msgs_per_day\}\/d/,  'en-tete since/days/avg' ],
    ) {
        $assert->like($src, $keep->[0], "mb629-812: dashboard — $keep->[1] conserve");
    }
    my ($dash) = $src =~ /(# 8\. Affichage.*?achievements unlocked on \$channel[^\n]*\n)/s;
    my @dash_colours = $dash =~ /\\x03(\d{2})/g;
    $assert->ok(scalar @dash_colours >= 6,
        'mb629-812: le dashboard a bien gagne des couleurs');
    $assert->is(scalar(grep { $forbidden{$_} } @dash_colours), 0,
        'mb629-812: ... toutes lisibles selon le theme du client');
};
