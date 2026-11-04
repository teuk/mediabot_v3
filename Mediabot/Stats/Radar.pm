package Mediabot::Stats::Radar;

use strict;
use warnings;
use utf8;
use Exporter 'import';
use DateTime ();

our @EXPORT_OK = qw(mbRadar_ctx);

# Keep the legacy facade's transports and number formatter late bound.
sub botPrivmsg { goto &Mediabot::UserCommands::botPrivmsg }
sub botNotice  { goto &Mediabot::UserCommands::botNotice }
sub _fmt_n     { goto &Mediabot::UserCommands::_fmt_n }

# ---------------------------------------------------------------------------
# mbRadar_ctx --- !radar
# Détecte les anomalies d'activité sur le canal :
#   - spike (activité dernière heure >> moyenne 24h)
#   - silence (canal très calme depuis >X min)
#   - newcomers (nicks vus pour la 1ère fois dans les dernières 24h)
#   - ghosts (nicks présents en nicklist mais silencieux > 6h)
#   - karma vortex (votes karma soudains)
#   - loudest talkers (top 3 dernière heure)
# ---------------------------------------------------------------------------
sub mbRadar_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    unless ($channel && $channel =~ /^#/) {
        botNotice($self, $nick, 'Syntax: !radar  [Nd]  (must be in a channel)'); return;
    }

    # mb116: mode étendu — !radar 7d  vue historique sur N jours
    my $hist_days;
    if (@args && $args[0] =~ /^(\d+)d$/i) {
        $hist_days = $1; $hist_days = 30 if $hist_days > 30; $hist_days = 1 if $hist_days < 1;
    }

    my $dbh = $self->{dbh};
    my @lines;

    if (defined $hist_days) {
        # One SQL-session calendar window, including today. A rolling N*24h
        # cutoff can span N+1 dates; sparse GROUP BY rows also omit quiet days.
        my ($sth_d, $today, %by_day, @sorted_days);
        my $history_ok = eval {
            $sth_d = $dbh->prepare(q{
            SELECT DATE(cl.ts) AS d, COUNT(*) AS c, CURDATE() AS today
            FROM CHANNEL_LOG cl
            JOIN CHANNEL c ON c.id_channel = cl.id_channel
            WHERE c.name = ?
              AND cl.event_type IN ('public','action')
              AND cl.ts >= CURDATE() - INTERVAL ? DAY
              AND cl.ts < CURDATE() + INTERVAL 1 DAY
            GROUP BY DATE(cl.ts)
            ORDER BY d
            }) or die "radar_history_prepare\n";
            $sth_d->execute($channel, $hist_days - 1) or die "radar_history_execute\n";
            while (my $r = $sth_d->fetchrow_hashref) {
                $by_day{$r->{d}} = $r->{c};
                $today //= $r->{today};
            }
            die "radar_history_fetch\n" if $sth_d->err;
            if (%by_day) {
                die "radar_history_calendar\n" unless defined($today)
                    && $today =~ /\A([0-9]{4})-([0-9]{2})-([0-9]{2})\z/;
                # UTC is only a date-arithmetic carrier. The database's
                # CURDATE(), not the host clock/timezone, owns these labels.
                my $day = DateTime->new(year=>$1, month=>$2, day=>$3, time_zone=>'UTC');
                $day->subtract(days=>$hist_days - 1);
                for (1 .. $hist_days) {
                    push @sorted_days, $day->ymd;
                    $by_day{$day->ymd} //= 0;
                    $day->add(days=>1);
                }
            }
            1;
        };
        # Check EOF before finish can clear DBI's read status. Cleanup must
        # not replace a failed read or discard a completely fetched chart.
        eval { $sth_d->finish } if $sth_d;
        unless ($history_ok) {
            botNotice($self, $nick, 'Database error.');
            return;
        }
        unless (%by_day) {
            botPrivmsg($self, $channel, "\x{1F4E1} \x02Radar\x02 $channel: no data in last ${hist_days}d");
            return 1;
        }
        my @counts      = map { $by_day{$_} } @sorted_days;
        my $max = (sort { $b <=> $a } @counts)[0] || 1;
        my $sum = 0; $sum += $_ for @counts;
        my $avg = $sum / scalar(@counts);
        my @glyphs = ("\x{2581}","\x{2582}","\x{2583}","\x{2584}","\x{2585}","\x{2586}","\x{2587}","\x{2588}");
        my $spark = '';
        for my $c (@counts) {
            my $idx = int(($c / $max) * 7);
            $idx = 0 if $idx < 0; $idx = 7 if $idx > 7;
            $spark .= $glyphs[$idx];
        }
        # Best & worst day
        my ($best_d) = sort { $by_day{$b} <=> $by_day{$a} || $a cmp $b } @sorted_days;
        my ($worst_d) = sort { $by_day{$a} <=> $by_day{$b} || $a cmp $b } @sorted_days;
        botPrivmsg($self, $channel, "\x{1F4E1} \x02Radar\x02 $channel (last ${hist_days}d):");
        botPrivmsg($self, $channel,
            sprintf("  \x{1F4C8} %s  \x{B7}  total %s msgs  \x{B7}  avg %.0f/d",
                $spark, _fmt_n($sum), $avg));
        botPrivmsg($self, $channel,
            sprintf("  \x{1F389} best:  %s (%s msgs)  \x{B7}  \x{1F614} worst: %s (%s msgs)",
                $best_d, _fmt_n($by_day{$best_d}),
                $worst_d, _fmt_n($by_day{$worst_d})));
        return 1;
    }

    # Read each diagnostic completely before deriving absence or publishing
    # the report. DBI may signal a failed fetch through err instead of dying.
    my $read_rows = sub {
        my ($sql, $bind, $single) = @_;
        my ($sth, @rows);
        my $ok = eval {
            $sth = $dbh->prepare($sql) or die "radar_prepare\n";
            $sth->execute(@$bind) or die "radar_execute\n";
            while (my $row = $sth->fetchrow_hashref) { push @rows, $row }
            die "radar_fetch\n" if $sth->err;
            die "radar_aggregate\n" if $single && @rows != 1;
            1;
        };
        # Observe EOF before cleanup can clear err; cleanup cannot invalidate
        # a complete read or replace the original failure.
        eval { $sth->finish } if $sth;
        unless ($ok) {
            botNotice($self, $nick, 'Database error.');
            return;
        }
        return \@rows;
    };

    # Mode standard (par défaut) — diagnostic temps réel
    # 1. Activity rate — dernière heure vs moyenne 24h
    my $rate_rows = $read_rows->(q{
        SELECT
            SUM(IF(cl.ts >= NOW() - INTERVAL  1 HOUR, 1, 0)) AS last_h,
            SUM(IF(cl.ts >= NOW() - INTERVAL 24 HOUR, 1, 0)) AS last_24h
        FROM CHANNEL_LOG cl
        JOIN CHANNEL c ON c.id_channel = cl.id_channel
        WHERE c.name = ? AND cl.event_type IN ('public','action')
    }, [$channel], 1);
    return unless $rate_rows;
    my $last_h   = $rate_rows->[0]{last_h}   // 0;
    my $last_24h = $rate_rows->[0]{last_24h} // 0;
    my $avg_h    = $last_24h / 24;

    my $rate_emoji = "\x{3030}\x{FE0F}";
    my $rate_msg   = "calm";
    if ($avg_h > 0) {
        my $ratio = $last_h / ($avg_h || 1);
        if    ($ratio >= 3.0) { $rate_emoji = "\x{1F525}"; $rate_msg = sprintf("SPIKE x%.1f", $ratio); }
        elsif ($ratio >= 2.0) { $rate_emoji = "\x{1F4C8}"; $rate_msg = sprintf("busy x%.1f", $ratio); }
        elsif ($ratio <= 0.2) { $rate_emoji = "\x{1F319}"; $rate_msg = sprintf("quiet x%.1f", $ratio); }
        else                  { $rate_emoji = "\x{3030}\x{FE0F}"; $rate_msg = sprintf("normal x%.1f", $ratio); }
    }

    push @lines, sprintf('%s rate: %d msgs/last-hour (avg %.0f/h over 24h) - %s',
        $rate_emoji, $last_h, $avg_h, $rate_msg);

    # 2. Last message ago
    my $last_rows = $read_rows->(q{
        SELECT TIMESTAMPDIFF(MINUTE, MAX(cl.ts), NOW()) AS m
        FROM CHANNEL_LOG cl
        JOIN CHANNEL c ON c.id_channel = cl.id_channel
        WHERE c.name = ? AND cl.event_type IN ('public','action')
    }, [$channel], 1);
    return unless $last_rows;
    {
        my $m = $last_rows->[0]{m} // 0;
        if ($m > 30) {
            my $silent_emoji = $m > 360 ? "\x{1F997}" : "\x{1F634}";
            push @lines, sprintf('%s last public msg: %s ago',
                $silent_emoji,
                ($m < 60 ? "${m}m"
                 : $m < 1440 ? sprintf('%dh%dm', int($m/60), $m%60)
                 : sprintf('%dd%dh', int($m/1440), int(($m%1440)/60))));
        }
    }

    # 3. Newcomers — premières activités dans les dernières 24h
    my $new_rows = $read_rows->(q{
        SELECT cl.nick, MIN(cl.ts) AS first
        FROM CHANNEL_LOG cl
        JOIN CHANNEL c ON c.id_channel = cl.id_channel
        WHERE c.name = ?
          AND cl.event_type IN ('public','action')
        GROUP BY cl.nick
        HAVING first >= NOW() - INTERVAL 24 HOUR
        ORDER BY first ASC
        LIMIT 10
    }, [$channel]);
    return unless $new_rows;
    {
        my @newbies = map { $_->{nick} } @$new_rows;
        if (@newbies) {
            my $list = join(', ', @newbies);
            $list = substr($list, 0, 200) . '...' if length($list) > 200;
            push @lines, sprintf("\x{1F195} newcomers (24h): %s", $list);
        }
    }

    # 4. Ghosts — nicks en nicklist mais silencieux > 6h
    my @nicks_on_chan = eval { $self->gethChannelsNicksOnChan($channel) };
    if (@nicks_on_chan) {
        my $bot_nick = eval { $self->{irc}->nick_folded } // '';
        my @candidates = grep { lc($_) ne lc($bot_nick) } @nicks_on_chan;
        my @ghosts;
        if (@candidates) {
            my $ph = join(',', ('?') x scalar(@candidates));
            my $ghost_rows = $read_rows->(qq{
                SELECT cl.nick, MAX(cl.ts) AS last_ts,
                       TIMESTAMPDIFF(HOUR, MAX(cl.ts), NOW()) AS hours_silent
                FROM CHANNEL_LOG cl
                JOIN CHANNEL c ON c.id_channel = cl.id_channel
                WHERE c.name = ?
                  AND cl.nick IN ($ph)
                  AND cl.event_type IN ('public','action')
                GROUP BY cl.nick
            }, [$channel, @candidates]);
            return unless $ghost_rows;
            my %last_seen;
            for my $r (@$ghost_rows) {
                $last_seen{lc($r->{nick})} = $r->{hours_silent} // 9999;
            }
            for my $n (@candidates) {
                my $h = $last_seen{lc($n)} // 9999;
                push @ghosts, "$n (${h}h)" if $h >= 6;
            }
            @ghosts = sort {
                my ($ah) = $a =~ /\((\d+)h\)/;
                my ($bh) = $b =~ /\((\d+)h\)/;
                ($bh // 0) <=> ($ah // 0)
            } @ghosts;
            @ghosts = @ghosts[0..4] if @ghosts > 5;
            push @lines, "\x{1F47B} silent ghosts: " . join(', ', @ghosts) if @ghosts;
        }
    }

    # 5. Karma vortex — récent karma activity > 5 votes dernière heure
    my $klog = $self->{_karma_log}{$channel} // [];
    my $now = time();
    my $recent_karma = scalar grep { ($_->{ts}//0) >= $now - 3600 } @$klog;
    if ($recent_karma >= 5) {
        my $kpos = scalar grep { ($_->{ts}//0) >= $now-3600 && ($_->{delta}//'') eq '+1' } @$klog;
        my $kneg = $recent_karma - $kpos;
        push @lines, sprintf("\x{26A1} karma vortex (1h): %d votes (+%d / -%d)",
            $recent_karma, $kpos, $kneg);
    }

    # 6. Top talkers dernière heure
    if ($last_h > 0) {
        my $talker_rows = $read_rows->(q{
            SELECT cl.nick, COUNT(*) AS c
            FROM CHANNEL_LOG cl
            JOIN CHANNEL c ON c.id_channel = cl.id_channel
            WHERE c.name = ?
              AND cl.ts >= NOW() - INTERVAL 1 HOUR
              AND cl.event_type IN ('public','action')
            GROUP BY cl.nick
            ORDER BY c DESC
            LIMIT 3
        }, [$channel]);
        return unless $talker_rows;
        my @talkers = map { "$_->{nick}:$_->{c}" } @$talker_rows;
        push @lines, sprintf("\x{1F399}\x{FE0F} loudest (1h): %s", join('  ', @talkers)) if @talkers;
    }

    botPrivmsg($self, $channel, "\x{1F4E1} \x02Radar\x02 on $channel:");
    botPrivmsg($self, $channel, "  $_") for @lines;
    return 1;
}

1;
