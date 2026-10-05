package Mediabot::External::News;

# MB815: one evidence set for an IRC bulletin and its links. Fetch selected
# dated press headlines first, enrich those exact articles when possible, and
# execute the stateless AI request synchronously INSIDE the existing worker.
# No nested async callback, no public waiting line and no conversation history.

use strict;
use warnings;
use utf8;
use Exporter 'import';
use JSON::PP ();
use POSIX qw(strftime);
use URI::Escape qw(uri_escape_utf8);
use Time::HiRes ();
use Mediabot::External::NewsBulletin qw(clean_text safe_url story_overlap
    matching_excerpt bulletin_prompt parse_summary summary_fallback);
use Mediabot::URLShortener qw(make_bot_shortener format_event);

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
    require Time::Local;
    my ($y, $m, $d, $h, $min, $sec, $zone);
    if ($raw =~ /\A(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(Z|[+-]\d{2}:?\d{2}))?\z/) {
        ($y, $m, $d, $h, $min, $sec, $zone) = ($1, $2, $3, $4, $5, $6, $7);
        # A calendar-only date starts at midnight for freshness comparison.
        # Assigning noon can wrongly classify this morning's article as future.
        ($h, $min, $sec, $zone) = (0, 0, 0, 'Z') unless defined $h;
        $m--;
    }
    elsif ($raw =~ /\A(?:[A-Za-z]{3},\s*)?(\d{1,2})\s+([A-Za-z]{3})\s+(\d{4})\s+(\d{2}):(\d{2}):(\d{2})\s+(GMT|UTC|[+-]\d{4})\z/) {
        my %mon = (Jan=>0,Feb=>1,Mar=>2,Apr=>3,May=>4,Jun=>5,
                   Jul=>6,Aug=>7,Sep=>8,Oct=>9,Nov=>10,Dec=>11);
        return undef unless exists $mon{ucfirst lc $2};
        ($d, $m, $y, $h, $min, $sec, $zone) = ($1, $mon{ucfirst lc $2}, $3, $4, $5, $6, $7);
    }
    else { return undef }
    return undef if $y < 2000 || $y > 2100;
    my $epoch = eval { Time::Local::timegm($sec, $min, $h, $d, $m, $y) };
    return undef unless defined $epoch;
    if ($zone =~ /\A([+-])(\d{2}):?(\d{2})\z/) {
        return undef if $2 > 23 || $3 > 59;
        $epoch -= ($1 eq '+' ? 1 : -1) * ($2 * 3600 + $3 * 60);
    }
    return $epoch;
}

