package Mediabot::Stats::History;

use strict;
use warnings;
use utf8;
use Exporter 'import';
use Mediabot::Helpers ();
use Time::Piece ();

our @EXPORT_OK = qw(
    mbWordCount_ctx
    mbStreak_ctx
    mbLast_ctx
);

# Keep call-time compatibility with the existing command facade. Registry,
# transport and test integrations still use UserCommands' historical hooks.
sub botPrivmsg { goto &Mediabot::UserCommands::botPrivmsg }
sub botNotice  { goto &Mediabot::UserCommands::botNotice }
sub logBot     { goto &Mediabot::UserCommands::logBot }

# ---------------------------------------------------------------------------
# mbWordCount_ctx --- !wordcount [nick]
# Count distinct words spoken by a nick on the channel.
# ---------------------------------------------------------------------------
sub mbWordCount_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # mb85-B3: !karma log et !karma top étaient mal routés ici — déplacés dans mbKarma_ctx

    $self->{metrics}->inc('mediabot_wordcount_requests_total') if $self->{metrics};

    # mb92/polish: wordcount is channel-scoped
    unless (defined($channel) && $channel =~ /^#/) {
        botNotice($self, $nick, "wordcount must be used from a channel.");
        return 1;
    }

    # mb94-IMP1 / mb100-IMP1 / mb100-polish:
    # Supported forms:
    #   !wordcount
    #   !wordcount <nick>
    #   !wordcount <period>
    #   !wordcount <nick> <period>
    # where <period> is today/yesterday/week/Nd/Nh.
    my $period_re = qr/^(?:today|yesterday|week|all|\d+[dh])$/i;

    my $target = lc($nick);
    my $period_arg;
    my $no_limit = 0;  # mb102-IMP2: option all = pas de LIMIT

    if (@args) {
        if (defined($args[0]) && $args[0] =~ $period_re) {
            $period_arg = lc($args[0]);
        }
        else {
            $target = lc($args[0]);
            $period_arg = lc($args[1]) if defined($args[1]) && $args[1] =~ $period_re;
        }
    }

    my $period_sql   = '';
    my $period_label = '';
    if (defined($period_arg) && $period_arg ne '') {
        my $p = $period_arg;
        if ($p eq 'today') {
            $period_sql   = "AND cl.ts >= CURDATE() AND cl.ts < CURDATE() + INTERVAL 1 DAY";  # mb577-B1: plage indexable
            $period_label = " (today)";
        } elsif ($p eq 'yesterday') {
            $period_sql   = "AND cl.ts >= CURDATE() - INTERVAL 1 DAY AND cl.ts < CURDATE()";  # mb577-B1: plage indexable
            $period_label = " (yesterday)";
        } elsif ($p eq 'week') {
            $period_sql   = "AND cl.ts >= DATE_SUB(CURDATE(), INTERVAL WEEKDAY(CURDATE()) DAY)";
            $period_label = " (this week)";
        } elsif ($p eq 'all') {
            # mb102-IMP2: pas de LIMIT — peut être lent sur gros datasets
            $no_limit     = 1;
            $period_label = " (all time, no limit — may be slow)";
        } elsif ($p =~ /^(\d+)(d|h)$/i) {
            my ($val, $unit) = ($1, lc $2);
            my $interval = $unit eq 'h' ? "$val HOUR" : "$val DAY";
            $period_sql   = "AND cl.ts >= DATE_SUB(NOW(), INTERVAL $interval)";
            $period_label = " (last ${val}${unit})";
        }
    }

    # mb92-B1: LIMIT 50000 par défaut — mb102-IMP2: désactivé si option 'all'
    my $ROW_LIMIT = 50_000;
    my $limit_clause = $no_limit ? '' : "LIMIT $ROW_LIMIT";
    # mb575-B1: carriere -> vif + archive (les PK sont preservees au
    # deplacement, l'ORDER BY id_channel_log reste globalement coherent).
    # mb576-B1: LIMIT par table (index scans), le comptage de mots agrege
    # les deux flux — l'ordre entre tables est indifferent pour un total,
    # et le plafond global est applique dans la boucle de lecture.
    # mb577-B1: en mode all, les textes sont STREAMES dans les compteurs
    # (jamais accumules — un canal Undernet en compterait des millions) ;
    # en mode plafonne, l'accumulation reste bornee a 2 x ROW_LIMIT avant
    # le splice qui garde les plus recents. Succes via live_ok.
    my %words;
    my $rows_read = 0;
    my @wc_texts;
    my $wc_count_text = sub {
        my ($text) = @_;
        $rows_read++;
        # mb426-B1: la connexion DBI ne décode pas l'UTF-8 (pas de mariadb_utf8,
        # seulement SET NAMES) -> publictext arrive en OCTETS UTF-8. Un split
        # sur \W+ coupait sur chaque octet d'accent (café -> caf, réponse ->
        # r+ponse), faussant le comptage sur un canal francophone. On splitte
        # de façon byte-safe : les octets >= 0x80 (continuation/amorce des
        # séquences UTF-8 multi-octets) comptent comme des lettres, donc les
        # mots accentués restent entiers.
        $words{lc $_}++ for split /[^0-9A-Za-z_\x80-\xFF]+/, ($text // '');
    };
    my $wc_g = Mediabot::Helpers::channel_log_gather($self, $self->{dbh}, qq{
        SELECT publictext FROM __CLSRC__ cl
        JOIN CHANNEL c ON c.id_channel = cl.id_channel
        WHERE cl.nick = ? AND c.name = ? AND event_type IN ('public','action')
        $period_sql
        ORDER BY cl.id_channel_log DESC
        $limit_clause
    }, [ $target, $channel ], $no_limit
        ? sub { $wc_count_text->($_[0]->{publictext}) }
        : sub { push @wc_texts, $_[0]->{publictext} },
    'content');
    unless ($wc_g->{live_ok}) {
        botNotice($self, $nick, 'Database error.');
        return;
    }
    unless ($no_limit) {
        splice(@wc_texts, $ROW_LIMIT) if @wc_texts > $ROW_LIMIT;
        $wc_count_text->($_) for @wc_texts;
    }
    delete $words{''};

    # V9/MB75-R4: show top 5 most frequent useful words.
    my $distinct = scalar keys %words;
    my @word_candidates = grep { defined($_) && length($_) >= 3 } keys %words;
    my @top5 = (sort { $words{$b} <=> $words{$a} || $a cmp $b } @word_candidates)[0..4];
    @top5 = grep { defined($_) } @top5;
    my $top_str = @top5
        ? '  | top words: ' . join(', ', map { "$_ ($words{$_})" } @top5)
        : '';
    # mb92-B1: avertir si le résultat est tronqué
    my $trunc_note = (!$no_limit && $rows_read >= $ROW_LIMIT) ? " [last 50k msgs]" : "";

    # mb114/mb115: activity rank among nicks on this channel.
    # Only calculate it for the unfiltered/default mode. Period filters and
    # 'all' can already be expensive, so they deliberately skip this extra query.
    #
    # This is an activity-rank proxy based on logged line count, not an exact
    # distinct-word rank for every nick. The exact distinct-word rank would need
    # a much heavier full-channel tokenization pass.
    my $rank_str = '';
    unless (defined($period_arg) && $period_arg ne '') {
        # mb576-B1: comptes par nick fusionnes AVANT le seuil (meme patron
        # que le rank de stats) — un nick a cheval compte sa somme.
        my %wc_rank_counts;
        my $wc_rank_g = Mediabot::Helpers::channel_log_gather($self, $self->{dbh}, q{
            SELECT cl2.nick AS nick, COUNT(*) AS cnt
            FROM __CLSRC__ cl2
            JOIN CHANNEL c2 ON c2.id_channel = cl2.id_channel
            WHERE c2.name = ?
              AND cl2.nick != ?
              AND cl2.event_type IN ('public','action')
            GROUP BY cl2.nick
        }, [ $channel, $target ], sub {
            $wc_rank_counts{ lc $_[0]->{nick} } += $_[0]->{cnt} // 0;
        }, 'content');
        # mb578-B1: suffixe OPTIONNEL documente — sans live_ok, pas de
        # « activity rank » (un rang sur l'archive seule serait faux) ;
        # le comptage principal deja calcule reste affiche. Teste.
        if ($wc_rank_g->{live_ok} && %wc_rank_counts) {
            my $rank_pos = 1 + scalar grep { $wc_rank_counts{$_} > $rows_read }
                keys %wc_rank_counts;
            $rank_str = "  | activity rank: #" . $rank_pos;
        }
    }

    botPrivmsg($self, $channel, "$target: $distinct distinct word(s) on $channel$period_label$trunc_note$rank_str$top_str");

    # mb115: hook achievements wordcount
    if ($self->{achievements}) {
        eval { $self->{achievements}->check_wordcount($target, $channel, $distinct) };
        if ($@) { $self->{logger}->log(1, "achievements check_wordcount error: $@"); }
    }
    return 1;
}

