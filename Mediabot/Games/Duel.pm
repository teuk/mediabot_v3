package Mediabot::Games::Duel;

use strict;
use warnings;
use utf8;
use Exporter 'import';
use Mediabot::Helpers ();

our @EXPORT_OK = qw(
    mbDuel_ctx
);

# Resolve historical transport hooks at call time: existing callers and test
# integrations may replace them after either module has been loaded.
sub botPrivmsg { goto &Mediabot::UserCommands::botPrivmsg }
sub botNotice  { goto &Mediabot::UserCommands::botNotice }
sub logBot     { goto &Mediabot::UserCommands::logBot }
sub _ach_progress { goto &Mediabot::UserCommands::_ach_progress }

# ---------------------------------------------------------------------------
# mbDuel_ctx --- !duel <nick>
# Mini-jeu : roll de d20 chacun, le gagnant prend +1 karma, le perdant -1.
# Cooldown 24h par paire de nicks (ordre indépendant). Égalité = redite.
# ---------------------------------------------------------------------------
sub mbDuel_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    unless ($channel && $channel =~ /^#/) {
        botNotice($self, $nick, 'Syntax: !duel <nick>  (must be in a channel)'); return;
    }

    # mb118-IMP2: gate par chanset +Games (default=1 backward compat)
    unless (Mediabot::Helpers::chanset_enabled($self, $channel, 'Games', default => 1)) {
        botNotice($self, $nick, "Games are disabled on $channel (chanset -Games)");
        return;
    }

    # !duel stats [nick] — affichage des stats personnelles
    if (@args && lc($args[0]) eq 'stats') {
        shift @args;
        my $target = @args ? lc(shift @args) : lc($nick);
        my $stats = $self->{_duel_stats}{$channel}{$target} // {};
        my $w = $stats->{wins}   // 0;
        my $l = $stats->{losses} // 0;
        my $tot = $w + $l;
        my $wr = $tot > 0 ? sprintf('%.0f%%', 100*$w/$tot) : 'n/a';
        botPrivmsg($self, $channel,
            "\x{2694}\x{FE0F} $target duel record on $channel: $w win(s) / $l loss(es) (winrate $wr)");
        return 1;
    }

    # !duel top — classement des duellistes
    if (@args && lc($args[0]) eq 'top') {
        my $tbl = $self->{_duel_stats}{$channel} // {};
        unless (%$tbl) {
            botPrivmsg($self, $channel, 'No duels recorded on this channel yet.'); return 1;
        }
        my @sorted = sort {
            ($tbl->{$b}{wins} // 0) <=> ($tbl->{$a}{wins} // 0)
            || $a cmp $b
        } keys %$tbl;
        my @top = @sorted > 5 ? @sorted[0..4] : @sorted;
        my @parts;
        for my $n (@top) {
            my $w = $tbl->{$n}{wins}   // 0;
            my $l = $tbl->{$n}{losses} // 0;
            push @parts, "$n: ${w}W/${l}L";
        }
        botPrivmsg($self, $channel, "\x{2694}\x{FE0F} Top duellists: " . join('  |  ', @parts));
        return 1;
    }

    my $target = $args[0];
    unless (defined $target && $target ne '') {
        botNotice($self, $nick, 'Syntax: !duel <nick>  |  !duel stats [nick]  |  !duel top');
        return;
    }
    $target = lc($target);

    if (lc($nick) eq $target) {
        botPrivmsg($self, $channel, "$nick: you can't duel yourself \x{1F614}");
        return 1;
    }

    # Vérifier que le target est sur le canal
    my @nicks_on = eval { $self->gethChannelsNicksOnChan($channel) };
    my $bot_nick = eval { $self->{irc}->nick_folded } // '';
    unless (grep { lc($_) eq $target } @nicks_on) {
        botPrivmsg($self, $channel, "$nick: $target is not on $channel");
        return 1;
    }
    if (lc($target) eq lc($bot_nick)) {
        botPrivmsg($self, $channel,
            "\x{1F916} I don't duel mortals (I would always roll natural 20)");
        return 1;
    }

    # Cooldown 24h par paire — ordre indépendant
    my $pair_key = join("\x00", sort (lc($nick), $target));
    my $now = time();
    my $cooldown_until = $self->{_duel_cooldown}{$channel}{$pair_key} // 0;
    if ($cooldown_until > $now) {
        my $wait = $cooldown_until - $now;
        my $wait_str = $wait < 60 ? "${wait}s"
                     : $wait < 3600 ? sprintf('%dm', int($wait/60))
                     : sprintf('%dh%dm', int($wait/3600), int(($wait%3600)/60));
        botPrivmsg($self, $channel,
            "\x{1F570}\x{FE0F} $nick vs $target: cooldown active ($wait_str remaining)");
        return 1;
    }

    # Roll de d20
    my $r1 = int(rand(20)) + 1;
    my $r2 = int(rand(20)) + 1;

    # Critique 20 -> +5 bonus, fumble 1 -> -3 malus
    my $b1 = ''; my $b2 = '';
    if ($r1 == 20) { $r1 += 5; $b1 = " \x{1F525}CRIT"; }
    if ($r2 == 20) { $r2 += 5; $b2 = " \x{1F525}CRIT"; }
    if ($r1 == 1)  { $r1 -= 3; $b1 = " \x{1F4A5}FUMBLE"; }
    if ($r2 == 1)  { $r2 -= 3; $b2 = " \x{1F4A5}FUMBLE"; }

    botPrivmsg($self, $channel,
        "\x{2694}\x{FE0F} \x02$nick\x02 (\x{1F3B2}$r1$b1) vs \x02$target\x02 (\x{1F3B2}$r2$b2)");

    # Égalité
    if ($r1 == $r2) {
        botPrivmsg($self, $channel, "\x{1F91D} Draw! No cooldown applied, try again.");
        return 1;
    }

    my $winner = $r1 > $r2 ? lc($nick) : $target;
    my $loser  = $r1 > $r2 ? $target   : lc($nick);

    # Apply karma changes via in-DB update (sans passer par mbKarma_ctx → pour éviter double event)
    my $dbh = $self->{dbh};
    # mb414-R1: id canal via le helper central (cache d'abord, mb411).
    my $id_channel = Mediabot::Helpers::channel_id_cached($self, $channel) // 0;

    if ($id_channel) {
        # +1 winner
        my $sth_w = $dbh->prepare(q{
            INSERT INTO KARMA (id_channel, nick, score) VALUES (?, ?, 1)
            ON DUPLICATE KEY UPDATE score = score + 1
        });
        $sth_w->execute($id_channel, $winner) if $sth_w;
        $sth_w->finish if $sth_w;

        # -1 loser
        my $sth_l = $dbh->prepare(q{
            INSERT INTO KARMA (id_channel, nick, score) VALUES (?, ?, -1)
            ON DUPLICATE KEY UPDATE score = score - 1
        });
        $sth_l->execute($id_channel, $loser) if $sth_l;
        $sth_l->finish if $sth_l;
    }

    # Update in-memory stats
    $self->{_duel_stats}{$channel}{$winner}{wins}++;
    $self->{_duel_stats}{$channel}{$loser}{losses}++;

    # mb120-B3: tracking streak corrigé.
    #
    # Avant : le test `if (last_result eq 'win')` était évalué APRÈS qu'on vient
    # de mettre 'win' dans cette variable -> toujours vrai (test mort). Et le
    # streak du loser était simplement décrementé sans tenir compte de la
    # transition (un loser qui sortait d'une série de wins gardait son streak+).
    #
    # Convention du streak :
    #   > 0  : nombre de victoires consecutives
    #   < 0  : nombre de defaites consecutives
    #
    # Detection underdog (gagner apres 8 defaites consecutives) :
    #   - on regarde le streak du winner *avant* l'update
    #   - si <= -5, c'est un underdog
    my $prev_winner_result = $self->{_duel_last_result}{$channel}{$winner};
    my $prev_loser_result  = $self->{_duel_last_result}{$channel}{$loser};
    my $prev_winner_streak = $self->{_duel_streak}{$channel}{$winner} // 0;

    # Calcul d'eligibilite underdog AVANT update
    my $underdog_streak = $prev_winner_streak < 0 ? -$prev_winner_streak : 0;

    # Update last_result
    $self->{_duel_last_result}{$channel}{$winner} = 'win';
    $self->{_duel_last_result}{$channel}{$loser}  = 'loss';

    # Update streak winner
    if (defined $prev_winner_result && $prev_winner_result eq 'win') {
        $self->{_duel_streak}{$channel}{$winner}++;
    } else {
        # Premier duel OU transition loss -> win
        $self->{_duel_streak}{$channel}{$winner} = 1;
    }

    # Update streak loser
    if (defined $prev_loser_result && $prev_loser_result eq 'loss') {
        $self->{_duel_streak}{$channel}{$loser}--;
    } else {
        # Premier duel OU transition win -> loss
        $self->{_duel_streak}{$channel}{$loser} = -1;
    }

    # Set cooldown 24h
    $self->{_duel_cooldown}{$channel}{$pair_key} = $now + 24*3600;

    # Annonce résultat
    botPrivmsg($self, $channel,
        sprintf("\x{1F3C6} \x02%s\x02 wins! (+1 karma to %s, -1 to %s)  \x{2022}  cooldown 24h",
            $winner, $winner, $loser));

    # Hooks achievements
    if ($self->{achievements}) {
        # mb610-B1: victoires cumulees persistantes (la table memoire
        # servait de compteur et repartait a zero a chaque redemarrage).
        my $wins = _ach_progress($self, 'duel_win', $winner, $channel)
                // ($self->{_duel_stats}{$channel}{$winner}{wins} // 0);
        eval { $self->{achievements}->check_duel($winner, $channel, $wins, $underdog_streak) };
        if ($@) { $self->{logger}->log(1, "achievements check_duel error: $@") }
        # Karma achievements potentiellement aussi
        my $sth_s = $dbh->prepare("SELECT score FROM KARMA WHERE id_channel=? AND nick=?");
        if ($sth_s && $sth_s->execute($id_channel, $winner)) {
            my $r = $sth_s->fetchrow_hashref; $sth_s->finish;
            if ($r) {
                eval { $self->{achievements}->check_karma($winner, $channel, $r->{score}, undef, undef) };
            }
        }
    }

    # Metrics
    $self->{metrics}->inc('mediabot_duel_total', { channel => $channel }) if $self->{metrics};

    logBot($self, $ctx->message, $channel, 'duel', "$nick vs $target -> $winner");
    return 1;
}

1;
