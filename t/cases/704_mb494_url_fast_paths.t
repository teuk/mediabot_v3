# t/cases/704_mb494_url_fast_paths.t
# =============================================================================
# mb494 — Répondre en < 1 s comme les bots rapides : plus de navigateur sur le
# chemin principal.
#
#   X         : FAST PATH api.fxtwitter.com (JSON public, ~300 ms) AVANT
#               chromium -> nom (@screen), texte du tweet, likes/RTs compactés.
#               Chromium ne tourne QUE si fxtwitter rate.
#   Facebook  : l'étape HTTP utilise l'UA de crawler social
#               (facebookexternalhit) -> og: tags servis server-side.
#   Instagram : idem (le silence total venait de là : HTTP sans og + chromium
#               bloqué, et pas de fallback URL).
#
# Handlers réels + mocks locaux (pattern 702), plus gardes par scan.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

use Mediabot::External;
use Mediabot::External::URL;

{
    package L704; sub new { bless {}, shift } sub log { }
    package H704; sub new { my ($c,$body)=@_; bless { body=>$body }, $c }
    sub get { return { success => 1, status => 200, content => $_[0]->{body} } }
    package HFail704; sub new { bless {}, shift }
    sub get { return { success => 0, status => 503, reason => 'down' } }
}

sub _strip { my ($s)=@_; $s =~ s/\x03\d{0,2}(?:,\d{1,2})?|\x0f|\x02//g; return $s; }
sub _slurp_704 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

my @SENT;
my $CHROMIUM_CALLS;

return sub {
    my ($assert) = @_;

    no warnings 'redefine';
    no warnings 'once';
    local *Mediabot::Helpers::botPrivmsg = sub { push @SENT, $_[2]; 1 };

    my $fx_json = q({"code":200,"message":"OK","tweet":{"text":"just setting up my twttr","likes":123456,"retweets":98765,"author":{"name":"jack","screen_name":"jack"}}});

    # -------------------------------------------------------------------------
    # 1. X fast path : ligne riche complète, chromium ÉVITÉ
    # -------------------------------------------------------------------------
    {
        local *Mediabot::External::_make_http = sub { H704->new($fx_json) };
        $CHROMIUM_CALLS = 0;
        local *Mediabot::External::URL::_fetch_url_chromium_dumpdom = sub { $CHROMIUM_CALLS++; undef };
        @SENT = ();
        my $self = { logger => L704->new, _x_twitter_cache => {} };
        Mediabot::External::URL::_handle_x_twitter($self, 'u', 'nick', '#c',
            'https://x.com/jack/status/20');
        my $line = _strip($SENT[0] // '');
        $assert->like($line, qr/\[X\]/, 'X: badge');
        $assert->like($line, qr/jack \(\@jack\) on X/, 'X: nom + @screen (fxtwitter)');
        $assert->like($line, qr/"just setting up my twttr"/, 'X: texte du tweet');
        $assert->like($line, qr/123\.5k likes, 98\.8k RTs/, 'X: stats compactées');
        $assert->is($CHROMIUM_CALLS, 0, 'X: chromium PAS appelé (fast path)');
    }

    # -------------------------------------------------------------------------
    # 2. X : fxtwitter en panne -> chromium prend le relais (cascade intacte)
    # -------------------------------------------------------------------------
    {
        local *Mediabot::External::_make_http = sub { HFail704->new };
        $CHROMIUM_CALLS = 0;
        local *Mediabot::External::URL::_fetch_url_chromium_dumpdom = sub {
            $CHROMIUM_CALLS++;
            q{<meta property="og:title" content="jack on X"/><meta property="og:description" content="just setting up my twttr"/>};
        };
        @SENT = ();
        my $self = { logger => L704->new, _x_twitter_cache => {} };
        Mediabot::External::URL::_handle_x_twitter($self, 'u', 'nick', '#c',
            'https://x.com/jack/status/21');
        my $line = _strip($SENT[0] // '');
        $assert->is($CHROMIUM_CALLS, 1, 'X: chromium appelé en secours');
        $assert->like($line, qr/jack on X: "just setting up my twttr"/, 'X: extraction chromium OK');
    }

    # -------------------------------------------------------------------------
    # 3. X : URL de profil (pas de /status/) -> pas d'appel fxtwitter, cascade normale
    # -------------------------------------------------------------------------
    {
        my $http_calls = 0;
        local *Mediabot::External::_make_http = sub { $http_calls++; HFail704->new };
        $CHROMIUM_CALLS = 0;
        local *Mediabot::External::URL::_fetch_url_chromium_dumpdom = sub { $CHROMIUM_CALLS++; undef };
        @SENT = ();
        my $self = { logger => L704->new, _x_twitter_cache => {} };
        Mediabot::External::URL::_handle_x_twitter($self, 'u', 'nick', '#c',
            'https://x.com/Snowden');
        $assert->is($http_calls, 0, 'X profil: fxtwitter non appelé (réservé aux /status/)');
        $assert->is($CHROMIUM_CALLS, 1, 'X profil: chromium tenté');
        my $line = _strip($SENT[0] // '');
        $assert->like($line, qr/X (?:post|profile).*Snowden|Snowden/, 'X profil: fallback URL');
    }

    # -------------------------------------------------------------------------
    # 4. Gardes par scan : UA crawler social sur FB et Instagram
    # -------------------------------------------------------------------------
    {
        my $src = _slurp_704(File::Spec->catfile('.', 'Mediabot', 'External', 'URL.pm'));
        my ($ig) = $src =~ /(sub _handle_instagram \{.*?\n\})\n\n/s; $ig //= '';
        my ($fb) = $src =~ /(sub _handle_facebook \{.*?\n\})\n\n/s;  $fb //= '';
        $assert->like($ig, qr/facebookexternalhit\/1\.1/,
            'Instagram: étape HTTP en UA crawler social');
        $assert->like($fb, qr/facebookexternalhit\/1\.1/,
            'Facebook: étape HTTP en UA crawler social');
        # le fast path X est bien AVANT le chromium dans le source
        my ($x) = $src =~ /(sub _handle_x_twitter \{.*?\n\})\n\n/s; $x //= '';
        my $p_fx = index($x, 'api.fxtwitter.com');
        my $p_ch = index($x, '_fetch_url_chromium_dumpdom');
        $assert->ok($p_fx >= 0 && $p_ch >= 0 && $p_fx < $p_ch,
            'X: fxtwitter placé avant chromium');
        $assert->like($x, qr/unless \(defined \$title && \$title ne ''\) \{\s*\n\s*\$dom = eval/,
            'X: chromium conditionné au miss du fast path');
    }

    # -------------------------------------------------------------------------
    # 5. Helper compactage
    # -------------------------------------------------------------------------
    {
        $assert->is(Mediabot::External::URL::_x_compact_count(950), '950', 'compact: 950');
        $assert->is(Mediabot::External::URL::_x_compact_count(12345), '12.3k', 'compact: 12.3k');
        $assert->is(Mediabot::External::URL::_x_compact_count(1000), '1k', 'compact: 1000 -> 1k');
        $assert->is(Mediabot::External::URL::_x_compact_count(4_200_000), '4.2M', 'compact: 4.2M');
        $assert->is(Mediabot::External::URL::_x_compact_count(undef), '0', 'compact: undef -> 0');
    }
};
