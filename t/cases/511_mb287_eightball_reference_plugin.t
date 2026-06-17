# t/cases/511_mb287_eightball_reference_plugin.t
# =============================================================================
# mb287 — plugin Tcl de référence : plugins/scripts/examples/eightball.tcl
#
# Un Magic 8-Ball pour p8ball : exemple Tcl utile au-delà du hello-world. Il
# extrait des champs de l'enveloppe sans parseur JSON, utilise le json_escape
# corrigé (mb284, clé 1 backslash), et émet le contrat mediabot-script-v1.
#
# Les checks statiques tournent partout ; le check fonctionnel ne tourne que si
# `tclsh` est présent (sandbox : SKIP — à valider sur l'hôte/CI).
# =============================================================================

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../..";
use File::Spec;
use Test::More;

my $root = File::Spec->rel2abs("$Bin/../..");
my $ex   = File::Spec->catdir($root, 'plugins', 'scripts', 'examples');
my $tcl  = File::Spec->catfile($ex, 'eightball.tcl');

plan skip_all => "eightball.tcl not found" unless -e $tcl;

my $src = do { open my $fh, '<', $tcl or die $!; local $/; <$fh> };

# --- checks statiques (sans tclsh) ------------------------------------------
like($src, qr/mediabot-script-v1/,        'eightball declares the protocol');
like($src, qr/"ok":true/,                 'eightball sets ok:true explicitly');
like($src, qr/string map \[list \\\\ \\\\\\\\ /,
    'eightball uses the mb284-fixed json_escape (single-backslash key)');
unlike($src, qr/string map \[list \\\\\\\\ \\\\\\\\\\\\\\\\ /,
    'eightball does not use the old buggy double-backslash key');
like($src, qr/It is certain\./,           'eightball ships the classic answer list');
like($src, qr/lindex \$answers/,          'eightball picks a random answer by index');

# --- check fonctionnel gardé par tclsh --------------------------------------
my $tclsh;
for my $dir (split /:/, $ENV{PATH} || '') {
    my $cand = File::Spec->catfile($dir, 'tclsh');
    if (-x $cand) { $tclsh = $cand; last; }
}

SKIP: {
    skip 'tclsh not available (validate on the bot host / CI)', 8 unless $tclsh;

    require Mediabot::ScriptRunner;
    require Mediabot::ScriptActionRunner;
    my $sr = Mediabot::ScriptRunner->new(script_dir => $ex, timeout => 5);
    my $ar = Mediabot::ScriptActionRunner->new;

    # avec une question
    {
        my $r = $sr->run_script('eightball.tcl', 'public_command',
            channel => '#teuk', nick => 'te[u]k', command => '8ball',
            args => [qw(will it rain today?)]);
        ok($r->{ok},            'tcl run ok (question)');
        ok($r->{response}{ok},  'response ok flag true (question)');
        ok(($r->{exit_code} // -1) == 0, 'tcl exits 0 (question)');

        my $plan = $ar->apply_actions_dry($r, { channel => '#teuk' });
        ok($plan->{ok}, 'plan ok (question)');
        is($plan->{planned}[0]{target}, '#teuk', 'reply defaults to channel');
        like($plan->{planned}[0]{text}, qr/the 8-ball says:/, 'reply contains an 8-ball verdict');
    }

    # sans question -> usage
    {
        my $r = $sr->run_script('eightball.tcl', 'public_command',
            channel => '#teuk', nick => 'te[u]k', command => '8ball', args => []);
        my $plan = $ar->apply_actions_dry($r, { channel => '#teuk' });
        like($plan->{planned}[0]{text}, qr/ask me a yes\/no question/, 'empty question yields a usage hint');
        unlike($plan->{planned}[0]{text}, qr/[\r\n]/, 'reply has no control characters');
    }
}

done_testing();
