package Mediabot::Users::Horoscope;

use strict;
use warnings;
use utf8;
use Exporter 'import';
use Mediabot::Helpers ();
use Mediabot::External::Horoscope ();

our @EXPORT_OK = qw(
    mbHoroscope_ctx
    _horoscope_slug_from_sign
    _horoscope_sign_from_slug
    _horoscope_zodiac_sign
    _horoscope_zodiac_from_birthday
    %HOROSCOPE_SLUG_OF
);

# Calendar, output and persistent-progress hooks retain their legacy call-time seam.
sub botNotice            { goto &Mediabot::UserCommands::botNotice }
sub botPrivmsg           { goto &Mediabot::UserCommands::botPrivmsg }
sub _ach_progress        { goto &Mediabot::UserCommands::_ach_progress }
sub _birthday_valid_date { goto &Mediabot::UserCommands::_birthday_valid_date }

# ---------------------------------------------------------------------------
# mbHoroscope_ctx --- !horoscope [nick]
# Horoscope IRC compact, FR/EN selon le canal. Seed = nick + date.
# Compteur de consultations en mémoire (achievement star_gazer).
# ---------------------------------------------------------------------------
# mb561-B1: (jour, mois) -> (nom, glyphe, element) du signe, bornes standard.
# Retourne () si la date est invalide. Testable unitairement (test 752).
# mb620-B1: passerelles entre le tableau canonique FR (historique, verrouille
# par le test 752) et les slugs anglais que veut l'API. Deux fonctions plutot
# qu'une table de plus : la source de verite reste _horoscope_zodiac_sign.
our %HOROSCOPE_SLUG_OF = (
    'Verseau' => 'aquarius', 'Poissons' => 'pisces', 'Bélier' => 'aries',
    'Taureau' => 'taurus', 'Gémeaux' => 'gemini', 'Cancer' => 'cancer',
    'Lion' => 'leo', 'Vierge' => 'virgo', 'Balance' => 'libra',
    'Scorpion' => 'scorpio', 'Sagittaire' => 'sagittarius',
    'Capricorne' => 'capricorn',
);

sub _horoscope_slug_from_sign {
    my ($fr_name) = @_;
    return undef unless defined $fr_name;
    return $HOROSCOPE_SLUG_OF{$fr_name};
}

# Rend [ nom_fr, glyphe, element ] pour un slug anglais, en RELISANT le
# tableau canonique : si une date de bascule change un jour, rien a resynchroniser.
sub _horoscope_sign_from_slug {
    my ($slug) = @_;
    return undef unless defined $slug;
    my %date_of = (
        aquarius => [ 20, 1 ], pisces => [ 19, 2 ], aries => [ 21, 3 ],
        taurus   => [ 20, 4 ], gemini => [ 21, 5 ], cancer => [ 21, 6 ],
        leo      => [ 23, 7 ], virgo  => [ 23, 8 ], libra  => [ 23, 9 ],
        scorpio  => [ 23, 10 ], sagittarius => [ 22, 11 ], capricorn => [ 22, 12 ],
    );
    my $d = $date_of{$slug} or return undef;
    my @sign = _horoscope_zodiac_sign(@$d);
    return @sign ? \@sign : undef;
}

