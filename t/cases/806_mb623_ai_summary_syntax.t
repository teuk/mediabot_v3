# t/cases/806_mb623_ai_summary_syntax.t
# =============================================================================
# mb623 — 'ai summary' : syntaxe claire, fautes annoncees, periode reellement
# couverte.
#
# TROIS DEFAUTS DE TERRAIN (rapportes par teuk) :
#   1. une faute de frappe ne disait RIEN : « ai summary todya » survivait au
#      filtre d'options et devenait le filtre PSEUDO, d'ou un « aucun message
#      trouve » qui ressemblait a un canal vide ;
#   2. « ai summary today » n'etait pas la journee mais « ORDER BY id DESC
#      LIMIT 200 » — les 200 DERNIERS messages, en silence ;
#   3. l'ordre des mots etait fige : la periode devait etre en 1re position.
#
#   [1] parseur pur : chaque jeton classe, ordre libre, options combinables.
#   [2] fautes de frappe : quasi-mot-cle detecte et SUGGERE ; les vrais
#       pseudos ne sont jamais requalifies en erreur.
#   [3] jetons vraiment inconnus et doublons -> refus explicite.
#   [4] periode : couverture large + echantillon REPARTI (debut, milieu, fin)
#       plutot que la seule fin, et verite dite sur ce qui a ete lu.
#   [5] <N>h : la fenetre en heures, qui manquait.
#   [6] syntaxe canonique unique, lue par l'aide ET par les erreurs.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }

