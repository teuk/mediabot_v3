# t/cases/797_mb614_accented_command_folding.t
# =============================================================================
# mb614 — une commande accentuee doit atteindre sa table.
#
# INCIDENT (prod #test, 2026-08-08) : « m actualités » ne declenchait
# RIEN. Ce fichier a « use utf8 », donc la cle litterale 'actualités' est une
# chaine de CARACTERES (é = U+00E9) alors qu'IRC livre des OCTETS utf-8
# ("actualit\xC3\xA9s") : aucune correspondance, chute silencieuse dans le
# chemin des commandes inconnues (visible dans le log sous la forme mojibake
# « actualitÃ©s »).
#
#   [1] _fold_command_name rend une cle ASCII minuscule depuis n'importe
#       quelle forme : ASCII, majuscules, OCTETS utf-8, caracteres decodes,
#       latin-1 ; l'ASCII pur ressort inchange.
#   [2] les 5 formes demandees (actualités, actualité, actualites,
#       actualite, news) tombent sur une cle REELLEMENT presente au dispatch.
#   [3] le repliement est branche AVANT toute recherche, en public ET en
#       prive.
#   [4] aucune cle non-ASCII ne subsiste dans la table (elles ne pourraient
#       jamais matcher) et chaque alias a son entree d'aide.
#   [5] robustesse : undef, chaine vide, reference, accents d'autres langues.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }

return sub {
    my ($assert) = @_;

    require Mediabot::Mediabot;
    my $fold = \&Mediabot::_fold_command_name;

    # [1] toutes les formes d'entree
    $assert->is($fold->('actualites'), 'actualites', 'mb614-797: ascii inchange');
    $assert->is($fold->('ACTUALITES'), 'actualites', 'mb614-797: majuscules repliees');
    $assert->is($fold->("actualit\xc3\xa9s"), 'actualites',
        'mb614-797: OCTETS utf-8 — la forme reellement recue d IRC');
    $assert->is($fold->("actualit\xc3\xa9"), 'actualite',
        'mb614-797: octets utf-8, singulier');
    $assert->is($fold->("actualit\xe9s"), 'actualites',
        'mb614-797: latin-1 replie aussi');
    $assert->is($fold->("\x{e9}v\x{e8}nement"), 'evenement',
        'mb614-797: chaine de caracteres deja decodee');
    $assert->is($fold->("ni\x{f1}o"), 'nino', 'mb614-797: n tilde');
    $assert->is($fold->("\x{fc}ber"), 'uber', 'mb614-797: trema allemand');

    # [2] les 5 formes demandees atteignent une cle du dispatch
    my $src = do { open my $fh, '<:encoding(UTF-8)', 'Mediabot/Mediabot.pm'
        or die $!; local $/; <$fh> };
    my ($table) = $src =~ /my %command_map = \((.*?)\n    \);/s;
    $assert->ok(defined $table, 'mb614-797: table publique localisee');
    my %keys = map { $_ => 1 } ($table =~ /^\s{8}'?([a-z_]+)'?\s*=>/mg);
    my $reachable = 0;
    for my $typed ("actualit\xc3\xa9s", "actualit\xc3\xa9", 'actualites', 'actualite', 'news') {
        $reachable++ if $keys{ $fold->($typed) };
    }
    $assert->is($reachable, 5,
        'mb614-797: les 5 formes demandees tombent sur une cle presente');
    $assert->ok($keys{actu}, 'mb614-797: la forme courte reste servie');

    # [3] branchement avant toute recherche
    $assert->like($src, qr/my \$cmd = _fold_command_name\(\$sCommand\);/,
        'mb614-797: le repliement precede la recherche publique');
    $assert->like($src, qr/\$command_table\{ _fold_command_name\(\$sCommand\) \}/,
        'mb614-797: ... et la recherche privee');
    my $fold_pos = index($src, 'my $cmd = _fold_command_name');
    my $look_pos = index($src, '$command_map{$cmd}');
    $assert->ok($fold_pos > 0 && $look_pos > $fold_pos,
        'mb614-797: l ordre est bien repliement puis lecture de la table');

    # [4] plus aucune cle non-ASCII : elle ne pourrait jamais matcher
    $assert->ok($table !~ /'[^']*[^\x00-\x7F][^']*'\s*=>/,
        'mb614-797: aucune cle accentuee ne subsiste au dispatch');
    my ($help) = $src =~ /(actualites\|.*?news\|[^\n]*)/s;
    my $documented = 0;
    for my $alias (qw(actualites actualite actu news)) {
        $documented++ if defined $help && $help =~ /^\Q$alias\E\|/m;
    }
    $assert->is($documented, 4, 'mb614-797: chaque alias a son entree d aide');

    # [5] robustesse
    $assert->is($fold->(undef), '', 'mb614-797: undef -> chaine vide');
    $assert->is($fold->(''), '', 'mb614-797: vide -> vide');
    $assert->is($fold->([ 'x' ]), '', 'mb614-797: reference refusee');
    # Des octets qui ne sont pas de l'utf-8 valide sont relus en latin-1 puis
    # replies : le resultat n'a pas de sens comme commande, mais la fonction
    # rend une valeur et ne meurt pas — c'est tout ce qu'on lui demande sur
    # une entree hostile.
    my $garbage = eval { $fold->("\xff\xfe") };
    $assert->ok(!$@ && defined $garbage,
        'mb614-797: octets indecodables — pas de mort, une valeur rendue');
    $assert->ok(!$keys{ $garbage },
        'mb614-797: ... et ils n atteignent aucune commande');
};
