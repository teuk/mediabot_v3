# t/cases/802_mb619_news_fresh_relevant_headlines.t
# =============================================================================
# mb619 — la vitrine news doit etre fraiche ET alignee avec la synthese.
# =============================================================================
use strict;
use warnings;
use utf8;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }

return sub {
    my ($assert) = @_;
    require Mediabot::External::News;
    require Time::Local;

    my $top = Mediabot::External::News::_news_google_rss_url(
        'fr', 'actualités importantes du jour en France', 1, 0);
    $assert->like($top, qr{^https://news\.google\.com/rss\?hl=fr&gl=FR&ceid=FR:fr$},
        'mb619-802: sans sujet on utilise Top Stories FR, pas une recherche textuelle');
    $assert->unlike($top, qr{/rss/search|\?q=},
        'mb619-802: le defaut ne cherche plus les mots actualites importantes');

    my $q1 = Mediabot::External::News::_news_google_rss_url('fr', 'Colombie', 0, 0);
    my $q3 = Mediabot::External::News::_news_google_rss_url('fr', 'Colombie', 0, 1);
    my $q7 = Mediabot::External::News::_news_google_rss_url('fr', 'Colombie', 0, 2);
    $assert->like($q1, qr/Colombie%20when%3A1d/, 'mb619-802: sujet commence a 1 jour');
    $assert->like($q3, qr/Colombie%20when%3A3d/, 'mb619-802: sujet peut elargir a 3 jours');
    $assert->like($q7, qr/Colombie%20when%3A7d/, 'mb619-802: dernier palier sujet a 7 jours');

    my $now = Time::Local::timegm(0, 0, 14, 8, 7, 2026); # 08/08/2026 14:00 UTC
    my $fresh1 = Time::Local::timegm(0, 0, 12, 8, 7, 2026);
    my $fresh2 = Time::Local::timegm(0, 0, 8, 8, 7, 2026);
    my $old    = Time::Local::timegm(0, 0, 12, 17, 6, 2026);
    my $ancient= Time::Local::timegm(0, 0, 12, 1, 3, 2026);

    my $arts = [
        { title => q{Mortalité infantile : l'IGAS alerte sur la hausse en France},
          source => 'France Culture', url => 'https://g/1', epoch => $fresh1 },
        { title => q{L'actu de ce vendredi : chaleur, grève et politique},
          source => 'Liberation', url => 'https://g/2', epoch => $fresh1 },
        { title => q{Le gouvernement annonce de nouvelles mesures pour les urgences},
          source => 'Le Monde', url => 'https://g/3', epoch => $fresh2 },
        { title => q{ONU et guerre en Ukraine},
          source => 'UNRIC', url => 'https://g/4', epoch => $old },
        { title => q{Guerre au Moyen-Orient : Donald Trump doit donner des nouvelles},
          source => 'BFMTV', url => 'https://g/5', epoch => $ancient },
        { title => q{Titre sans date}, source => 'SansDate', url => 'https://g/6', epoch => undef },
    ];

    my $sel = Mediabot::External::News::_news_select_press_articles(
        $arts, $now, max_age_s => 36 * 3600, limit => 3);
    $assert->is(scalar @$sel, 2,
        'mb619-802: seuls les articles precis et recents restent');
    $assert->is($sel->[0]{source}, 'France Culture',
        'mb619-802: premier article frais conserve');
    $assert->is($sel->[1]{source}, 'Le Monde',
        'mb619-802: second article frais conserve');
    $assert->unlike(join(' ', map { $_->{source} } @$sel), qr/Liberation|UNRIC|BFMTV|SansDate/,
        'mb619-802: roundup, vieux et sans-date sont exclus');

    my $src = do {
        open my $fh, '<:encoding(UTF-8)', 'Mediabot/External/News.pm' or die $!;
        local $/; <$fh>
    };
    $assert->like($src, qr/PRESS_DEFAULT_MAX_AGE_HOURS\s*=\s*36/,
        'mb619-802: vitrine par defaut bornee a 36 heures');
    $assert->like($src, qr/_news_fetch_google_articles\(\$rss_http, \$lang, \$query, \$is_default, \$now\)/,
        'mb619-802: runtime sait si la requete est le flux par defaut');
    $assert->like($src, qr/PRECISE PRESS HEADLINES.+clickable stories/s,
        'mb619-802: le prompt ancre la synthese sur les liens affiches');
    $assert->like($src, qr/do not introduce an unrelated.+Tavily-only event/s,
        'mb619-802: un sujet Tavily sans lien visible ne peut plus parasiter le resume');
};
