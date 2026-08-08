# t/cases/791_mb608_ai_summary_language.t
# =============================================================================
# mb608 — 'ai summary' repond dans la langue du canal, et sait etre force.
#   [1] table de rendu : 3 langues, repli anglais pour toute valeur inconnue
#       ou absente ; chaque langue possede toutes les cles utilisees.
#   [2] libelles de periode par langue, y compris les formes a parametre
#       (last <h/m>, <N> jours) et la cle vide = aucun libelle (inchange).
#   [3] le jeton de langue est extrait AVANT le filtre nick (sinon 'fr'
#       serait pris pour un pseudo) — garde structurelle sur la passe grep.
#   [4] resolution : jeton force > langue du canal (channel_lang mb563) >
#       'en' ; un code inconnu previent l'appelant et retombe proprement.
#   [5] le PROMPT reste anglais dans ses metadonnees et gagne la seule
#       instruction de langue (aucune regression de comportement).
#   [6] l'aide documente la langue ; la ligne de commande publique aussi.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }

return sub {
    my ($assert) = @_;

    require Mediabot::External::Claude;
    my $S = \%Mediabot::External::Claude::SUMMARY_STRINGS;

    # [1] table complete et repli
    $assert->is(join(',', sort keys %$S), 'en,es,fr',
        'mb608-791: trois langues declarees');
    my @keys = qw(name by none working last_h last_m no_last today yesterday week days);
    my $complete = 0;
    for my $lang (sort keys %$S) {
        $complete++ if @keys == grep { defined $S->{$lang}{$_} && length $S->{$lang}{$_} } @keys;
    }
    $assert->is($complete, 3, 'mb608-791: chaque langue a toutes les cles');
    $assert->is(Mediabot::External::Claude::_summary_lang_strings('de')->{name},
        'English', 'mb608-791: langue inconnue -> repli anglais');
    $assert->is(Mediabot::External::Claude::_summary_lang_strings(undef)->{name},
        'English', 'mb608-791: langue absente -> repli anglais');
    $assert->is($S->{fr}{name}, 'French', 'mb608-791: fr demande du francais au modele');
    $assert->is($S->{es}{name}, 'Spanish', 'mb608-791: es demande de l espagnol');

    # [2] libelles de periode
    my $L = \&Mediabot::External::Claude::_summary_period_label;
    $assert->is($L->('fr', 'today'), " (aujourd'hui)",
        'mb608-791: today en francais');
    $assert->is($L->('es', 'yesterday'), ' (ayer)', 'mb608-791: yesterday en espagnol');
    $assert->is($L->('en', 'today'), ' (today)', 'mb608-791: anglais inchange');
    $assert->is($L->('fr', 'days', 7), ' (7 derniers jours)',
        'mb608-791: periode a parametre en francais');
    $assert->is($L->('fr', 'last', 125), ' (depuis 2h05m)',
        'mb608-791: last au format heures/minutes');
    $assert->is($L->('fr', 'last', 12), ' (depuis 12m)',
        'mb608-791: last au format minutes');
    $assert->is($L->('fr', ''), '', 'mb608-791: aucun filtre = aucun libelle');
    $assert->is($L->('fr', 'inconnu'), '', 'mb608-791: cle inconnue = rien');

    my $src = do { open my $fh, '<:encoding(UTF-8)', 'Mediabot/External/Claude.pm'
        or die $!; local $/; <$fh> };

    # [3] extraction avant le filtre nick
    my ($grep_block) = $src =~ /\@args = grep \{(.+?)\} \@args;/s;
    $assert->ok(defined $grep_block && $grep_block =~ /forced_lang/,
        'mb608-791: le jeton de langue est extrait dans la passe grep');
    my $grep_pos = index($src, '@args = grep {');
    my $nick_pos = index($src, 'my $filter_nick =');
    $assert->ok($grep_pos > 0 && $nick_pos > $grep_pos,
        'mb608-791: ... donc AVANT le parsing du filtre nick');
    $assert->like($grep_block, qr/lang\[=:\]\(\[a-z\]\{2\}\)/,
        'mb608-791: la forme lang=xx est acceptee');
    $assert->like($grep_block, qr/\\A\(\?:en\|fr\|es\)\\z/,
        'mb608-791: le jeton nu en|fr|es est accepte');
    $assert->like($grep_block, qr/nick=\(\.\+\)/,
        'mb608-791: nick=<pseudo> echappe les collisions avec les options');

    # [3b] SONDE EXECUTABLE : la passe grep est extraite du source et
    # reellement executee sur des arguments realistes. Une garde structurelle
    # dit que le code est la ; ceci prouve qu'il fait ce qu'on croit.
    my $probe = eval "sub { my \@args = \@_;
        my (\$public_out, \$out_lines, \$want_help) = (0, undef, 0);
        my (\$forced_lang, \$bad_lang, \$forced_nick) = (undef, undef, undef);
        \@args = grep {$grep_block} \@args;
        return { rest => [ \@args ], lang => \$forced_lang, bad => \$bad_lang,
                 nick => \$forced_nick, public => \$public_out,
                 lines => \$out_lines, help => \$want_help };
    }";
    $assert->ok(ref($probe) eq 'CODE', 'mb608-791: sonde du parseur compilee');
    my $r = $probe->(qw(today fr));
    $assert->is(($r->{lang} // ''), 'fr', 'mb608-791: sonde — jeton nu fr capte');
    $assert->is(join(',', @{ $r->{rest} }), 'today',
        'mb608-791: sonde — la periode survit au filtrage');
    $r = $probe->(qw(today teuk));
    $assert->ok(!defined $r->{lang} && join(',', @{ $r->{rest} }) eq 'today,teuk',
        'mb608-791: sonde — un pseudo ordinaire n est PAS pris pour une langue');
    $r = $probe->(qw(7d 3l public lang=es SlaY));
    $assert->ok(($r->{lang} // '') eq 'es' && $r->{public} && $r->{lines} == 3
                && join(',', @{ $r->{rest} }) eq '7d,SlaY',
        'mb608-791: sonde — lang=es coexiste avec public, 3l, periode et nick');
    $r = $probe->(qw(lang=de));
    $assert->ok(!defined $r->{lang} && ($r->{bad} // '') eq 'de',
        'mb608-791: sonde — un code inconnu est signale, pas accepte');
    $r = $probe->(qw(today lang=en nick=fr));
    $assert->ok(($r->{lang} // '') eq 'en' && ($r->{nick} // '') eq 'fr'
                && join(',', @{ $r->{rest} }) eq 'today',
        'mb608-791: sonde — nick=fr reste un filtre nick avec langue explicite');
    $r = $probe->(qw(today fr nick=fr));
    $assert->ok(($r->{lang} // '') eq 'fr' && ($r->{nick} // '') eq 'fr'
                && join(',', @{ $r->{rest} }) eq 'today',
        'mb608-791: sonde — langue fr et pseudo fr peuvent coexister');
    $r = $probe->(qw(10));
    $assert->ok(!defined $r->{lang} && !defined $r->{bad},
        'mb608-791: sonde — sans jeton, rien n est force (defaut = canal)');

    # [4] resolution et repli
    # mb609: la regle vit desormais dans resolve_ai_lang, partagee avec
    # 'recap ai' — on verifie le helper ET son usage par summary.
    $assert->like($src, qr/sub resolve_ai_lang \{.*?\$forced\s*
\s*\|\|.*channel_lang/s,
        'mb608-791: force > langue du canal');
    $assert->like($src, qr/sub resolve_ai_lang \{.*?\$lang = 'en' unless \$lang =~/s,
        'mb608-791: ... et repli anglais si la valeur sort du trio');
    $assert->like($src, qr/my \$lang = resolve_ai_lang\(\$self, \$channel, \$forced_lang\)/,
        'mb608-791: summary consomme le helper partage');
    $assert->like($src, qr/Unsupported language '\$bad_lang'/,
        'mb608-791: un code inconnu previent l appelant');

    # [5] le prompt garde ses metadonnees anglaises
    $assert->like($src, qr/"Summarise this IRC conversation\$\{who_str\}\$\{date_label\} "/,
        'mb608-791: le prompt conserve son entete anglais');
    $assert->like($src, qr/\$len_str, in \$lang_name:/,
        'mb608-791: seule une instruction de langue est ajoutee');
    $assert->like($src, qr/\$date_label\s+= ' \(today\)';/,
        'mb608-791: le libelle du prompt reste anglais');

    # [6] documentation
    $assert->like($src, qr/Forcer avec en \| fr \| es, ou lang=fr/,
        'mb608-791: l aide de la sous-commande documente la langue');
    $assert->like($src, qr/nick=<pseudo>/,
        'mb608-791: l aide documente l echappement des pseudos homonymes');
    my $mb = do { open my $fh, '<:encoding(UTF-8)', 'Mediabot/Mediabot.pm'
        or die $!; local $/; <$fh> };
    $assert->like($mb, qr/summary \[periode\] \[N\] \[Nl\] \[public\] \[en\|fr\|es\]/,
        'mb608-791: la ligne de commande publique annonce la langue');
};
