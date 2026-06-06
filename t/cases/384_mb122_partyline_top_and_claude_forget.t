# t/cases/384_mb122_partyline_top_and_claude_forget.t
# =============================================================================
# Tests des corrections mb122 :
#   - B2 : Partyline _cmd_top extrayait le PREMIER chiffre du args entier,
#          donc `.top #chan42 10` produisait n=42 (clampe a 15) au lieu de 10.
#   - B3 : claude_ctx 'forget' utilisait lc($nick) pour la cle de l'historique
#          alors que l'historique est ecrit avec $nick raw (case-sensitive),
#          donc le forget ne supprimait rien pour les nicks avec capitales.
# =============================================================================

use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;

my $case = sub {
    my ($assert) = @_;

    # -------------------------------------------------------------------------
    # B2 : Partyline _cmd_top arg parsing
    # -------------------------------------------------------------------------
    my $parse_top = sub {
        my ($args) = @_;
        my $all_chans = ($args =~ /\ball\b/i) ? 1 : 0;
        my ($chan) = ($args =~ /(#\S+)/i);

        my $args_for_n = $args;
        $args_for_n =~ s/#\S+//g;
        $args_for_n =~ s/\ball\b//gi;
        my ($n) = ($args_for_n =~ /(?:^|\s)(\d+)(?=\s|$)/);
        $n //= 5;
        $n = 5  if !$n || $n < 1;
        $n = 15 if $n > 15;

        return ($all_chans, $chan, $n);
    };

    my @top_cases = (
        # args              expected_all  expected_chan   expected_n
        ['#chan42 10',      0, '#chan42',  10],   # le bug originel
        ['#teuk 10',        0, '#teuk',    10],
        ['#chan 3',         0, '#chan',    3],
        ['all 7',           1, undef,      7],
        ['#chan42',         0, '#chan42',  5],    # default n=5
        ['#chan42 0',       0, '#chan42',  5],    # clamp bas
        ['all 100',         1, undef,      15],   # clamp haut
        ['#a1b2c3 5',       0, '#a1b2c3',  5],    # chiffres dans nom de canal
        ['#chan 20',        0, '#chan',    15],   # clamp 20 -> 15
        ['#chan foo10bar',  0, '#chan',    5],    # non-standalone digits ignored
        ['#chan 10foo 7',   0, '#chan',    7],    # later standalone n accepted
    );
    for my $c (@top_cases) {
        my ($args, $exp_all, $exp_chan, $exp_n) = @$c;
        my ($all, $chan, $n) = $parse_top->($args);
        $assert->($all == $exp_all,
            "_cmd_top '$args' -> all=$exp_all (got $all)");
        $assert->( (defined $chan && defined $exp_chan && $chan eq $exp_chan)
                || (!defined $chan && !defined $exp_chan),
            "_cmd_top '$args' -> chan=" . ($exp_chan // '(none)') . " (got " . ($chan // '(none)') . ")");
        $assert->($n == $exp_n,
            "_cmd_top '$args' -> n=$exp_n (got $n)");
    }

    # -------------------------------------------------------------------------
    # B3 : Claude !ai forget key consistency
    # -------------------------------------------------------------------------
    # Simulation : un dict represente _claude_history (key case-sensitive)
    # et _claude_persona (key lc).
    # Le forget doit supprimer les deux entrees pour le nick courant.
    my $sim_forget = sub {
        my ($nick, $channel, $history, $persona) = @_;
        my $chan_part   = (defined $channel ? $channel : '__private__');
        my $hist_key    = "$nick\x00$chan_part";
        my $persona_key = lc($nick) . "\x00" . $chan_part;
        my $had = (exists $history->{$hist_key} || exists $persona->{$persona_key}) ? 1 : 0;
        delete $history->{$hist_key};
        delete $persona->{$persona_key};
        return $had;
    };

    # Setup : un user 'Teuk' a une session active (history sous "Teuk", persona sous "teuk")
    {
        my $history = { "Teuk\x00#boulets" => [{ role => 'user', content => 'hi' }] };
        my $persona = { "teuk\x00#boulets" => 'mode mechant' };

        my $had = $sim_forget->('Teuk', '#boulets', $history, $persona);
        $assert->($had == 1, "B3 forget('Teuk') -> had=1 (found existing session)");
        $assert->(scalar keys %$history == 0, "B3 forget cleared history (no key left)");
        $assert->(scalar keys %$persona == 0, "B3 forget cleared persona (no key left)");
    }

    # Edge: user sans session active
    {
        my $history = {};
        my $persona = {};
        my $had = $sim_forget->('NewUser', '#chan', $history, $persona);
        $assert->($had == 0, "B3 forget('NewUser') with no session -> had=0");
    }

    # Edge: user lowercase (sanity check, doit toujours fonctionner)
    {
        my $history = { "teuk\x00#chan" => [{ role => 'user', content => 'hi' }] };
        my $persona = { "teuk\x00#chan" => 'mode default' };
        my $had = $sim_forget->('teuk', '#chan', $history, $persona);
        $assert->($had == 1, "B3 forget('teuk' lowercase) -> had=1");
        $assert->(scalar keys %$history == 0, "B3 forget lowercase cleared history");
        $assert->(scalar keys %$persona == 0, "B3 forget lowercase cleared persona");
    }
    # B3-source: guard the real implementation, not only the simulation.
    # History keys must use the raw IRC nick, while persona keys stay lower-case.
    {
        my $claude_pm = File::Spec->catfile($Bin, '..', '..', 'Mediabot', 'External', 'Claude.pm');
        open my $cfh, '<', $claude_pm
            or do { $assert->(0, "B3-source cannot open Claude.pm: $!"); return; };
        my $src = do { local $/; <$cfh> };
        close $cfh;

        $assert->($src =~ /my\s+\$hist_key\s*=\s*"\$nick\\x00\$chan_part"/,
            "B3-source history key uses raw IRC nick");

        $assert->($src =~ /my\s+\$persona_key\s*=\s*lc\(\$nick\)\s*\.\s*"\\x00"\s*\.\s*\$chan_part/,
            "B3-source persona key remains lower-cased");

        $assert->($src !~ /my\s+\$hist_key\s*=\s*lc\(\$nick\)\s*\.\s*"\\x00"/,
            "B3-source old lc(nick) history key is gone");
    }

};

# ---------------------------------------------------------------------------
# Direct runner for standalone execution:
#   perl t/cases/384_mb122_partyline_top_and_claude_forget.t
#
# When loaded by the project test harness, keep returning the case coderef.
# ---------------------------------------------------------------------------
if (caller) {
    return $case;
}

my $tests = 0;
my $fail  = 0;

my $assert = sub {
    my ($ok, $name) = @_;
    $tests++;

    $name = 'unnamed assertion' unless defined $name && $name ne '';

    if ($ok) {
        print "ok $tests - $name\n";
    }
    else {
        print "not ok $tests - $name\n";
        $fail++;
    }
};

$case->($assert);

print "1..$tests\n";
exit($fail ? 1 : 0);

