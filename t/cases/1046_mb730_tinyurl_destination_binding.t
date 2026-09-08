# t/cases/1046_mb730_tinyurl_destination_binding.t
# =============================================================================
# MB730 — the retired anonymous TinyURL endpoint must not turn unrelated news
# into one shared link. Every runtime consumer uses the authenticated helper,
# and no token means exact original URLs with no shortening request.
# =============================================================================

use strict;
use warnings;
use utf8;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }

use Mediabot::RSS::TinyURL qw(shorten_url make_shortener);

sub _slurp_1046 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "open $path: $!";
    local $/;
    return <$fh>;
}

{
    package NeverHTTP1046;
    sub new { bless { calls => 0 }, shift }
    sub request { $_[0]{calls}++; die 'HTTP must stay disabled without a token' }
}

return sub {
    my ($assert) = @_;

    my $article_a = 'https://www.numerama.com/tech/article-a.html';
    my $article_b = 'https://www.journaldugeek.com/article-b/';
    my $http = NeverHTTP1046->new;

    $assert->is(shorten_url($article_a, http => $http), $article_a,
        'mb730-1046: unconfigured direct helper preserves article A');
    my $pass = make_shortener(http => $http);
    $assert->is($pass->($article_b), $article_b,
        'mb730-1046: unconfigured reusable helper preserves article B');
    $assert->is($http->{calls}, 0,
        'mb730-1046: no API token means no HTTP request at all');

    my $tiny = _slurp_1046('Mediabot/RSS/TinyURL.pm');
    my $runtime = _slurp_1046('Mediabot/RSS/Runtime.pm');
    my $commands = _slurp_1046('Mediabot/RSS/Commands.pm');
    my $news = _slurp_1046('Mediabot/External/News.pm');
    my $sample = _slurp_1046('mediabot.sample.conf');
    my $changelog = _slurp_1046('CHANGELOG.md');

    $assert->like($tiny, qr/our \$API = 'https:\/\/api\.tinyurl\.com\/create'/,
        'mb730-1046: helper locks the modern TinyURL create endpoint');
    $assert->like($tiny, qr/request\('POST', \$API/,
        'mb730-1046: helper uses authenticated JSON POST');
    $assert->like($tiny, qr/Authorization\s*=>\s*"Bearer \$api_key"/,
        'mb730-1046: token is sent in an authorization header');
    $assert->like($tiny, qr/\$returned_url eq \$url/,
        'mb730-1046: response destination is bound to the submitted article');
    $assert->unlike($tiny, qr{https://tinyurl\.com/api-create\.php\?url=},
        'mb730-1046: executable legacy endpoint URL is absent');

    $assert->like($runtime, qr/get\('tinyurl\.API_KEY'\).*?make_shortener\(api_key => \$api_key\)/s,
        'mb730-1046: automatic RSS polling passes the configured key');
    $assert->like($commands, qr/sub _tinyurl_api_key.*?get\('tinyurl\.API_KEY'\)/s,
        'mb730-1046: manual RSS commands read the same key');
    $assert->like($commands, qr/make_shortener\(api_key => _tinyurl_api_key\(\$ctx->bot\)\)/,
        'mb730-1046: probe and show use the authenticated helper');
    $assert->like($news, qr/use Mediabot::RSS::TinyURL qw\(shorten_url\)/,
        'mb730-1046: interactive news shares the same implementation');
    $assert->like($news, qr/get\('tinyurl\.API_KEY'\).*?_news_shorten_url\(\$tiny_http, shift, \$tiny_api_key\)/s,
        'mb730-1046: interactive news passes its configured key');

    my ($tiny_conf) = $sample =~ /^\[tinyurl\]\s*\n(.*?)(?=^\[[^\]]+\]\s*$|\z)/ms;
    $assert->ok(defined($tiny_conf),
        'mb730-1046: sample configuration has a tinyurl section');
    $assert->like($tiny_conf // '', qr/^API_KEY=$/m,
        'mb730-1046: TinyURL is safely unconfigured by default');
    $assert->unlike($tiny_conf // '', qr/^API_KEY=\S+/m,
        'mb730-1046: repository contains no TinyURL credential');
    $assert->like($changelog, qr/^### mb730 — bind every news link to its article again$/m,
        'mb730-1046: regression and operational fallback are documented in 3.5');
};
