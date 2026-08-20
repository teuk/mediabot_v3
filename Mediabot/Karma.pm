package Mediabot::Karma;

# =============================================================================
# Mediabot::Karma
# =============================================================================
# mb676: staged Karma extraction from Mediabot::UserCommands.
#
# Public and historical symbols are imported back into UserCommands so dispatch,
# plugins and tests keep the same Mediabot::UserCommands::* call surface.
#
# Compatibility trampolines deliberately resolve UserCommands helper symbols at
# CALL time. Existing callers that locally mock botPrivmsg/botNotice/logBot or
# _seconds_to_human therefore keep working during the staged split.
# =============================================================================

use strict;
use warnings;
use utf8;
use Exporter 'import';
use Mediabot::Helpers ();

our @EXPORT_OK = qw(
    mbKarma_ctx
    processKarma
    mbKarmaHist_ctx
    _karma_current_score
    mbKarmaWatch_ctx
    mbKarmaInfo_ctx
    mbKarmaGraph_ctx
    mbKarmaReset_ctx
    mbKarmaDiff_ctx
    mbKarmaTop_ctx
);

sub botPrivmsg        { goto &Mediabot::UserCommands::botPrivmsg }
sub botNotice         { goto &Mediabot::UserCommands::botNotice }
sub logBot            { goto &Mediabot::UserCommands::logBot }
sub _seconds_to_human { goto &Mediabot::UserCommands::_seconds_to_human }

