# t/cases/855_mb672_applemusic_lookup_async.t
use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);
use Scalar::Util qw(refaddr);
use Mediabot::External ();
use Mediabot::External::URL ();
use Mediabot::External::AppleMusic ();

{
    package L855;
    sub new { bless {}, shift }
    sub log { 1 }

    package Loop855;
    sub new { bless {}, shift }
    sub add { 1 }
    sub remove { 1 }
    sub watch_process { 1 }

    package Bot855;
    sub getLoop { $_[0]{loop} }

    package H855;
    sub new {
        my ($class, $calls) = @_;
        bless { calls => $calls }, $class;
    }
    sub get {
        my ($self, $url) = @_;
        push @{ $self->{calls} }, $url;

        if ($url =~ m{itunes\.apple\.com/lookup\?id=309576635}) {
            return {
                success => 1,
                status  => 200,
                reason  => 'OK',
                content => q{{"resultCount":1,"results":[{"wrapperType":"track","kind":"song","trackId":309576635,"trackName":"Starrider","artistName":"Foreigner","collectionName":"Foreigner (Deluxe Version)","releaseDate":"1977-03-08T08:00:00Z","trackTimeMillis":242867}]}}
            };
        }

        return { success => 0, status => 404, reason => 'unexpected URL', content => '' };
    }
}

sub _strip_855 {
    my ($s) = @_;
    $s //= '';
    $s =~ s/\x03(?:\d{1,2}(?:,\d{1,2})?)?//g;
    $s =~ s/[\x02\x0f\x16\x1d\x1f]//g;
    return $s;
}

