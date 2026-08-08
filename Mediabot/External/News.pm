package Mediabot::External::News;

# =============================================================================
# mb613-B1: !actualites <sujet> — recherche d'actualites (Tavily, topic news)
# puis synthese par Claude, dans LA LANGUE DU CANAL.
#
# Portage du news_teuk.tcl (Windrop) dans le moule mediabot :
#   * Tavily fournit la matiere factuelle de la synthese ; Google News RSS
#     fournit, quand disponible, les titres/date/editeur precis de la liste
#     cliquable. Aucun titre de source n'est invente par le modele ;
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
use URI::Escape qw(uri_escape_utf8);

our @EXPORT_OK = qw(mbNews_ctx _news_select_results _news_sources_line
                    _news_default_query _news_search_params
                    _news_google_rss_url _news_parse_google_rss
                    _news_select_press_articles _news_fetch_google_articles
                    _news_article_segments _news_article_lines);

our $TAVILY_URL     = 'https://api.tavily.com/search';
our $GNEWS_URL      = 'https://news.google.com/rss/search';
our $GNEWS_TOP_URL  = 'https://news.google.com/rss';
our $MAX_RESULTS    = 8;
our $MAX_ARTICLES   = 3;
our $PRESS_SCAN_LIMIT = 30;
our $PRESS_DEFAULT_MAX_AGE_HOURS = 36;
our $PRESS_TOPIC_MAX_AGE_DAYS = 7;
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

