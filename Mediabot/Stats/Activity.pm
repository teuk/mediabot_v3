package Mediabot::Stats::Activity;

use strict;
use warnings;
use utf8;
use Exporter 'import';
use Mediabot::Helpers ();

our @EXPORT_OK = qw(
    mbStats_ctx
    mbTop_ctx
    mbActive_ctx
    mbWhen_ctx
    mbCompare_ctx
    mbHeatmap_ctx
    mbMonthStats_ctx
);

# Keep call-time compatibility with the existing command facade. Registry,
# transport and test integrations still use UserCommands' historical hooks.
sub botPrivmsg { goto &Mediabot::UserCommands::botPrivmsg }
sub botNotice  { goto &Mediabot::UserCommands::botNotice }
sub logBot     { goto &Mediabot::UserCommands::logBot }
sub getIdUser { goto &Mediabot::UserCommands::getIdUser }

# ---------------------------------------------------------------------------
# mbStats_ctx — !stats [nick]
# Show IRC activity stats for a nick: message count, last seen, join date.
# ---------------------------------------------------------------------------
sub mbStats_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    my $target = $args[0] ? lc($args[0]) : lc($nick);
    my $channel_timezone = eval {
        my $channel_obj = $self->{channels}{lc($channel // '')};
        $channel_obj ? $channel_obj->get_timezone : undef;
    } || 'UTC';
    my $sql_timezone = $channel_timezone eq 'UTC'
        ? '+00:00' : $channel_timezone;

    # Message count + last real message on this channel.
    # MB75-S1: exclude the stats command itself from the aggregate, otherwise
    # "m stats" immediately becomes the user's last message and always shows 0h ago.
    # mb576-B1: compteurs carriere -> vif + archive par requetes par table.
    # mb576-B1: une petite requete PAR TABLE + fusion Perl — jamais de
    # UNION ALL derive (WHERE pousses mais pas ORDER/LIMIT ; les COUNT
    # materialisent). Comparaisons de ts au format fixe -> gt/lt suffisent.
    # mb577-B1: scope content (l'archive n'est jointe que si CONTENT_DAYS>0),
    # event_type explicite (des « msg » ne comptent pas la presence), et le
    # succes se lit sur live_ok — zero ligne est un succes valide.
    # mb578-B1: msg_count et last_msg restent des MESSAGES (public/action,
    # scope content) ; first_seen redevient la PREMIERE TRACE du nick —
    # tout event_type, scope 'all' (un JOIN archive anterieur au premier
    # message fait foi). La revue avait raison : mb577 avait change
    # « join date » en « date du premier message ».
    my ($msg_count, $last_msg, $first_seen) = (0, undef, undef);
    my $stats_g = Mediabot::Helpers::channel_log_gather($self, $self->{dbh}, q{
        SELECT COUNT(*)  AS msg_count,
               MAX(ts)  AS last_msg
        FROM __CLSRC__ cl
        JOIN CHANNEL c ON c.id_channel = cl.id_channel
        WHERE LOWER(cl.nick) = LOWER(?)
          AND c.name = ?
          AND cl.event_type IN ('public','action')
          AND NOT (
              LOWER(TRIM(COALESCE(cl.publictext, ''))) REGEXP '^m[[:space:]]+stats([[:space:]]|$)'
              OR LOWER(TRIM(COALESCE(cl.publictext, ''))) REGEXP '^!stats([[:space:]]|$)'
          )
    }, [ $target, $channel ], sub {
        my ($r) = @_;
        $msg_count += $r->{msg_count} // 0;
        $last_msg = $r->{last_msg}
            if defined $r->{last_msg}
            && (!defined $last_msg || $r->{last_msg} gt $last_msg);
    }, 'content');
    unless ($stats_g->{live_ok}) {
        botNotice($self, $nick, "Database error.");
        return;
    }
    my $stats_first_g = Mediabot::Helpers::channel_log_gather($self, $self->{dbh}, q{
        SELECT MIN(cl.ts) AS first_seen
        FROM __CLSRC__ cl
        JOIN CHANNEL c ON c.id_channel = cl.id_channel
        WHERE LOWER(cl.nick) = LOWER(?)
          AND c.name = ?
    }, [ $target, $channel ], sub {
        $first_seen = $_[0]->{first_seen}
            if defined $_[0]->{first_seen}
            && (!defined $first_seen || $_[0]->{first_seen} lt $first_seen);
    }, 'all');
    unless ($stats_first_g->{live_ok}) {
        botNotice($self, $nick, "Database error.");
        return;
    }
    $last_msg //= 'never';

    # A1: total messages on channel for percentage (global, no period filter)
    # Keep the denominator aligned with the user aggregate above.
    # mb578-B1: gather indispensable (les pourcentages en dependent) —
    # panne LIVE = echec franc, jamais un pct calcule sur un total absent.
    my $total = 0;
    my $stats_tot_g = Mediabot::Helpers::channel_log_gather($self, $self->{dbh}, q{
        SELECT COUNT(*) AS total
        FROM __CLSRC__ cl
        JOIN CHANNEL c ON c.id_channel = cl.id_channel
        WHERE c.name = ?
          AND cl.event_type IN ('public','action')
          AND NOT (
              LOWER(TRIM(COALESCE(cl.publictext, ''))) REGEXP '^m[[:space:]]+stats([[:space:]]|$)'
              OR LOWER(TRIM(COALESCE(cl.publictext, ''))) REGEXP '^!stats([[:space:]]|$)'
          )
    }, [ $channel ], sub { $total += $_[0]->{total} // 0 }, 'content');
    unless ($stats_tot_g->{live_ok}) {
        botNotice($self, $nick, "Database error.");
        return;
    }
    my $pct = ($total > 0 && $msg_count > 0)
        ? sprintf(" (%.1f%%)", 100 * $msg_count / $total) : '';

    # S7/fix: fetch karma score for inline display in !stats
    my $karma_str = '';
    {
        my $dbh_k = eval { $self->{db}->ensure_connected } // $self->{dbh};  # C3/fix
        # mb414-R1: id canal via le helper central (cache d'abord, mb411).
        my $cid_ks = Mediabot::Helpers::channel_id_cached($self, $channel);
        {
            my $rc = defined($cid_ks) ? { id_channel => $cid_ks } : undef;
            if ($rc) {
                my $sth_k = $dbh_k->prepare(
                    'SELECT score FROM KARMA WHERE id_channel = ? AND nick = ?');
                if ($sth_k && $sth_k->execute($rc->{id_channel}, lc($target))) {
                    my $kr = $sth_k->fetchrow_hashref; $sth_k->finish;
                    if ($kr) {
                        my $sign = $kr->{score} > 0 ? '+' : '';
                        $karma_str = " | karma ${sign}$kr->{score}";
                    }
                }
            }
        }
    }

    # Last seen (USER_SEEN)
    my $sth2 = $self->{dbh}->prepare(q{
        SELECT seen_at, event_type FROM USER_SEEN WHERE nick = ?
        ORDER BY seen_at DESC LIMIT 1
    });
    unless ($sth2 && $sth2->execute($target)) {
        botNotice($self, $nick, "Database error.");
        $sth2->finish if $sth2;
        return;
    }
    my $seen_row  = $sth2->fetchrow_hashref;
    $sth2->finish;

    # MB75-R5: USER_SEEN may have no row for this nick.
    my $seen_at   = $seen_row ? ($seen_row->{seen_at}    // 'never') : 'never';
    my $seen_type = $seen_row ? ($seen_row->{event_type} // '')      : '';

    # User level (if registered)
    my $level_desc = '';
    my $id_user    = getIdUser($self, $target);
    if ($id_user) {
        my $sth3 = $self->{dbh}->prepare(q{
            SELECT ul.description
            FROM USER u
            JOIN USER_LEVEL ul ON ul.id_user_level = u.id_user_level
            WHERE u.id_user = ?
        });
        if ($sth3 && $sth3->execute($id_user)) {
            my $lvl = $sth3->fetchrow_hashref;
            $level_desc = " (" . ($lvl->{description} // '?') . ")" if $lvl;
            $sth3->finish;
        }
    }

    # Format output
    my $out = sprintf("%s%s: %d message%s%s on %s",
        $target, $level_desc,
        $msg_count, ($msg_count != 1 ? "s" : ""),
        $pct, $channel
    );
    # V6: helper to compute '(X ago)' from a SQL timestamp string
    my $_ago = sub {
        my ($ts) = @_;
        return '' unless defined $ts && $ts =~ /^\d{4}-\d{2}-\d{2}/;
        require Time::Local;
        my ($y,$mo,$d,$h,$mi,$s) = $ts =~ /^(\d{4})-(\d{2})-(\d{2})(?: (\d{2}):(\d{2}):(\d{2}))?$/;
        $h //= 12; $mi //= 0; $s //= 0;
        my $epoch = eval { Time::Local::timelocal($s,$mi,$h,$d,$mo-1,$y-1900) };
        return '' unless $epoch;
        my $diff = time() - $epoch;
        return '' if $diff < 0;
        my $dy = int($diff/31536000); $diff %= 31536000;
        my $dm = int($diff/2592000);  $diff %= 2592000;
        my $dd = int($diff/86400);    $diff %= 86400;
        my $dh = int($diff/3600);
        my $str = $dy  ? "${dy}y ${dm}m"
                : $dm  ? "${dm}m ${dd}d"
                : $dd  ? "${dd}d ${dh}h"
                :        int((time()-$epoch)/3600) . 'h';
        return " ($str ago)";
    };
    # mb579-B1: un nick deja apparu mais encore silencieux a bien une
    # premiere apparition. Le compteur a zero ne doit plus masquer la date.
    $out .= " | first seen: $first_seen" . $_ago->($first_seen) if $first_seen;
    $out .= " | last msg: $last_msg" . $_ago->($last_msg)       if $msg_count > 0;

    # MB75-S1: when a user asks for their own stats, USER_SEEN may already
    # have been updated by the current command, so it is misleading and always
    # reads as "0h ago". Keep it for stats about another nick.
    my $show_seen = (lc($target // '') ne lc($nick // '')) ? 1 : 0;
    $out .= " | last seen: $seen_at ($seen_type)" . $_ago->($seen_at)
        if $show_seen && $seen_at ne 'never';

    $out .= $karma_str if $karma_str;
    $out .= " | not in database" unless $id_user || $msg_count || $first_seen;

    # CC17: add global rank on channel
    if ($msg_count > 0 && $total > 0) {
        # mb576-B1: les comptes par nick des deux tables sont fusionnes
        # AVANT le seuil — un nick a cheval vif/archive compte sa somme.
        # Chaque requete par table est un index scan groupe, sans HAVING.
        my %rank_counts;
        my $stats_rank_g = Mediabot::Helpers::channel_log_gather($self, $self->{dbh},
            "SELECT cl2.nick AS nick, COUNT(*) AS cnt"
          . " FROM __CLSRC__ cl2 JOIN CHANNEL c2 ON c2.id_channel=cl2.id_channel"
          . " WHERE c2.name=? AND cl2.event_type IN ('public','action')"
          # Rank must compare the same message counts as the numerator and
          # denominator above, including exclusion of the current !stats.
          . q{ AND NOT (
                LOWER(TRIM(COALESCE(cl2.publictext, ''))) REGEXP '^m[[:space:]]+stats([[:space:]]|$)'
                OR LOWER(TRIM(COALESCE(cl2.publictext, ''))) REGEXP '^!stats([[:space:]]|$)'
            )}
          . " GROUP BY cl2.nick",
            # mb577-B1: cle lc — la collation SQL est insensible a la casse,
            # les tables peuvent rendre SlaY et slay pour la meme identite.
            [ $channel ], sub { $rank_counts{ lc $_[0]->{nick} } += $_[0]->{cnt} // 0 },
            'content');
        # mb578-B1: sans live_ok, un rang calcule sur une fusion vide
        # afficherait #1 — panne LIVE = echec franc.
        unless ($stats_rank_g->{live_ok}) {
            botNotice($self, $nick, "Database error.");
            return;
        }
        my $rank = 1 + scalar grep { $rank_counts{$_} > $msg_count } keys %rank_counts;
        $out .= " | rank: #" . $rank;
    }
    # mb480: show unlocked achievement count on this channel, if any.
    if ($self->{achievements}) {
        my $ach = eval { $self->{achievements}->get_for_nick($target, $channel) };
        if (ref($ach) eq 'HASH') {
            my $n = scalar keys %$ach;
            $out .= " | achievements: $n" if $n > 0;
        }
    }

    botPrivmsg($self, $channel, $out);
    logBot($self, $ctx->message, $channel, "stats", $target);
    return 1;
}

# ---------------------------------------------------------------------------
# mbTop_ctx — !top [n]
# Show the top N most active nicks on the current channel (default 5, max 10).
# ---------------------------------------------------------------------------
sub mbTop_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    my $n = 5;
    if (@args && $args[0] =~ /^\d+$/) {
        $n = int(shift @args);
        $n = 1  if $n < 1;
        $n = 10 if $n > 10;
    }

    # mb91-IMP1: !top bots — mode inverse: montrer uniquement les bots détectés
    # !top nobots — exclure les bots connus du classement (défaut implicite si conf BOT_NICKS)
    my $bots_mode    = 0;   # 1=show only bots, -1=exclude bots
    my $bots_filter  = '';
    my @bot_list;
    if (@args && lc($args[0]) eq 'bots') {
        shift @args; $bots_mode = 1;
    } elsif (@args && lc($args[0]) eq 'nobots') {
        shift @args; $bots_mode = -1;
    }
    # Charger la liste des bots depuis la conf (main.BOT_NICKS = "bot1,bot2,...")
    if ($bots_mode != 0) {
        my $conf_bots = eval { $self->{conf}->get('main.BOT_NICKS') } // '';
        @bot_list = map { lc(s/^\s+|\s+$//gr) } split /,/, $conf_bots if $conf_bots;
        # Toujours inclure le nick du bot lui-même
        my $bot_nick = eval { $self->{irc}->nick_folded } // '';
        push @bot_list, lc($bot_nick) if $bot_nick;
        if (@bot_list) {
            my $placeholders = join(',', ('?') x @bot_list);
            if ($bots_mode == -1) {
                $bots_filter = "AND LOWER(cl.nick) NOT IN ($placeholders)";
            } else {
                $bots_filter = "AND LOWER(cl.nick) IN ($placeholders)";
            }
        }
    }

    # A4: optional period filter — Nd/Nh + today/yesterday/week (mb91-IMP1)
    my $period_sql  = '';
    my $period_label = '';
    if (@args) {
        my $p = lc($args[0]);
        if ($p eq 'today') {
            $period_sql   = "AND cl.ts >= CURDATE() AND cl.ts < CURDATE() + INTERVAL 1 DAY";  # mb577-B1: plage indexable
            $period_label = " (today)";
        } elsif ($p eq 'yesterday') {
            $period_sql   = "AND cl.ts >= CURDATE() - INTERVAL 1 DAY AND cl.ts < CURDATE()";  # mb577-B1: plage indexable
            $period_label = " (yesterday)";
        } elsif ($p eq 'week') {
            $period_sql   = "AND cl.ts >= DATE_SUB(CURDATE(), INTERVAL WEEKDAY(CURDATE()) DAY)";
            $period_label = " (this week)";
        } elsif ($p =~ /^(\d+)(d|h)$/i) {
            my ($val, $unit) = ($1, lc $2);
            my $interval = $unit eq 'h' ? "$val HOUR" : "$val DAY";
            $period_sql   = "AND cl.ts >= DATE_SUB(NOW(), INTERVAL $interval)";
            $period_label = " (last ${val}${unit})";
        }
    }

    my @bind_base = ($channel, @bot_list);

    # A2: fetch total for percentage
    # mb574-B1: carriere -> vif + archive.
    # mb576-B1: une requete par table, somme Perl.
    # mb578-B1: indispensable (les % de chaque ligne en dependent).
    my $total = 0;
    my $top_tot_g = Mediabot::Helpers::channel_log_gather($self, $self->{dbh},
        "SELECT COUNT(*) AS total"
        . " FROM __CLSRC__ cl"
        . " JOIN CHANNEL c ON c.id_channel = cl.id_channel"
        . " WHERE c.name = ? AND cl.event_type IN ('public','action')"
        . " $bots_filter $period_sql",
        [ @bind_base ], sub { $total += $_[0]->{total} // 0 }, 'content');
    unless ($top_tot_g->{live_ok}) {
        botNotice($self, $nick, "Database error.");
        return;
    }

    # mb576-B1: GROUP BY complet par table + fusion par nick + tri/LIMIT
    # Perl (un LIMIT par branche fausserait le classement d'un nick a
    # cheval vif/archive).
    # mb577-B1: event_type explicite, cle lc (casse d'affichage memorisee a
    # la premiere rencontre, vif d'abord), scope content, succes via live_ok.
    my (%top_counts, %top_display);
    my $top_g = Mediabot::Helpers::channel_log_gather($self, $self->{dbh},
        "SELECT cl.nick AS nick, COUNT(*) AS msg_count"
        . " FROM __CLSRC__ cl"
        . " JOIN CHANNEL c ON c.id_channel = cl.id_channel"
        . " WHERE c.name = ? AND cl.event_type IN ('public','action')"
        . " $bots_filter $period_sql"
        . " GROUP BY cl.nick",
        [ @bind_base ], sub {
            my $k = lc $_[0]->{nick};
            $top_display{$k} //= $_[0]->{nick};
            $top_counts{$k} += $_[0]->{msg_count} // 0;
        }, 'content');
    unless ($top_g->{live_ok}) {
        botNotice($self, $nick, "Database error.");
        return;
    }
    my @top_nicks = sort { $top_counts{$b} <=> $top_counts{$a} || $a cmp $b }
        keys %top_counts;
    splice(@top_nicks, $n) if @top_nicks > $n;
    my @rows = map { { nick => $top_display{$_}, msg_count => $top_counts{$_} } } @top_nicks;

    unless (@rows) {
        botPrivmsg($self, $channel, "No data for $channel yet.");
        return 1;
    }

    # V2: show total messages in header
    my $total_hdr_str = $total > 0 ? " ($total msgs)" : "";
    my $bots_label = $bots_mode == 1 ? ' [bots]' : $bots_mode == -1 ? ' [no bots]' : '';
    botPrivmsg($self, $channel, "Top $n on $channel$period_label$bots_label$total_hdr_str:");
    my $rank = 1;
    for my $row (@rows) {
        my $msgs = $row->{msg_count};
        my $pct = $total > 0 ? sprintf(" (%.1f%%)", 100 * $msgs / $total) : "";
        botPrivmsg($self, $channel, sprintf("  %d. %-16s %d msg%s%s",
            $rank++, $row->{nick}, $msgs, ($msgs != 1 ? "s" : ""), $pct));
    }

    # V10 / mb576-B1: caller rank uses the exact same live+archive source.
    my $chan_ok = defined $channel && $channel =~ /^#/;
    if ($total > 0 && $chan_ok && $bots_mode != 1) {
        # mb578-B1: gather OPTIONNEL documente — la ligne bonus « your
        # rank » est simplement omise si ce comptage echoue ($mine reste 0,
        # le classement principal deja affiche n'est pas invalide). Teste.
        my $mine = 0;
        my $top_mine_g = Mediabot::Helpers::channel_log_gather($self, $self->{dbh},
            "SELECT COUNT(*) AS mine FROM __CLSRC__ cl"
          . " JOIN CHANNEL c ON c.id_channel=cl.id_channel"
          . " WHERE c.name=? AND cl.event_type IN ('public','action')"
          . " $bots_filter $period_sql AND LOWER(cl.nick)=LOWER(?)",
            [ $channel, @bot_list, lc($nick) ],
            sub { $mine += $_[0]->{mine} // 0 }, 'content');
        $mine = 0 unless $top_mine_g->{live_ok};
        if ($mine > 0) {
            # mb576-B1: la fusion complete par nick est deja en memoire
            # (%top_counts porte le meme filtre) — zero requete de plus.
            {
                my $my_rank = 1 + scalar grep { $top_counts{$_} > $mine }
                    keys %top_counts;
                if ($my_rank > $n) {
                    my $pct_me = $total > 0 ? sprintf('%.1f%%', 100*$mine/$total) : '0%';
                    botPrivmsg($self, $channel,
                        "  (your rank: #$my_rank — $mine msg(s), $pct_me)");
                }
            }
        }
    }
    logBot($self, $ctx->message, $channel, "top", "$n");
    return 1;
}

# ---------------------------------------------------------------------------
# mbActive_ctx --- !active [period]
# List nicks active in the last N hours or days.
# ---------------------------------------------------------------------------
sub mbActive_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    my $interval = '24 HOUR';
    my $label    = 'last 24h';
    my $use_date_filter = 0;
    my $date_filter = '';

    if (@args) {
        my $p = lc($args[0]);
        if ($p eq 'today') {
            # mb90-IMP2: activité du jour courant (depuis minuit)
            $date_filter     = "cl.ts >= CURDATE() AND cl.ts < CURDATE() + INTERVAL 1 DAY";  # mb577-B1: plage indexable
            $use_date_filter = 1;
            $label           = 'today';
        } elsif ($p eq 'yesterday') {
            $date_filter     = "cl.ts >= CURDATE() - INTERVAL 1 DAY AND cl.ts < CURDATE()";  # mb577-B1: plage indexable
            $use_date_filter = 1;
            $label           = 'yesterday';
        } elsif ($p eq 'week') {
            $date_filter     = "cl.ts >= DATE_SUB(CURDATE(), INTERVAL WEEKDAY(CURDATE()) DAY)";
            $use_date_filter = 1;
            $label           = 'this week';
        } elsif ($p eq 'month') {
            # mb627-B1: mb577 avait converti today/yesterday en plages mais
            # OUBLIE le mois courant, juste au-dessous. Meme mois, meme
            # resultat, index utilisable.
            $date_filter     = "cl.ts >= DATE_FORMAT(CURDATE(), '%Y-%m-01')"
                             . " AND cl.ts < DATE_FORMAT(CURDATE(), '%Y-%m-01') + INTERVAL 1 MONTH";
            $use_date_filter = 1;
            $label           = 'this month';
        } elsif ($p eq 'now') {
            $interval = '60 MINUTE';
            $label    = 'last 60min';
        } elsif ($p =~ /^(\d+)(d|h)$/i) {
            my ($v, $u) = ($1, lc $2);
            $interval = $u eq 'h' ? "$v HOUR" : "$v DAY";
            $label    = "last ${v}${u}";
        }
    }

    my $where_clause = $use_date_filter
        ? "c.name = ? AND $date_filter"
        : "c.name = ? AND cl.ts >= DATE_SUB(NOW(), INTERVAL $interval)";

    my $sth = $self->{dbh}->prepare(
        "SELECT cl.nick, COUNT(*) AS mc FROM CHANNEL_LOG cl"
        . " JOIN CHANNEL c ON c.id_channel = cl.id_channel"
        . " WHERE $where_clause"
        . " GROUP BY cl.nick ORDER BY mc DESC LIMIT 30"
    );
    unless ($sth && $sth->execute($channel)) {
        botNotice($self, $nick, 'Database error.'); $sth->finish if $sth; return;
    }
    my @nicks;
    while (my ($n, $mc) = $sth->fetchrow_array) { push @nicks, [$n, $mc]; }
    $sth->finish;

    if (@nicks) {
        # EE9: format as 'nick(msg_count)' pairs
        my $list = join(', ', map { ref $_ ? "$_->[0]($_->[1])" : $_ } @nicks);
        # B5/fix: truncate to avoid IRC 512-byte limit
        if (length($list) > 350) {
            $list = substr($list, 0, 347) . '...';
        }
        botPrivmsg($self, $channel,
            "Active in $label on $channel: $list"
            . " (" . scalar(@nicks) . " nick(s))");
    } else {
        botPrivmsg($self, $channel, "No activity in $label on $channel.");
    }

    # mb105-IMP1: pour le mode 'now', ajouter aussi les nicks présents en ce moment (nicklist mémoire)
    if ($label eq 'last 60min') {
        my @online = eval { $self->gethChannelsNicksOnChan($channel) };
        if (@online) {
            my $active_set = { map { lc($_->[0]) => 1 } @nicks };
            my @online_only = grep { !$active_set->{lc($_)} } @online;
            if (@online_only) {
                my $silent = join(', ', sort @online_only);
                $silent = substr($silent, 0, 350) . '...' if length($silent) > 350;
                botPrivmsg($self, $channel,
                    "Present but silent in last 60min: $silent (" . scalar(@online_only) . " nick(s))");
            }
        }
    }

    return 1;
}

# ---------------------------------------------------------------------------
# mbWhen_ctx --- !when <nick>
# When did a nick first appear on the channel.
# ---------------------------------------------------------------------------
sub mbWhen_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    unless (@args && $args[0] ne '') {
        botNotice($self, $nick, 'Syntax: when <nick>'); return;
    }
    my $target = lc($args[0]);

    # HH10: also count total messages for richer output
    # mb576-B1: first appearance and total span live + archive.
    # mb576-B1: MIN/COUNT par table, fusion Perl (min lexical, somme).
    # mb578-B1: « when » = PREMIERE APPARITION (revue pre-commit) — la
    # sur-application mb577 du filtre public/action l'avait transformee en
    # « premier message » : un nick ayant rejoint sans parler etait declare
    # absent, et l'archive de presence (qui contient precisement les vieux
    # JOIN) n'etait plus consultee. Deux gathers aux scopes distincts :
    #   1) premiere apparition : TOUT event_type, scope 'all' ;
    #   2) compteur de messages : public/action, scope 'content'.
    my $row = { first_seen => undef, total_msgs => 0 };
    my $when_first_g = Mediabot::Helpers::channel_log_gather($self, $self->{dbh}, q{
        SELECT MIN(cl.ts) AS first_seen FROM __CLSRC__ cl
        JOIN CHANNEL c ON c.id_channel = cl.id_channel
        WHERE cl.nick = ? AND c.name = ?
    }, [ $target, $channel ], sub {
        my ($r) = @_;
        $row->{first_seen} = $r->{first_seen}
            if defined $r->{first_seen}
            && (!defined $row->{first_seen} || $r->{first_seen} lt $row->{first_seen});
    }, 'all');
    unless ($when_first_g->{live_ok}) {
        botNotice($self, $nick, 'Database error.'); return;
    }
    my $when_msgs_g = Mediabot::Helpers::channel_log_gather($self, $self->{dbh}, q{
        SELECT COUNT(*) AS total_msgs FROM __CLSRC__ cl
        JOIN CHANNEL c ON c.id_channel = cl.id_channel
        WHERE cl.nick = ? AND c.name = ?
          AND cl.event_type IN ('public','action')
    }, [ $target, $channel ], sub {
        $row->{total_msgs} += $_[0]->{total_msgs} // 0;
    }, 'content');
    unless ($when_msgs_g->{live_ok}) {
        botNotice($self, $nick, 'Database error.'); return;
    }

    if ($row && $row->{first_seen}) {
        # V3: show age alongside raw date
        my $age_str = '';
        if ($row->{first_seen} =~ /^(\d{4})-(\d{2})-(\d{2})/) {
            require Time::Local;
            my ($y,$mo,$d) = ($1,$2,$3);
            my $then = eval { Time::Local::timelocal(0,0,12,$d,$mo-1,$y-1900) };
            if ($then) {
                my $age   = int((time() - $then) / 86400);
                my $years = int($age / 365); $age -= $years * 365;
                my $months= int($age / 30);  $age -= $months * 30;
                my $days  = $age;
                if    ($years)  { $age_str = " (${years}y ${months}m ago)"; }
                elsif ($months) { $age_str = " (${months}m ${days}d ago)"; }
                else            { $age_str = " (${days}d ago)"; }
            }
        }
        my $tot_msgs = $row->{total_msgs} // 0;
        # mb578-B1: un nick apparu sans jamais parler affiche « 0 msg(s) »
        # au lieu de masquer l'information.
        my $msgs_str = ", $tot_msgs msg(s)";
        botPrivmsg($self, $channel,
            "$target first seen on $channel: $row->{first_seen}$age_str$msgs_str");
    } else {
        botPrivmsg($self, $channel, "$target: no history found on $channel.");
    }
    logBot($self, $ctx->message, $channel, 'when', $target);  # Q1
    return 1;
}

# ---------------------------------------------------------------------------
# mbCompare_ctx --- !compare <nick1> <nick2>
# ---------------------------------------------------------------------------
sub mbCompare_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
    unless (@args >= 2) {
        botNotice($self, $nick, 'Syntax: compare <nick1> <nick2> [Nd|Nw|Nm|all]  (ex: 7d 4w 3m)');
        return;
    }
    my ($t1, $t2) = (lc($args[0]), lc($args[1]));
    # mb86-IMP2: période optionnelle — 7d, 4w, 3m, 1y, all (défaut: all)
    my ($period_sql, $period_label) = ('', 'all time');
    if (@args >= 3) {
        my $p = lc($args[2]);
        if ($p =~ /^(\d+)d$/) {
            $period_sql   = "AND cl.ts >= NOW() - INTERVAL $1 DAY";
            $period_label = "last ${1}d";
        } elsif ($p =~ /^(\d+)w$/) {
            my $days = $1 * 7;
            $period_sql   = "AND cl.ts >= NOW() - INTERVAL $days DAY";
            $period_label = "last ${1}w";
        } elsif ($p =~ /^(\d+)m$/) {
            $period_sql   = "AND cl.ts >= NOW() - INTERVAL $1 MONTH";
            $period_label = "last ${1}m";
        } elsif ($p =~ /^(\d+)y$/) {
            $period_sql   = "AND cl.ts >= NOW() - INTERVAL $1 YEAR";
            $period_label = "last ${1}y";
        } elsif ($p eq 'all') {
            # explicit all — no filter
        } else {
            botNotice($self, $nick, "Unknown period '$p'. Use: 7d, 4w, 3m, 1y, all");
            return;
        }
    }

    # mb576-B1: une requete par table, comptes additionnes en Perl.
    # mb577-B1: event_type explicite, cle lc (t1/t2 sont deja lc — la
    # collation SQL peut rendre une autre casse), scope content, live_ok.
    my %counts;
    my $cmp_g = Mediabot::Helpers::channel_log_gather($self, $self->{dbh}, qq{
        SELECT cl.nick AS nick, COUNT(*) AS cnt
        FROM __CLSRC__ cl
        JOIN CHANNEL c ON c.id_channel = cl.id_channel
        WHERE c.name = ? AND cl.nick IN (?,?)
          AND cl.event_type IN ('public','action')
        $period_sql
        GROUP BY cl.nick
    }, [ $channel, $t1, $t2 ], sub {
        $counts{ lc $_[0]->{nick} } += $_[0]->{cnt} // 0;
    }, 'content');
    unless ($cmp_g->{live_ok}) {
        botNotice($self, $nick, 'Database error.'); return;
    }
    my $c1 = $counts{$t1} // 0;
    my $c2 = $counts{$t2} // 0;
    my $diff = abs($c1 - $c2);
    my $leader = $c1 > $c2 ? $t1 : $c1 < $c2 ? $t2 : undef;
    my $verdict = $leader ? "$leader leads by $diff msg(s)" : 'tied!';
    my $tot_c = $c1 + $c2;
    my $p1 = $tot_c > 0 ? int(100*$c1/$tot_c) : 0;
    my $p2 = $tot_c > 0 ? 100 - $p1 : 0;
    botPrivmsg($self, $channel,
        "[$period_label] $t1: $c1 msg(s) ($p1%) | $t2: $c2 msg(s) ($p2%) | $verdict");
    return 1;
}

# ---------------------------------------------------------------------------
# mbHeatmap_ctx --- !heatmap [nick]
# Activity by hour of day, ASCII bar chart.
# ---------------------------------------------------------------------------
sub mbHeatmap_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
    my $target  = @args ? lc($args[0]) : lc($nick);
    # mb576-B1: GROUP BY horaire par table, buckets additionnes en Perl.
    # mb577-B1: event_type explicite (activite = paroles), scope content,
    # succes via live_ok (heatmap vide = reponse fonctionnelle).
    my @hours = (0) x 24;
    my $hm_g = Mediabot::Helpers::channel_log_gather($self, $self->{dbh},
        'SELECT HOUR(cl.ts) AS h, COUNT(*) AS cnt'
        . ' FROM __CLSRC__ cl'
        . ' JOIN CHANNEL c ON c.id_channel = cl.id_channel'
        . ' WHERE cl.nick = ? AND c.name = ?'
        . " AND cl.event_type IN ('public','action')"
        . ' GROUP BY HOUR(cl.ts) ORDER BY h',
        [ $target, $channel ], sub {
            $hours[ $_[0]->{h} ] += $_[0]->{cnt} // 0;
        }, 'content');
    unless ($hm_g->{live_ok}) {
        botNotice($self, $nick, 'Database error.'); return;
    }
    my $max = (sort { $b <=> $a } @hours)[0] || 1;
    # 6-hour blocks
    my @blocks = ('00-05', '06-11', '12-17', '18-23');
    my $grand_total = 0; $grand_total += $_ for @hours;
    # V15: afficher le total de messages en en-tête
    botPrivmsg($self, $channel,
        "$target activity by hour on $channel ($grand_total msgs total):");
    for my $b (0..3) {
        my $label = $blocks[$b];
        my @slice = @hours[$b*6 .. $b*6+5];
        my $total = 0; $total += $_ for @slice;
        my $bar_len = int(10 * $total / ($max * 6 || 1));
        $bar_len = 1 if $total > 0 && $bar_len == 0;
        # IMP22: IRC color codes — intensity: green < yellow < red
        my $ratio = $max > 0 ? $total / $max : 0;
        my $irc_color = $ratio >= 0.75 ? "\x0304"  # red
                      : $ratio >= 0.40 ? "\x0308"  # yellow
                      : $ratio >  0    ? "\x0303"  # green
                      :                  '';       # no color if 0
        my $reset = $irc_color ne '' ? "\x0f" : '';
        my $bar = $irc_color . chr(0x2588) x $bar_len . $reset
                . chr(0x2591) x (10 - $bar_len);
        botPrivmsg($self, $channel, sprintf('  %s  %s  %d msgs', $label, $bar, $total));
    }
    # V7: show peak time slot
    # mb84-B6: supprimé $peak_slot (code mort et calcul incorrect) — $peak_idx via @slot_totals est correct
    my @slot_labels = ("00-05", "06-11", "12-17", "18-23");
    my @slot_totals = map { my $s=$_; my $t=0; $t += ($hours[$s*6+$_] // 0) for 0..5; $t } 0..3;
    my ($peak_idx) = sort { $slot_totals[$b] <=> $slot_totals[$a] } 0..3;
    if ($slot_totals[$peak_idx] > 0) {
        botPrivmsg($self, $channel,
            "  Peak activity: $slot_labels[$peak_idx] ($slot_totals[$peak_idx] msgs)");
    }
    return 1;
}

# ---------------------------------------------------------------------------
# mbMonthStats_ctx --- !monthstats [nick]
# Activity count per month for the last 12 months.
# ---------------------------------------------------------------------------
sub mbMonthStats_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # mb90-IMP3: !monthstats nick1 vs nick2 — mode comparaison côte à côte
    my ($t1, $t2);
    if (@args >= 3 && lc($args[1]) eq 'vs') {
        ($t1, $t2) = (lc($args[0]), lc($args[2]));
    }

    if (defined $t1 && defined $t2) {
        # Fetch counts for both nicks per month
        my $sth = $self->{dbh}->prepare(
            "SELECT DATE_FORMAT(cl.ts, '%Y-%m') AS ym, cl.nick, COUNT(*) AS cnt"
            . ' FROM CHANNEL_LOG cl'
            . ' JOIN CHANNEL c ON c.id_channel = cl.id_channel'
            . ' WHERE cl.nick IN (?,?) AND c.name = ?'
            . '   AND cl.ts >= DATE_SUB(NOW(), INTERVAL 12 MONTH)'
            . ' GROUP BY ym, cl.nick ORDER BY ym'
        );
        unless ($sth && $sth->execute($t1, $t2, $channel)) {
            botNotice($self, $nick, 'Database error.'); $sth->finish if $sth; return;
        }
        my %by_month;
        while (my $r = $sth->fetchrow_hashref) {
            # SQL may return a group's original display case. Use the same
            # identity key as the requested nicks, merging any case variants.
            $by_month{$r->{ym}}{lc $r->{nick}} += $r->{cnt};
        }
        $sth->finish;
        unless (%by_month) {
            botPrivmsg($self, $channel, "No data found for $t1 or $t2 on $channel."); return 1;
        }
        my $max_c = 1;
        for my $ym (keys %by_month) {
            for my $n (keys %{ $by_month{$ym} }) {
                $max_c = $by_month{$ym}{$n} if $by_month{$ym}{$n} > $max_c;
            }
        }
        botPrivmsg($self, $channel, "$t1 vs $t2 on $channel (last 12 months):");
        my @parts;
        for my $ym (sort keys %by_month) {
            my $c1 = $by_month{$ym}{$t1} // 0;
            my $c2 = $by_month{$ym}{$t2} // 0;
            my $b1 = int(4 * $c1 / $max_c); $b1 = 1 if $c1 > 0 && $b1 == 0;
            my $b2 = int(4 * $c2 / $max_c); $b2 = 1 if $c2 > 0 && $b2 == 0;
            my $bar1 = chr(0x2588) x $b1 . chr(0x2591) x (4-$b1);
            my $bar2 = chr(0x2588) x $b2 . chr(0x2591) x (4-$b2);
            push @parts, "$ym $bar1/$bar2";
        }
        my @line1 = splice(@parts, 0, 6);
        my @line2 = @parts;
        botPrivmsg($self, $channel, "  $t1//$t2 — " . join('  ', @line1)) if @line1;
        botPrivmsg($self, $channel, '  ' . join('  ', @line2)) if @line2;
        return 1;
    }

    # Mode normal — un seul nick
    my $target  = @args ? lc($args[0]) : lc($nick);
    my $sth = $self->{dbh}->prepare(
        "SELECT DATE_FORMAT(cl.ts, '%Y-%m') AS ym, COUNT(*) AS cnt"
        . ' FROM CHANNEL_LOG cl'
        . ' JOIN CHANNEL c ON c.id_channel = cl.id_channel'
        . ' WHERE cl.nick = ? AND c.name = ?'
        . "   AND cl.ts >= DATE_SUB(NOW(), INTERVAL 12 MONTH)"
        . ' GROUP BY ym ORDER BY ym'
    );
    unless ($sth && $sth->execute($target, $channel)) {
        botNotice($self, $nick, 'Database error.'); $sth->finish if $sth; return;
    }
    my @rows;
    while (my $r = $sth->fetchrow_hashref) { push @rows, $r; }
    $sth->finish;
    unless (@rows) {
        botPrivmsg($self, $channel, "$target: no data in last 12 months on $channel.");
        return 1;
    }
    # V11: sparkline visuelle par mois
    my $max_m = (sort { $b <=> $a } map { $_->{cnt} } @rows)[0] || 1;
    my @parts;
    for my $r (@rows) {
        my $bar_len = int(5 * $r->{cnt} / $max_m);
        $bar_len = 1 if $r->{cnt} > 0 && $bar_len == 0;
        my $bar = chr(0x2588) x $bar_len . chr(0x2591) x (5 - $bar_len);
        push @parts, "$r->{ym} $bar $r->{cnt}";
    }
    botPrivmsg($self, $channel, "$target on $channel (last 12 months):");
    my @line1 = splice(@parts, 0, 6);
    my @line2 = @parts;
    botPrivmsg($self, $channel, '  ' . join('  ', @line1)) if @line1;
    botPrivmsg($self, $channel, '  ' . join('  ', @line2)) if @line2;
    return 1;
}

1;