# ---------------------------------------------------------------------------
# mbStreak_ctx --- !streak [nick]
# Count consecutive days of activity on the channel.
# ---------------------------------------------------------------------------
sub mbStreak_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # mb94-IMP2: !streak teuk all — forcer recalcul sans cache
    my $force_refresh = 0;
    if (@args >= 2 && lc($args[-1]) eq 'all') {
        $force_refresh = 1;
        pop @args;
    }
    my $target = $args[0] ? lc($args[0]) : lc($nick);
    my $channel_timezone = eval {
        my $channel_obj = $self->{channels}{lc($channel // '')};
        $channel_obj ? $channel_obj->get_timezone : undef;
    } || 'UTC';
    my $sql_timezone = $channel_timezone eq 'UTC'
        ? '+00:00' : $channel_timezone;

    # mb574-B1: le streak est une carriere -> vif + archive.
    # mb576-B1: LIMIT par table (chaque branche sert son index), puis
    # dedup + tri + tronque en Perl — jamais d'ORDER/LIMIT sur une derivee.
    # mb577-B1: event_type explicite (le streak mesure des jours de PAROLE,
    # pas des join/quit), scope content, succes via live_ok (vide = valide).
    my %seen_days;
    my $streak_g = Mediabot::Helpers::channel_log_gather($self, $self->{dbh}, q{
        SELECT DISTINCT DATE(CONVERT_TZ(cl.ts, @@session.time_zone, ?)) AS day
        FROM __CLSRC__ cl
        JOIN CHANNEL c ON c.id_channel = cl.id_channel
        WHERE cl.nick = ? AND c.name = ?
          AND cl.event_type IN ('public','action')
        ORDER BY day DESC
        LIMIT 365
    }, [ $sql_timezone, $target, $channel ], sub {
        $seen_days{ $_[0]->{day} } = 1 if defined $_[0]->{day};
    }, 'content');
    unless ($streak_g->{live_ok}) {
        botNotice($self, $nick, 'Database error.');
        return;
    }
    my @days = sort { $b cmp $a } keys %seen_days;
    splice(@days, 365) if @days > 365;

    unless (@days) {
        botPrivmsg($self, $channel, "$target: no activity found on $channel.");
        return 1;
    }

    # Count consecutive days from most recent
    my $streak = 1;
    for my $i (1 .. $#days) {
        my $d1 = Time::Piece->strptime($days[$i-1], '%Y-%m-%d');
        my $d2 = Time::Piece->strptime($days[$i],   '%Y-%m-%d');
        last unless int(($d1 - $d2)->days + 0.5) == 1;  # B4/fix: ->days is float
        $streak++;
    }

    # V14: compute best streak (max consecutive run in full history)
    my $best = $streak;  # current is at least as good as best from start
    my $cur_run = 1;
    for my $i (1 .. $#days) {
        my $d1 = Time::Piece->strptime($days[$i-1], '%Y-%m-%d');
        my $d2 = Time::Piece->strptime($days[$i],   '%Y-%m-%d');
        if (int(($d1 - $d2)->days + 0.5) == 1) {
            $cur_run++;
            $best = $cur_run if $cur_run > $best;
        } else {
            $cur_run = 1;
        }
    }
    my $best_str = $best > $streak ? "  (best ever: ${best}d)" : '';

    # mb655: checking one's own streak also records the already-computed best
    # run in the persistent Achievement registry.  Looking up somebody else's
    # streak stays read-only: a third party must never create/touch that person's
    # durable Achievement profile merely by inspecting it.
    if ($self->{achievements} && lc($target) eq lc($nick)) {
        eval { $self->{achievements}->check_streak($nick, $channel, $streak, $best) };
        if ($@) {
            eval { $self->{logger}->log(1, "achievements check_streak error: $@") };
        }
    }

    # mb85-IMP1 / mb92-B2: rang du streak — cache TTL 5min pour éviter la sous-requête coûteuse
    my $rank_str  = '';
    my $cache_key = "streak_rank:$channel:$target:$streak";
    my $cached    = $self->{_streak_rank_cache}{$cache_key};
    # mb94-IMP2: invalider le cache si !streak all
    delete $self->{_streak_rank_cache}{$cache_key} if $force_refresh;
    $cached = undef if $force_refresh;
    if ($cached && (time() - $cached->{ts}) < 300) {
        $rank_str = $cached->{rank_str};
    } else {
        eval {
            my $sth_r2 = $self->{dbh}->prepare(q{
                SELECT COUNT(DISTINCT sub.nick) AS ahead
                FROM (
                    SELECT cl.nick, COUNT(DISTINCT DATE(cl.ts)) AS days_active
                    FROM CHANNEL_LOG cl
                    JOIN CHANNEL c ON c.id_channel = cl.id_channel
                    WHERE c.name = ?
                      AND cl.nick != ?
                      -- mb627-B1: plage indexable. DATE(ts) >= D equivaut a
                      -- ts >= D (DATE() tronque vers le bas), mais la fonction
                      -- autour de la colonne interdisait l'index (id_channel, ts).
                      AND cl.ts >= CURDATE() - INTERVAL 365 DAY
                    GROUP BY cl.nick
                ) sub
                WHERE sub.days_active > ?
            });
            if ($sth_r2 && $sth_r2->execute($channel, $target, $streak)) {
                my $rrow = $sth_r2->fetchrow_hashref; $sth_r2->finish;
                if ($rrow && defined $rrow->{ahead}) {
                    $rank_str = "  rank #" . ($rrow->{ahead} + 1);
                }
            }
        };
        $self->{_streak_rank_cache}{$cache_key} = { ts => time(), rank_str => $rank_str };
    }

    my $refresh_note = $force_refresh ? " [live]" : "";
    botPrivmsg($self, $channel,
        "$target: $streak consecutive day(s) active on $channel (most recent: $days[0])$best_str$rank_str$refresh_note");
    logBot($self, $ctx->message, $channel, 'streak', $target);  # Q1
    return 1;
}

# ---------------------------------------------------------------------------
# mbLast_ctx --- !last <nick> [n]
# Show the last N messages posted by a nick on the current channel. Max 5.
# ---------------------------------------------------------------------------
sub mbLast_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    unless (@args && defined $args[0] && $args[0] ne '') {
        botNotice($self, $nick, 'Syntax: last <nick> [n]  (n = 1-5, default 1)');
        return;
    }
    my $target = lc($args[0]);

    # mb107-IMP2: option [n] — afficher les N derniers messages (max 5)
    my $limit = 1;
    if (defined $args[1] && $args[1] =~ /^(\d+)$/) {
        $limit = int($1);
        $limit = 1 if $limit < 1;
        $limit = 5 if $limit > 5;
    }

    # mb575-B1: le vrai « last » d'un nick parti depuis longtemps vit dans
    # l'archive — union vif + annexe.
    # mb576-B1: le cas d'ecole de l'analyse — ORDER/LIMIT ne se poussent
    # pas dans une derivee UNION : chaque table repond ses $limit dernieres
    # lignes via SON index, la fusion triee garde les plus recentes.
    # mb577-B1: succes via live_ok — un nick inconnu (zero ligne) recoit la
    # reponse fonctionnelle, plus jamais « Database error ».
    my @rows;
    my $last_g = Mediabot::Helpers::channel_log_gather($self, $self->{dbh}, qq{
        SELECT cl.publictext, cl.ts,
               TIMESTAMPDIFF(MINUTE, cl.ts, NOW()) AS minutes_ago
        FROM __CLSRC__ cl
        JOIN CHANNEL c ON c.id_channel = cl.id_channel
        WHERE cl.nick = ? AND c.name = ?
          AND cl.event_type IN ('public','action') AND cl.publictext != ''
        ORDER BY cl.ts DESC
        LIMIT $limit
    }, [ $target, $channel ], sub { push @rows, $_[0] }, 'content');
    unless ($last_g->{live_ok}) {
        botNotice($self, $nick, 'Database error.'); return;
    }
    @rows = sort { ($b->{ts} // '') cmp ($a->{ts} // '') } @rows;
    splice(@rows, $limit) if @rows > $limit;

    unless (@rows) {
        botPrivmsg($self, $channel, "$target: no message found on $channel.");
        return 1;
    }

    my $fmt_ago = sub {
        my ($ago) = @_;
        return $ago < 60
            ? "${ago}m ago"
            : $ago < 1440
                ? sprintf('%dh %dm ago', int($ago/60), $ago%60)
                : sprintf('%dd %dh ago', int($ago/1440), int(($ago%1440)/60));
    };

    if ($limit == 1) {
        my $row = $rows[0];
        my $ago_str   = $fmt_ago->($row->{minutes_ago});
        my $time_exact = '';
        if ($row->{ts} && $row->{ts} =~ /\d{4}-\d{2}-\d{2} (\d{2}:\d{2})/) {
            $time_exact = ", $1";
        }
        botPrivmsg($self, $channel,
            "$target last said ($ago_str${time_exact} on $channel): \"$row->{publictext}\"");
    } else {
        botPrivmsg($self, $channel, "Last ${\scalar(@rows)} message(s) from $target on $channel:");
        for my $row (reverse @rows) {
            my $ago_str = $fmt_ago->($row->{minutes_ago});
            my $time_exact = '';
            if ($row->{ts} && $row->{ts} =~ /\d{4}-\d{2}-\d{2} (\d{2}:\d{2})/) {
                $time_exact = " [$1]";
            }
            botPrivmsg($self, $channel, "  ($ago_str$time_exact) $row->{publictext}");
        }
    }
    return 1;
}

1;
