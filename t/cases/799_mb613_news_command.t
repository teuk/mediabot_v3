# t/cases/799_mb613_news_command.t
# =============================================================================
# mb613 — !actualites <sujet> : recherche Tavily + synthese dans la langue du
# canal, portage du news_teuk.tcl.
#   [1] la commande est routee (4 alias, dont la forme accentuee) et passe
#       par un worker : deux appels reseau ne doivent pas figer la boucle.
#   [2] langue : jeton force puis langue du canal, via l'API PARTAGEE mb609
#       (aucune regle de langue recopiee) ; textes de service par langue
#       avec repli anglais.
#   [3] SANS SUJET : une vraie requete d'actualites du jour, propre a la
#       langue — jamais un refus « rien a resumer ».
#   [4] FRAICHEUR : tri du plus recent au plus ancien, les resultats de plus
#       de 7 jours ecartes DES QU'il reste assez de matiere fraiche, mais
#       jamais au prix du silence.
#   [5] la ligne « Sources: » est DETERMINISTE (domaine + date depuis les
#       resultats), dedupliquee, bornee — le modele ne peut pas halluciner
#       une source.
#   [6] sans cle Tavily : la commande le dit et ne fait rien d'autre. Aucune
#       cle n'est ecrite dans le depot.
# =============================================================================

use strict;
use warnings;
use utf8;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }

{
    package ConfN; sub new { bless { kv => $_[1] || {} }, $_[0] }
    sub get { $_[0]{kv}{ $_[1] } }
}
{
    package LogN; sub new { bless {}, shift } sub log { 1 }
}
{
    package CtxN;
    sub new { my ($c,%a)=@_; bless {%a}, $c }
    sub bot { $_[0]{bot} } sub nick { $_[0]{nick} }
    sub channel { $_[0]{channel} } sub args { $_[0]{args} || [] }
}

