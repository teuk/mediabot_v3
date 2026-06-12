# t/cases/399_mb163_claude_prompt_cache.t
# =============================================================================
# Tests des corrections mb163 :
#
#   - B1 : le bloc "DD1 prompt cache" dans claudeAI lisait
#          _claude_prompt_cache{lc($prompt)} alors que le cache F53 (dans
#          _claude_send_and_parse) ecrit sous md5_hex(lc($prompt)...).
#          Les formats de cle ne matchaient jamais -> DD1 etait du code
#          mort. Et le "reparer" en alignant les cles aurait ete pire :
#          DD1 s'executait AVANT le chanset check et AVANT le rate limit,
#          sans maintenir l'history. Fix : suppression du bloc, le F53
#          fait deja ce travail au bon endroit.
#
#   - B2 : la cle de cache F53 etait md5(lc(prompt)) seule, globale,
#          independante du persona et du pin context. La reponse
#          personnalisee d'Alice (persona pirate + pin prive) etait servie
#          a Bob posant la meme question dans les 60s : mauvais style ET
#          fuite du contenu du pin. Fix : cle = md5(lc(prompt) + "\x00" +
#          sys_prompt effectif), qui contient persona et pin.
# =============================================================================

use strict;
use warnings;
use Digest::MD5 qw(md5_hex);
use Encode qw(encode);

