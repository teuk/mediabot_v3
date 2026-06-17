# t/cases/512_mb289_choose_reference_plugin.t
# =============================================================================
# mb289 — plugin Perl de référence utile : plugins/scripts/examples/choose.pl
#
# Un assistant de décision pour pchoose : exemple Perl au-delà du hello-world.
# Il découpe les arguments en options (délimiteur "|" sinon espaces), borne le
# nombre d'options (anti-abus), répond une usage amicale si < 2 options, et
# s'appuie sur encode_json (JSON::PP) pour échapper automatiquement le texte des
# options (entrée utilisateur) — contraste avec le json_escape manuel du Tcl.
#
# Validé de bout en bout via le VRAI bridge (ScriptRunner + ScriptActionRunner),
# sans bot ni DB. Nécessite l'interpréteur perl (toujours présent).
# =============================================================================

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../..";
use File::Spec;
use Test::More;

my $root   = File::Spec->rel2abs("$Bin/../..");
my $ex     = File::Spec->catdir($root, 'plugins', 'scripts', 'examples');
my $choose = File::Spec->catfile($ex, 'choose.pl');

plan skip_all => "choose.pl not found" unless -e $choose;

# --- contrat statique --------------------------------------------------------
my $src = do { open my $fh, '<', $choose or die $!; local $/; <$fh> };
like($src, qr/mediabot-script-v1/, 'choose.pl declares the protocol');
like($src, qr/MAX_OPTIONS/,        'choose.pl bounds the number of options (anti-abuse)');
like($src, qr/JSON::PP::true/,     'choose.pl sets ok => true explicitly');

require Mediabot::ScriptRunner;
require Mediabot::ScriptActionRunner;
my $sr = Mediabot::ScriptRunner->new(script_dir => $ex, timeout => 5);
my $ar = Mediabot::ScriptActionRunner->new;

my $run = sub {
    my (@args) = @_;
    my $r = $sr->run_script('choose.pl', 'public_command',
        channel => '#teuk', nick => 'teuk', command => 'choose', args => \@args);
    my $plan = $ar->apply_actions_dry($r, { channel => '#teuk' });
    return ($r, $plan);
};

# --- options séparées par "|" ------------------------------------------------
{
    my ($r, $plan) = $run->('pizza', '|', 'sushi', '|', 'tacos');
    ok($r->{response}{ok}, 'pipe options: response ok');
    ok($plan->{ok}, 'pipe options: plan ok');
    is($plan->{planned}[0]{type}, 'reply', 'pipe options: first action is a reply');
    is($plan->{planned}[0]{target}, '#teuk', 'pipe options: reply defaults to channel');
    like($plan->{planned}[0]{text}, qr/I choose: (pizza|sushi|tacos)\b/,
        'pipe options: picks one of the given options');
    is(scalar(@{ $plan->{planned} }), 2, 'pipe options: reply + log');
}

# --- options multi-mots via "|" ---------------------------------------------
{
    my ($r, $plan) = $run->('go', 'out', '|', 'stay', 'home');
    like($plan->{planned}[0]{text}, qr/I choose: (go out|stay home)$/,
        'multi-word options preserved through the pipe delimiter');
}

# --- fallback espaces --------------------------------------------------------
{
    my ($r, $plan) = $run->('heads', 'tails');
    like($plan->{planned}[0]{text}, qr/I choose: (heads|tails)$/,
        'whitespace fallback splits single-word options');
}

# --- moins de deux options -> usage -----------------------------------------
{
    my ($r, $plan) = $run->('solo');
    like($plan->{planned}[0]{text}, qr/at least two options/, 'single option yields a usage hint');
    is(scalar(@{ $plan->{planned} }), 1, 'usage case emits a single reply');
}
{
    my ($r, $plan) = $run->();
    like($plan->{planned}[0]{text}, qr/at least two options/, 'no options yields a usage hint');
}

# --- entrée piégée : guillemets / backslash gérés par encode_json -----------
{
    my ($r, $plan) = $run->('a"b', '|', 'c\\d', '|', 'e f');
    ok($r->{response}{ok}, 'special-char options: response still ok (encode_json escapes them)');
    ok($plan->{ok}, 'special-char options: plan ok (no JSON corruption)');
    unlike($plan->{planned}[0]{text}, qr/[\r\n]/, 'reply has no control characters');
}

done_testing();
