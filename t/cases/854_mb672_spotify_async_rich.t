# t/cases/854_mb672_spotify_async_rich.t
use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;
use Mediabot::External ();

{
    package L854;
    sub new { bless {}, shift }
    sub log { 1 }

    package Loop854;
    sub new { bless {}, shift }
    sub add { 1 }
    sub remove { 1 }
    sub watch_process { 1 }

    package Bot854;
    sub getLoop { $_[0]{loop} }

    package H854;
    sub new {
        my ($class, $calls) = @_;
        bless { calls => $calls }, $class;
    }

    sub get {
        my ($self, $url) = @_;
        push @{ $self->{calls} }, $url;

        if ($url =~ m{/oembed\?}) {
            return {
                success => 1,
                status  => 200,
                reason  => 'OK',
                content => q({"title":"Bien cordialement","author_name":null}),
            };
        }

        if ($url =~ m{/embed/track/03wI4pbnIvAzRrPcvuKs4X}) {
            return {
                success => 1,
                status  => 200,
                reason  => 'OK',
                content => q{<html><body>
<script id="__NEXT_DATA__" type="application/json">{"props":{"pageProps":{"state":{"data":{"entity":{"type":"track","name":"Bien cordialement","title":"Bien cordialement","artists":[{"name":"The Toxic Avenger"},{"name":"Simone"}],"releaseDate":{"isoString":"2022-11-04T00:00:00Z"},"duration":423387}}}}}}</script>
</body></html>},
            };
        }

        return {
            success => 1,
            status  => 200,
            reason  => 'OK',
            content => q{<title>Spotify – Web Player</title>},
        };
    }
}

sub _strip_854 {
    my ($s) = @_;
    $s //= '';
    $s =~ s/\x03(?:\d{1,2}(?:,\d{1,2})?)?//g;
    $s =~ s/[\x02\x0f\x16\x1d\x1f]//g;
    return $s;
}

sub _slurp_854 {
    my ($p) = @_;
    open my $fh, '<:encoding(UTF-8)', $p or die "$p: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;
    no warnings 'redefine';
    no warnings 'once';

    {
        my %info = (type => 'track');
        my $html = q{<script id="__NEXT_DATA__" type="application/json">{"props":{"pageProps":{"state":{"data":{"entity":{"type":"track","title":"Bien cordialement","artists":[{"name":"The Toxic Avenger"},{"name":"Simone"}],"releaseDate":{"isoString":"2022-11-04T00:00:00Z"},"duration":423387}}}}}}</script>};

        my $self = bless { logger => L854->new }, 'Bot854';

        Mediabot::External::Spotify::_spotify_extract_jsonish(
            $self, \%info, $html, 'mb672-next-data'
        );

        $assert->is($info{title}, 'Bien cordialement',
            'mb672-854: __NEXT_DATA__ exposes track title');
        $assert->is($info{artist}, 'The Toxic Avenger, Simone',
            'mb672-854: __NEXT_DATA__ exposes all artists');
        $assert->is($info{year}, '2022',
            'mb672-854: __NEXT_DATA__ releaseDate exposes year');
        $assert->is($info{duration}, '7m 03s',
            'mb672-854: __NEXT_DATA__ millisecond duration is formatted');
    }

    {
        my @http_calls;
        my @sent;
        my %worker;
        my $chromium_calls = 0;

        local *Mediabot::External::_make_http = sub {
            return H854->new(\@http_calls);
        };
        local *Mediabot::External::_fetch_url_chromium_dumpdom = sub {
            $chromium_calls++;
            return '<title>SHOULD NOT RUN</title>';
        };
        local *Mediabot::Helpers::botPrivmsg = sub {
            push @sent, $_[2];
            return 1;
        };
        local *Mediabot::AsyncWorker::start = sub {
            my ($class, %args) = @_;
            %worker = %args;
            return bless {}, 'Worker854';
        };

        my $self = bless {
            logger => L854->new,
            loop   => Loop854->new,
        }, 'Bot854';

        my $ret = Mediabot::External::_handle_spotify(
            $self,
            undef,
            'nick',
            '#c',
            'https://open.spotify.com/intl-fr/track/03wI4pbnIvAzRrPcvuKs4X?si=test'
        );

        $assert->is($ret, 1,
            'mb672-854: async Spotify handler reports handled');
        $assert->is(scalar(@http_calls), 0,
            'mb672-854: parent event loop performs zero Spotify HTTP');
        $assert->is(scalar(@sent), 0,
            'mb672-854: no IRC output before worker completion');
        $assert->ok(ref($worker{child}) eq 'CODE' && ref($worker{on_done}) eq 'CODE',
            'mb672-854: AsyncWorker receives child and completion callbacks');

        my $value = $worker{child}->();

        $assert->is(scalar(@http_calls), 2,
            'mb672-854: happy track path uses only oEmbed + lightweight embed');
        $assert->like($http_calls[0] // '', qr{/oembed\?},
            'mb672-854: oEmbed remains first');
        $assert->like($http_calls[1] // '',
            qr{/embed/track/03wI4pbnIvAzRrPcvuKs4X},
            'mb672-854: lightweight embed supplies rich metadata');
        $assert->is($chromium_calls, 0,
            'mb672-854: Spotify happy path never invokes Chromium');

        $worker{on_done}->({ ok => 1, value => $value });

        $assert->is(scalar(@sent), 1,
            'mb672-854: worker completion emits exactly one IRC line');

        my $clean = _strip_854($sent[0]);

        $assert->is(
            $clean,
            '(nick) [Spotify] Bien cordialement - by The Toxic Avenger, Simone - 2022 - 7m 03s',
            'mb672-854: existing Spotify format gains year and duration'
        );

        my ($after_reset) = ($sent[0] // '') =~ /\x0f\s+(.*)\z/s;
        $assert->ok(defined($after_reset),
            'mb672-854: historical Spotify badge is followed by IRC RESET');
    }

    {
        my $src = _slurp_854(
            File::Spec->catfile('.', 'Mediabot', 'External', 'Spotify.pm')
        );

        my ($handler) = $src =~ /(sub _handle_spotify \{.*?\n\})\n\n/s;
        $handler //= '';

        $assert->like($handler, qr/Mediabot::AsyncWorker->start\(/,
            'mb672-854: runtime Spotify handler uses shared AsyncWorker');
        $assert->unlike($handler, qr/_fetch_url_chromium_dumpdom/,
            'mb672-854: Chromium is absent from Spotify runtime handler');
        $assert->like(
            $handler,
            qr/String::IRC->new\("Spotify"\)->black\('green'\)/,
            'mb672-854: Spotify badge colors remain unchanged'
        );
        $assert->like(
            $handler,
            qr/my\s+\$msg\s*=\s*"\$badge\\x0f\s+\$display";/,
            'mb672-854: Spotify badge/reset/display contract remains unchanged'
        );
    }
};