return sub {
    my ($assert) = @_;

    my $key_old = sub {
        my ($prompt) = @_;
        return md5_hex(encode('UTF-8', lc($prompt // '')));
    };
    my $key_new = sub {
        my ($prompt, $sys) = @_;
        return md5_hex(encode('UTF-8', lc($prompt // '') . "\x00" . ($sys // '')));
    };

    # -------------------------------------------------------------------------
    # Cas 1 : B1 — les cles DD1 (lecture) et F53 (ecriture) ne matchent jamais
    # -------------------------------------------------------------------------
    {
        my $prompt = 'Quelle heure est-il ?';
        my $dd1_read  = lc($prompt);
        my $f53_write = $key_old->($prompt);
        $assert->($dd1_read ne $f53_write,
            "B1 REGRESSION-POC: cle DD1 (texte lc) != cle F53 (md5) -> DD1 jamais hit");
        $assert->($f53_write =~ /^[0-9a-f]{32}$/,
            "B1: la cle F53 est bien un md5 hex 32 chars");
    }

    # -------------------------------------------------------------------------
    # Cas 2 : B1 — consequence du dead code : ordre des checks preserve
    # -------------------------------------------------------------------------
    # Apres suppression de DD1, le SEUL chemin cache-hit est dans
    # _claude_send_and_parse, qui n'est atteint qu'apres : @args check,
    # chanset check, rate limit, history push. On simule cet ordre.
    {
        my @order;
        my $simulate_claudeai = sub {
            my (%opt) = @_;
            push @order, 'args_check';
            return 'no_args' unless $opt{has_args};
            push @order, 'chanset_check';
            return 'chanset_denied' unless $opt{chanset_ok};
            push @order, 'rate_limit';
            return 'rate_limited' if $opt{rate_exceeded};
            push @order, 'history_push';
            push @order, 'cache_check_f53';
            return 'cache_hit' if $opt{cache_hit};
            push @order, 'api_call';
            return 'answered';
        };

        @order = ();
        my $r = $simulate_claudeai->(has_args => 1, chanset_ok => 0, cache_hit => 1);
        $assert->($r eq 'chanset_denied',
            "B1 FIX: chanset -Claude bloque AVANT tout cache-hit possible");
        $assert->(!grep({ $_ eq 'cache_check_f53' } @order),
            "B1 FIX: le cache n'est jamais consulte si chanset refuse");

        @order = ();
        $r = $simulate_claudeai->(has_args => 1, chanset_ok => 1, rate_exceeded => 1, cache_hit => 1);
        $assert->($r eq 'rate_limited',
            "B1 FIX: rate limit bloque AVANT tout cache-hit possible");

        @order = ();
        $r = $simulate_claudeai->(has_args => 1, chanset_ok => 1, cache_hit => 1);
        $assert->($r eq 'cache_hit',
            "B1 FIX: cache-hit F53 fonctionne sur le chemin legitime");
        my ($i_hist) = grep { $order[$_] eq 'history_push' } 0..$#order;
        my ($i_cache) = grep { $order[$_] eq 'cache_check_f53' } 0..$#order;
        $assert->(defined $i_hist && defined $i_cache && $i_hist < $i_cache,
            "B1 FIX: history push precede le cache check (coherence mb141-B2)");
    }

    # -------------------------------------------------------------------------
    # Cas 3 : B2 — REGRESSION-POC : fuite persona/pin via cle globale
    # -------------------------------------------------------------------------
    {
        my $prompt      = 'raconte une blague';
        my $default_sys = 'You are a helpful IRC bot.';
        my $alice_sys   = '[Always remember: my pet is Talos] Tu es un pirate bourru.';

        my %cache;
        # Alice (persona+pin) recoit et cache sa reponse — cle BUGGY
        $cache{ $key_old->($prompt) } = { ts => time(), answer => 'Arrr... et pense a Talos !' };

        # Bob (sans persona) pose la meme question — cle BUGGY identique
        my $bob_hit = $cache{ $key_old->($prompt) };
        $assert->(defined $bob_hit,
            "B2 REGRESSION-POC: Bob recoit la reponse cachee d'Alice (cle globale)");
        $assert->($bob_hit->{answer} =~ /Talos/,
            "B2 REGRESSION-POC: le contenu du pin prive d'Alice fuite vers Bob");
    }

    # -------------------------------------------------------------------------
    # Cas 4 : B2 — FIX : isolation par system prompt effectif
    # -------------------------------------------------------------------------
    {
        my $prompt      = 'raconte une blague';
        my $default_sys = 'You are a helpful IRC bot.';
        my $alice_sys   = '[Always remember: my pet is Talos] Tu es un pirate bourru.';

        my %cache;
        $cache{ $key_new->($prompt, $alice_sys) } = { answer => 'Arrr... et pense a Talos !' };

        my $bob_hit = $cache{ $key_new->($prompt, $default_sys) };
        $assert->(!defined $bob_hit,
            "B2 FIX: Bob (sys par defaut) ne recoit PAS la reponse persona d'Alice");

        # Alice elle-meme re-pose la question dans les 60s -> hit legitime
        my $alice_hit = $cache{ $key_new->($prompt, $alice_sys) };
        $assert->(defined $alice_hit && $alice_hit->{answer} =~ /Arrr/,
            "B2 FIX: Alice garde son propre cache-hit (meme sys effectif)");
    }

    # -------------------------------------------------------------------------
    # Cas 5 : B2 — dedup utile preservee entre users SANS persona
    # -------------------------------------------------------------------------
    {
        my $prompt      = 'quelle heure est-il';
        my $default_sys = 'You are a helpful IRC bot.';

        my %cache;
        # Bob pose la question -> reponse cachee sous cle (prompt, default_sys)
        $cache{ $key_new->($prompt, $default_sys) } = { answer => 'Il est 21h12.' };

        # Carol (aucun persona non plus -> meme sys effectif) pose la meme
        my $carol_hit = $cache{ $key_new->($prompt, $default_sys) };
        $assert->(defined $carol_hit,
            "B2 FIX: dedup preservee entre users au meme sys par defaut");
    }

    # -------------------------------------------------------------------------
    # Cas 6 : B2 — le pin seul (sans persona) suffit a isoler
    # -------------------------------------------------------------------------
    {
        my $prompt      = 'resume notre conversation';
        my $default_sys = 'You are a helpful IRC bot.';
        my $dave_sys    = "[Always remember: project X is secret] $default_sys";

        $assert->($key_new->($prompt, $dave_sys) ne $key_new->($prompt, $default_sys),
            "B2 FIX: un pin different => cle differente (isolation)");
    }

    # -------------------------------------------------------------------------
    # Cas 7 : B2 — casse du prompt normalisee, sys_prompt sensible a la casse
    # -------------------------------------------------------------------------
    {
        my $sys = 'You are a helpful IRC bot.';
        $assert->($key_new->('Hello', $sys) eq $key_new->('hello', $sys),
            "B2: prompt case-insensitive (dedup 'Hello'/'hello' preservee)");
        $assert->($key_new->('hello', $sys) ne $key_new->('hello', lc($sys)),
            "B2: sys_prompt compare tel quel (persona exacte requise)");
    }

    # -------------------------------------------------------------------------
    # Cas 8 : B2 — UTF-8 dans le prompt ne fait pas crasher le md5
    # -------------------------------------------------------------------------
    {
        my $sys = 'sys';
        my $k = eval { $key_new->("caf\x{e9} et \x{2615}", $sys) };
        $assert->(defined $k && $k =~ /^[0-9a-f]{32}$/,
            "B2: prompt avec caracteres UTF-8 -> md5 valide (encode avant hash)");
    }
};