# Dated, specific articles only: stale or undated pages cannot become news.
sub _news_select_results {
    my ($results, $now) = @_;
    $now ||= time();
    my @clean;
    for my $r (@{ $results || [] }) {
        next unless ref $r eq 'HASH';
        my $title = $r->{title};
        next unless defined $title && length $title;
        my $epoch = _epoch_of($r->{published_date});
        # Clock-skew tolerance is for timestamps, not tomorrow's calendar date.
        next if defined $epoch && $r->{published_date} =~ /\A\d{4}-\d{2}-\d{2}\z/
            && $epoch > $now;
        push @clean, {
            title   => clean_text($title, 500),
            url     => $r->{url} // '',
            domain  => _domain_of($r->{url}),
            content => clean_text($r->{content}, 1800),
            epoch   => $epoch,
            age_d   => defined $epoch ? int(($now - $epoch) / 86400) : undef,
        };
    }
    @clean = sort {
        ( defined $b->{epoch} ? $b->{epoch} : 0 )
            <=> ( defined $a->{epoch} ? $a->{epoch} : 0 )
    } @clean;
    # Undated and old results do not become current news through fallback.
    my @fresh = grep { defined $_->{epoch} && $_->{epoch} <= $now + 3 * 3600
        && $now - $_->{epoch} <= $MAX_AGE_DAYS * 86400
        && safe_url($_->{url}) && !_news_press_title_is_generic($_->{title}) } @clean;
    return \@fresh;
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
    my ($body, $limit, %opt) = @_;
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
        my ($source_url) = $item =~ m{<source\b[^>]*\burl=["']([^"']+)["']}si;
        next unless defined $title && defined $link;

        for ($title, $link, $pubdate, $source) {
            next unless defined $_;
            s/^\s*<!\[CDATA\[(.*?)\]\]>\s*$/$1/s;
            $_ = _xml_unescape($_);
            s/<[^>]+>/ /g;
            s/\s+/ /g;
            s/^\s+|\s+$//g;
        }
        next unless length($title) && safe_url($link);
        next if _news_press_title_is_generic($title);
        next if $seen_url{$link}++;

        # Google News appends " - Publisher" to the title even though the
        # publisher is already available in <source>. Keep the useful part.
        if (defined $source && length $source) {
            $title =~ s/\s+-\s+\Q$source\E\s*\z//i;
            my $sk = lc $source;
            next if !$opt{all_candidates} && $seen_source{$sk}++;
        }

        my $epoch = _epoch_of($pubdate);
        push @articles, {
            title  => $title,
            url    => $link,
            source => (defined $source && length $source) ? $source : 'source',
            domain => _domain_of($link),
            source_domain => safe_url(_xml_unescape($source_url))
                ? _domain_of(_xml_unescape($source_url)) : '',
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
    return 1 if $t =~ /(?:l[’']info\s+du\s+jour|brief\s+quotidien|journaux?\s+d[’']information)/;
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
        my $domain = _domain_of($url);
        next if grep { $domain eq $_ || $domain =~ /\.\Q$_\E\z/ } @NOISE_DOMAINS;
        next unless safe_url($url) && !$seen_url{$url}++;
        next if grep { my ($ratio, $common) = story_overlap($_->{title}, $a->{title});
            $ratio >= 0.70 && $common >= 3 } @out;
        my $src = lc($a->{source} || $a->{domain} || '');
        next if length($src) && $seen_source{$src}++;

        push @out, { %$a, title => clean_text($a->{title}, 500),
            source => clean_text($a->{source} || $a->{domain}, 80) };
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

        my $raw = _news_parse_google_rss($res->{content} // '', $PRESS_SCAN_LIMIT, all_candidates => 1);
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

sub _news_shorturl_event {
    my ($self, $event) = @_;
    return unless ref($event) eq 'HASH';
    my $logger = $self->{logger};
    return unless $logger && eval { $logger->can('log') };
    my $level = int($event->{level} // 1);
    $level = 0 if $level < 0;
    $level = 4 if $level > 4;
    eval { $logger->log($level, format_event($event)); 1 };
    return;
}

sub _news_title_excerpt {
    my ($title, $max_bytes) = @_;
    $max_bytes = 64 unless defined $max_bytes;
    return '' if $max_bytes < 8;
    $title = clean_text($title, 500);
    return $title if _utf8_bytes($title) <= $max_bytes;
    my $excerpt = '';
    for my $word (split /\s+/, $title) {
        my $candidate = length($excerpt) ? "$excerpt $word" : $word;
        last if _utf8_bytes($candidate . '…') > $max_bytes;
        $excerpt = $candidate;
    }
    return length($excerpt) ? $excerpt . '…' : _cap_bytes($title, $max_bytes);
}

sub _news_article_segments {
    my ($picked, $shortener, %opt) = @_;

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
        if ($opt{compact}) {
            # A short, word-boundary title hint identifies each exact source.
            # Spend at most 64 UTF-8 bytes; the URL always remains complete.
            my $space = 370 - _utf8_bytes($prefix . '  ' . $link);
            my $hint = _news_title_excerpt($title, $space < 64 ? $space : 64);
            if (_utf8_bytes($prefix . ' ' . $link) <= 370) {
                push @segments, $prefix . ' ' . (length($hint) ? "$hint " : '') . $link;
            }
            else {
                # Oversized original URLs are omitted rather than clipped.
                push @segments, $prefix . ' ' . _news_title_excerpt($title, 64);
            }
            next;
        }
        my $overhead = _utf8_bytes($prefix . '  ' . $link);
        my $tmax = 370 - $overhead;
        if ($tmax < 20) {
            # Never emit a clipped URL. The source/title remain useful when
            # the original URL cannot fit a single IRC payload.
            push @segments, $prefix . ' ' . _cap_bytes($title, 300);
            next;
        }
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

sub _news_tavily {
    my ($api_key, $params, $deadline, $self) = @_;
    my $timeout = int($deadline - Time::HiRes::time() - 14);
    return undef if $timeout < 1;
    $timeout = 4 if $timeout > 4;
    my $http = Mediabot::External::_make_http(timeout => $timeout,
        verify_SSL => 1, max_redirect => 0, max_size => 512 * 1024);
    my $payload = eval { JSON::PP->new->utf8->canonical->encode({ %$params, api_key => $api_key }) };
    return undef unless defined $payload;
    my $res = eval { $http->request('POST', $TAVILY_URL, {
        headers => { 'Content-Type' => 'application/json' }, content => $payload,
    }) };
    unless (ref($res) eq 'HASH' && $res->{success}) {
        eval { $self->{logger}->log(2, 'news: discovery/enrichment unavailable') };
        return undef;
    }
    my $data = eval { JSON::PP->new->utf8->decode($res->{content} || '') };
    return undef unless ref($data) eq 'HASH' && ref($data->{results}) eq 'ARRAY';
    return $data;
}

sub _news_synthesis_log {
    my ($self, $code, $provider, $attempt, $status) = @_;
    $code = 'unavailable' unless defined($code) && $code =~ /\A[a-z_]{1,32}\z/;
    $provider = 'none' unless defined($provider) && $provider =~ /\A(?:anthropic|openai|gemini)\z/;
    $attempt = $attempt && $attempt == 2 ? 2 : 1;
    my $http = defined($status) && !ref($status) && "$status" =~ /\A[1-5]\d\d\z/
        ? " status=$status" : '';
    eval { $self->{logger}->log(2, "news: synthesis code=$code provider=$provider attempt=$attempt$http") };
    return;
}

sub _news_synthesize {
    my ($self, $system, $prompt, $articles, $deadline) = @_;
    require Mediabot::AI::Client;
    my $timeout = int($deadline - Time::HiRes::time() - 7);
    if ($timeout < 1) {
        _news_synthesis_log($self, 'budget_exhausted');
        return undef;
    }
    $timeout = 12 if $timeout > 12;
    # Choose one configured provider; do not stack provider/model timeout
    # retries until the enclosing command worker kills the whole bulletin.
    my ($provider) = grep {
        my $key = eval { $self->{conf}->get("$_.API_KEY") };
        defined($key) && !ref($key) && length($key)
    } qw(anthropic openai gemini);
    unless ($provider) {
        _news_synthesis_log($self, 'not_configured');
        return undef;
    }
    my $client = Mediabot::AI::Client->new(conf => $self->{conf},
        http_factory => sub {
            my %opt = @_;
            my $left = int($deadline - Time::HiRes::time() - 7);
            die "news time budget exhausted\n" if $left < 1;
            $opt{timeout} = $left if $left < $opt{timeout};
            $opt{max_redirect} = 0;
            return Mediabot::External::_make_http(%opt);
        });
    my $request_prompt = $prompt;
    for my $attempt (1 .. 2) {
        $timeout = int($deadline - Time::HiRes::time() - 7);
        if ($timeout < ($attempt == 2 ? 5 : 1)) {
            _news_synthesis_log($self, 'budget_exhausted', $provider, $attempt);
            last;
        }
        $timeout = 12 if $timeout > 12;
        my $result = eval { $client->execute({ provider => $provider, purpose => 'news.bulletin',
            system => $system, messages => [{ role => 'user', content => $request_prompt }],
            temperature => 0.1, max_output_tokens => 600, timeout_seconds => $timeout,
        }) };
        unless (ref($result) eq 'HASH' && $result->{ok}) {
            my %codes = (http_error => 'provider_http_error', parse_error => 'provider_parse_error',
                invalid_request => 'invalid_request', not_configured => 'not_configured');
            my $code = ref($result) eq 'HASH' && !ref($result->{error})
                ? ($codes{$result->{error} || ''} || 'provider_failure') : 'provider_failure';
            _news_synthesis_log($self, $code, $provider, $attempt,
                ref($result) eq 'HASH' ? $result->{status} : undef);
            last; # Do not retry an outage or consume the reserved link budget.
        }
        my $reason = 'answer_shape';
        my $briefs = parse_summary($result->{answer}, $articles, sub { $reason = $_[0] });
        if ($briefs) {
            _news_synthesis_log($self, 'repaired', $provider, $attempt) if $attempt == 2;
            return $briefs;
        }
        _news_synthesis_log($self, $reason, $provider, $attempt);
        # One bounded fresh request may repair a rejected shape/length. It
        # receives the same evidence, never the rejected response or history.
        $request_prompt = $prompt . "\nEDITORIAL CORRECTION ($reason): "
            . 'Return exactly the summary JSON schema. Cover every supplied id once in order. '
            . 'Use short factual sentences, aiming for 320 UTF-8 bytes total; '
            . 'keep numbers and qualifications from the cited evidence, without URLs or numbering.';
    }
    return undef;
}

sub _news_summary_lines {
    my ($sections, $badge) = @_;
    my @words = split /\s+/, join(' ', @$sections);
    my @lines;
    my $line = "$badge ";
    for my $word (@words) {
        # Provider text already has a word limit. Bound malformed headline
        # tokens too, so an extractive fallback cannot exceed an IRC payload.
        $word = _cap_bytes($word, 380) if _utf8_bytes($word) > 380;
        my $candidate = $line . ($line =~ /\s\z/ ? '' : ' ') . $word;
        if (_utf8_bytes($candidate) > 400) {
            push @lines, $line;
            $line = $word;
        }
        else { $line = $candidate }
    }
    push @lines, $line if length $line;
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

    my $api_key = eval { $self->{conf}->get('tavily.API_KEY') } || '';
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

    my $deadline = Time::HiRes::time() + 34;
    my $rss_http = Mediabot::External::_make_http(timeout => 3, max_size => 512 * 1024, verify_SSL => 1, max_redirect => 0);
    my $press_articles = _news_fetch_google_articles($rss_http, $lang, $query, $is_default, $now);
    my $picked = [];
    if (!@$press_articles && length($api_key) && !ref($api_key)) {
        # Discovery fallback only: precise, dated results, never homepages or
        # undated pages dressed up as today's news. At most two short calls.
        for my $window (0 .. 1) {
            my ($params) = _news_search_params($lang, $query, $window);
            my $data = _news_tavily($api_key, $params, $deadline, $self);
            next unless $data;
            my $sel = _news_select_results($data->{results}, $now);
            my $candidate = _news_select_press_articles($sel, $now,
                max_age_s => ($is_default ? 36 * 3600 : 7 * 86400));
            $picked = $candidate if @$candidate > @$picked;
            last if @$picked >= $MIN_FRESH;
        }
    }
    my $display_articles = @$press_articles ? $press_articles : $picked;
    unless (@$display_articles) {
        $say->($lang eq 'fr' ? 'Aucun article récent et suffisamment précis disponible pour ce bulletin.'
            : $lang eq 'es' ? 'No hay artículos recientes y suficientemente concretos para este boletín.'
            : 'No sufficiently recent, specific articles are available for this bulletin.');
        return;
    }

    # Enrich only selected headlines and their own publishers. No broad,
    # unrelated Tavily briefing can replace the selected events or citations.
    if (@$press_articles && length($api_key) && !ref($api_key)) {
        for my $a (@$display_articles) {
            last if Time::HiRes::time() > $deadline - 14;
            next unless $a->{source_domain};
            my $data = _news_tavily($api_key, {
                query => clean_text($a->{title}, 300), topic => 'general',
                search_depth => 'advanced', max_results => 3,
                time_range => $is_default ? 'day' : 'week',
                include_domains => [$a->{source_domain}],
                include_answer => JSON::PP::false, include_raw_content => JSON::PP::false,
            }, $deadline, $self);
            my $match = $data ? matching_excerpt($a, $data->{results}, $now) : undef;
            if ($match) {
                $a->{content} = $match->{content};
                $a->{url} = $match->{url}; # Link the article actually used.
            }
        }
    }

    my ($system, $prompt) = bulletin_prompt($lang, $display_articles, $query, $now);
    my $briefs = _news_synthesize($self, $system, $prompt, $display_articles, $deadline);
    my @lines;
    my $badge = "\x0300,04" . _text($lang, 'badge') . "\x0f";
    $briefs ||= summary_fallback($lang, $display_articles);
    push @lines, @{_news_summary_lines($briefs, $badge)};
    # URL shortening is presentation only. The private service validates the
    # destination binding; missing credentials or any mismatch keeps the exact
    # original article URL. Unconfigured legacy installs retain MB735 TinyURL
    # compatibility until they opt in to the private endpoint.
    my $shorten = make_bot_shortener(
        bot      => $self,
        http     => Mediabot::External::_make_http(timeout => 2, max_size => 4096,
            verify_SSL => 1, max_redirect => 0),
        on_event => sub { _news_shorturl_event($self, shift) },
    );
    my $bounded_shorten = sub {
        return $_[0] if Time::HiRes::time() > $deadline - 3;
        return $shorten->($_[0]);
    };
    my $article_segments = _news_article_segments($display_articles, $bounded_shorten,
        compact => 1);
    my $article_lines = _news_article_lines($article_segments, 400);
    if (@$article_lines) {
        push @lines, @$article_lines;
    }
    else {
        my $sources = _news_sources_line($lang, $picked);
        push @lines, "$badge $sources" if length $sources;
    }

    # A complete opening paragraph followed by packed publisher links. Source
    # ids stay internal; neither the opening nor the references are numbered.
    $say->(_cap_bytes($_, 400)) for @lines;
    return 1;
}

1;
