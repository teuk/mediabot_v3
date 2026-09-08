# t/cases/900_mb693_rss_tinyurl_display.t
# =============================================================================
# MB693/MB730 — RSS display keeps the TCL charter and uses only TinyURL's
# authenticated API. Missing credentials, failure or destination mismatch must
# preserve the original article URL.
# =============================================================================

use strict;
use warnings;
use utf8;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }

use Mediabot::RSS qw(format_rss_announcement);
use Mediabot::RSS::TinyURL qw(shorten_url make_shortener);

{
    package FakeTiny900;
    sub new { my ($class, %args) = @_; bless { calls => [], %args }, $class }
    sub request {
        my ($self, $method, $endpoint, $opts) = @_;
        push @{ $self->{calls} }, [$method, $endpoint, $opts];
        return $self->{response} if $self->{response};

        my $payload = eval { JSON::PP->new->utf8->decode($opts->{content} // '') } || {};
        my $url = $payload->{url} // '';
        my $alias = $self->{aliases}{$url};
        return { success => 0, status => 503, content => '' }
            unless defined $alias;
        return {
            success => 1,
            status  => 200,
            content => JSON::PP->new->utf8->encode({
                data => { url => $url, tiny_url => "https://tinyurl.com/$alias" },
            }),
        };
    }
}

return sub {
    my ($assert) = @_;

    my $long = 'https://korben.info/article?utm_source=rss&utm_medium=feed';
    my $key = 'mb730-test-token-123456789';
    my $http = FakeTiny900->new(
        response => {
            success => 1,
            status  => 200,
            content => JSON::PP->new->utf8->encode({
                data => {
                    url      => $long,
                    tiny_url => 'https://tinyurl.com/mb730rss',
                },
            }),
        },
    );

    my $short = shorten_url($long, http => $http, api_key => $key);
    $assert->is(
        $short,
        'https://tinyurl.com/mb730rss',
        'mb730-900: authenticated TinyURL response becomes the RSS presentation URL',
    );
    $assert->is($http->{calls}[0][0], 'POST',
        'mb730-900: modern TinyURL API uses POST');
    $assert->is($http->{calls}[0][1], 'https://api.tinyurl.com/create',
        'mb730-900: modern TinyURL endpoint is exact');
    $assert->is($http->{calls}[0][2]{headers}{Authorization}, "Bearer $key",
        'mb730-900: API token is carried only in the authorization header');
    my $sent = JSON::PP->new->utf8->decode($http->{calls}[0][2]{content});
    $assert->is($sent->{url}, $long,
        'mb730-900: original article URL is bound in the JSON request');
    $assert->is($sent->{domain}, 'tinyurl.com',
        'mb730-900: requested short-link domain is explicit');

    my $unconfigured = FakeTiny900->new(response => { success => 1 });
    $assert->is(
        shorten_url($long, http => $unconfigured),
        $long,
        'mb730-900: missing API key fails closed to the original URL',
    );
    $assert->is(scalar @{ $unconfigured->{calls} }, 0,
        'mb730-900: missing API key performs no HTTP request');

    $assert->is(
        format_rss_announcement(
            label => 'Les news de Korben',
            title => 'Un titre accentué',
            url   => $short,
        ),
        "\001ACTION - news \002:\002 \00313[Les news de Korben]\0036 Un titre accentué \00313\002-\002\00314 https://tinyurl.com/mb730rss\001",
        'mb693-900: exact RSS IRC charter is preserved with the short link',
    );

    my $failed = FakeTiny900->new(
        response => { success => 0, status => 503, content => '' },
    );
    $assert->is(
        shorten_url($long, http => $failed, api_key => $key),
        $long,
        'mb730-900: TinyURL failure falls back to the original article URL',
    );

    my $garbage = FakeTiny900->new(
        response => { success => 1, status => 200, content => '{broken' },
    );
    $assert->is(
        shorten_url($long, http => $garbage, api_key => $key),
        $long,
        'mb730-900: malformed API JSON is rejected',
    );

    my $mismatch = FakeTiny900->new(
        response => {
            success => 1,
            status  => 200,
            content => JSON::PP->new->utf8->encode({
                data => {
                    url      => 'https://unrelated.example/wrong',
                    tiny_url => 'https://tinyurl.com/29b5h4p4',
                },
            }),
        },
    );
    $assert->is(
        shorten_url($long, http => $mismatch, api_key => $key),
        $long,
        'mb730-900: valid-looking alias for another destination is rejected',
    );

    $assert->is(
        shorten_url('https://tinyurl.com/already-short', http => $http, api_key => $key),
        'https://tinyurl.com/already-short',
        'mb693-900: existing HTTPS TinyURL is not shortened again',
    );

    my $shared = FakeTiny900->new(aliases => {
        'https://example.org/a' => 'article-a',
        'https://example.org/b' => 'article-b',
    });
    my $shortener = make_shortener(http => $shared, api_key => $key);
    $assert->is($shortener->('https://example.org/a'), 'https://tinyurl.com/article-a',
        'mb730-900: first article keeps its own compact URL');
    $assert->is($shortener->('https://example.org/b'), 'https://tinyurl.com/article-b',
        'mb730-900: second article cannot reuse the first compact URL');
    $assert->is(scalar @{ $shared->{calls} }, 2,
        'mb730-900: reusable worker client still performs one bound request per article');

    my $passthrough = make_shortener();
    $assert->is($passthrough->('https://example.org/no-token'),
        'https://example.org/no-token',
        'mb730-900: unconfigured worker shortener is a pure pass-through');

    my $cmd = do {
        open my $fh, '<:encoding(UTF-8)', 'Mediabot/RSS/Commands.pm' or die $!;
        local $/;
        <$fh>;
    };
    $assert->like($cmd, qr/use Mediabot::RSS::TinyURL qw\(make_shortener\);/,
        'mb693-900: RSS commands use the dedicated presentation shortener');
    $assert->like($cmd, qr/sub _probe_worker .*?make_shortener\(api_key => _tinyurl_api_key\(\$ctx->bot\)\).*?format_rss_announcement/s,
        'mb730-900: probe uses the configured authenticated shortener');
    $assert->like($cmd, qr/sub _show_worker .*?my \$shorten = make_shortener\(api_key => _tinyurl_api_key\(\$ctx->bot\)\);.*?for my \$it/s,
        'mb730-900: show reuses one authenticated TinyURL client across displayed items');

    my $tiny = do {
        open my $fh, '<:encoding(UTF-8)', 'Mediabot/RSS/TinyURL.pm' or die $!;
        local $/;
        <$fh>;
    };
    $assert->like($tiny, qr/timeout\s*=>\s*2/,
        'mb693-900: TinyURL timeout stays short for async budget');
    $assert->like($tiny, qr/max_size\s*=>\s*4096/,
        'mb693-900: TinyURL response is tightly bounded');
    $assert->like($tiny, qr/verify_SSL\s*=>\s*1/,
        'mb693-900: TinyURL TLS verification remains enabled');
    $assert->like($tiny, qr{https://api\.tinyurl\.com/create},
        'mb730-900: modern authenticated endpoint is locked');
    $assert->unlike($tiny, qr/api-create\.php/,
        'mb730-900: retired anonymous endpoint is absent');
};
