# t/cases/761_mb572_horoscope_bilingual.t
# =============================================================================
# mb572 — l'horoscope parle la langue du canal (channel_lang, mb563) :
#   [1] PARITE DES POOLS : chaque pool EN a exactement la meme taille que son
#       jumeau FR (un meme tirage LCG tombe sur la meme carte) — garde
#       structurelle par comptage des elements dans la source ;
#   [2] la traduction du signe est un mapping COMPLET des 12 signes et des
#       4 elements, applique a l'affichage seulement (la sub zodiaque reste
#       canonique FR — le test 752 la couvre) ;
#   [3] gardes de gabarit : les deux jeux (FR: Horoscope du/Climat/Conseil/
#       Méfiance/chance ; EN: Horoscope for/Vibe/Advice/Beware/luck) sont
#       presents, la selection vient de channel_lang($self, $channel), et
#       le contrat mb444 (ordre des tirages, LCG local) reste couvert par
#       659 — ici on verifie que la selection de langue precede les
#       tirages sans les modifier.
# =============================================================================

use strict;
use warnings;
use utf8;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_761 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

sub _count_items_761 {
    my ($src, $decl) = @_;
    my ($body) = $src =~ /\Q$decl\E\s*=\s*\((.*?)\n    \);/s;
    return -1 unless defined $body;
    my $n = () = $body =~ /"(?:[^"\\]|\\.)*"/g;
    return $n;
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_761(File::Spec->catfile('Mediabot', 'UserCommands.pm'));
    my ($ctx) = $src =~ /(sub mbHoroscope_ctx \{.*?\n\})/s;
    $assert->ok(defined $ctx, 'source de mbHoroscope_ctx isolee');

    # ------------------------------------------------------------------
    # [1] Parite des tailles FR/EN
    # ------------------------------------------------------------------
    my @pairs = (
        [ 'my @humeurs',         'my @moods_en'      ],
        [ 'my @climats_social',  'my @social_en'     ],
        [ 'my @climats_projets', 'my @projets_en'    ],
        [ 'my @evenements',      'my @events_en'     ],
        [ 'my @recommandations', 'my @recos_en'      ],
        [ 'my @attentions',      'my @attentions_en' ],
    );
    for my $p (@pairs) {
        my ($fr, $en) = @$p;
        my ($nf, $ne) = (_count_items_761($ctx, $fr), _count_items_761($ctx, $en));
        $assert->ok($nf > 0 && $nf == $ne, "parite $fr ($nf) == $en ($ne)");
    }
    # couleurs en qw()
    my ($cf) = $ctx =~ /my \@couleurs\s*= qw\(([^)]+)\)/;
    my ($ce) = $ctx =~ /my \@colours_en\s*= qw\(([^)]+)\)/;
    $assert->ok(defined $cf && defined $ce
        && scalar(split ' ', $cf) == scalar(split ' ', $ce),
        'parite couleurs FR/EN');
    # elans : 3 par element des deux cotes
    my $fr_elans = () = $ctx =~ /^\s{19}"[^"]+"(?:,| \])/mg;
    for my $el (qw(feu terre air eau)) {
        $assert->like($ctx, qr/\Q$el\E\s+=> \[ "/, "elans_en: element $el present (cles FR)");
    }

    # ------------------------------------------------------------------
    # [2] Mapping complet signes + elements
    # ------------------------------------------------------------------
    for my $sign ('Bélier', 'Taureau', 'Gémeaux', 'Cancer', 'Lion', 'Vierge',
                  'Balance', 'Scorpion', 'Sagittaire', 'Capricorne', 'Verseau', 'Poissons') {
        $assert->like($ctx, qr/'\Q$sign\E' => '[A-Z][a-z]+'/, "sign_en: $sign mappe");
    }
    for my $el (qw(feu terre air eau)) {
        $assert->like($ctx, qr/\Q$el\E => '[a-z]+'/, "element_en: $el mappe");
    }
    $assert->like($ctx, qr/\$elans\{\$sign_element\}/,
        'les elans restent indexes par la cle FR (les deux langues)');

    # ------------------------------------------------------------------
    # [3] Gabarits et selection
    # ------------------------------------------------------------------
    $assert->like($ctx, qr/Mediabot::Helpers::channel_lang\(\$self, \$channel\)/,
        'selection: channel_lang du canal');
    my $sel_pos  = index($ctx, 'my $horo_lang');
    my $draw_pos = index($ctx, 'my $humeur    = $pick->');
    $assert->ok($sel_pos > -1 && $draw_pos > $sel_pos,
        'la selection de langue precede les tirages');

    for my $frag ('Horoscope du \$date_key', 'Climat : ', 'Conseil : %s\. Méfiance : %s\.',
                  'chance %d%%') {
        $assert->like($ctx, qr/$frag/, "gabarit FR: $frag");
    }
    for my $frag ('Horoscope for \$date_key', 'Vibe: ', 'Advice: %s\. Beware of: %s\.',
                  'luck %d%%', 'kindred sign: %s') {
        $assert->like($ctx, qr/$frag/, "gabarit EN: $frag");
    }
    $assert->like($ctx, qr/mood: \$humeur/, 'gabarit EN: mood');
};