sub _slurp_855 {
    my ($p) = @_;
    open my $fh, '<:encoding(UTF-8)', $p or die "$p: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;
    no warnings 'redefine';
    no warnings 'once';

    # MB886: canonical owner, legacy aliases and independent load order.
    my @moved = qw(_am_duration_from_iso _am_duration_from_ms _applemusic_url_info
        _applemusic_extract_details _applemusic_lookup_track _applemusic_fetch_sync
        _handle_applemusic);
    $assert->ok(!grep({
        refaddr(Mediabot::External::URL->can($_))
            != refaddr(Mediabot::External::AppleMusic->can($_))
    } @moved), 'mb886: every historical URL entry points to the single AppleMusic owner');
    $assert->is(refaddr(Mediabot::External->can('_handle_applemusic')),
        refaddr(Mediabot::External::AppleMusic->can('_handle_applemusic')),
        'mb886: External facade imports the canonical handler');
    for my $order (
        [qw(External::AppleMusic)],
        [qw(External::URL External::AppleMusic External)],
        [qw(External External::AppleMusic External::URL)],
    ) {
        my $code = join('', map {"require Mediabot::$_;\n"} @$order);
        if (@$order == 1) {
            $code .= q{die 'URL loaded eagerly' if $INC{'Mediabot/External/URL.pm'};};
            $code .= q{die 'AI loaded eagerly' if $INC{'Mediabot/External/Claude.pm'};};
        }
        $code .= q{die 'missing pure helper' unless
            Mediabot::External::AppleMusic::_am_duration_from_ms(242867) eq '4m 02s';
            print 'loaded';};
        my $err = gensym;
        my $pid = open3(undef, my $out, $err, $^X, '-I.', '-It/lib', '-we', $code);
        my $stdout = do {local $/; <$out>} // '';
        my $stderr = do {local $/; <$err>} // '';
        waitpid($pid, 0);
        $assert->ok($? == 0 && $stdout eq 'loaded' && $stderr eq '',
            'mb886: independent import order loads quietly: ' . join('/', @$order));
    }
    my $expected_badge = "\x0300,01[\x0f\x0300,14AppleMusic\x0f\x0300,01]\x0f\x0f ";

    $assert->is(
        Mediabot::External::AppleMusic::_am_duration_from_ms(242867),
        '4m 02s',
        'mb672-855: Apple milliseconds use floor, matching displayed duration'
    );
    $assert->is(
        Mediabot::External::AppleMusic::_am_duration_from_ms(222200),
        '3m 42s',
        'mb672-855: second observed Apple duration is stable'
    );

    {
        my $self = bless { logger => L855->new }, 'Bot855';
        my $am = Mediabot::External::AppleMusic::_applemusic_extract_details(
            $self,
            q{<meta property="og:description" content="Låt · 1977 · 1 Song"/>}
        );
        $assert->ok(!defined($am->{artist}),
            'mb672-855: localized content-type label is never guessed as artist');
    }

    {
        my @http_calls;
        my @sent;
        my %worker;
        my $worker_starts = 0;

        local *Mediabot::External::_make_http = sub { H855->new(\@http_calls) };
        local *Mediabot::Helpers::botPrivmsg = sub {
            push @sent, $_[2];
            return 1;
        };
        local *Mediabot::AsyncWorker::start = sub {
            my ($class, %args) = @_;
            $worker_starts++;
            %worker = %args;
            return bless {}, 'Worker855';
        };

        my $self = bless {
            logger => L855->new,
            loop   => Loop855->new,
        }, 'Bot855';

        my $url = 'https://music.apple.com/se/album/starrider/309576627?i=309576635';
        my $ret = Mediabot::External::AppleMusic::_handle_applemusic(
            $self, undef, 'nick', '#c', $url
        );

        $assert->is($ret, 1,
            'mb672-855: async Apple Music handler reports handled');
        $assert->is(scalar(@http_calls), 0,
            'mb672-855: parent event loop performs zero Apple HTTP');
        $assert->is(scalar(@sent), 0,
            'mb672-855: no IRC output before worker completion');
        $assert->ok(ref($worker{child}) eq 'CODE' && ref($worker{on_done}) eq 'CODE',
            'mb672-855: AsyncWorker receives child and completion callbacks');

        my $value = $worker{child}->();
        $assert->is(scalar(@http_calls), 1,
            'mb672-855: track happy path uses one direct Apple lookup');
        $assert->like($http_calls[0] // '', qr{itunes\.apple\.com/lookup\?id=309576635},
            'mb672-855: exact track id is used for structured lookup');
        $assert->like($http_calls[0] // '', qr{[?&]country=SE(?:&|$)},
            'mb672-855: Apple storefront maps to lookup country');

        $worker{on_done}->({ ok => 1, value => $value });
        $assert->is(scalar(@sent), 1,
            'mb672-855: worker completion emits exactly one IRC line');

        $assert->ok(index($sent[0], "(nick) $expected_badge") == 0 && utf8::is_utf8($sent[0]),
            'mb886: actual badge preserves colors, reset bytes and Unicode line representation');

        my $clean = _strip_855($sent[0]);
        $assert->is(
            $clean,
            "(nick) [AppleMusic] Starrider - by Foreigner - album Foreigner (Deluxe Version) - 1977 - 4m 02s",
            'mb672-855: structured Apple lookup renders exact rich track line'
        );
        $assert->unlike($clean, qr/\bLåt\b/i,
            'mb672-855: Swedish content label never leaks as artist');

        my ($after_reset) = ($sent[0] // '') =~ /\x0f\s+(.*)\z/s;
        $assert->ok(defined($after_reset),
            'mb672-855: Apple Music badge is followed by IRC RESET');

        my $ret2 = Mediabot::External::AppleMusic::_handle_applemusic(
            $self, undef, 'nick2', '#c',
            'https://music.apple.com/se/album/starrider/309576627?i=309576635&l=en-GB'
        );
        $assert->is($ret2, 1,
            'mb672-855: equivalent track URL is handled from canonical cache');
        $assert->is($worker_starts, 1,
            'mb672-855: equivalent tracking/locale variant starts no second worker');
        $assert->is(scalar(@sent), 2,
            'mb672-855: canonical cache still emits IRC response');
        $assert->is($sent[1], '(nick2) ' . substr($sent[0], length('(nick) ')),
            'mb886: canonical cache preserves the complete colored badge and display');
    }

    {
        my (@calls, @sent);
        my $browser_calls = 0;
        local *Mediabot::External::_make_http = sub { H855->new(\@calls) };
        local *Mediabot::External::URL::_fetch_url_chromium_dumpdom = sub {
            $browser_calls++;
            return q{<meta property="og:title" content="Browser &amp; title"/>};
        };
        local *Mediabot::Helpers::botPrivmsg = sub { push @sent, $_[2]; return 1; };
        my $self = bless { logger => L855->new }, 'Bot855';
        my $ret = Mediabot::External::_handle_applemusic(
            $self, undef, 'nick', '#test', 'https://music.apple.com/us/playlist/example/pl.fixture');
        $assert->ok($ret == 1 && $browser_calls == 1 && @calls == 1,
            'mb886: facade fallback still resolves the dynamic URL browser hook');
        $assert->is($sent[0], "(nick) ${expected_badge}Browser & title",
            'mb886: browser fallback shares the exact badge and existing HTML decoder');
    }

    {
        my $src = _slurp_855(
            File::Spec->catfile('.', 'Mediabot', 'External', 'AppleMusic.pm')
        );
        my ($handler) = $src =~ /(sub _handle_applemusic \{.*?\n\})\n\n/s;
        $handler //= '';

        $assert->like($handler, qr/Mediabot::AsyncWorker->start\(/,
            'mb672-855: Apple Music runtime uses shared AsyncWorker');
        $assert->unlike($handler, qr/_make_http|_fetch_url_chromium_dumpdom/,
            'mb672-855: Apple Music parent handler performs no network/browser work');
        $assert->like(
            $handler,
            qr/String::IRC->new\("AppleMusic"\)->white\('grey'\)/,
            'mb672-855: Apple Music badge keeps historical colors'
        );
        $assert->like(
            $handler,
            qr/my\s+\$msg\s*=\s*"\$badge\\x0f\s+\$display";/,
            'mb672-855: Apple Music badge keeps reset/display contract'
        );
    }
};