sub _horoscope_zodiac_sign {
    my ($d, $m) = @_;
    return () unless defined $d && defined $m;
    return () unless $d =~ /^\d+$/ && $m =~ /^\d+$/;
    return () unless $d >= 1 && $d <= 31 && $m >= 1 && $m <= 12;
    return () unless _birthday_valid_date(2000, $m, $d);
    # Trié par date de début CROISSANTE : on garde le DERNIER signe dont la
    # date de début est <= (mois,jour) demandé. Capricorne (début 22/12) est
    # le défaut : il couvre aussi le début d'année (01/01 - 19/01), avant le
    # premier début de la liste (Verseau 20/01).
    my @zodiac = (
        [ 'Verseau',    "♒", 'air',    1, 20 ],
        [ 'Poissons',   "♓", 'eau',    2, 19 ],
        [ 'Bélier',     "♈", 'feu',    3, 21 ],
        [ 'Taureau',    "♉", 'terre',  4, 20 ],
        [ 'Gémeaux',    "♊", 'air',    5, 21 ],
        [ 'Cancer',     "♋", 'eau',    6, 21 ],
        [ 'Lion',       "♌", 'feu',    7, 23 ],
        [ 'Vierge',     "♍", 'terre',  8, 23 ],
        [ 'Balance',    "♎", 'air',    9, 23 ],
        [ 'Scorpion',   "♏", 'eau',   10, 23 ],
        [ 'Sagittaire', "♐", 'feu',   11, 22 ],
        [ 'Capricorne', "♑", 'terre', 12, 22 ],
    );
    my $md = $m * 100 + $d;
    my $found = [ 'Capricorne', "♑", 'terre' ];   # 01/01 - 19/01
    for my $z (@zodiac) {
        my $z_md = $z->[3] * 100 + $z->[4];
        $found = $z if $md >= $z_md;
    }
    return @$found[0, 1, 2];
}

# mb565-R1: USER.birthday is stored by the birthday command as MM-DD or
# YYYY-MM-DD. Accept those canonical DB formats and legacy dd/mm variants,
# validate the real calendar date, then delegate the zodiac boundaries to the
# tested helper above.
sub _horoscope_zodiac_from_birthday {
    my ($birthday) = @_;
    return () unless defined $birthday && !ref($birthday);

    my $raw = "$birthday";
    $raw =~ s/^\s+|\s+$//g;
    return () unless length $raw;

    my ($year, $month, $day) = (2000, undef, undef);
    if ($raw =~ /\A(\d{4})-(\d{2})-(\d{2})\z/) {
        ($year, $month, $day) = ($1 + 0, $2 + 0, $3 + 0);
    }
    elsif ($raw =~ /\A(\d{2})-(\d{2})\z/) {
        ($month, $day) = ($1 + 0, $2 + 0);
    }
    elsif ($raw =~ m{\A(\d{1,2})/(\d{1,2})(?:/(\d{4}))?\z}) {
        ($day, $month) = ($1 + 0, $2 + 0);
        $year = $3 + 0 if defined $3;
    }
    else {
        return ();
    }

    return () unless _birthday_valid_date($year, $month, $day);
    return _horoscope_zodiac_sign($day, $month);
}