# Google News RSS is deliberately separate from Tavily. Tavily is good raw
# material for the synthesis, but its `general` search can return section or
# homepage titles ("Journaux d'information", "Actualites Ile-de-France", ...).
# The RSS feed is used only for the visible clickable article list: precise
# press headline, publisher and publication date. Tavily remains the fallback.
sub _xml_unescape {
    my ($s) = @_;
    return '' unless defined $s;
    $s =~ s{&(#x[0-9A-Fa-f]+|#\d+|amp|lt|gt|quot|apos);}{
        my $e = $1;
        if ($e eq 'amp')  { '&' }
        elsif ($e eq 'lt')   { '<' }
        elsif ($e eq 'gt')   { '>' }
        elsif ($e eq 'quot') { '"' }
        elsif ($e eq 'apos') { "'" }
        elsif ($e =~ /^#x([0-9A-Fa-f]+)$/) {
            my $cp = hex($1);
            ($cp <= 0x10FFFF && !($cp >= 0xD800 && $cp <= 0xDFFF)) ? chr($cp) : '';
        }
        elsif ($e =~ /^#(\d+)$/) {
            my $cp = 0 + $1;
            ($cp <= 0x10FFFF && !($cp >= 0xD800 && $cp <= 0xDFFF)) ? chr($cp) : '';
        }
        else { '' }
    }eg;
    return $s;
}

sub _news_google_rss_url {
    my ($lang, $query, $is_default, $window) = @_;
    $query = '' unless defined $query;
    $window = 0 unless defined $window;
    my %locale = (
        fr => 'hl=fr&gl=FR&ceid=FR:fr',
        es => 'hl=es&gl=ES&ceid=ES:es',
        en => 'hl=en-US&gl=US&ceid=US:en',
    );
    my $loc = $locale{$lang || ''} || $locale{en};

    # A no-subject request means "today's headlines", not a text search for
    # the literal words "important news today". Google News' localized top
    # feed is much better for that job and is already editorially ranked.
    return $GNEWS_TOP_URL . '?' . $loc if $is_default;

    # For a requested topic, keep Google News Search but make recency explicit.
    # Widen only when necessary; otherwise relevance search can surface a
    # months-old evergreen page ahead of a current article.
    my @when = ('1d', '3d', '7d');
    my $age = $when[$window] // '7d';
    my $q = $query;
    $q .= " when:$age" unless $q =~ /(?:^|\s)when:\S+/i;
    return $GNEWS_URL . '?q=' . uri_escape_utf8($q) . '&' . $loc;
}

sub _news_parse_google_rss {
    my ($body, $limit) = @_;
    $limit ||= $MAX_ARTICLES;
    return [] unless defined $body && length $body;

    require Encode;
    my $xml = utf8::is_utf8($body)
        ? $body
        : Encode::decode('UTF-8', $body, Encode::FB_DEFAULT());

    my (@articles, %seen_source, %seen_url);
    while ($xml =~ m{<item\b[^>]*>(.*?)</item>}sig) {
        last if @articles >= $limit;
        my $item = $1;
        my ($title)  = $item =~ m{<title\b[^>]*>(.*?)</title>}si;
        my ($link)   = $item =~ m{<link\b[^>]*>(.*?)</link>}si;
        my ($pubdate)= $item =~ m{<pubDate\b[^>]*>(.*?)</pubDate>}si;
        my ($source) = $item =~ m{<source\b[^>]*>(.*?)</source>}si;
        next unless defined $title && defined $link;

        for ($title, $link, $pubdate, $source) {
            next unless defined $_;
            s/^\s*<!\[CDATA\[(.*?)\]\]>\s*$/$1/s;
            $_ = _xml_unescape($_);
            s/<[^>]+>/ /g;
            s/\s+/ /g;
            s/^\s+|\s+$//g;
        }
        next unless length($title) && $link =~ m{\Ahttps?://}i;
        next if $seen_url{$link}++;

        # Google News appends " - Publisher" to the title even though the
        # publisher is already available in <source>. Keep the useful part.
        if (defined $source && length $source) {
            $title =~ s/\s+-\s+\Q$source\E\s*\z//i;
            my $sk = lc $source;
            next if $seen_source{$sk}++;
        }

        my $epoch = _epoch_of($pubdate);
        push @articles, {
            title  => $title,
            url    => $link,
            source => (defined $source && length $source) ? $source : 'source',
            domain => _domain_of($link),
            epoch  => $epoch,
            age_d  => defined $epoch ? int((time() - $epoch) / 86400) : undef,
        };
    }
    return \@articles;
}

sub _news_press_title_is_generic {
    my ($title) = @_;
    return 1 unless defined $title && $title =~ /\S/;
    my $t = lc $title;
    return 1 if $t =~ /\b(?:actualit(?:é|e)s?\s+du\s+jour|info(?:s)?\s+en\s+continu|fil\s+info|journal(?:\s+des)?\s+informations?)\b/;
    return 1 if $t =~ /\b(?:l['’]actu(?:alité)?\s+de\s+ce|en\s+direct\s*[:\-]|à\s+la\s+une\s*[:\-])\b/;
    return 1 if $t =~ /\b(?:latest\s+news|live\s+updates?|breaking\s+news\s+live|top\s+stories)\b/;
    return 1 if $t =~ /\b(?:últimas\s+noticias|noticias\s+de\s+hoy|en\s+directo\s*[:\-])\b/;
    return 0;
}

sub _news_select_press_articles {
    my ($articles, $now, %opt) = @_;
    $now ||= time();
    my $max_age_s = $opt{max_age_s};
    $max_age_s = 36 * 3600 unless defined $max_age_s;
    my $limit = $opt{limit} || $MAX_ARTICLES;

    my (@out, %seen_source, %seen_url);
    for my $a (@{ $articles || [] }) {
        next unless ref $a eq 'HASH';
        next unless defined $a->{epoch};  # visible dates must be provable
        my $age_s = $now - $a->{epoch};
        next if $age_s < -3 * 3600;       # reject implausible future dates
        next if $age_s > $max_age_s;
        next if _news_press_title_is_generic($a->{title});

        my $url = $a->{url} // '';
        next unless length $url && !$seen_url{$url}++;
        my $src = lc($a->{source} || $a->{domain} || '');
        next if length($src) && $seen_source{$src}++;

        push @out, $a;
        last if @out >= $limit;
    }
    return \@out;
}

sub _news_fetch_google_articles {
    my ($http, $lang, $query, $is_default, $now) = @_;
    return [] unless $http;
    $now ||= time();

    # The default command uses the localized Top Stories feed and a tight
    # freshness window. A topic search starts at 1 day and widens to 3/7 days
    # only if it cannot produce enough precise, dated articles.
    my @windows = $is_default ? (0) : (0 .. 2);
    my $best = [];
    for my $window (@windows) {
        my $url = _news_google_rss_url($lang, $query, $is_default, $window);
        my $res = eval { $http->get($url) } || { success => 0 };
        next unless $res->{success};

        my $raw = _news_parse_google_rss($res->{content} // '', $PRESS_SCAN_LIMIT);
        my $max_age_s = $is_default
            ? $PRESS_DEFAULT_MAX_AGE_HOURS * 3600
            : (1, 3, $PRESS_TOPIC_MAX_AGE_DAYS)[$window] * 86400;
        my $sel = _news_select_press_articles($raw, $now,
            max_age_s => $max_age_s, limit => $MAX_ARTICLES);
        $best = $sel if @$sel > @$best;
        last if @$sel >= $MIN_FRESH;
    }
    return $best;
}

sub _utf8_bytes {
    my ($s) = @_;
    $s = '' unless defined $s;
    require Encode;
    return length(Encode::encode('UTF-8', $s));
}

sub _cap_bytes {
    my ($s, $max) = @_;
    $s = '' unless defined $s;
    $s =~ s/\s+/ /g;
    $s =~ s/^\s+|\s+$//g;
    return $s if _utf8_bytes($s) <= $max;
    my $cut = length($s);
    while ($cut > 0) {
        my $trial = substr($s, 0, $cut) . "…";
        return $trial if _utf8_bytes($trial) <= $max;
        $cut--;
    }
    return "…";
}

sub _news_shorten_url {
    my ($http, $url) = @_;
    return '' unless defined $url && length $url;
    return $url unless $url =~ m{\Ahttps?://}i;
    return $url if $url =~ m{\Ahttps?://tinyurl\.com/}i;
    return $url unless $http;
    my $tiny = 'https://tinyurl.com/api-create.php?url=' . uri_escape_utf8($url);
    my $res = eval { $http->get($tiny) } || { success => 0 };
    return $url unless $res->{success};
    my $short = $res->{content} // '';
    $short =~ s/^\s+|\s+$//g;
    return $short =~ m{\Ahttps?://tinyurl\.com/\S+\z}i ? $short : $url;
}

sub _news_article_segments {
    my ($picked, $shortener) = @_;

    # Prefer three different publishers when Tavily gives enough variety;
    # if not, fill the remaining slots with additional articles.
    my (@primary, @same_domain, %seen_domain, %seen_url);
    for my $r (@{ $picked || [] }) {
        next unless ref $r eq 'HASH';
        my $title = $r->{title} // '';
        my $url   = $r->{url} // '';
        next unless length($title) && $url =~ m{\Ahttps?://}i;
        next if $seen_url{$url}++;
        my $publisher = $r->{source} || $r->{domain} || _domain_of($url) || 'source';
        my $publisher_key = lc $publisher;
        if (!$seen_domain{$publisher_key}++) { push @primary, $r }
        else                                 { push @same_domain, $r }
    }

    my @segments;
    for my $r (@primary, @same_domain) {
        last if @segments >= 3;
        my $title = $r->{title} // '';
        my $when = defined $r->{epoch} ? strftime('%d/%m', gmtime($r->{epoch})) : '?';
        my $publisher = $r->{source} || $r->{domain} || _domain_of($r->{url}) || 'source';
        my $url  = $r->{url} // '';
        my $short = $url;
        if ($shortener && ref($shortener) eq 'CODE') {
            $short = eval { $shortener->($url) } || $url;
        }

        # Same charter as news_teuk.tcl: date/source grey, orange separators,
        # blue underlined clickable URL. No decorative brackets: preserve IRC
        # bytes for the useful title/link payload.
        my $prefix = "\x0314$when $publisher\x03";
        my $link   = "\x1f\x0312$short\x0f";
        my $overhead = _utf8_bytes($prefix . '  ' . $link);
        my $tmax = 400 - $overhead;
        $tmax = 40 if $tmax < 40;
        my $seg = $prefix . ' ' . _cap_bytes($title, $tmax) . ' ' . $link;
        push @segments, $seg;
    }
    return \@segments;
}

sub _news_article_lines {
    my ($segments, $max_bytes) = @_;
    $max_bytes ||= 400;
    my $sep = " 07| ";
    my @lines;
    my ($cur, $curb) = ('', 0);
    for my $seg (@{ $segments || [] }) {
        next unless defined $seg && length $seg;
        my $segb = _utf8_bytes($seg);
        if (!length $cur) {
            $cur = $seg;
            $curb = $segb;
            next;
        }
        if ($curb + _utf8_bytes($sep) + $segb <= $max_bytes) {
            $cur .= $sep . $seg;
            $curb += _utf8_bytes($sep) + $segb;
        }
        else {
            push @lines, $cur;
            $cur = $seg;
            $curb = $segb;
        }
    }
    push @lines, $cur if length $cur;
    return \@lines;
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

    # Precise visible article list, like news_teuk.tcl: Google News RSS is
    # independent from Tavily and gives real press headlines instead of
    # generic section/homepage labels. Failure is non-fatal: Tavily articles
    # remain the deterministic fallback.
    my $rss_http = Mediabot::External::_make_http(timeout => 5, max_size => 512 * 1024);
    my $press_articles = _news_fetch_google_articles($rss_http, $lang, $query, $is_default, $now);
    my $display_articles = @$press_articles ? $press_articles : $picked;

    # Matiere pour le modele : titre, source, date, extrait.
    my @block;
    for my $r (@$picked) {
        my $when = defined $r->{epoch} ? strftime('%Y-%m-%d', gmtime($r->{epoch})) : 'n/a';
        push @block, "- $r->{title} [$r->{domain}, $when] $r->{content}";
    }
    my $lang_name = (Mediabot::External::Claude->can('ai_lang_name')
        ? Mediabot::External::Claude::ai_lang_name($lang) : 'English');
    my $prompt =
        "You are summarising news dispatches for an IRC channel. Write in $lang_name, in at most "
      . "2 lines of under 380 characters each. The PRECISE PRESS HEADLINES listed below, when "
      . "present, define the visible article selection and therefore the events you may lead with. "
      . "Keep the summary aligned with those clickable stories; do not introduce an unrelated "
      . "Tavily-only event. Use Tavily snippets only to corroborate or add concrete context to those "
      . "same events. LINE 1: the most recent and important selected development, with concrete facts "
      . "(figures, names, places). LINE 2: another selected development or useful context. Attribute "
      . "single-source claims explicitly. Invent no fact, date or source. No Markdown, no emoji, "
      . "no lists, no preamble.\n\n"
      . "Topic: $query\n\nTavily corroboration material:\n" . join("\n", @block);

    if (@$press_articles) {
        my @press = map {
            my $when = defined $_->{epoch} ? strftime('%Y-%m-%d', gmtime($_->{epoch})) : 'n/a';
            my $publisher = $_->{source} || $_->{domain} || 'source';
            "- [$when] $publisher: $_->{title}";
        } @$press_articles;
        $prompt .= "\n\nPRECISE PRESS HEADLINES — these are the clickable stories "
                 . "shown to the user; keep the synthesis on these events:\n"
                 . join("\n", @press);
    }

    my $badge = "\x0300,04" . _text($lang, 'badge') . "\x0f";
    my @lines;
    my $summary_count = 0;
    my $push_summary = sub {
        my ($line) = @_;
        return unless defined $line && $line =~ /\S/;
        $line =~ s/^\s+|\s+$//g;
        push @lines, ($summary_count++ == 0 ? "$badge $line" : $line);
    };
    my $emit = sub {
        my ($text) = @_;
        return unless defined $text && $text =~ /\S/;
        for my $line (split /\n/, $text) {
            next unless $line =~ /\S/;
            last if @lines >= 2;
            $push_summary->($line);
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
            $push_summary->("$r->{title} — $r->{domain}");
        }
    }
    # TinyURL is presentation only: keep its timeout small so three shortener
    # calls cannot consume the 45 s CommandAsync budget. Failure simply keeps
    # the original article URL.
    my $tiny_http = Mediabot::External::_make_http(timeout => 2, max_size => 4096);
    my $article_segments = _news_article_segments($display_articles,
        sub { _news_shorten_url($tiny_http, shift) });
    my $article_lines = _news_article_lines($article_segments, 400);
    if (@$article_lines) {
        push @lines, @$article_lines;
    }
    else {
        my $sources = _news_sources_line($lang, $picked);
        push @lines, "$badge $sources" if length $sources;
    }

    $say->($_) for @lines;
    return 1;
}

1;
