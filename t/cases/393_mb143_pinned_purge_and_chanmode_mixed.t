# t/cases/393_mb143_pinned_purge_and_chanmode_mixed.t
# =============================================================================
# Tests des corrections mb143 :
#
#   - B1 : purge_claude_session_for_nick (appelee sur QUIT/NICK genuine)
#          purgeait _claude_history + _claude_persona + _ai_last_active
#          mais oubliait _claude_pinned. C'est l'analogue automatique du
#          bug mb141-B1 que nous avions fixe pour la commande explicite
#          `!ai forget`.
#
#   - B2 : set_chanmode rejetait les modes IRC mixtes legitimes (RFC 2812)
#          comme "+stn-k" (set s,t,n et unset k) ou "+ms-Lr". Le regex
#          /^[+-]?[a-zA-Z]+$/ n'acceptait qu'un seul prefix. Resultat :
#          impossible de stocker certains chanmodes operationnels via
#          `!chanset chanmode +stn-k`.
# =============================================================================

use strict;
use warnings;

return sub {
    my ($assert) = @_;

    # -------------------------------------------------------------------------
    # B1 : purge_claude_session_for_nick purge AUSSI _claude_pinned
    # -------------------------------------------------------------------------

    my $purge_for_nick = sub {
        my ($bot, $nick) = @_;
        return unless $bot && defined($nick) && $nick ne '';

        my $hist_prefix    = "$nick\x00";
        my $persona_prefix = lc($nick) . "\x00";

        for my $cache (qw(_claude_history)) {
            next unless $bot->{$cache};
            delete $bot->{$cache}{$_}
                for grep { index($_, $hist_prefix) == 0 } keys %{ $bot->{$cache} };
        }
        for my $cache (qw(_claude_persona _ai_last_active _claude_pinned)) {
            next unless $bot->{$cache};
            delete $bot->{$cache}{$_}
                for grep { index($_, $persona_prefix) == 0 } keys %{ $bot->{$cache} };
        }
    };

    # Setup: Bob QUIT alors qu'il avait pin/persona/history/last_active
    {
        my $bot = {
            _claude_history => {
                "Bob\x00#chan"   => [{role=>'user',content=>'hi'}],
                "Alice\x00#chan" => [{role=>'user',content=>'hello'}],
            },
            _claude_persona => {
                "bob\x00#chan"   => 'mode pirate',
                "alice\x00#chan" => 'mode sage',
            },
            _ai_last_active => {
                "bob\x00#chan"   => 1000,
                "alice\x00#chan" => 1100,
            },
            _claude_pinned => {
                "bob\x00#chan"   => 'pin: my pet is Talos',
                "alice\x00#chan" => 'pin: alice has cats',
            },
        };

        $purge_for_nick->($bot, 'Bob');

        # Bob : tout vide
        $assert->(!exists $bot->{_claude_history}{"Bob\x00#chan"},
            "B1 history Bob purge sur QUIT");
        $assert->(!exists $bot->{_claude_persona}{"bob\x00#chan"},
            "B1 persona bob purge sur QUIT");
        $assert->(!exists $bot->{_ai_last_active}{"bob\x00#chan"},
            "B1 ai_last_active bob purge sur QUIT");
        $assert->(!exists $bot->{_claude_pinned}{"bob\x00#chan"},
            "B1 pinned bob purge sur QUIT (NOUVEAU dans mb143)");

        # Alice : intact
        $assert->(exists $bot->{_claude_history}{"Alice\x00#chan"},
            "B1 Alice history preserve");
        $assert->(exists $bot->{_claude_persona}{"alice\x00#chan"},
            "B1 Alice persona preserve");
        $assert->(exists $bot->{_ai_last_active}{"alice\x00#chan"},
            "B1 Alice last_active preserve");
        $assert->(exists $bot->{_claude_pinned}{"alice\x00#chan"},
            "B1 Alice pinned preserve");
    }

    # Bob avec pin sur plusieurs canaux : tous purges
    {
        my $bot = {
            _claude_pinned => {
                "bob\x00#chan1" => 'pin1',
                "bob\x00#chan2" => 'pin2',
                "bob\x00#chan3" => 'pin3',
            },
        };
        $purge_for_nick->($bot, 'Bob');
        $assert->(scalar(keys %{ $bot->{_claude_pinned} }) == 0,
            "B1 pin sur 3 canaux : tous purges sur QUIT Bob");
    }

    # Regression POC : sans le fix, le pin survivait au QUIT
    {
        my $purge_buggy = sub {
            my ($bot, $nick) = @_;
            my $hist_prefix    = "$nick\x00";
            my $persona_prefix = lc($nick) . "\x00";
            for my $cache (qw(_claude_history)) {
                next unless $bot->{$cache};
                delete $bot->{$cache}{$_}
                    for grep { index($_, $hist_prefix) == 0 } keys %{ $bot->{$cache} };
            }
            for my $cache (qw(_claude_persona _ai_last_active)) {  # PAS _claude_pinned
                next unless $bot->{$cache};
                delete $bot->{$cache}{$_}
                    for grep { index($_, $persona_prefix) == 0 } keys %{ $bot->{$cache} };
            }
        };

        my $bot = {
            _claude_pinned => { "bob\x00#chan" => 'sticky pin' },
        };
        $purge_buggy->($bot, 'Bob');
        $assert->(exists $bot->{_claude_pinned}{"bob\x00#chan"},
            "B1 REGRESSION-POC: ancien code laisse le pin sticky");
    }

    # -------------------------------------------------------------------------
    # B2 : set_chanmode accepte les modes IRC mixtes
    # -------------------------------------------------------------------------

    my $check_chanmode_old = sub {
        my ($mode) = @_;
        return 1 if $mode eq '';
        return ($mode =~ /^[+-]?[a-zA-Z]+$/ && length($mode) <= 32) ? 1 : 0;
    };
    my $check_chanmode_new = sub {
        my ($mode) = @_;
        return 1 if $mode eq '';
        return ($mode =~ /^([+-][a-zA-Z]+)+$/ && length($mode) <= 32) ? 1 : 0;
    };

    # Modes IRC simples (compat preservee)
    for my $mode (qw(+stn +s -k +ntk)) {
        $assert->($check_chanmode_old->($mode) == 1,
            "B2 ancien code accepte '$mode' (compat preservee)");
        $assert->($check_chanmode_new->($mode) == 1,
            "B2 nouveau code accepte '$mode'");
    }

    # Modes mixtes IRC (regression POC + fix)
    for my $mode ('+stn-k', '+ms-Lr', '+o-v', '+i+s-l') {
        $assert->($check_chanmode_old->($mode) == 0,
            "B2 REGRESSION-POC: ancien rejette '$mode' (mode IRC mixte legitime)");
        $assert->($check_chanmode_new->($mode) == 1,
            "B2 FIX: nouveau accepte '$mode'");
    }

    # Modes invalides — toujours rejetes
    for my $mode ('foo', '++', '+a b', '+abc;', '+a' x 17) {  # dernier > 32 chars
        $assert->($check_chanmode_new->($mode) == 0,
            "B2 nouveau rejette mode invalide: '$mode'");
    }

    # Edge case: empty string accepted (= clear chanmode)
    $assert->($check_chanmode_new->('') == 1,
        "B2 empty string accepte (= clear chanmode)");

    # Edge case : just + or - sans lettres
    $assert->($check_chanmode_new->('+') == 0,
        "B2 nouveau rejette '+' seul (pas de lettre)");
    $assert->($check_chanmode_new->('-') == 0,
        "B2 nouveau rejette '-' seul");
};