sub mbHoroscope_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # mb620-B1: l'argument est SOIT un signe (dans n'importe laquelle des
    # trois langues, accentue ou non, glyphe ou abrege), SOIT un pseudo. On
    # teste le signe d'abord : « m horoscope lion » doit donner le Lion, pas
    # l'horoscope d'un utilisateur hypothetique nomme lion. Les trois cas
    # demandes sont ainsi couverts : signe donne, pseudo donne, rien donne.
    my $forced_sign;
    if (@args) {
        my $joined = join ' ', @args;
        $forced_sign = Mediabot::External::Horoscope::normalize_sign($joined)
                    || Mediabot::External::Horoscope::normalize_sign($args[0]);
    }
    my $target = (!$forced_sign && @args) ? lc($args[0]) : lc($nick);

    my $reply_to = ($channel && $channel =~ /^#/) ? $channel : $nick;

    # mb118-IMP2: gate par chanset +Games sur canal public (PM toujours autorisé)
    if ($channel && $channel =~ /^#/) {
        unless (Mediabot::Helpers::chanset_enabled($self, $channel, 'Games', default => 1)) {
            botNotice($self, $nick, "Games are disabled on $channel (chanset -Games)");
            return;
        }
    }

    # mb561-B1 + mb565-R1: signe astrologique depuis USER.birthday, avec
    # les formats réellement stockés par la commande birthday (MM-DD ou
    # YYYY-MM-DD) et compatibilité legacy dd/mm[/YYYY]. Même clé d'accès :
    # USER.nickname = cible. Best-effort : sans base, sans user ou sans date
    # valide -> horoscope complet quand même, simplement sans signe.
    my ($sign_name, $sign_glyph, $sign_element);
    {
        my $bday;
        eval {
            my $sth_b = $self->{dbh}->prepare(
                "SELECT birthday FROM USER WHERE nickname = ?");
            if ($sth_b && $sth_b->execute($target)) {
                my $row_b = $sth_b->fetchrow_hashref;
                $bday = $row_b->{birthday} if $row_b;
                $sth_b->finish;
            }
            1;
        };
        if (defined $bday) {
            ($sign_name, $sign_glyph, $sign_element) =
                _horoscope_zodiac_from_birthday($bday);
        }
    }

    # mb620-B1: un signe donne a la main gagne sur la date de naissance
    # stockee — c'est le cas « on me donne le signe ».
    my $api_slug;
    if ($forced_sign) {
        $api_slug = $forced_sign;
        my ($fr_name) = _horoscope_sign_from_slug($forced_sign);
        if (defined $fr_name) {
            ($sign_name, $sign_glyph, $sign_element) = @{ $fr_name };
        }
    }
    elsif (defined $sign_name) {
        $api_slug = _horoscope_slug_from_sign($sign_name);
    }

    # Seed déterministe : nick + date du jour
    my @lt = localtime(time);
    my $date_key = sprintf('%04d-%02d-%02d', $lt[5]+1900, $lt[4]+1, $lt[3]);
    my $seed = 0;
    # mb620-B1: quand un signe est demande explicitement, il entre dans la
    # graine — sinon « !horoscope lion » et « !horoscope vierge » rendraient
    # la meme saveur au meme utilisateur le meme jour. Sans signe force, la
    # graine est identique a l'historique (contrat mb444/test 659 intact).
    my $seed_src = $target . ':' . $date_key
                 . (defined $forced_sign ? ':' . $forced_sign : '');
    $seed = ($seed * 31 + ord($_)) & 0xFFFFFFFF for split //, $seed_src;

    # mb444-B1: PRNG LOCAL déterministe — le RNG global (dés, duels, 8ball,
    # trivia, Hailo) n'est JAMAIS touché. Contrat verrouillé par le test 659.
    my $rng  = $seed & 0x7FFFFFFF;
    my $next = sub { $rng = (($rng * 1103515245) + 12345) & 0x7FFFFFFF; return $rng; };
    my $pick = sub { my ($aref) = @_; return $aref->[ $next->() % scalar(@$aref) ]; };

    # mb572-B1: la langue du canal choisit les pools (Helpers::channel_lang,
    # mb563) — 'fr' garde les textes historiques, tout le reste (en, es tant
    # qu'aucun pool ES n'existe) recoit la version anglaise. CHAQUE pool EN a
    # EXACTEMENT la meme taille que son jumeau FR : un meme tirage LCG tombe
    # sur la meme "carte" dans les deux langues, et le contrat mb444 (ordre
    # des tirages, LCG local) est strictement inchange.
    my $horo_lang = Mediabot::Helpers::channel_lang($self, $channel);
    my $horo_fr = ($horo_lang eq 'fr') ? 1 : 0;

    # mb561-B1: pools entierement generiques — aucune personne, aucun projet,
    # aucun evenement interne. Teinte legerement IRC/tech assumee (c'est un
    # bot), mais rien de nominatif.
    my @humeurs = (
        "lumineuse 🌞", "mystérieuse 🌕", "espiègle 😈",
        "philosophe 🤔", "conquérante ⚔️", "rêveuse ☁️",
        "indomptable 🦁", "fluide 🌊", "électrique ⚡",
        "feutrée 🐾", "sereine 🧘", "magnétique 🧲",
    );

    # Accroches par élément (utilisées seulement si le signe est connu)
    my %elans = (
        feu   => [ "ton énergie ouvre les portes avant que tu frappes",
                   "l'étincelle du jour t'appartient, ne la prête pas",
                   "ce qui résiste aujourd'hui cédera par enthousiasme" ],
        terre => [ "ta constance vaut mieux que trois coups d'éclat",
                   "bâtis petit mais bâtis vrai, le reste suivra",
                   "un pas mesuré t'emmènera plus loin qu'un sprint" ],
        air   => [ "une conversation légère portera une idée sérieuse",
                   "ta curiosité est le bon outil, laisse-la ouvrir les onglets",
                   "les mots justes te viendront au moment exact" ],
        eau   => [ "ton intuition lit entre les lignes, fais-lui confiance",
                   "la marée du jour ramène quelque chose que tu croyais perdu",
                   "écoute deux fois, réponds une fois : magie garantie" ],
    );

    my @climats_social = (
        "Une attention discrète te fera plus de bien qu'un long discours",
        "Quelqu'un pense à toi sans te le dire",
        "Un échange anodin cachera une vraie complicité",
        "On te lira plus attentivement que tu ne le crois",
        "Un ancien contact refera surface au bon moment",
        "Ta bonne humeur sera contagieuse, dose-la avec malice",
        "Un silence bien placé vaudra une réponse brillante",
    );

    my @climats_projets = (
        "une tâche repoussée se révélera plus courte que prévu",
        "la solution viendra en expliquant le problème à voix haute",
        "un détail négligé mérite une seconde lecture",
        "ce que tu ranges aujourd'hui te sauvera demain",
        "une idée notée à la va-vite contient l'essentiel",
        "termine avant d'améliorer : l'ordre compte",
        "la version simple est la bonne",
    );

    my @evenements = (
        "Un café partagé deviendra mémorable.",
        "Quelqu'un te citera de travers : souris, ne corrige pas.",
        "Une question d'hier trouvera sa réponse toute seule.",
        "Une notification ignorée ce matin reviendra ce soir.",
        "Un air de musique te suivra toute la journée.",
        "Une coïncidence te fera lever un sourcil.",
        "Un objet perdu réapparaîtra à l'endroit évident.",
        "Une fenêtre oubliée contient encore une réponse précieuse.",
        "Un message tapé trop vite t'apprendra la patience.",
        "Une promesse faite à la légère te rattrapera gentiment.",
    );

    my @recommandations = (
        "ne refuse pas le café qu'on te tend",
        "lis le mode d'emploi d'un outil que tu crois maîtriser",
        "réponds à un message que tu avais laissé filer",
        "range une seule chose, mais range-la vraiment",
        "note l'idée avant qu'elle ne s'évapore",
        "fais une sauvegarde, tu sais pourquoi",
        "prends l'escalier, les astres y voient plus clair",
        "offre un compliment sans raison",
        "éteins un écran une heure avant de dormir",
        "goûte quelque chose de nouveau, même en pensée",
    );

    my @attentions = (
        "une promesse faite trop vite",
        "un détail qui grossit dans l'ombre",
        "une certitude qui mériterait vérification",
        "un raccourci qui coûtera plus qu'il ne rapporte",
        "une réponse envoyée sous le coup de l'agacement",
        "un oubli minuscule aux grandes conséquences",
        "une rumeur plus rapide que les faits",
        "un « ça peut attendre » de trop",
    );

    my @couleurs = qw(turquoise carmin indigo or pourpre ardoise émeraude saphir cuivre ivoire);
    my @chiffres = (3, 7, 11, 13, 17, 21, 23, 42, 47, 77, 100, 666);
    my @glyphs   = ("✨", "🌟", "🌙", "🔥", "☄️",
                    "🌌", "🔮", "⚡", "🌀");
    my @autres_signes = ('Bélier', 'Taureau', 'Gémeaux', 'Cancer', 'Lion', 'Vierge',
                         'Balance', 'Scorpion', 'Sagittaire', 'Capricorne', 'Verseau', 'Poissons');


    # mb572-B1: jumeaux anglais (tailles identiques aux pools FR).
    my @moods_en = (
        "radiant 🌞", "mysterious 🌕", "mischievous 😈",
        "philosophical 🤔", "conquering ⚔️", "dreamy ☁️",
        "untamable 🦁", "fluid 🌊", "electric ⚡",
        "hushed 🐾", "serene 🧘", "magnetic 🧲",
    );
    my %elans_en = (
        feu   => [ "your energy opens doors before you knock",
                   "today's spark is yours, don't lend it out",
                   "what resists today will yield to enthusiasm" ],
        terre => [ "your steadiness beats three flashy moves",
                   "build small but build true, the rest will follow",
                   "one measured step will carry you further than a sprint" ],
        air   => [ "a light conversation will carry a serious idea",
                   "your curiosity is the right tool, let it open the tabs",
                   "the right words will come at the exact moment" ],
        eau   => [ "your intuition reads between the lines, trust it",
                   "today's tide brings back something you thought lost",
                   "listen twice, answer once: guaranteed magic" ],
    );
    my @social_en = (
        "A quiet gesture will do you more good than a long speech",
        "Someone is thinking of you without saying it",
        "A casual exchange will hide a real bond",
        "You will be read more carefully than you think",
        "An old contact will resurface at the right time",
        "Your good mood will be contagious, dose it with mischief",
        "A well-placed silence will be worth a brilliant reply",
    );
    my @projets_en = (
        "a postponed task will turn out shorter than expected",
        "the answer will come while explaining the problem out loud",
        "an overlooked detail deserves a second read",
        "what you tidy today will save you tomorrow",
        "an idea scribbled in haste holds the essential",
        "finish before improving: order matters",
        "the simple version is the right one",
    );
    my @events_en = (
        "A shared coffee will become memorable.",
        "Someone will misquote you: smile, don't correct.",
        "Yesterday's question will answer itself.",
        "A notification ignored this morning will return tonight.",
        "A tune will follow you all day long.",
        "A coincidence will raise one of your eyebrows.",
        "A lost object will reappear in the obvious place.",
        "A forgotten window still holds a precious answer.",
        "A message typed too fast will teach you patience.",
        "A promise made lightly will gently catch up with you.",
    );
    my @recos_en = (
        "don't refuse the coffee you're offered",
        "read the manual of a tool you think you master",
        "answer a message you had let slip",
        "tidy one single thing, but tidy it truly",
        "write the idea down before it evaporates",
        "make a backup, you know why",
        "take the stairs, the stars see clearer there",
        "give a compliment for no reason",
        "turn off a screen one hour before sleep",
        "taste something new, even in thought",
    );
    my @attentions_en = (
        "a promise made too fast",
        "a detail growing in the shadows",
        "a certainty that deserves a check",
        "a shortcut that will cost more than it saves",
        "a reply sent in irritation",
        "a tiny oversight with big consequences",
        "a rumor faster than the facts",
        "one 'it can wait' too many",
    );
    my @colours_en = qw(turquoise crimson indigo gold purple slate emerald sapphire copper ivory);
    my %sign_en = (
        'Bélier' => 'Aries', 'Taureau' => 'Taurus', 'Gémeaux' => 'Gemini',
        'Cancer' => 'Cancer', 'Lion' => 'Leo', 'Vierge' => 'Virgo',
        'Balance' => 'Libra', 'Scorpion' => 'Scorpio', 'Sagittaire' => 'Sagittarius',
        'Capricorne' => 'Capricorn', 'Verseau' => 'Aquarius', 'Poissons' => 'Pisces',
    );
    my %element_en = (feu => 'fire', terre => 'earth', air => 'air', eau => 'water');

    # Selection par langue (les tailles jumelles garantissent la parite LCG).
    unless ($horo_fr) {
        @humeurs         = @moods_en;
        %elans           = %elans_en;
        @climats_social  = @social_en;
        @climats_projets = @projets_en;
        @evenements      = @events_en;
        @recommandations = @recos_en;
        @attentions      = @attentions_en;
        @couleurs        = @colours_en;
        @autres_signes   = map { $sign_en{$_} } @autres_signes;
    }

    # Tirages (LCG local, mb444-B1) — ordre FIXE pour la stabilité du jour
    my $humeur    = $pick->(\@humeurs);
    my $social    = $pick->(\@climats_social);
    my $projets   = $pick->(\@climats_projets);
    my $event     = $pick->(\@evenements);
    my $reco      = $pick->(\@recommandations);
    my $attention = $pick->(\@attentions);
    my $couleur   = $pick->(\@couleurs);
    my $chiffre   = $pick->(\@chiffres);
    my $glyph     = $pick->(\@glyphs);
    my $chance    = 35 + ($next->() % 60);  # 35..94, biais positif léger

    # Affichage — meme gabarit avec ou sans signe (mb561-B1)
    # mb572-B1: le nom/element du signe se traduit A L'AFFICHAGE seulement —
    # _horoscope_zodiac_sign reste canonique FR (test 752 intact), la cle
    # d'element des elans reste FR des deux cotes.
    my ($disp_sign, $disp_element) = ($sign_name, $sign_element);
    if (defined $sign_name && !$horo_fr) {
        $disp_sign    = $sign_en{$sign_name}       // $sign_name;
        $disp_element = $element_en{$sign_element} // $sign_element;
    }

    # mb620-B1: la prevision REELLE du jour pour ce signe. Best-effort de bout
    # en bout : API muette, lente ou changee, traduction indisponible -> undef,
    # et l'horoscope local s'affiche seul, exactement comme avant. L'utilisateur
    # ne voit jamais un message d'echec pour un horoscope.
    my $api_line;
    if (defined $api_slug) {
        $api_line = eval {
            Mediabot::External::Horoscope::daily_line(
                $self, $api_slug, ($horo_fr ? 'fr' : $horo_lang), $nick);
        };
    }

    # MB817: two bounded lines. Keep the historical local draws and their
    # order, so compacting the reply does not reshuffle daily lucky details.
    my $complice;
    if (defined $sign_name) {
        $pick->($elans{$sign_element});
        my @complices = grep { $_ ne $disp_sign } @autres_signes;
        $complice = $pick->(\@complices);
    }
    my $forecast = Mediabot::External::Horoscope::clean_text($api_line);
    $forecast //= Mediabot::External::Horoscope::local_forecast(
        $api_slug, $date_key, ($horo_fr ? 'fr' : 'en')) if defined $api_slug;
    my $lines = Mediabot::External::Horoscope::compact_lines(
        lang => ($horo_fr ? 'fr' : 'en'), target => $target, date => $date_key,
        sign => $disp_sign, glyph => $sign_glyph, forecast => $forecast,
        number => $chiffre, colour => $couleur, luck => $chance,
        companion => $complice);
    botPrivmsg($self, $reply_to, $_) for @$lines;

    # mb610-B1: le compteur passe au registre PERSISTANT des achievements
    # (le compteur memoire reste pour les instances sans systeme
    # d'achievements, et pour ne rien changer au reste du code).
    $self->{_horoscope_count}{$nick}++;
    if ($self->{achievements} && $channel =~ /^#/) {
        my $count = _ach_progress($self, 'horoscope', $nick, $channel)
                 // ($self->{_horoscope_count}{$nick} // 0);
        eval { $self->{achievements}->check_horoscope($nick, $channel, $count) };
        if ($@) { $self->{logger}->log(1, "achievements check_horoscope error: $@") }
    }

    $self->{metrics}->inc('mediabot_horoscope_total') if $self->{metrics};
    return 1;
}


1;