return sub {
    my ($assert) = @_;

    require Mediabot::External::Claude;
    my $C = 'Mediabot::External::Claude';
    my $P = $C->can('_summary_parse');
    $assert->ok($P, 'mb623-806: le parseur est une fonction pure exposee');

    # [1] ordre libre et combinaisons
    my %shapes = (
        'today'            => { period => 'today' },
        'today teuk'       => { period => 'today', nick => 'teuk' },
        'teuk today'       => { period => 'today', nick => 'teuk' },
        'teuk 7d'          => { period => 'days',  nick => 'teuk' },
        '6h public'        => { period => 'hours', public => 1 },
        'week 3l fr'       => { period => 'week',  lines => 3, lang => 'fr' },
        'public today fr'  => { period => 'today', public => 1, lang => 'fr' },
    );
    my $ok = 0;
    for my $line (sort keys %shapes) {
        my $o = $P->(split / /, $line);
        my $want = $shapes{$line};
        my $good = 1;
        for my $k (keys %$want) {
            $good = 0 unless defined $o->{$k} && $o->{$k} eq $want->{$k};
        }
        $good = 0 if @{ $o->{unknown} } || @{ $o->{typos} } || @{ $o->{duplicate} };
        $ok++ if $good;
    }
    $assert->is($ok, scalar(keys %shapes),
        'mb623-806: chaque forme est lue correctement, dans n importe quel ordre');
    my $o = $P->(qw(teuk 7d));
    $assert->is($o->{period_arg}, 7, 'mb623-806: <N>d garde son nombre');
    $o = $P->(qw(20));
    $assert->is($o->{count}, 20, 'mb623-806: un nombre nu reste un nombre de messages');

    # [2] fautes de frappe
    my %typos = (todya => 'today', yesteday => 'yesterday', wek => 'week',
                 lat => 'last', publi => 'public');
    my $caught = 0;
    for my $bad (sort keys %typos) {
        my $p = $P->($bad);
        $caught++ if @{ $p->{typos} } == 1
                  && $p->{typos}[0][0] eq $bad
                  && $p->{typos}[0][1] eq $typos{$bad}
                  && !defined $p->{nick};
    }
    $assert->is($caught, scalar(keys %typos),
        'mb623-806: chaque quasi-mot-cle est detecte et le bon mot suggere');
    my $false = 0;
    for my $real (qw(teuk SaYa sky poyan bob mediabot Te[u]K aur)) {
        my $p = $P->($real);
        $false++ if @{ $p->{typos} } || !defined $p->{nick};
    }
    $assert->is($false, 0,
        'mb623-806: aucun vrai pseudo requalifie en faute de frappe');
    $o = $P->('nick=todya');
    $assert->ok(!@{ $o->{typos} } && ($o->{nick_opt} // '') eq 'todya',
        'mb623-806: nick= reste l echappatoire si c est vraiment un pseudo');

    # [3] inconnus et doublons
    $o = $P->('@@@');
    $assert->is(scalar @{ $o->{unknown} }, 1, 'mb623-806: jeton illisible refuse');
    $o = $P->(qw(today yesterday));
    $assert->is(scalar @{ $o->{duplicate} }, 1, 'mb623-806: deux periodes = doublon');
    $o = $P->(qw(today teuk saya));
    $assert->is(scalar @{ $o->{duplicate} }, 1, 'mb623-806: deux pseudos = doublon');
    $o = $P->(qw(today));
    $assert->ok(!@{ $o->{unknown} } && !@{ $o->{duplicate} } && !@{ $o->{typos} },
        'mb623-806: une ligne correcte ne produit aucun grief');

    # [4] echantillon REPARTI
    my $spread = $C->can('_summary_spread');
    $assert->ok($spread, 'mb623-806: l echantillonnage est expose');
    my @rows = map { "msg$_" } 1 .. 1000;
    my $kept = $spread->(\@rows, 100);
    $assert->is(scalar @$kept, 100, 'mb623-806: la taille demandee est respectee');
    $assert->is($kept->[0], 'msg1',
        'mb623-806: le DEBUT de la periode est represente (le bug: il ne l etait pas)');
    $assert->is($kept->[-1], 'msg1000', 'mb623-806: la fin aussi');
    my ($mid) = grep { $kept->[$_] eq 'msg500' } 0 .. $#$kept;
    $assert->ok(defined $mid || (grep { /^msg4\d\d$|^msg5\d\d$/ } @$kept),
        'mb623-806: ... et le milieu');
    my $tail_dense = grep { /^msg9\d\d$/ } @$kept;
    $assert->ok($tail_dense >= 30,
        'mb623-806: la fin reste plus dense (c est ce dont on parle encore)');
    $assert->is(scalar @{ $spread->([ map { "m$_" } 1 .. 50 ], 100) }, 50,
        'mb623-806: sous le seuil, rien n est retire');
    my %seen; $seen{$_}++ for @$kept;
    $assert->is(scalar(grep { $seen{$_} > 1 } keys %seen), 0,
        'mb623-806: aucun message compte deux fois');

    # ordre chronologique conserve
    my @nums = map { /(\d+)/ ? $1 : 0 } @$kept;
    my $sorted = 1;
    for my $i (1 .. $#nums) { $sorted = 0 if $nums[$i] < $nums[$i-1] }
    $assert->is($sorted, 1, 'mb623-806: l ordre chronologique est conserve');

    my $src = do { open my $fh, '<:encoding(UTF-8)', 'Mediabot/External/Claude.pm'
        or die $!; local $/; <$fh> };
    $assert->like($src, qr/\$n_msgs = \$CLAUDE_SUMMARY_FETCH_CAP if \$date_filter;/,
        'mb623-806: avec une periode, la lecture n est plus plafonnee a 200');
    $assert->ok(CLAUDE_SUMMARY_FETCH_CAP_ok(), 'mb623-806: plafond de lecture large');
    $assert->like($src, qr/sampled\s+=>/,
        'mb623-806: un message de service annonce l echantillonnage');
    my $S = $C->can('_summary_lang_strings');
    my $langs = 0;
    for my $l (qw(en fr es)) {
        $langs++ if defined $S->($l)->{sampled} && length $S->($l)->{sampled};
    }
    $assert->is($langs, 3, 'mb623-806: ... dans les trois langues');

    # [5] fenetre en heures
    $o = $P->('6h');
    $assert->ok(($o->{period} // '') eq 'hours' && $o->{period_arg} == 6,
        'mb623-806: <N>h est reconnu');
    $assert->like($src, qr/INTERVAL \$hours HOUR/,
        'mb623-806: ... et se traduit en fenetre SQL');

    # [6] syntaxe canonique unique
    my @usage = $C->can('_summary_usage')->();
    $assert->ok(scalar @usage >= 4, 'mb623-806: la syntaxe est documentee');
    $assert->like($usage[0], qr/l'ordre est libre/,
        'mb623-806: l aide annonce l ordre libre');
    $assert->ok((grep { /<N>h/ } @usage), 'mb623-806: la fenetre en heures est documentee');
    $assert->like($src, qr/botNotice\(\$self, \$nick, \$_summary_usage_lines\[0\]\);/,
        'mb623-806: les erreurs rappellent LA MEME ligne de syntaxe');
};

sub _CLAUDE_SUMMARY_FETCH_CAP_ok { 1 }
sub CLAUDE_SUMMARY_FETCH_CAP_ok {
    return $Mediabot::External::Claude::CLAUDE_SUMMARY_FETCH_CAP >= 1000 ? 1 : 0;
}
