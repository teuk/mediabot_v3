# t/cases/792_mb609_recap_ai_language.t
# =============================================================================
# mb609 — 'recap ai' suit la langue du canal, avec la MEME implementation
# que 'ai summary' (aucune seconde specification).
#   [1] l'API de langue est publique et unitairement juste :
#       extract_ai_lang_token, resolve_ai_lang, ai_lang_name, ai_lang_text.
#   [2] resolve_ai_lang : force > langue du canal (channel_lang mb563) >
#       'en' ; casse et valeurs hors trio normalisees.
#   [3] recap CONSOMME ces fonctions (pas de regex/regle recopiee) et les
#       appelle a travers can() — le module Claude est charge paresseusement.
#   [4] le prompt de recap demande explicitement la langue : plus de
#       « in the same language as the conversation » laisse au hasard.
#   [5] les 3 messages de service du chemin IA sont localises, avec repli
#       sur la formulation anglaise historique si Claude n'est pas charge.
#   [6] la syntaxe annoncee (usage + ligne de commande publique) le dit.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }

{
    package ConfL792;
    sub new { bless { lang => $_[1] }, $_[0] }
    sub get { return $_[1] eq 'main.LANG' ? $_[0]{lang} : undef }
}
{
    package Bot792;
    sub new { bless { conf => ConfL792->new($_[1]), chansets => $_[2] || {} }, $_[0] }
}

return sub {
    my ($assert) = @_;

    require Mediabot::External::Claude;
    require Mediabot::Helpers;
    require Mediabot::UserCommands;
    my $C = 'Mediabot::External::Claude';

    # [1] API publique
    for my $fn (qw(extract_ai_lang_token resolve_ai_lang ai_lang_name ai_lang_text)) {
        $assert->ok($C->can($fn), "mb609-792: $C->$fn est expose");
    }
    my ($forced, $bad, @rest) = $C->can('extract_ai_lang_token')->(qw(30m ai fr));
    $assert->is($forced, 'fr', 'mb609-792: jeton nu extrait');
    $assert->is(join(',', @rest), '30m,ai', 'mb609-792: le reste des args survit');
    ($forced, $bad, @rest) = $C->can('extract_ai_lang_token')->(qw(2h lang=es ai));
    $assert->is($forced, 'es', 'mb609-792: forme lang=xx extraite');
    ($forced, $bad, @rest) = $C->can('extract_ai_lang_token')->(qw(ai lang=de));
    $assert->ok(!defined $forced && $bad eq 'de',
        'mb609-792: code hors trio signale, pas accepte');
    ($forced, $bad, @rest) = $C->can('extract_ai_lang_token')->(qw(30m ai));
    $assert->ok(!defined $forced && !defined $bad,
        'mb609-792: sans jeton, rien n est force');

    # [2] resolution
    my $resolve = $C->can('resolve_ai_lang');
    my $bot_en = Bot792->new('en');
    $assert->is($resolve->($bot_en, '#c', 'fr'), 'fr',
        'mb609-792: le jeton force gagne');
    $assert->is($resolve->($bot_en, '#c', undef), 'en',
        'mb609-792: sans jeton et sans chanset, main.LANG (en)');
    my $bot_fr = Bot792->new('fr');
    $assert->is($resolve->($bot_fr, '#c', undef), 'fr',
        'mb609-792: main.LANG=fr suit');
    $assert->is($resolve->($bot_en, '#c', 'FR'), 'fr',
        'mb609-792: la casse est normalisee');
    $assert->is($resolve->($bot_en, '#c', 'de'), 'en',
        'mb609-792: valeur hors trio -> repli anglais');
    $assert->is($C->can('ai_lang_name')->('fr'), 'French',
        'mb609-792: le nom demande au modele');
    $assert->is($C->can('ai_lang_text')->('fr', 'recap_truncated'),
        'recap: resume tronque (trop long).',
        'mb609-792: texte de service en francais');
    $assert->is($C->can('ai_lang_text')->('de', 'recap_notconf'),
        $C->can('ai_lang_text')->('en', 'recap_notconf'),
        'mb609-792: langue inconnue -> texte anglais');
    $assert->is($C->can('ai_lang_text')->('fr', 'cle_absente'), '',
        'mb609-792: cle absente -> chaine vide, jamais undef');

    my $src = do { open my $fh, '<:encoding(UTF-8)', 'Mediabot/SocialHistory.pm'
        or die $!; local $/; <$fh> };

    # [3] recap consomme l API, via can()
    $assert->like($src, qr/can\('extract_ai_lang_token'\)/,
        'mb609-792: recap extrait le jeton via l API partagee');
    $assert->like($src, qr/can\('resolve_ai_lang'\)/,
        'mb609-792: ... et resout la langue par le meme helper');
    $assert->ok($src !~ /unless \$recap_lang =~/,
        'mb609-792: aucune regle de langue recopiee dans recap');
    $assert->like($src, qr/channel_lang\(\$self, \$channel\) \} \|\| 'en'\)/,
        'mb609-792: repli si le module Claude n est pas charge');

    # [4] prompt explicite
    $assert->like($src, qr/in 3-5 concise bullet points, "\s*\n\s*\.\s*"in \$lang_name\./,
        'mb609-792: le prompt demande explicitement la langue');
    $assert->ok($src !~ /in the same language as the conversation/,
        'mb609-792: le « devine la langue » a disparu');

    # [5] messages de service localises avec repli
    $assert->like($src, qr/sub _recap_text \{.*?return \$fallback;.*?\}/s,
        'mb609-792: helper de repli present');
    my $localized = 0;
    for my $key (qw(recap_truncated recap_unavailable recap_notconf)) {
        $localized++ if $src =~ /_recap_text\(\$recap_lang, '\Q$key\E'/;
    }
    $assert->is($localized, 3, 'mb609-792: les 3 messages du chemin IA sont localises');
    $assert->like($src, qr/'recap: AI summary unavailable, showing stats instead\.'\)/,
        'mb609-792: la formulation historique reste le repli');

    # [6] syntaxe annoncee
    # mb624: l'usage vit dans @RECAP_USAGE_LINES (source unique lue par l'aide
    # et par les messages d'erreur).
    $assert->ok((grep { /en\|fr\|es ou lang=fr/ } @Mediabot::UserCommands::RECAP_USAGE_LINES),
        'mb609-792: l usage annonce la langue');
    my $mb = do { open my $fh, '<:encoding(UTF-8)', 'Mediabot/Mediabot.pm'
        or die $!; local $/; <$fh> };
    $assert->like($mb, qr/recap \[30m\\\|2h\] \[ai\] \[en\\\|fr\\\|es\]/,
        'mb609-792: la ligne de commande publique aussi');
};
