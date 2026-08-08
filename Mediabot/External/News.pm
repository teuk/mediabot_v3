package Mediabot::External::News;

# =============================================================================
# mb613-B1: !actualites <sujet> — recherche d'actualites (Tavily, topic news)
# puis synthese par Claude, dans LA LANGUE DU CANAL.
#
# Portage du news_teuk.tcl (Windrop) dans le moule mediabot :
#   * la recherche est faite par Tavily ; la ligne « Sources: » est construite
#     DETERMINISTEMENT depuis les resultats (domaine + date) — aucune source
#     ne peut etre hallucinee par le modele ;
#   * la synthese passe par claudeAI, donc elle herite du modele, des quotas,
#     du decoupage IRC et de la gestion d'erreur deja en place ;
#   * la langue vient de l'API partagee mb609 (jeton force en|fr|es, sinon
#     langue du canal, sinon main.LANG) : une seule regle de langue dans tout
#     le bot.
#
# Deux exigences de terrain, tenues ici :
#   1. « m actualites » SANS sujet doit donner les actualites du jour, pas un
#      refus. La requete par defaut depend de la langue et la fenetre
#      temporelle S'ELARGIT par paliers (jour -> 3 jours -> semaine) tant
#      qu'on n'a pas de matiere : on ne rend jamais « rien a resumer ».
#   2. Pas de vieux articles. Les resultats sont tries du plus recent au plus
#      ancien, ceux qui depassent $MAX_AGE_DAYS sont ecartes DES QU'il reste
#      assez de matiere fraiche, et la date de chaque source est affichee —
#      l'utilisateur juge lui-meme.
# =============================================================================

use strict;
use warnings;
use utf8;
use Exporter 'import';
use JSON::PP ();
use POSIX qw(strftime);

our @EXPORT_OK = qw(mbNews_ctx _news_select_results _news_sources_line
                    _news_default_query _news_search_params);

our $TAVILY_URL     = 'https://api.tavily.com/search';
our $MAX_RESULTS    = 8;
our $MAX_AGE_DAYS   = 7;     # au-dela, un resultat n'est plus une actualite
our $MIN_FRESH      = 2;     # en dessous, on elargit la fenetre
our $SNIPPET_MAX    = 400;
our $COOLDOWN_S     = 45;    # informatif : applique par checkCmdCooldown (parent)
our @NOISE_DOMAINS  = qw(youtube.com facebook.com x.com twitter.com
                         instagram.com tiktok.com reddit.com pinterest.com);

# Requete par defaut et pays de rattachement, par langue. Le pays n'a de sens
# que pour le topic 'general' de Tavily (son index 'news' couvre mal la presse
# non anglophone : paywalls), d'ou la bascule ci-dessous.
our %DEFAULTS = (
    fr => { query => "actualités importantes du jour en France", country => 'france'  },
    es => { query => "noticias importantes de hoy en España",    country => 'spain'   },
    en => { query => 'top news stories today',                   country => undef     },
);

# Messages de service, dans la langue de sortie.
our %TEXT = (
    en => {
        badge     => 'News',
        searching => 'Searching the news for "%s"...',
        headlines => 'Searching today\'s headlines...',
        nokey     => 'News search is not configured (tavily.API_KEY missing).',
        http      => 'News search failed (HTTP %s).',
        empty     => 'Nothing found for "%s" in the last %d days.',
        sources   => 'Sources',
        cooldown  => 'Easy — news search is rate-limited here (%ds left).',
    },
    fr => {
        badge     => 'Actu',
        searching => 'Recherche des actualités sur « %s »...',
        headlines => "Recherche des actualités du jour...",
        nokey     => "La recherche d'actualités n'est pas configurée (tavily.API_KEY manquante).",
        http      => "Échec de la recherche d'actualités (HTTP %s).",
        empty     => "Rien trouvé sur « %s » sur les %d derniers jours.",
        sources   => 'Sources',
        cooldown  => 'Doucement — recherche limitée sur ce salon (%ds).',
    },
    es => {
        badge     => 'Noticias',
        searching => 'Buscando noticias sobre «%s»...',
        headlines => 'Buscando las noticias de hoy...',
        nokey     => 'La búsqueda de noticias no está configurada (falta tavily.API_KEY).',
        http      => 'Error en la búsqueda de noticias (HTTP %s).',
        empty     => 'Nada encontrado sobre «%s» en los últimos %d días.',
        sources   => 'Fuentes',
        cooldown  => 'Calma — búsqueda limitada en este canal (%ds).',
    },
);

