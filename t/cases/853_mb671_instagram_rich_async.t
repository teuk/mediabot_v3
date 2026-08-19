# t/cases/853_mb671_instagram_rich_async.t
use strict;
use warnings;
use utf8;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;
use Mediabot::External::URL;

{
    package L853;
    sub new { bless { rows => [] }, shift }
    sub log { my ($self,$level,$msg)=@_; push @{ $self->{rows} }, [$level,$msg]; 1 }

    package H853;
    sub new { my ($class,$body,%opts)=@_; bless { body=>$body, %opts }, $class }
    sub get {
        my ($self,$url)=@_;
        return {
            success => exists($self->{success}) ? $self->{success} : 1,
            status  => $self->{status} // 200,
            reason  => $self->{reason} // 'OK',
            content => $self->{body} // '',
        };
    }

    package Loop853;
    sub new { bless {}, shift }
    sub add { 1 }
    sub remove { 1 }
    sub watch_process { 1 }

    package Bot853;
    sub getLoop { $_[0]->{loop} }
}

sub _strip_853 {
    my ($s)=@_;
    $s //= '';
    $s =~ s/\x03\d{0,2}(?:,\d{1,2})?|\x0f|\x02//g;
    return $s;
}

sub _slurp_853 {
    my ($p)=@_;
    open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;
    no warnings 'redefine';
    no warnings 'once';

    {
        my @cases = (
            ['https://www.instagram.com/p/ABC123/',              'post',      '📷', 'Post',      undef],
            ['https://www.instagram.com/reel/ABC123/',           'reel',      '🎬', 'Reel',      undef],
            ['https://www.instagram.com/tv/ABC123/',             'tv',        '📺', 'Video',     undef],
            ['https://www.instagram.com/stories/alice/12345/',   'story',     '📖', 'Story',     'alice'],
            ['https://www.instagram.com/stories/highlights/99/', 'highlight', '✨', 'Highlight', undef],
            ['https://www.instagram.com/nasa/',                  'profile',   '👤', 'Profile',   'nasa'],
        );
        for my $c (@cases) {
            my $info = Mediabot::External::URL::_instagram_url_info($c->[0]);
            $assert->is($info->{kind},  $c->[1], "mb671-853: type $c->[1]");
            $assert->is($info->{icon},  $c->[2], "mb671-853: icon $c->[1]");
            $assert->is($info->{label}, $c->[3], "mb671-853: label $c->[1]");
            $assert->is($info->{owner}, $c->[4], "mb671-853: owner $c->[1]") if defined $c->[4];
        }
    }

    {
        my $html = q{<html><head>
          <meta content="A &amp; B" property="og:title">
          <meta property="og:description" content="12 likes, 3 comments - alice on May 4, 2026: &quot;Hello world&quot;.">
          <meta name="twitter:description" content="twitter fallback">
          <title>Instagram</title>
        </head></html>};
        my $meta = Mediabot::External::URL::_instagram_meta_from_html($html);
        $assert->is($meta->{'og:title'}, 'A & B', 'mb671-853: og:title decoded regardless of attribute order');
        $assert->like($meta->{'og:description'} // '', qr/^12 likes, 3 comments - alice /,
            'mb671-853: og:description extracted');
        $assert->ok(!exists($meta->{title}), 'mb671-853: generic Instagram title rejected');
    }

    {
        my $desc = '55K likes, 282 comments - natgeo on April 1, 2025: "Beautiful. Breathtaking. Home. 🌍 Celebrate Earth Month.".';
        my $fetch = { ok => 1, status => 200, meta => { 'og:description' => $desc } };
        my $info = Mediabot::External::URL::_instagram_url_info('https://www.instagram.com/reel/DH56yy7p3lZ/');
        my $line = Mediabot::External::URL::_instagram_build_display($info, $fetch);
        $assert->like($line, qr/^🎬 Reel · \@natgeo · ❤️ 55K · 💬 282 · 📅 April 1, 2025 · /,
            'mb671-853: Reel rich header contains type/author/stats/date');
        $assert->like($line, qr/Beautiful\. Breathtaking\. Home\. 🌍/,
            'mb671-853: Reel keeps caption');
    }

    {
        my $story_info = Mediabot::External::URL::_instagram_url_info(
            'https://www.instagram.com/stories/natgeo/9999999999999999999/'
        );
        my $story_fetch = {
            ok => 1,
            status => 200,
            meta => {
                'og:title' => 'Watch this story by National Geographic on Instagram before it disappears.',
                'og:description' => '283M Followers, 195 Following, 0 Posts',
                description => '283M Followers, 195 Following, 0 Posts',
                title => 'Watch this story by National Geographic on Instagram before it disappears.',
            },
        };
        my $story_line = Mediabot::External::URL::_instagram_build_display(
            $story_info, $story_fetch
        );
        $assert->is(
            $story_line,
            '📖 Story · @natgeo · public details unavailable',
            'mb671-853: generic Story viewer shell is not misreported as story content'
        );

        my $real_story_fetch = {
            ok => 1,
            status => 200,
            meta => {
                'og:title' => 'Watch this story by Alice on Instagram before it disappears.',
                'og:description' => 'Behind the scenes from tonight.',
            },
        };
        my $real_story_line = Mediabot::External::URL::_instagram_build_display(
            Mediabot::External::URL::_instagram_url_info(
                'https://www.instagram.com/stories/alice/12345/'
            ),
            $real_story_fetch
        );
        $assert->like(
            $real_story_line,
            qr/^📖 Story · \@alice · Watch this story by Alice .* · Behind the scenes from tonight\.$/,
            'mb671-853: Story with useful metadata is preserved'
        );
    }

    {
        my $info = Mediabot::External::URL::_instagram_url_info(
            'https://www.instagram.com/p/DcA9SsWtiNIOyeLRbzqL5B4O9moN4Wep6znlII0/'
        );
        my $line = Mediabot::External::URL::_instagram_build_display($info, { ok => 1, status => 200, meta => {} });
        $assert->is($line, '📷 Post · public details unavailable',
            'mb671-853: inaccessible post gets honest deterministic fallback');

        my $profile = Mediabot::External::URL::_instagram_build_display(
            Mediabot::External::URL::_instagram_url_info('https://www.instagram.com/nasa/'),
            { ok => 0, meta => {} },
        );
        $assert->is($profile, '👤 Profile · @nasa',
            'mb671-853: profile fallback still exposes URL owner');
    }

    {
        my $html = q{<meta property="og:description" content="55K likes, 282 comments - natgeo on April 1, 2025: &quot;Penguins.&quot;.">};
        my $http_calls = 0;
        my $chromium_calls = 0;
        my %worker;
        my @sent;

        local *Mediabot::External::_make_http = sub { $http_calls++; H853->new($html) };
        local *Mediabot::External::URL::_fetch_url_chromium_dumpdom = sub { $chromium_calls++; return '<title>SHOULD NOT RUN</title>'; };
        local *Mediabot::Helpers::botPrivmsg = sub { push @sent, $_[2]; 1 };
        local *Mediabot::Helpers::truncate_utf8 = sub { return $_[1] >= length($_[0] // '') ? ($_[0] // '') : substr(($_[0] // ''), 0, $_[1]); };
        local *Mediabot::AsyncWorker::start = sub {
            my ($class,%args)=@_;
            %worker = %args;
            return bless {}, 'Worker853';
        };

        my $self = bless { logger => L853->new, loop => Loop853->new, _instagram_cache => {} }, 'Bot853';
        my $ret = Mediabot::External::URL::_handle_instagram(
            $self, undef, 'nick', '#c', 'https://www.instagram.com/reel/DH56yy7p3lZ/'
        );
        $assert->is($ret, 1, 'mb671-853: async Instagram handler reports handled');
        $assert->is($http_calls, 0, 'mb671-853: parent event loop performs zero HTTP fetches');
        $assert->is(scalar(@sent), 0, 'mb671-853: no IRC line before worker completion');
        $assert->ok(ref($worker{child}) eq 'CODE' && ref($worker{on_done}) eq 'CODE',
            'mb671-853: AsyncWorker receives child and completion callback');

        my $value = $worker{child}->();
        $assert->is($http_calls, 1, 'mb671-853: child owns the single HTTP fetch');
        $worker{on_done}->({ ok => 1, value => $value });
        $assert->is(scalar(@sent), 1, 'mb671-853: worker completion emits one IRC line');
        $assert->is($chromium_calls, 0, 'mb671-853: Instagram never launches Chromium');

        my $clean = _strip_853($sent[0]);
        $assert->like($clean, qr/\[Instagram\] 🎬 Reel · \@natgeo · ❤️ 55K · 💬 282 · 📅 April 1, 2025/,
            'mb671-853: existing Instagram badge + rich Reel details');

        my ($after_reset) = ($sent[0] // '') =~ /\x0f\s+(.*)\z/s;
        $assert->ok(defined($after_reset), 'mb671-853: badge is followed by IRC RESET');
        $assert->unlike($after_reset // '', qr/\x03/, 'mb671-853: details have no forced IRC color (dark/light safe)');
    }

    {
        my $http_calls = 0;
        my $chromium_calls = 0;
        my @sent;
        local *Mediabot::External::_make_http = sub {
            $http_calls++;
            H853->new('<html><head><title>Instagram</title></head></html>');
        };
        local *Mediabot::External::URL::_fetch_url_chromium_dumpdom = sub { $chromium_calls++; undef };
        local *Mediabot::Helpers::botPrivmsg = sub { push @sent, $_[2]; 1 };
        local *Mediabot::Helpers::truncate_utf8 = sub { return $_[1] >= length($_[0] // '') ? ($_[0] // '') : substr(($_[0] // ''), 0, $_[1]); };

        my $self = { logger => L853->new, _instagram_cache => {} };
        my $ret = Mediabot::External::URL::_handle_instagram(
            $self, undef, 'nick', '#c',
            'https://www.instagram.com/p/DcA9SsWtiNIOyeLRbzqL5B4O9moN4Wep6znlII0/'
        );
        $assert->is($ret, 1, 'mb671-853: no-loop adapter still handles Instagram');
        $assert->is($http_calls, 1, 'mb671-853: no-loop adapter uses one HTTP request');
        $assert->is($chromium_calls, 0, 'mb671-853: no-loop path also never invokes Chromium');
        $assert->like(_strip_853($sent[0] // ''), qr/\[Instagram\] 📷 Post · public details unavailable/,
            'mb671-853: generic Instagram shell is no longer silent');
    }

    {
        my $src = _slurp_853(File::Spec->catfile('.', 'Mediabot', 'External', 'URL.pm'));
        my ($handler) = $src =~ /(sub _handle_instagram \{.*?\n\})\n\n/s; $handler //= '';
        my ($fetch)   = $src =~ /(sub _instagram_fetch_sync \{.*?\n\})\n\n/s; $fetch //= '';

        $assert->like($handler, qr/String::IRC->new\("Instagram"\)->white\('pink'\)/,
            'mb671-853: Instagram badge is unchanged');
        $assert->like($handler, qr/Mediabot::AsyncWorker->start\(/,
            'mb671-853: runtime uses shared AsyncWorker');
        $assert->unlike($handler, qr/_fetch_url_chromium_dumpdom/,
            'mb671-853: Chromium removed from Instagram handler');
        $assert->like($fetch, qr/facebookexternalhit\/1\.1/,
            'mb671-853: crawler UA retained');
        $assert->like($fetch, qr/'accept-language'\s*=>\s*'en-US/,
            'mb671-853: stable English metadata counters retained');
    }
};
