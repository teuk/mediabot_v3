# t/cases/705_mb495_facebook_entities_counters.t
# =============================================================================
# mb495 — Facebook rendait sur IRC (capture de prod) :
#   [Facebook] 377&#xa0;&#x442;&#x44b;&#x441;. ... | Would you be so kind...&#x1f979;
#
# Trois causes, trois fixes :
#   [1] _decode_html ne déclenchait decode_entities que sur entités nommées ou
#       DÉCIMALES (&#160;) — les HEX (&#xa0; &#x442; &#x1f979;) n'étaient
#       JAMAIS décodées -> déclencheur hex ajouté (profite à tous les handlers).
#   [2] og:title des reels = "<compteurs, locale aléatoire> | <caption>" ->
#       _facebook_title_from_html coupe le préfixe compteurs (titre commençant
#       par un chiffre + pipe) et normalise les nbsp.
#   [3] locale des compteurs imprévisible -> les GET crawler FB/IG envoient
#       Accept-Language en-US (support default_headers ajouté à _make_http).
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

use Mediabot::External;
use Mediabot::External::URL;

{
    package L705; sub new { bless {}, shift } sub log { }
    package H705; sub new { my ($c,$b)=@_; bless { b=>$b }, $c }
    sub get { return { success => 1, status => 200, content => $_[0]->{b} } }
}

sub _strip { my ($s)=@_; $s =~ s/\x03\d{0,2}(?:,\d{1,2})?|\x0f|\x02//g; return $s; }
sub _slurp_705 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

my @SENT;

return sub {
    my ($assert) = @_;

    no warnings 'redefine';
    no warnings 'once';
    local *Mediabot::Helpers::botPrivmsg = sub { push @SENT, $_[2]; 1 };

    # -------------------------------------------------------------------------
    # [1] _decode_html décode désormais les entités HEX
    # -------------------------------------------------------------------------
    {
        my $d = Mediabot::External::URL::_decode_html('A&#x20;B');
        $assert->is($d, 'A B', 'hex &#x20; (espace) décodée');
        $d = Mediabot::External::URL::_decode_html('&#x442;&#x44b;&#x441;');
        $assert->is($d, "\x{442}\x{44b}\x{441}", 'hex cyrillique décodé');
        $d = Mediabot::External::URL::_decode_html('ok&#x1f979;');
        $assert->is($d, "ok\x{1f979}", 'hex emoji (plan astral) décodé');
        # les chemins existants restent intacts
        $d = Mediabot::External::URL::_decode_html('A &amp; B &#160;C');
        $assert->like($d, qr/^A & B .?C$/, 'entités nommées + décimales toujours décodées');
        $d = Mediabot::External::URL::_decode_html('plain text');
        $assert->is($d, 'plain text', 'texte sans entité inchangé');
    }

    # -------------------------------------------------------------------------
    # [2] _facebook_title_from_html : fixture EXACTE façon capture de prod
    # -------------------------------------------------------------------------
    {
        my $self = { logger => L705->new };
        my $og = '377&#xa0;&#x442;&#x44b;&#x441;. &#x43f;&#x440;&#x43e;&#x441;&#x43c;&#x43e;&#x442;&#x440;&#x43e;&#x432; &#xb7; 2,6&#xa0;&#x442;&#x44b;&#x441;. &#x440;&#x435;&#x430;&#x43a;&#x446;&#x438;&#x439; | Would you be so kind as to feed her?&#x1f979; #viralreels';
        my $html = qq{<meta property="og:title" content="$og"/>};
        my $t = Mediabot::External::URL::_facebook_title_from_html($self, $html, 'test');
        $assert->is($t, "Would you be so kind as to feed her?\x{1f979} #viralreels",
            'reel: compteurs coupés, entités décodées, caption propre');

        # titre normal sans pipe -> intact
        $html = q{<meta property="og:title" content="Le Gorafi"/>};
        $t = Mediabot::External::URL::_facebook_title_from_html($self, $html, 'test');
        $assert->is($t, 'Le Gorafi', 'titre normal intact');

        # pipe mais ne commençant PAS par un chiffre -> intact (pas un compteur)
        $html = q{<meta property="og:title" content="Foo Bar | The Official Page"/>};
        $t = Mediabot::External::URL::_facebook_title_from_html($self, $html, 'test');
        $assert->is($t, 'Foo Bar | The Official Page', 'pipe non-compteur préservé');

        # nbsp décodés normalisés en espaces
        $html = q{<meta property="og:title" content="A&#xa0;B"/>};
        $t = Mediabot::External::URL::_facebook_title_from_html($self, $html, 'test');
        $assert->is($t, 'A B', 'nbsp -> espace');
    }

    # -------------------------------------------------------------------------
    # bout-en-bout : le handler FB réel sur la fixture de la capture
    # -------------------------------------------------------------------------
    {
        my $og = '377&#xa0;&#x442;&#x44b;&#x441;. &#x43f;&#x440; &#xb7; 2,6&#xa0;&#x442;&#x44b;&#x441;. | Would you be so kind as to feed her?&#x1f979; #viralreels';
        my $html = qq{<html><head><meta property="og:title" content="$og"/><meta property="og:description" content="Some reel description"/></head></html>};
        local *Mediabot::External::_make_http = sub { H705->new($html) };
        local *Mediabot::External::URL::_fetch_url_chromium_dumpdom = sub { undef };
        @SENT = ();
        my $self = { logger => L705->new, _facebook_cache => {} };
        Mediabot::External::URL::_handle_facebook($self, 'u', 'nick', '#c',
            'https://www.facebook.com/reel/1672309937302951');
        my $line = _strip($SENT[0] // '');
        $assert->like($line, qr/\[Facebook\] Would you be so kind as to feed her\?\x{1f979} #viralreels - Some reel description/,
            'bout-en-bout: ligne IRC propre et riche');
        $assert->unlike($line, qr/&#x/i, 'bout-en-bout: aucune entité brute');
        $assert->unlike($line, qr/^\(\S+\) \[Facebook\] \d/, 'bout-en-bout: pas de préfixe compteurs');
    }

    # -------------------------------------------------------------------------
    # [3] gardes par scan : accept-language + support default_headers
    # -------------------------------------------------------------------------
    {
        my $url_src = _slurp_705(File::Spec->catfile('.', 'Mediabot', 'External', 'URL.pm'));
        my ($ig) = $url_src =~ /(sub _handle_instagram \{.*?\n\})\n\n/s; $ig //= '';
        my ($fb) = $url_src =~ /(sub _handle_facebook \{.*?\n\})\n\n/s;  $fb //= '';
        $assert->like($ig, qr/default_headers => \{ 'accept-language' => 'en-US/,
            'Instagram: Accept-Language en-US sur le GET crawler');
        $assert->like($fb, qr/default_headers => \{ 'accept-language' => 'en-US/,
            'Facebook: Accept-Language en-US sur le GET crawler');

        my $ext_src = _slurp_705(File::Spec->catfile('.', 'Mediabot', 'External.pm'));
        $assert->like($ext_src,
            qr/ref\(\$opts\{default_headers\}\) eq 'HASH' \? \(default_headers => \$opts\{default_headers\}\) : \(\)/,
            '_make_http: support default_headers (opt-in, sans effet ailleurs)');
    }
};