# ---------------------------------------------------------------------------
# mbKarma_ctx --- !karma [nick]
# Show karma for a nick. nick++ / nick-- in messages auto-increment.
# Requires: CREATE TABLE KARMA (
#   id_karma INT AUTO_INCREMENT PRIMARY KEY,
#   id_channel INT NOT NULL,
#   nick VARCHAR(64) NOT NULL,
#   score INT DEFAULT 0,
#   UNIQUE KEY uniq_chan_nick (id_channel, nick)
# ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
# ---------------------------------------------------------------------------
sub mbKarma_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # mb85-B3: !karma log [nick] — déplacé ici depuis mbWordCount_ctx (S4)
    if (@args && lc($args[0]) eq 'log') {
        shift @args;
        my $filter = @args ? lc($args[0]) : undef;
        my $klog   = $self->{_karma_log}{$channel} // [];
        unless (@$klog) {
            botPrivmsg($self, $channel, "$nick: no karma history on $channel."); return 1;
        }
        my @entries = reverse @$klog;
        @entries = grep { lc($_->{nick}) eq $filter } @entries if $filter;
        @entries = @entries[0..4] if @entries > 5;
        unless (@entries) {
            botPrivmsg($self, $channel, "$nick: no karma history for '$filter'."); return 1;
        }
        for my $e (@entries) {
            my $sign = $e->{score} > 0 ? '+' : '';
            my $ago  = _seconds_to_human(time() - $e->{ts});
            botPrivmsg($self, $channel,
                "  $e->{nick} $e->{delta} (now ${sign}$e->{score}) by $e->{from} — $ago ago");
        }
        return 1;
    }

    # mb85-B3: !karma top [n] — déplacé ici depuis mbWordCount_ctx (P1)
    if (@args && lc($args[0]) eq 'top') {
        shift @args;
        $ctx->{args} = \@args;
        return mbKarmaTop_ctx($ctx);
    }

    # NEW: explicit karma vote syntax — !karma + <nick> or !karma - <nick>
    # Replaces the fragile nick++/nick-- auto-detection (triggered on e.g. Notepad++).
    if (@args >= 2 && ($args[0] eq '+' || $args[0] eq '-' || $args[0] eq '++' || $args[0] eq '--')) {
        my $op     = ($args[0] eq '+' || $args[0] eq '++') ? '++' : '--';
        my $ktarget = lc($args[1]);
        # Reject self-karma
        if ($ktarget eq lc($nick) || $ktarget eq lc(do { (my $t=$nick)=~s/\[.*?\]//g;$t })) {
            my $dest = (defined $channel && $channel =~ /^#/) ? $channel : $nick;
            botPrivmsg($self, $dest, "$nick: you can't change your own karma.");
            return 1;
        }
        # MB75-R3: explicit karma votes require a registered public channel.
        unless (defined $channel && $channel =~ /^#/) {
            botNotice($self, $nick, "$nick: use !karma + <nick> or !karma - <nick> in a registered channel.");
            return 1;
        }

        # mb410-R1: id du canal depuis le cache interne (clé canonique lc,
        # mb407) — plus de SELECT par vote. La DB reste le repli si le canal
        # n'est pas (encore) dans le cache.
        my $vote_id_channel;
        my $vote_chan_obj = $self->{channels}{lc $channel};
        $vote_id_channel = $vote_chan_obj->get_id if $vote_chan_obj;
        unless ($vote_id_channel) {
            my $sth_vote_chan = $self->{dbh}->prepare('SELECT id_channel FROM CHANNEL WHERE name = ?');
            if ($sth_vote_chan && $sth_vote_chan->execute($channel)) {
                my $vote_chan_row = $sth_vote_chan->fetchrow_hashref;
                $vote_id_channel = $vote_chan_row->{id_channel} if $vote_chan_row;
            }
            $sth_vote_chan->finish if $sth_vote_chan;
        }

        unless ($vote_id_channel) {
            botNotice($self, $nick, "$nick: this channel is not registered.");
            return 1;
        }

        my @chan_nicks = eval { $self->gethChannelsNicksOnChan($channel) };
        my $present = grep { lc($_) eq $ktarget || lc(do{(my $t=$_)=~s/\[.*?\]//g;$t}) eq $ktarget } @chan_nicks;
        unless ($present) {
            botPrivmsg($self, $channel, "$nick: $ktarget is not on this channel.");
            return 1;
        }
        # Route through processKarma with a synthetic text
        my $synthetic = "$ktarget$op";
        eval { processKarma($self, $nick, $channel, $synthetic) };
        botNotice($self, $nick, "Error: $@") if $@;
        return 1;
    }

    my $target  = $args[0] ? lc($args[0]) : lc($nick);

    # mb410-R1: id du canal depuis le cache interne (mb407), SELECT en repli.
    my $id_channel;
    my $kchan_obj = $self->{channels}{lc $channel};
    $id_channel = $kchan_obj->get_id if $kchan_obj;
    unless ($id_channel) {
        my $sth_chan = $self->{dbh}->prepare('SELECT id_channel FROM CHANNEL WHERE name = ?');
        if ($sth_chan && $sth_chan->execute($channel)) {
            my $r = $sth_chan->fetchrow_hashref;
            $sth_chan->finish;
            $id_channel = $r->{id_channel} if $r;
        }
    }
    # U1/fix: informative message instead of silent return when channel not registered
    unless ($id_channel) {
        my $dest = (defined $channel && $channel =~ /^#/) ? $channel : $nick;
        botNotice($self, $dest, defined $channel && $channel =~ /^#/
            ? "$nick: this channel is not registered."
            : "$nick: use !karma in a registered channel.");
        return 1;
    }

    my $sth = $self->{dbh}->prepare(q{
        SELECT score FROM KARMA WHERE id_channel = ? AND nick = ?
    });
    unless ($sth && $sth->execute($id_channel, $target)) {
        botNotice($self, $nick, 'Database error.'); $sth->finish if $sth; return;
    }
    my $row = $sth->fetchrow_hashref;
    $sth->finish;

    my $score = $row ? $row->{score} : 0;
    my $sign  = $score > 0 ? '+' : '';
    # Z1: show rank alongside score
    my $rank_z1 = '';
    eval {
        my $sth_r = $self->{dbh}->prepare(
            'SELECT COUNT(*)+1 AS r FROM KARMA WHERE id_channel=? AND score>?');
        if ($sth_r && $sth_r->execute($id_channel, $score)) {
            my $rr = $sth_r->fetchrow_hashref; $sth_r->finish;
            $rank_z1 = " (rank #$rr->{r})" if $rr && defined $rr->{r};
        }
    };
    botPrivmsg($self, $channel, "$target: karma ${sign}${score}${rank_z1}");
    logBot($self, $ctx->message, $channel, 'karma', $target);  # S2/fix
    return 1;
}

# ---------------------------------------------------------------------------
# processKarma($self, $nick, $channel, $text)
# Called from on_message_PRIVMSG. Detects nick++ / nick-- patterns.
# ---------------------------------------------------------------------------
sub processKarma {
    my ($self, $nick, $channel, $text) = @_;

    # fix: [^\s+\-]+ avoids greedy \S+ consuming the ++ before the pattern can catch it
    return unless defined $text && $text =~ /[^\s+\-]{2,}(\+\+|--)/;

    # mb413-R1: id canal via le helper central (cache d'abord, mb411).
    my $id_channel = Mediabot::Helpers::channel_id_cached($self, $channel);
    return unless $id_channel;

    # NOTE: nick++/nick-- auto-detection is kept but gated:
    #   1. The ++ or -- must be at end-of-word (not followed by non-space/non-punct)
    #   2. The target nick must be present on the channel
    # Use '!karma + <nick>' for reliable explicit votes.
    my $karma_hits = 0;  # C2/fix: cap at 3 karma changes per message
    my @chan_nicks_pk = eval { $self->gethChannelsNicksOnChan($channel) };
    while ($text =~ /([^\s+\-]{2,32})(\+\+|--)(?![\w+\-])/g) {
        last if ++$karma_hits > 3;
        my ($target, $op) = (lc($1), $2);
        # PRESENCE CHECK: target must be on the channel
        my $on_chan = grep {
            lc($_) eq $target
            || lc(do { (my $t = $_) =~ s/\[.*?\]//g; $t }) eq $target
        } @chan_nicks_pk;
        unless ($on_chan) { next; }  # silently skip — not on channel
        # Self-karma: block and notify — mb86-B4: metrics ajoutées ici, check Y2 redondant supprimé
        if ($target eq lc($nick) || $target eq lc(do { (my $t = $nick) =~ s/\[.*?\]//g; $t })) {
            Mediabot::Helpers::botPrivmsg($self, $channel,
                "$nick: you can't change your own karma.");
            $self->{metrics}->inc('mediabot_karma_selfvote_blocked') if $self->{metrics};
            next;
        }
        # DD9: anti-brigade guard — >5 different nicks voting for same target in 30s → block
    {
        my $now = time();
        my $brigade_key = "brigade:$target:$channel";
        # mb140-B1: tracker les NICKS DISTINCTS au lieu des hits bruts.
        # Avant ce fix, brigade->{hits} etait un arrayref de timestamps qui
        # comptait toutes les tentatives de vote, meme celles deja bloquees
        # par le cooldown anti-spam plus bas. Resultat : un seul user qui
        # spam-vote 6 fois en 30s declenchait le message "Karma brigade
        # detected for X — votes temporarily blocked" alors qu'il n'y a
        # qu'un seul voteur (deja bloque par cooldown). Le commentaire dit
        # bien ">5 different nicks", mais le code ne distinguait pas.
        # On utilise maintenant un hashref { lc(nick) => last_ts } pour
        # compter les voteurs distincts dans la fenetre de 30s.
        my $brigade = $self->{_karma_brigade}{$brigade_key}
            //= { nicks => {}, warned => 0 };
        # mb140-B1 migration: ancien format (arrayref hits) -> nouveau (hash nicks)
        if (ref($brigade->{hits}) eq 'ARRAY' && !$brigade->{nicks}) {
            $brigade->{nicks} = {};
            delete $brigade->{hits};
        }
        $brigade->{nicks}{lc($nick)} = $now;
        # Purge entries older than 30s
        for my $k (keys %{ $brigade->{nicks} }) {
            delete $brigade->{nicks}{$k}
                if ($now - $brigade->{nicks}{$k}) >= 30;
        }
        my $distinct_voters = scalar keys %{ $brigade->{nicks} };
        if ($distinct_voters > 5) {
            unless ($brigade->{warned}) {
                $brigade->{warned} = 1;
                Mediabot::Helpers::botPrivmsg($self, $channel,
                    "Karma brigade detected for $target — votes temporarily blocked.");
                $self->{logger}->log(1,
                    "DD9: karma brigade on $target in $channel ($distinct_voters distinct voters)");
            }
            $self->{metrics}->inc('mediabot_karma_brigade_blocks') if $self->{metrics};
            next;
        }
        $brigade->{warned} = 0 if $distinct_voters <= 2;
    }

    # U6: anti-spam cooldown — 30s between votes targeting the same nick
        my $cd_key = lc($nick) . ':' . lc($target);
        if (time() - ($self->{_karma_cooldown}{$channel}{$cd_key} // 0) < 30) {
            my $wait = 30 - (time() - ($self->{_karma_cooldown}{$channel}{$cd_key} // 0));
            Mediabot::Helpers::botPrivmsg($self, $channel,
                "$nick: wait ${wait}s before voting for $target again.");
            next;
        }
        $self->{_karma_cooldown}{$channel}{$cd_key} = time();
    $self->{metrics}->inc('mediabot_karma_votes_total') if $self->{metrics};  # AA6
    # FF1: notify watchers of this karma change
    # B2/fix: use $op (captured at loop start) not $2 (regex global — stale)
    for my $watcher (keys %{ $self->{_karma_watch} // {} }) {
        my $wlist = $self->{_karma_watch}{$watcher} // [];
        if (grep { $_ eq $target } @$wlist) {
            my $verb = ($op eq '++') ? 'received ++' : 'received --';
            Mediabot::Helpers::botNotice($self, $watcher,
                "[karmawatch] $target $verb karma from $nick on $channel");
        }
    }
        my $delta = ($op eq '++') ? 1 : -1;
        my $sth = $self->{dbh}->prepare(q{
            INSERT INTO KARMA (id_channel, nick, score) VALUES (?, ?, ?)
            ON DUPLICATE KEY UPDATE score = score + ?
        });
        next unless $sth && $sth->execute($id_channel, $target, $delta, $delta);
        $sth->finish;

        # Fetch updated score
        my $sth2 = $self->{dbh}->prepare('SELECT score FROM KARMA WHERE id_channel = ? AND nick = ?');
        if ($sth2 && $sth2->execute($id_channel, $target)) {
            my $row = $sth2->fetchrow_hashref; $sth2->finish;
            my $score = $row ? $row->{score} : $delta;
            my $sign  = $score > 0 ? '+' : '';

            # T4: compute rank on channel
            my $rank_str = '';
            eval {
                my $sth_rank = $self->{dbh}->prepare(
                    'SELECT COUNT(*)+1 AS rank FROM KARMA WHERE id_channel=? AND score>?'
                );
                if ($sth_rank && $sth_rank->execute($id_channel, $score)) {
                    my $rr = $sth_rank->fetchrow_hashref;
                    $sth_rank->finish;
                    $rank_str = " (rank #$rr->{rank})" if $rr && defined $rr->{rank};
                }
            };

            Mediabot::Helpers::botPrivmsg(
                $self,
                $channel,
                "$target\'s karma: ${sign}${score}${rank_str}"
            );

        # mb115: hook achievements karma (positifs : score atteint, gift_giver pour le donneur)
        if ($self->{achievements}) {
            # Pour gift_giver, on compte les +1 donnés par $nick sur le canal — via ring buffer.
            # mb453-B1 (off-by-one): $given_pos était calculé AVANT que le vote
            # courant soit poussé dans _karma_log (le push est plus bas), donc le
            # don en cours n'était pas compté — gift_giver (seuil 100) se
            # débloquait au 101e don au lieu du 100e. On amorce à 1 quand le vote
            # courant est lui-même un don positif (++), 0 sinon.
            my $given_pos = ($op eq '++') ? 1 : 0;
            for my $e (@{ $self->{_karma_log}{$channel} // [] }) {
                $given_pos++ if defined $e->{from} && lc($e->{from}) eq lc($nick) && ($e->{delta} // '') eq '+1';
            }
            eval {
                $self->{achievements}->check_karma($target, $channel, $score, $nick, $given_pos);
            };
            if ($@) { $self->{logger}->log(1, "achievements check_karma error: $@"); }
        }

        # I4: append to in-memory karma log (ring buffer, max 20 per channel)
        my $klog = $self->{_karma_log}{$channel} //= [];
        push @$klog, {
            ts    => time(),
            nick  => $target,
            delta => ($op eq '++' ? '+1' : '-1'),
            score => $score,
            from  => $nick,
        };
        splice @$klog, 0, @$klog - 500 if @$klog > 500;  # IMP3: 500 entries (was 20)
        # I8: persist to KARMA_LOG if table exists (graceful — skip on error)
        eval {
            my $sth_log = $self->{dbh}->prepare(q{
                INSERT IGNORE INTO KARMA_LOG
                    (id_channel, nick, delta, from_nick, score, ts)
                VALUES (?, ?, ?, ?, ?, NOW())
            });

            if ($sth_log && $sth_log->execute($id_channel, $target,
                    ($op eq '++' ? 1 : -1), $nick, $score)) {
                $sth_log->finish;
            }
            else {
                $sth_log->finish if $sth_log;
            }
        };  # silently ignore if KARMA_LOG table doesn't exist yet
        }
    }
}

# ---------------------------------------------------------------------------
# mbKarmaHist_ctx --- !karmahist [nick]
# Show the last karma changes on the channel (optionally filtered by nick).
# ---------------------------------------------------------------------------
sub mbKarmaHist_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
    my $filter  = @args ? lc($args[0]) : undef;

    # I8: try DB first, fall back to in-memory ring buffer
    my @db_entries;
    eval {
        # mb414-R1: id canal via le helper central (cache d'abord, mb411).
        my $cid_kl = Mediabot::Helpers::channel_id_cached($self, $channel);
        {
            my $rc = defined($cid_kl) ? { id_channel => $cid_kl } : undef;
            if ($rc) {
                my $sth_hl = $self->{dbh}->prepare(q{
                    SELECT nick, delta, from_nick, score,
                           UNIX_TIMESTAMP(ts) AS ts
                    FROM KARMA_LOG WHERE id_channel = ?
                    ORDER BY ts DESC LIMIT 20
                });
                if ($sth_hl && $sth_hl->execute($rc->{id_channel})) {
                    while (my $r = $sth_hl->fetchrow_hashref) {
                        push @db_entries, {
                            nick  => $r->{nick},
                            delta => ($r->{delta} > 0 ? '+1' : '-1'),
                            from  => $r->{from_nick},
                            score => $r->{score},
                            ts    => $r->{ts},
                        };
                    }
                    $sth_hl->finish;
                }
            }
        }
    };  # silently fall back to in-memory if KARMA_LOG not available
    # KH1/fix: in PM, search in-memory log across all channels
    my $kh_chan = (defined $channel && $channel =~ /^#/) ? $channel : undef;
    my @klog_mem_entries;
    if ($kh_chan) {
        @klog_mem_entries = @{ $self->{_karma_log}{$kh_chan} // [] };
    } else {
        for my $ch (keys %{ $self->{_karma_log} // {} }) {
            push @klog_mem_entries, @{ $self->{_karma_log}{$ch} // [] };
        }
    }
    my @klog_combined = @db_entries ? @db_entries : @klog_mem_entries;
    my $klog = \@klog_combined;
    my $kh_reply = $kh_chan // $nick;
    unless (@$klog) {
        botPrivmsg($self, $kh_reply,
            "$nick: no karma history yet" . ($kh_chan ? " on $channel" : '') . ".");
        return 1;
    }

    my $kh_source = @db_entries ? '' : ' [memory]';
    my @entries = reverse @$klog;  # most recent first
    if ($filter) {
        @entries = grep { lc($_->{nick}) eq $filter } @entries;
        unless (@entries) {
            botPrivmsg($self, $kh_reply, "$nick: no karma history for '$filter' on $channel.");
            return 1;
        }
    }
    @entries = @entries[0..4] if @entries > 5;  # show last 5

    my $label = $filter ? "karma history for $filter" : "recent karma changes";
    # U4/fix: use $kh_chan (not $channel which is nick in PM)
    my $on_str = $kh_chan ? " on $kh_chan" : '';
    # GG1: add +/- vote summary in header
    my $kh_pos = scalar grep { ($_->{delta}//"") eq "+1" } @entries;
    my $kh_neg = scalar(@entries) - $kh_pos;
    my $kh_summary = @entries ? " (+$kh_pos/-$kh_neg)" : "";
    botPrivmsg($self, $kh_reply, "$nick: $label$on_str$kh_summary$kh_source:");
    for my $e (@entries) {
        my $sign  = $e->{score} > 0 ? '+' : '';
        my $delta = $e->{delta};
        my $ago   = _seconds_to_human(time() - $e->{ts});
        botPrivmsg($self, $kh_reply,
            "  $e->{nick} $delta (now ${sign}$e->{score}) by $e->{from} — $ago ago");
    }
    logBot($self, $ctx->message, $channel, 'karmahist', $filter // '');
    # L3: Prometheus counter for !karmahist
    $self->{metrics}->inc('mediabot_karmahist_requests_total') if $self->{metrics};
    return 1;
}

# ---------------------------------------------------------------------------
# mbKarmaWatch_ctx --- !karmawatch [nick]  (FF1)
# Watch a nick's karma changes — receive a NOTICE when someone votes for them.
# !karmawatch         → toggle watch on yourself
# !karmawatch <nick>  → toggle watch on that nick
# !karmawatch list    → show your active watches
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# _karma_current_score($self, $nick)  (mb459-B1)
# Shared "current karma score": the score of the MOST RECENT karma_log entry
# (max ts) for $nick across ALL channels, or undef if none.
#
# Single source of truth for the selection that was copy-pasted (and identically
# buggy) in !karmawatch list (mb457) and !karmadiff (mb458): both used
# `keys %_karma_log` (hash order) + `last`, returning an arbitrary/stale
# channel's score. Centralising the max-ts logic keeps them deterministic and
# stops the pattern from being re-introduced by copy-paste.
# ---------------------------------------------------------------------------
sub _karma_current_score {
    my ($self, $nick, $channel) = @_;

    # mb464-B1: karma scores are channel-scoped in SQL.  When a caller is
    # operating in a channel (notably !karmadiff), only that channel may supply
    # the displayed "current" score.  PM/global callers keep the historical
    # all-channel view.  Sort channel keys and apply an explicit tie-break so
    # two votes recorded in the same integer second never reintroduce hash-order
    # nondeterminism.
    my @channels = sort { lc($a) cmp lc($b) || $a cmp $b }
                   keys %{ $self->{_karma_log} // {} };
    if (defined $channel && $channel ne '') {
        @channels = grep { lc($_) eq lc($channel) } @channels;
    }

    my ($best, $best_ts, $best_channel, $best_index);
    for my $ch (@channels) {
        my $entries = $self->{_karma_log}{$ch} // [];
        for my $idx (0 .. $#$entries) {
            my $e = $entries->[$idx];
            next unless defined $e->{nick}
                     && lc($e->{nick}) eq lc($nick)
                     && defined $e->{score};

            my $ts = $e->{ts} // 0;
            my $channel_key = lc($ch);
            if (!defined $best
                || $ts > $best_ts
                || ($ts == $best_ts && $channel_key gt $best_channel)
                || ($ts == $best_ts && $channel_key eq $best_channel
                    && $idx > $best_index)) {
                ($best, $best_ts, $best_channel, $best_index)
                    = ($e, $ts, $channel_key, $idx);
            }
        }
    }
    return defined $best ? $best->{score} : undef;
}

sub mbKarmaWatch_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # !karmawatch list
    if (@args && lc($args[0]) eq 'list') {
        my $watching = $self->{_karma_watch}{lc $nick} // [];
        unless (@$watching) {
            botNotice($self, $nick, 'You are not watching any karma targets.');
            return 1;
        }
        # IMP19: show current karma score for each watched nick.
        # mb459-B1: delegate to the shared _karma_current_score() helper
        # (most recent entry, max ts, all channels) — single source of truth.
        my @watch_with_scores;
        for my $wt (@$watching) {
            my $sc = _karma_current_score($self, $wt);
            my $score_str = defined $sc ? ($sc >= 0 ? "+$sc" : "$sc") : '';
            push @watch_with_scores, $score_str ne '' ? "$wt ($score_str)" : $wt;
        }
        botNotice($self, $nick, 'You are watching: ' . join(', ', @watch_with_scores));
        return 1;
    }

    my $target = @args ? lc($args[0]) : lc($nick);
    my $watchers = $self->{_karma_watch}{lc $nick} //= [];

    # Toggle: add if not watching, remove if already watching
    my $idx = do { my $i = 0; my $found = -1;
        for (@$watchers) { $found = $i if $_ eq $target; $i++; } $found };
    if ($idx >= 0) {
        splice @$watchers, $idx, 1;
        botNotice($self, $nick, "Stopped watching karma for $target.");
    } else {
        if (scalar @$watchers >= 5) {
            botNotice($self, $nick, 'Max 5 watches reached. Remove one first (!karmawatch <nick> to toggle off).');
            return 1;
        }
        push @$watchers, $target;
        botNotice($self, $nick, "Now watching karma for $target. You will be notified of any votes.");
    }
    return 1;
}

# ---------------------------------------------------------------------------
# mbKarmaInfo_ctx --- !karmainfo <nick>  (BB5)
# Show detailed karma stats for a nick from _karma_log.
# ---------------------------------------------------------------------------
sub mbKarmaInfo_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
    my $target  = @args ? lc(shift @args) : lc($nick);

    # mb113-IMP1: mode 'all' — recherche cross-canal
    my $all_chans = 0;
    if (@args && lc($args[0]) eq 'all') {
        $all_chans = 1;
        shift @args;
    }

    # mb112-IMP1: période optionnelle Nd/Nh — borner le ring buffer
    my $window_secs;
    my $window_label = '';
    if (@args && $args[0] =~ /^(\d+)(d|h)$/i) {
        my ($val, $unit) = ($1, lc $2);
        $window_secs  = $unit eq 'h' ? $val * 3600 : $val * 86400;
        $window_secs  = 3600    if $window_secs < 3600;
        $window_secs  = 2592000 if $window_secs > 2592000;
        $window_label = " (last ${val}${unit})";
        shift @args;
    }
    my $since = defined $window_secs ? time() - $window_secs : 0;

    # KI1/fix: karmainfo works in PM — use $channel if public, else nick-scoped log
    # mb113-IMP1: mode 'all' force la recherche cross-canal
    my $klog_chan = (!$all_chans && defined $channel && $channel =~ /^#/) ? $channel : undef;
    my @entries;
    if ($klog_chan) {
        my $klog = $self->{_karma_log}{$klog_chan} // [];
        @entries = grep { lc($_->{nick}) eq $target && ($_->{ts}//0) >= $since } @$klog;
    } else {
        # PM ou mode all: search across all channels
        for my $ch (keys %{ $self->{_karma_log} // {} }) {
            push @entries, grep { lc($_->{nick}) eq $target && ($_->{ts}//0) >= $since }
                @{ $self->{_karma_log}{$ch} // [] };
        }
    }
    my $all_label  = $all_chans ? ' (all channels)' : '';
    my $reply_to   = $klog_chan // $nick;
    unless (@entries) {
        botPrivmsg($self, $reply_to, "$target: no karma activity in log$window_label$all_label."); return 1;
    }
    my ($received_pos, $received_neg, $given_pos, $given_neg) = (0,0,0,0);
    my %givers;
    for my $e (@entries) {
        if (($e->{delta} // '') eq '+1') { $received_pos++; }  # B24/fix
        else                             { $received_neg++; }
        $givers{$e->{from} // $e->{giver} // ''}++  # B23/fix: field is 'from' not 'giver'
            if ($e->{from} // $e->{giver} // '');
    }
    # KI1/fix2: use all_entries (collected across channels) for @given too
    my @all_entries_for_given;
    if ($klog_chan) {
        @all_entries_for_given = @{ $self->{_karma_log}{$klog_chan} // [] };
    } else {
        for my $ch (keys %{ $self->{_karma_log} // {} }) {
            push @all_entries_for_given, @{ $self->{_karma_log}{$ch} // [] };
        }
    }
    my @given = grep { lc(($_->{from} // $_->{giver} // '')) eq $target } @all_entries_for_given;
    # B23/fix: _karma_log uses 'from' key, not 'giver'
    for my $e (@given) {
        if (($e->{delta} // '') eq '+1') { $given_pos++; }  # B24/fix
        else                             { $given_neg++; }
    }
    # U2/fix: deterministic sort on ties (lc nick), show giver vote count
    my ($top_giver, $top_giver_count);
    if (%givers) {
        my @sorted_givers = sort {
            $givers{$b} <=> $givers{$a} || lc($a) cmp lc($b)
        } keys %givers;
        $top_giver       = $sorted_givers[0];
        $top_giver_count = $givers{$top_giver};
    } else {
        $top_giver = 'nobody'; $top_giver_count = 0;
    }
    my $net_received = $received_pos - $received_neg;
    my $sign = $net_received >= 0 ? '+' : '';
    # IMP6: show current score from last known log entry
    my $last_score = @entries ? $entries[-1]{score} : undef;
    # II15: find oldest entry for 'since' info
    my $oldest_ts = @entries ? (sort { $a->{ts} <=> $b->{ts} } @entries)[0]{ts} : 0;
    my $since_str = '';
    if ($oldest_ts) {
        my $age_d = int((time() - $oldest_ts) / 86400);
        $since_str = " (last ${age_d}d in log)" if $age_d > 0;
    }
    my $score_str  = defined $last_score
        ? ' [score: ' . ($last_score >= 0 ? "+$last_score" : "$last_score") . ']'
        : '';
    # V1: positivity ratio — must be computed BEFORE the botPrivmsg call
    my $recv_total = $received_pos + $received_neg;
    my $pct_pos    = $recv_total > 0 ? int(100 * $received_pos / $recv_total) : 0;
    my $pct_str    = $recv_total > 0 ? ", ${pct_pos}% \x{2191}" : "";
    botPrivmsg($self, $reply_to,
        "karmainfo $target$score_str$since_str [memory]$window_label$all_label: received ${sign}${net_received} "
        . "(+${received_pos}/-${received_neg}${pct_str})"
        . " | given: +${given_pos}/-${given_neg}"
        . " | top voter: $top_giver" . ($top_giver_count ? " (${top_giver_count}x)" : ''));
    return 1;
}

# ---------------------------------------------------------------------------
# mbKarmaGraph_ctx --- !karma graph [nick]  (AA4)
# ASCII sparkline of karma changes over the last 7 days (from _karma_log).
# ---------------------------------------------------------------------------
sub mbKarmaGraph_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    # KG1/fix: sparkline requires a public channel context
    unless (defined $channel && $channel =~ /^#/) {
        botNotice($self, $nick, '!karmgraph requires a channel context. Use it in a channel.');
        return 1;
    }
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
    # Remove 'graph' keyword if called as '!karma graph'
    shift @args if (@args && lc($args[0]) eq 'graph');
    my $target  = @args ? lc($args[0]) : lc($nick);
    my $klog    = $self->{_karma_log}{$channel} // [];
    my $now     = time();
    my $days    = 7;
    # Build a bucket per day (today=6, yesterday=5, ... 7 days ago=0)
    my @buckets = (0) x $days;
    for my $entry (@$klog) {
        next unless lc($entry->{nick}) eq $target;
        my $age_days = int(($now - $entry->{ts}) / 86400);
        next if $age_days < 0;     # A16/fix: future ts (clock skew) → skip
        next if $age_days >= $days;
        my $bucket = $days - 1 - $age_days;  # most recent = rightmost
        $buckets[$bucket] += ($entry->{delta} eq '+1' ? 1 : -1);
    }
    # Check if any activity
    unless (grep { $_ != 0 } @buckets) {
        botPrivmsg($self, $channel,
            "$target: no karma activity in the last ${days} days.");
        return 1;
    }
    # Sparkline: map delta to block chars
    # ▁▂▃▄▅▆▇█ for positive, ▼ for negative, · for zero
    # mb84-B4: single-quoted \x{NNNN} ne sont pas interpolées en Perl → double-quotes requises
    my @spark_pos = ("\x{2581}","\x{2582}","\x{2583}","\x{2584}",
                     "\x{2585}","\x{2586}","\x{2587}","\x{2588}");
    my $max = (sort { $b <=> $a } map { abs($_) } @buckets)[0] || 1;
    my $spark = '';
    for my $v (@buckets) {
        if ($v == 0)    { $spark .= "\xb7"; }          # middle dot ·
        elsif ($v < 0)  { $spark .= "\x{25bc}"; }      # ▼
        else {
            my $idx = int(($v / $max) * 7);  # 0..7
            $spark .= $spark_pos[$idx];
        }
    }
    # B5/fix: guard against undef delta in _karma_log entries
    my $total = 0;
    $total += (($_ // '') eq '+1' ? 1 : -1)
        for map { $_->{delta} } grep {
            defined $_->{delta} && lc($_->{nick}) eq $target
            && $now - ($_->{ts} // 0) < $days * 86400
        } @$klog;
    my $sign = $total >= 0 ? '+' : '';
    botPrivmsg($self, $channel,
        "karma graph $target (7d) $spark  net: ${sign}${total}");
    return 1;
}

sub mbKarmaReset_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
    return unless $ctx->require_level('Master');

    my $target = lc($args[0] // '');
    unless ($target) {
        botNotice($self, $nick, 'Syntax: karmareset <nick>'); return;
    }

    # mb411-R1: id canal via le helper central (cache d'abord).
    my $cid_kr = Mediabot::Helpers::channel_id_cached($self, $channel);
    return unless defined $cid_kr;
    my $rc = { id_channel => $cid_kr };

    # W3: read current score before reset for informative message
    my $old_score = 0;
    {
        my $sth_sc = $self->{dbh}->prepare(
            'SELECT score FROM KARMA WHERE id_channel = ? AND nick = ?');
        if ($sth_sc && $sth_sc->execute($rc->{id_channel}, $target)) {
            my $r = $sth_sc->fetchrow_hashref;
            $old_score = $r->{score} // 0 if $r;
            $sth_sc->finish;
        }
    }
    my $sth = $self->{dbh}->prepare(q{
        UPDATE KARMA SET score = 0
        WHERE id_channel = ? AND nick = ?
    });
    unless ($sth && $sth->execute($rc->{id_channel}, $target)) {
        botNotice($self, $nick, 'Database error.'); $sth->finish if $sth; return;
    }
    my $rows = $sth->rows; $sth->finish;
    if ($rows > 0) {
        my $was = $old_score >= 0 ? "+$old_score" : "$old_score";
        Mediabot::Helpers::botPrivmsg($self, $channel,
            "$nick reset karma for $target to 0 (was $was).");
        logBot($self, $ctx->message, $channel, 'karmareset', $target);
    } else {
        botNotice($self, $nick, "No karma entry found for '$target' on $channel.");
    }
    return 1;
}


# ---------------------------------------------------------------------------
# mbKarmaDiff_ctx --- !karmadiff [nick]  (Z7)
# Show karma delta from the in-memory log (today's changes).
# ---------------------------------------------------------------------------
sub mbKarmaDiff_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # mb109-IMP1: !karmadiff all [period] — top 5 variations sur la période
    if (@args && lc($args[0]) eq 'all') {
        shift @args;
        my $window_secs  = 86400;
        my $window_label = '24h';
        if (@args && $args[0] =~ /^(\d+)(d|h)$/) {
            my ($val, $unit) = ($1, $2);
            $window_secs  = $unit eq 'h' ? $val * 3600 : $val * 86400;
            $window_secs  = 3600    if $window_secs < 3600;
            $window_secs  = 2592000 if $window_secs > 2592000;
            $window_label = "${val}${unit}";
        }
        my $kd_chan = (defined $channel && $channel =~ /^#/) ? $channel : undef;
        my @all_entries;
        if ($kd_chan) {
            @all_entries = @{ $self->{_karma_log}{$kd_chan} // [] };
        } else {
            for my $ch (keys %{ $self->{_karma_log} // {} }) {
                push @all_entries, @{ $self->{_karma_log}{$ch} // [] };
            }
        }
        my $now   = time();
        my $since = $now - $window_secs;
        my %deltas;
        for my $e (grep { ($_->{ts} // 0) >= $since } @all_entries) {
            $deltas{lc($e->{nick})} += (($e->{delta} // '') eq '+1' ? 1 : -1);
        }
        unless (%deltas) {
            botPrivmsg($self, $kd_chan // $nick, "No karma activity in the last $window_label.");
            return 1;
        }
        my @sorted = (sort { abs($deltas{$b}) <=> abs($deltas{$a}) || $a cmp $b } keys %deltas)[0..4];
        @sorted = grep { defined } @sorted;
        my @parts = map {
            my $d = $deltas{$_};
            my $sign = $d > 0 ? '+' : '';
            "$_: ${sign}${d}"
        } @sorted;
        botPrivmsg($self, $kd_chan // $nick,
            "Karma top movers (last $window_label): " . join('  |  ', @parts));
        return 1;
    }

    my $target  = @args ? lc($args[0]) : lc($nick);

    # mb89-IMP1 / mb108-IMP2: fenêtre temporelle configurable
    # Formes acceptées : 6h, 12h, 24h (défaut), 7d — et maintenant toute forme Nd/Nh
    my $window_secs  = 86400;
    my $window_label = '24h';
    if (@args >= 2) {
        my $w = lc($args[1]);
        if ($w =~ /^(\d+)(d|h)$/) {
            my ($val, $unit) = ($1, $2);
            $window_secs  = $unit eq 'h' ? $val * 3600 : $val * 86400;
            $window_secs  = 3600    if $window_secs < 3600;    # min 1h
            $window_secs  = 2592000 if $window_secs > 2592000; # max 30d
            $window_label = "${val}${unit}";
        } else {
            botNotice($self, $nick, "Unknown window '$w'. Use: 6h 12h 24h 7d 30d ...");
            return;
        }
    }

    # KD1/fix: search across all channels in PM
    my $kd_chan = (defined $channel && $channel =~ /^#/) ? $channel : undef;
    my @kd_entries_all;
    if ($kd_chan) {
        push @kd_entries_all, @{ $self->{_karma_log}{$kd_chan} // [] };
    } else {
        for my $ch (keys %{ $self->{_karma_log} // {} }) {
            push @kd_entries_all, @{ $self->{_karma_log}{$ch} // [] };
        }
    }
    my $now   = time();
    my $since = $now - $window_secs;
    my @entries = grep { lc($_->{nick}) eq $target && ($_->{ts} // 0) >= $since } @kd_entries_all;
    my $reply_to_kd = $kd_chan // $nick;
    unless (@entries) {
        botPrivmsg($self, $reply_to_kd,
            "$target: no karma changes in the last $window_label."); return 1;
    }
    my $delta = 0;
    $delta += (($_ ->{delta} // '') eq '+1' ? 1 : -1) for @entries;
    my $sign  = $delta > 0 ? '+' : '';

    # mb89-IMP1: top 3 givers dans la fenêtre
    my %givers_w;
    for my $e (@entries) {
        my $g = $e->{from} // $e->{giver} // '';
        $givers_w{$g}++ if $g;
    }
    my @top_givers = (sort { $givers_w{$b} <=> $givers_w{$a} || $a cmp $b }
                      keys %givers_w)[0..2];
    @top_givers = grep { defined } @top_givers;
    my $givers_str = @top_givers
        ? '  | by: ' . join(', ', map { "$_($givers_w{$_})" } @top_givers)
        : '';

    # CC11: fetch current score.
    # mb459/mb464: shared _karma_current_score() helper.  In a channel, the
    # displayed score is scoped to that same channel; in PM, it uses the
    # deterministic all-channel view (see also !karmawatch list).
    my $cur_score = _karma_current_score($self, $target, $kd_chan);
    my $score_info = defined $cur_score
        ? ', score: ' . ($cur_score >= 0 ? "+$cur_score" : "$cur_score")
        : '';

    botPrivmsg($self, $reply_to_kd,
        "$target: karma ${sign}${delta} in last $window_label ("
        . scalar(@entries) . " vote(s)$score_info)$givers_str");
    logBot($self, $ctx->message, $channel, 'karmadiff', $target);
    return 1;
}

# ---------------------------------------------------------------------------
# mbKarmaTop_ctx --- !karmatop [n]
# Show the top N karma scores on the channel.
# ---------------------------------------------------------------------------
sub mbKarmaTop_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    my $n = 5;
        # Q5: 'bottom' subcommand shows lowest karma scores
        my $bottom_mode = (@args && lc($args[0]) eq 'bottom') ? 1 : 0;
        shift @args if $bottom_mode;
    if (@args && $args[0] =~ /^\d+$/) {
        $n = int($args[0]); $n = 1 if $n < 1; $n = 10 if $n > 10;
    }

    # mb413-R1: id canal via le helper central (cache d'abord, mb411).
    my $id_channel = Mediabot::Helpers::channel_id_cached($self, $channel);
    return unless $id_channel;

    my $order = $bottom_mode ? 'ASC' : 'DESC';
    my $sth = $self->{dbh}->prepare(
        "SELECT nick, score FROM KARMA WHERE id_channel = ? ORDER BY score $order LIMIT ?"
    );
    unless ($sth && $sth->execute($id_channel, $n)) {
        botNotice($self, $nick, 'Database error.'); $sth->finish if $sth; return;
    }
    my @rows;
    while (my $r = $sth->fetchrow_hashref) { push @rows, $r; }
    $sth->finish;

    unless (@rows) {
        botPrivmsg($self, $channel, "No karma data for $channel yet.");
        return 1;
    }

    # EE1: compute 24h delta per nick from _karma_log ring buffer
    my $klog    = $self->{_karma_log}{$channel} // [];
    my $now_ee1 = time();
    my %delta24;
    for my $e (@$klog) {
        next unless ($now_ee1 - ($e->{ts} // 0)) < 86400;
        $delta24{lc($e->{nick})} += (($e->{delta} // '') eq '+1' ? 1 : -1);
    }
    my $label = $bottom_mode ? "Karma bottom $n" : "Karma top $n";
    botPrivmsg($self, $channel, "$label on $channel:");
    my $rank = 1;
    for my $r (@rows) {
        my $sign = $r->{score} > 0 ? '+' : '';
        my $d    = $delta24{lc($r->{nick})} // 0;
        my $dstr = $d > 0 ? " (\x{2191}${d} today)"
                 : $d < 0 ? " (\x{2193}" . abs($d) . " today)"
                 : '';
        botPrivmsg($self, $channel, sprintf('  %2d. %-20s %s%d%s',
            $rank++, $r->{nick}, $sign, $r->{score}, $dstr));
    }
    return 1;
}

1;