sub _text {
    my ($lang, $key) = @_;
    my $t = $TEXT{ $lang || '' } || $TEXT{en};
    return defined $t->{$key} ? $t->{$key} : ($TEXT{en}{$key} // '');
}

sub _news_default_query {
    my ($lang) = @_;
    my $d = $DEFAULTS{ $lang || '' } || $DEFAULTS{en};
    return $d->{query};
}

# Parametres d'une passe de recherche. $window est un palier d'elargissement :
# 0 = le jour, 1 = trois jours, 2 = la semaine.
sub _news_search_params {
    my ($lang, $query, $window) = @_;
    my $d = $DEFAULTS{ $lang || '' } || $DEFAULTS{en};
    my @days = (1, 3, 7);
    my $days = $days[$window] // 7;
    my %p = (
        query        => $query,
        search_depth => 'advanced',
        max_results  => $MAX_RESULTS,
        exclude_domains => [@NOISE_DOMAINS],
    );
    if ($d->{country}) {
        # topic general + country : la presse locale remonte bien mieux.
        $p{topic}      = 'general';
        $p{country}    = $d->{country};
        # Les paliers doivent VRAIMENT s'elargir : day -> week -> month.
        # (Deux paliers identiques auraient refait la meme recherche pour
        # rien avant de rendre les mains.)
        $p{time_range} = $days <= 1 ? 'day' : ($days <= 3 ? 'week' : 'month');
    }
    else {
        $p{topic} = 'news';
        $p{days}  = $days;
    }
    return (\%p, $days);
}

# --- normalisation d'un resultat Tavily --------------------------------------

sub _domain_of {
    my ($url) = @_;
    return '' unless defined $url;
    my ($host) = $url =~ m{^https?://([^/:?#]+)}i;
    return '' unless defined $host;
    $host =~ s/^www\.//i;
    return lc $host;
}

# Tavily rend published_date en ISO ou en RFC822 selon le topic. On ne garde
# que ce qu'on sait lire ; un resultat sans date reste utilisable mais ne peut
# pas etre juge « frais ».
sub _epoch_of {
    my ($raw) = @_;
    return undef unless defined $raw && !ref $raw && length $raw;
    if ($raw =~ /(\d{4})-(\d{2})-(\d{2})/) {
        my ($y, $m, $d) = ($1, $2, $3);
        return eval { require Time::Local; Time::Local::timegm(0, 0, 12, $d, $m - 1, $y) };
    }
    my %mon = (Jan=>0,Feb=>1,Mar=>2,Apr=>3,May=>4,Jun=>5,
               Jul=>6,Aug=>7,Sep=>8,Oct=>9,Nov=>10,Dec=>11);
    if ($raw =~ /(\d{1,2})\s+(\w{3})\w*\s+(\d{4})/ && defined $mon{ ucfirst lc $2 }) {
        return eval { require Time::Local;
                      Time::Local::timegm(0, 0, 12, $1, $mon{ ucfirst lc $2 }, $3) };
    }
    return undef;
}

# Tri du plus recent au plus ancien, puis ecartement des vieilleries — mais
# SEULEMENT s'il reste assez de matiere fraiche. Mieux vaut un article de dix
# jours annonce avec sa date qu'un silence.
sub _news_select_results {
    my ($results, $now) = @_;
    $now ||= time();
    my @clean;
    for my $r (@{ $results || [] }) {
        next unless ref $r eq 'HASH';
        my $title = $r->{title};
        next unless defined $title && length $title;
        my $epoch = _epoch_of($r->{published_date});
        push @clean, {
            title   => $title,
            url     => $r->{url} // '',
            domain  => _domain_of($r->{url}),
            content => substr(($r->{content} // ''), 0, $SNIPPET_MAX),
            epoch   => $epoch,
            age_d   => defined $epoch ? int(($now - $epoch) / 86400) : undef,
        };
    }
    @clean = sort {
        ( defined $b->{epoch} ? $b->{epoch} : 0 )
            <=> ( defined $a->{epoch} ? $a->{epoch} : 0 )
    } @clean;
    # An undated result remains usable, but cannot count as "fresh": without
    # a publication date we cannot prove that it is within MAX_AGE_DAYS.
    my @fresh = grep { defined $_->{age_d} && $_->{age_d} <= $MAX_AGE_DAYS } @clean;
    return (scalar @fresh >= $MIN_FRESH) ? \@fresh : \@clean;
}

# Ligne « Sources: » construite depuis les resultats, jamais depuis le modele.
sub _news_sources_line {
    my ($lang, $picked, $limit) = @_;
    $limit ||= 4;
    my (@parts, %seen);
    for my $r (@{ $picked || [] }) {
        my $dom = $r->{domain} or next;
        next if $seen{$dom}++;
        my $when = defined $r->{epoch}
            ? strftime('%d/%m', gmtime($r->{epoch})) : '?';
        push @parts, "$dom ($when)";
        last if @parts >= $limit;
    }
    return '' unless @parts;
    return _text($lang, 'sources') . ': ' . join(', ', @parts);
}

# --- commande ----------------------------------------------------------------

sub mbNews_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # Langue : jeton force (en|fr|es, lang=xx) puis langue du canal — la meme
    # API que 'ai summary' et 'recap ai' (mb609), chargee paresseusement.
    my ($forced, $bad);
    if (my $extract = Mediabot::External::Claude->can('extract_ai_lang_token')) {
        ($forced, $bad, @args) = $extract->(@args);
    }
    my $resolve = Mediabot::External::Claude->can('resolve_ai_lang');
    my $lang = $resolve ? $resolve->($self, $channel, $forced)
             : (eval { Mediabot::Helpers::channel_lang($self, $channel) } || 'en');

    my $reply_to = (defined $channel && $channel =~ /^#/) ? $channel : $nick;
    my $say = sub { Mediabot::Helpers::botPrivmsg($self, $reply_to, $_[0]) };

    my $api_key = eval { $self->{conf}->get('tavily.API_KEY') };
    unless (defined $api_key && !ref $api_key && length $api_key) {
        Mediabot::Helpers::botNotice($self, $nick, _text($lang, 'nokey'));
        return;
    }
    if (defined $bad) {
        Mediabot::Helpers::botNotice($self, $nick,
            "Unsupported language '$bad' (en, fr, es) - using '$lang'.");
    }

    my $subject = join ' ', grep { defined && length } @args;
    $subject =~ s/\s+/ /g if length $subject;
    $subject = '' unless defined $subject;
    my $is_default = (length($subject) == 0) ? 1 : 0;
    my $query = $is_default ? _news_default_query($lang) : $subject;

    # mb615-B1: le garde-fou de frequence vit cote PARENT (checkCmdCooldown,
    # defaut 45 s pour actualites et ses alias). Le poser ici serait un
    # trompe-l'oeil : cette commande tourne dans un worker jetable, tout
    # compteur ecrit dans $self meurt avec le processus fils. Meme raison
    # pour le cache de reponses du script Tcl d'origine : il n'aurait jamais
    # servi. Un round dedie pourra le remonter au parent si le besoin se
    # confirme.
    my $now = time();

    $say->($is_default
        ? _text($lang, 'headlines')
        : sprintf(_text($lang, 'searching'), $subject));

    # Recherche, avec elargissement par paliers : on ne rend jamais « rien a
    # resumer » sans avoir tente la fenetre suivante.
    my $http = Mediabot::External::_make_http(timeout => 12, max_size => 1024 * 1024);
    my ($picked, $last_status) = ([], 0);
    for my $window (0 .. 2) {
        my ($params, $days) = _news_search_params($lang, $query, $window);
        my $payload = eval {
            JSON::PP->new->utf8->canonical->encode({ %$params, api_key => $api_key })
        } or last;
        my $res = eval {
            $http->request('POST', $TAVILY_URL, {
                headers => { 'Content-Type' => 'application/json' },
                content => $payload,
            });
        } // { success => 0, status => 0 };
        $last_status = $res->{status} // 0;
        unless ($res->{success}) {
            eval { $self->{logger}->log(1,
                "news: Tavily HTTP $last_status " . substr(($res->{content} // ''), 0, 200)) };
            next;
        }
        my $data = eval { JSON::PP->new->utf8->decode($res->{content} // '{}') };
        my $sel = _news_select_results(ref($data) eq 'HASH' ? $data->{results} : [], $now);
        if (@$sel) {
            $picked = $sel;
            # Honor MIN_FRESH for real. A single dated result (or only
            # undated/old material) is useful as a fallback, but it should not
            # prevent the next, wider Tavily window from being attempted.
            my $fresh_count = grep {
                defined $_->{age_d} && $_->{age_d} <= $MAX_AGE_DAYS
            } @$sel;
            last if $fresh_count >= $MIN_FRESH || $window == 2;
        }
    }

    unless (@$picked) {
        if ($last_status && $last_status !~ /\A2/) {
            $say->(sprintf(_text($lang, 'http'), $last_status));
        }
        else {
            $say->(sprintf(_text($lang, 'empty'), ($is_default ? $query : $subject), 7));
        }
        return;
    }

    # Matiere pour le modele : titre, source, date, extrait.
    my @block;
    for my $r (@$picked) {
        my $when = defined $r->{epoch} ? strftime('%Y-%m-%d', gmtime($r->{epoch})) : 'n/a';
        push @block, "- $r->{title} [$r->{domain}, $when] $r->{content}";
    }
    my $lang_name = (Mediabot::External::Claude->can('ai_lang_name')
        ? Mediabot::External::Claude::ai_lang_name($lang) : 'English');
    my $prompt =
        "You are summarising news dispatches for an IRC channel. From the results below "
      . "(title, source, date, snippet), write a factual summary in $lang_name, in at most "
      . "2 lines of under 380 characters each. LINE 1: the most recent and most important "
      . "development, dated, with concrete facts (figures, names, places). LINE 2: context, "
      . "what is at stake, and disagreements between sources if any. Prefer what several "
      . "sources corroborate; attribute explicitly what rests on a single one. Ignore "
      . "off-topic results without commenting on them. Invent no fact, no date, no source; "
      . "if the material is thin, one sober line is enough. No Markdown, no emoji, no lists, "
      . "no preamble.\n\n"
      . "Topic: $query\n\n" . join("\n", @block);

    my $badge = "\x0300,04" . _text($lang, 'badge') . "\x0f";
    my @lines;
    my $emit = sub {
        my ($text) = @_;
        return unless defined $text && $text =~ /\S/;
        for my $line (split /\n/, $text) {
            next unless $line =~ /\S/;
            last if @lines >= 3;
            $line =~ s/^\s+|\s+$//g;
            push @lines, "$badge $line";
        }
    };
    my $ok = eval {
        Mediabot::External::Claude::claudeAI($self, $prompt, $nick, undef, $emit, $prompt);
        1;
    };
    unless ($ok && @lines) {
        eval { $self->{logger}->log(1, "news: synthesis failed: $@") } if $@;
        # Repli utile plutot qu'un message d'echec : les titres eux-memes.
        for my $r (@$picked) {
            last if @lines >= 3;
            push @lines, "$badge $r->{title} — $r->{domain}";
        }
    }
    my $sources = _news_sources_line($lang, $picked);
    push @lines, "$badge $sources" if length $sources;

    $say->($_) for @lines;
    return 1;
}

1;
