# t/cases/900_mb693_rss_tinyurl_display.t
# =============================================================================
# MB693 — RSS display keeps the TCL charter but presents compact TinyURL links.
# TinyURL is cosmetic: failure must preserve the original article URL.
# =============================================================================

use strict;
use warnings;
use utf8;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }

use Mediabot::RSS qw(format_rss_announcement);
use Mediabot::RSS::TinyURL qw(shorten_url make_shortener);

{
    package FakeTiny900;
    sub new { bless { @_ }, shift }
    sub get {
        my ($self, $url) = @_;
        $self->{seen} = $url;
        return $self->{response};
    }
}

return sub {
    my ($assert) = @_;

    my $long = 'https://korben.info/article?utm_source=rss&utm_medium=feed';
    my $http = bless {
        response => {
            success => 1,
            status  => 200,
            content => "https://tinyurl.com/mb693rss\n",
        },
    }, 'FakeTiny900';

    my $short = shorten_url($long, http => $http);
    $assert->is(
        $short,
        'https://tinyurl.com/mb693rss',
        'mb693-900: TinyURL response becomes the RSS presentation URL',
    );
    $assert->like(
        $http->{seen},
        qr{\Ahttps://tinyurl\.com/api-create\.php\?url=https%3A%2F%2Fkorben\.info%2Farticle%3Futm_source%3Drss%26utm_medium%3Dfeed\z},
        'mb693-900: original article URL is safely escaped for TinyURL',
    );

    $assert->is(
        format_rss_announcement(
            label => 'Les news de Korben',
            title => 'Un titre accentué',
            url   => $short,
        ),
        "\001ACTION - news \002:\002 \00313[Les news de Korben]\0036 Un titre accentué \00313\002-\002\00314 https://tinyurl.com/mb693rss\001",
        'mb693-900: exact RSS IRC charter is preserved with the short link',
    );

    my $failed = bless {
        response => { success => 0, status => 503, content => '' },
    }, 'FakeTiny900';
    $assert->is(
        shorten_url($long, http => $failed),
        $long,
        'mb693-900: TinyURL failure falls back to the original article URL',
    );

    my $garbage = bless {
        response => { success => 1, status => 200, content => 'https://evil.example/x' },
    }, 'FakeTiny900';
    $assert->is(
        shorten_url($long, http => $garbage),
        $long,
        'mb693-900: non-TinyURL API content is rejected',
    );

    $assert->is(
        shorten_url('https://tinyurl.com/already-short', http => $http),
        'https://tinyurl.com/already-short',
        'mb693-900: existing HTTPS TinyURL is not shortened again',
    );

    my $shared = bless {
        response => { success => 1, status => 200, content => 'https://tinyurl.com/shared' },
    }, 'FakeTiny900';
    my $shortener = make_shortener(http => $shared);
    $assert->is($shortener->('https://example.org/a'), 'https://tinyurl.com/shared',
        'mb693-900: reusable worker shortener returns compact URL');
    $assert->is($shortener->('https://example.org/b'), 'https://tinyurl.com/shared',
        'mb693-900: reusable worker shortener keeps the same HTTP client');

    my $cmd = do {
        open my $fh, '<:encoding(UTF-8)', 'Mediabot/RSS/Commands.pm' or die $!;
        local $/;
        <$fh>;
    };
    $assert->like($cmd, qr/use Mediabot::RSS::TinyURL qw\(make_shortener\);/,
        'mb693-900: RSS commands use the dedicated presentation shortener');
    $assert->like($cmd, qr/sub _probe_worker .*?make_shortener\(\).*?format_rss_announcement/s,
        'mb693-900: probe shortens before preserving the formatter charter');
    $assert->like($cmd, qr/sub _show_worker .*?my \$shorten = make_shortener\(\);.*?for my \$it/s,
        'mb693-900: show reuses one TinyURL client across displayed items');

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
};