return sub {
    my ($assert) = @_;

    require Mediabot::External::News;
    require Mediabot::External::Claude;
    require Mediabot::Mediabot;
    my $N = 'Mediabot::External::News';

    # [1] routage
    my $mb = do { open my $fh, '<:encoding(UTF-8)', 'Mediabot/Mediabot.pm' or die $!;
                  local $/; <$fh> };
    my $aliases = 0;
    for my $alias (qw(actualites actu news)) {
        $aliases++ if $mb =~ /^\s+\Q$alias\E\s+=> sub \{ Mediabot::CommandAsync::run_ctx_async/m;
    }
    $assert->is($aliases, 3, 'mb613-799: les alias ascii sont routes');
    # mb614: la forme accentuee n'est plus une CLE (elle ne pouvait pas
    # matcher : « use utf8 » cote source, octets utf-8 cote IRC) — elle
    # atteint la table par le repliement. Voir le test 797.
    $assert->like($mb, qr/^\s+actualite\s+=> sub \{ Mediabot::CommandAsync::run_ctx_async/m,
        'mb613-799: la forme singuliere est routee');
    $assert->is(Mediabot::_fold_command_name("actualit\xc3\xa9s"), 'actualites',
        'mb613-799: la forme accentuee y arrive par repliement');
    $assert->like($mb, qr/actualites\|actualites \[sujet\] \[en\\\|fr\\\|es\]\|public\|/,
        'mb613-799: la commande est documentee');

    my $src = do { open my $fh, '<:encoding(UTF-8)', 'Mediabot/External/News.pm'
        or die $!; local $/; <$fh> };

    # [2] langue : API partagee, pas de regle recopiee
    $assert->like($src, qr/can\('extract_ai_lang_token'\)/,
        'mb613-799: le jeton de langue vient de l API partagee');
    $assert->like($src, qr/can\('resolve_ai_lang'\)/,
        'mb613-799: la resolution aussi');
    $assert->ok($src !~ /LangFR|chanset_enabled/,
        'mb613-799: aucune regle de langue recopiee');
    $assert->is(join(',', sort keys %Mediabot::External::News::TEXT), 'en,es,fr',
        'mb613-799: trois langues de service');
    my $complete = 0;
    for my $lang (qw(en fr es)) {
        my $t = $Mediabot::External::News::TEXT{$lang};
        $complete++ if 8 == grep { defined $t->{$_} && length $t->{$_} }
            qw(badge searching headlines nokey http empty sources cooldown);
    }
    $assert->is($complete, 3, 'mb613-799: chaque langue a tous ses textes');
    $assert->is($N->can('_text') ? Mediabot::External::News::_text('de', 'badge') : '',
        'News', 'mb613-799: langue inconnue -> repli anglais');

    # [3] sans sujet : une vraie recherche
    $assert->like(Mediabot::External::News::_news_default_query('fr'),
        qr/actualités.*France/, 'mb613-799: requete par defaut en francais');
    $assert->like(Mediabot::External::News::_news_default_query('es'),
        qr/noticias/, 'mb613-799: ... et en espagnol');
    $assert->is(Mediabot::External::News::_news_default_query('de'),
        'top news stories today', 'mb613-799: repli anglais');
    $assert->like($src, qr/\$is_default\s*\?\s*_text\(\$lang, 'headlines'\)/,
        'mb613-799: sans sujet, le bot annonce une recherche, pas un refus');

    # les paliers s'elargissent VRAIMENT
    my (@days, @ranges);
    for my $w (0 .. 2) {
        my ($p, $d) = Mediabot::External::News::_news_search_params('fr', 'x', $w);
        push @days, $d; push @ranges, $p->{time_range};
    }
    $assert->is(join(',', @days), '1,3,7', 'mb613-799: trois paliers temporels');
    $assert->is(join(',', @ranges), 'day,week,month',
        'mb613-799: chaque palier est reellement plus large que le precedent');
    my ($pfr) = Mediabot::External::News::_news_search_params('fr', 'x', 0);
    $assert->is($pfr->{country}, 'france',
        'mb613-799: le francais interroge la presse francaise (topic general)');
    my ($pen) = Mediabot::External::News::_news_search_params('en', 'x', 0);
    $assert->is($pen->{topic}, 'news',
        'mb613-799: l anglais utilise le vertical news de Tavily');
    $assert->ok(scalar @{ $pfr->{exclude_domains} } >= 5,
        'mb613-799: les domaines bruyants sont exclus');

    # [4] fraicheur
    my $now = 1786000000;   # repere fixe
    my $day = 86400;
    my $iso = sub { my @t = gmtime($now - $_[0] * $day);
                    sprintf('%04d-%02d-%02d', $t[5]+1900, $t[4]+1, $t[3]) };
    my $sel = Mediabot::External::News::_news_select_results([
        { title => 'vieux',  url => 'https://old.example.com/a', published_date => $iso->(40) },
        { title => 'hier',   url => 'https://www.liberation.fr/c', published_date => $iso->(1) },
        { title => 'aujourd hui', url => 'https://lemonde.fr/b',  published_date => $iso->(0) },
    ], $now);
    $assert->is(scalar @$sel, 2, 'mb613-799: les vieilleries sont ecartees');
    $assert->is($sel->[0]{title}, 'aujourd hui',
        'mb613-799: le plus recent en tete');
    $assert->is($sel->[0]{domain}, 'lemonde.fr',
        'mb613-799: le domaine est extrait sans www');
    my $only_old = Mediabot::External::News::_news_select_results([
        { title => 'vieux', url => 'https://old.example.com/a', published_date => $iso->(40) },
    ], $now);
    $assert->is(scalar @$only_old, 1,
        'mb613-799: mais on ne rend jamais le silence faute de frais');
    my $undated = Mediabot::External::News::_news_select_results([
        { title => 'sans date', url => 'https://x.example.com/a' },
        { title => 'daté', url => 'https://y.example.com/b', published_date => $iso->(2) },
    ], $now);
    $assert->is(scalar @$undated, 2,
        'mb613-799: un resultat sans date reste utilisable');
    $assert->ok(!defined $undated->[1]{age_d} || $undated->[1]{age_d} >= 0,
        'mb613-799: un resultat sans date n est pas juge frais par defaut');
    my $one_fresh_plus_undated = Mediabot::External::News::_news_select_results([
        { title => 'frais', url => 'https://fresh.example/a', published_date => $iso->(1) },
        { title => 'sans date', url => 'https://unknown.example/b' },
        { title => 'ancien', url => 'https://old.example/c', published_date => $iso->(40) },
    ], $now);
    $assert->is(scalar @$one_fresh_plus_undated, 3,
        'mb613-799: un resultat sans date ne compte pas comme deuxieme resultat frais');
    $assert->like($src, qr/last if \$fresh_count >= \$MIN_FRESH \|\| \$window == 2/,
        'mb613-799: la boucle elargit vraiment tant que MIN_FRESH n est pas atteint');

    # [5] ligne Sources deterministe
    my $line = Mediabot::External::News::_news_sources_line('fr', [
        { domain => 'lemonde.fr',   epoch => $now },
        { domain => 'lemonde.fr',   epoch => $now },
        { domain => 'liberation.fr', epoch => $now - $day },
        { domain => 'lefigaro.fr',  epoch => undef },
    ]);
    $assert->like($line, qr/^Sources: lemonde\.fr \(\d\d\/\d\d\)/,
        'mb613-799: sources construites depuis les resultats');
    my $count = () = $line =~ /lemonde\.fr/g;
    $assert->is($count, 1, 'mb613-799: un domaine n apparait qu une fois');
    $assert->like($line, qr/lefigaro\.fr \(\?\)/,
        'mb613-799: une date manquante est signalee, pas inventee');
    $assert->is(Mediabot::External::News::_news_sources_line('en', []), '',
        'mb613-799: aucune source -> aucune ligne');

    # [6] sans cle : refus explicite, et rien dans le depot
    my @out;
    no warnings 'redefine';
    local *Mediabot::Helpers::botNotice  = sub { push @out, $_[2]; 1 };
    local *Mediabot::Helpers::botPrivmsg = sub { push @out, $_[2]; 1 };
    my $bot = bless { conf => ConfN->new({ 'main.LANG' => 'fr' }), logger => LogN->new },
        'Mediabot';
    Mediabot::External::News::mbNews_ctx(
        CtxN->new(bot => $bot, nick => 'teuk', channel => '#quebec', args => ['bitcoin']));
    $assert->is(scalar @out, 1, 'mb613-799: sans cle, une seule reponse');
    $assert->like($out[0], qr/tavily\.API_KEY/,
        'mb613-799: ... et elle dit quoi configurer');
    $assert->ok($src !~ /tvly-/,
        'mb613-799: aucune cle API dans le code');
    my $conf = do { open my $fh, '<:encoding(UTF-8)', 'mediabot.sample.conf' or die $!;
                    local $/; <$fh> };
    # Section active (garde-fou 615 : toute cle lue par le code doit y etre)
    # mais cle commentee : la fonctionnalite reste desactivee par defaut.
    $assert->like($conf, qr/^\[tavily\]\n#API_KEY=tvly-\.\.\.$/m,
        'mb613-799: la conf documente la cle sans en contenir une');
    $assert->ok($conf !~ /API_KEY=tvly-\w/,
        'mb613-799: aucune vraie cle dans le depot');
};
