package Mediabot::SocialHistory;

# =============================================================================
# Mediabot::SocialHistory
# =============================================================================
# mb670: staged social/history extraction from Mediabot::UserCommands.
#
# The public command symbols are imported back into UserCommands so the
# dispatch contract stays unchanged while implementation ownership moves here.
#
# The compatibility trampolines below deliberately resolve UserCommands'
# historical symbols at CALL time. Existing tests and plugins that locally mock
# Mediabot::UserCommands::botPrivmsg/botNotice/... therefore keep working
# during this compatibility phase.
# =============================================================================

use strict;
use warnings;
use utf8;
use Exporter 'import';
use Time::Local ();
use Encode ();

our @EXPORT_OK = qw(
    _fmt_n
    _awards_add
    _awards_pick
    mbAwards_ctx
    _yearbook_best_key
    _yearbook_month_label
    _yearbook_day_label
    _yearbook_collect
    mbYearbook_ctx
    mbMemory_ctx
    _memory_rand_bounded
    _memory_lines
    _profile_community_footprint
    mbProfil_ctx
    mbDashboard_ctx
    mbMood_ctx
    mbLeaderboard_ctx
    mbChronos_ctx
    _recap_text
    _recap_parse
    _ach_progress
    mbRecap_ctx
    mbOnThisDay_ctx
    _onthisday_lines
    mbMilestone_ctx
    _milestone_next
    _milestone_last
    _group_int
    _humanize_days
);

sub botPrivmsg          { goto &Mediabot::UserCommands::botPrivmsg }
sub botNotice           { goto &Mediabot::UserCommands::botNotice }
sub queueBotNotices     { goto &Mediabot::UserCommands::queueBotNotices }
sub isIrcChannelTarget  { goto &Mediabot::UserCommands::isIrcChannelTarget }
sub _ach_goal_line       { goto &Mediabot::UserCommands::_ach_goal_line }
sub _irc_bytes           { goto &Mediabot::UserCommands::_irc_bytes }

sub _fmt_n {
    my ($n) = @_;
    return '?' unless defined $n;
    return $n          if $n < 1000;
    return sprintf('%.1fk', $n/1000)  if $n < 10_000;
    return sprintf('%dk',   int($n/1000)) if $n < 1_000_000;
    return sprintf('%.1fM', $n/1_000_000);
}

sub _awards_add {
    my ($store, $nick, $metric, $value) = @_;
    return unless ref($store) eq 'HASH' && defined($nick) && defined($metric);
    $nick =~ s/^\s+|\s+$//g;
    return if $nick eq '';
    $value = int($value // 0);
    return if $value <= 0;

    my $key = lc $nick;
    $store->{$key}{display} //= $nick;
    $store->{$key}{$metric} = int($store->{$key}{$metric} // 0) + $value;
    return 1;
}

sub _awards_pick {
    my ($store, $metric) = @_;
    return unless ref($store) eq 'HASH' && defined $metric;
    my @keys = grep { int($store->{$_}{$metric} // 0) > 0 } keys %$store;
    return unless @keys;
    @keys = sort {
           int($store->{$b}{$metric} // 0) <=> int($store->{$a}{$metric} // 0)
        || lc($store->{$a}{display} // $a) cmp lc($store->{$b}{display} // $b)
    } @keys;
    my $k = $keys[0];
    return [ $store->{$k}{display} // $k, int($store->{$k}{$metric} // 0) ];
}

sub mbAwards_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel // '';
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    unless (isIrcChannelTarget($channel)) {
        botNotice($self, $nick, 'Syntax: awards [7d|30d]  (use it in a channel)');
        return 1;
    }

    my $period = @args ? lc($args[0] // '') : '7d';
    if (@args > 1 || $period !~ /\A(?:7d|30d)\z/) {
        botNotice($self, $nick, 'Syntax: awards [7d|30d]');
        return 1;
    }
    my $days = ($period eq '30d') ? 30 : 7;

    my $dbh = $self->{dbh};
    unless ($dbh) {
        botNotice($self, $nick, 'awards: database unavailable.');
        return 1;
    }

    my $channel_obj = $self->{channels}{lc $channel};
    my $id_channel  = $channel_obj ? eval { $channel_obj->get_id } : undef;
    unless (defined($id_channel) && $id_channel =~ /^\d+$/) {
        botNotice($self, $nick, 'awards: channel not known to the bot.');
        return 1;
    }

    # One archive-aware history gather gives both total activity and the same
    # 00:00-05:59 band used by the Night Owl achievement ladder.
    my %msg;
    my $g = Mediabot::Helpers::channel_log_gather($self, $dbh, qq{
        SELECT cl.nick AS nick,
               COUNT(*) AS msg_count,
               SUM(CASE WHEN HOUR(cl.ts) BETWEEN 0 AND 5 THEN 1 ELSE 0 END) AS night_count
        FROM __CLSRC__ cl
        JOIN CHANNEL c ON c.id_channel = cl.id_channel
        WHERE c.name = ?
          AND cl.event_type IN ('public','action')
          AND cl.ts >= NOW() - INTERVAL $days DAY
        GROUP BY cl.nick
    }, [ $channel ], sub {
        my ($r) = @_;
        _awards_add(\%msg, $r->{nick}, 'messages', $r->{msg_count});
        _awards_add(\%msg, $r->{nick}, 'night',    $r->{night_count});
    }, 'content');

    unless ($g->{live_ok}) {
        botNotice($self, $nick, 'awards: channel history is temporarily unavailable.');
        return 1;
    }

    # One bounded KARMA_LOG prepare, executed twice with a role selector.
    # This keeps the two indexed role scans (receiver / giver) without a
    # derived set-combining query, preserving the mb576 per-source SQL contract.
    my ($magnet, $generous);
    my $sth_k = eval { $dbh->prepare(qq{
        SELECT CASE WHEN ? = 'given' THEN kl.from_nick ELSE kl.nick END AS who,
               SUM(CASE WHEN kl.delta = 1 THEN 1 ELSE 0 END) AS positive_count
        FROM KARMA_LOG kl
        WHERE kl.id_channel = ?
          AND kl.ts >= NOW() - INTERVAL $days DAY
        GROUP BY CASE WHEN ? = 'given' THEN kl.from_nick ELSE kl.nick END
        HAVING who IS NOT NULL AND who <> '' AND positive_count > 0
        ORDER BY positive_count DESC, who ASC
        LIMIT 1
    }) };
    if ($sth_k) {
        if (eval { $sth_k->execute('received', $id_channel, 'received') }) {
            my $r = eval { $sth_k->fetchrow_hashref } || {};
            $magnet = [ $r->{who}, int($r->{positive_count} // 0) ]
                if defined($r->{who}) && length($r->{who})
                && int($r->{positive_count} // 0) > 0;
        }
        if (eval { $sth_k->execute('given', $id_channel, 'given') }) {
            my $r = eval { $sth_k->fetchrow_hashref } || {};
            $generous = [ $r->{who}, int($r->{positive_count} // 0) ]
                if defined($r->{who}) && length($r->{who})
                && int($r->{positive_count} // 0) > 0;
        }
        eval { $sth_k->finish };
    }

    # One bounded community prepare. Each scalar subquery owns its table and
    # returns only the winning contributor, avoiding derived-set materialization
    # while keeping quote/factoid attribution in a single DB round-trip.
    my ($archivist, $lore);
    my $sth_c = eval { $dbh->prepare(qq{
        SELECT
            (SELECT CONCAT(u.nickname, CHAR(9), COUNT(*))
               FROM QUOTES q
               JOIN USER u ON u.id_user = q.id_user
              WHERE q.id_channel = ?
                AND q.ts >= NOW() - INTERVAL $days DAY
                AND u.nickname <> ''
              GROUP BY u.nickname
              ORDER BY COUNT(*) DESC, u.nickname ASC
              LIMIT 1) AS archivist,
            (SELECT CONCAT(
                        COALESCE(NULLIF(f.created_by_nick, ''), NULLIF(u.nickname, ''), ''),
                        CHAR(9), COUNT(*)
                    )
               FROM FACTOID f
               LEFT JOIN USER u ON u.id_user = f.created_by
              WHERE f.id_channel = ?
                AND f.created_at >= NOW() - INTERVAL $days DAY
                AND COALESCE(NULLIF(f.created_by_nick, ''), NULLIF(u.nickname, ''), '') <> ''
              GROUP BY COALESCE(NULLIF(f.created_by_nick, ''), NULLIF(u.nickname, ''), '')
              ORDER BY COUNT(*) DESC,
                       COALESCE(NULLIF(f.created_by_nick, ''), NULLIF(u.nickname, ''), '') ASC
              LIMIT 1) AS lorekeeper
    }) };
    if ($sth_c && eval { $sth_c->execute($id_channel, $id_channel) }) {
        my $r = eval { $sth_c->fetchrow_hashref } || {};
        for my $spec (
            [ archivist => \$archivist ],
            [ lorekeeper => \$lore ],
        ) {
            my ($field, $slot) = @$spec;
            my $packed = $r->{$field};
            next unless defined($packed) && length($packed);
            my ($who, $count) = split /\t/, $packed, 2;
            next unless defined($who) && length($who)
                     && defined($count) && $count =~ /^\d+$/ && $count > 0;
            $$slot = [ $who, int($count) ];
        }
        eval { $sth_c->finish };
    }
    elsif ($sth_c) {
        eval { $sth_c->finish };
    }

    my $voice = _awards_pick(\%msg, 'messages');
    my $night = _awards_pick(\%msg, 'night');

    my @lines;
    my @activity;
    push @activity, "\x{1F5E3} Top Voice: \x02$voice->[0]\x02 \x{2014} " . _fmt_n($voice->[1]) . ' msgs'
        if $voice;
    push @activity, "\x{1F319} Night Owl: \x02$night->[0]\x02 \x{2014} " . _fmt_n($night->[1]) . ' night msgs'
        if $night;
    push @lines, join("  \x{B7}  ", @activity) if @activity;

    my @karma_line;
    push @karma_line, "\x{2728} Karma Magnet: \x02$magnet->[0]\x02 \x{2014} " . _fmt_n($magnet->[1]) . ' positive votes'
        if $magnet;
    push @karma_line, "\x{1F381} Generous Soul: \x02$generous->[0]\x02 \x{2014} " . _fmt_n($generous->[1]) . ' positive votes'
        if $generous;
    push @lines, join("  \x{B7}  ", @karma_line) if @karma_line;

    my @community_line;
    push @community_line, "\x{1F4DC} Archivist: \x02$archivist->[0]\x02 \x{2014} " . _fmt_n($archivist->[1]) . ' quotes'
        if $archivist;
    push @community_line, "\x{1F4DA} Lorekeeper: \x02$lore->[0]\x02 \x{2014} " . _fmt_n($lore->[1]) . ' factoids'
        if $lore;
    push @lines, join("  \x{B7}  ", @community_line) if @community_line;

    my $header = "\x{1F3C6} \x02$channel Awards\x02 \x{2014} last $days days";
    if (!@lines) {
        botPrivmsg($self, $channel, "$header \x{2014} not enough activity yet.");
        return 1;
    }

    botPrivmsg($self, $channel, $header);
    botPrivmsg($self, $channel, "  $_") for @lines;
    return 1;
}

sub _yearbook_best_key {
    my ($h) = @_;
    return unless ref($h) eq 'HASH' && keys %$h;
    my @keys = sort {
           int($h->{$b} // 0) <=> int($h->{$a} // 0)
        || $a cmp $b
    } keys %$h;
    my $k = $keys[0];
    return [ $k, int($h->{$k} // 0) ];
}

sub _yearbook_month_label {
    my ($month) = @_;
    my @names = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);
    $month = int($month // 0);
    return '?' if $month < 1 || $month > 12;
    return $names[$month - 1];
}

sub _yearbook_day_label {
    my ($day) = @_;
    return '?' unless defined($day) && $day =~ /\A\d{4}-(\d{2})-(\d{2})\z/;
    return _yearbook_month_label($1) . ' ' . int($2);
}

sub _yearbook_collect {
    my ($self, $id_channel, $year) = @_;
    my $dbh = $self->{dbh};
    return unless $dbh && defined($id_channel) && $id_channel =~ /^\d+$/;
    return unless defined($year) && $year =~ /^\d{4}$/;

    my $start = sprintf('%04d-01-01 00:00:00', $year);
    my $end   = sprintf('%04d-01-01 00:00:00', $year + 1);

    # Pass 1: group by nick. Merging by lower-cased nick avoids double
    # counting a case-only nick variant when the year crosses live/archive.
    my %voices;
    my $voices_g = Mediabot::Helpers::channel_log_gather($self, $dbh, q{
        SELECT nick, COUNT(*) AS messages
        FROM __CLSRC__
        WHERE id_channel = ?
          AND event_type IN ('public','action')
          AND ts >= ?
          AND ts < ?
        GROUP BY nick
    }, [ $id_channel, $start, $end ], sub {
        my ($r) = @_;
        my $display = $r->{nick};
        return unless defined($display) && length($display);
        my $count = int($r->{messages} // 0);
        return if $count <= 0;
        my $key = lc $display;
        $voices{$key}{display} //= $display;
        $voices{$key}{messages} = int($voices{$key}{messages} // 0) + $count;
    }, 'content');
    return unless $voices_g->{live_ok} && !$voices_g->{tainted};
    return unless keys %voices;

    my $messages = 0;
    $messages += int($voices{$_}{messages} // 0) for keys %voices;
    my $people = scalar keys %voices;
    my @voice_keys = sort {
           int($voices{$b}{messages} // 0) <=> int($voices{$a}{messages} // 0)
        || lc($voices{$a}{display} // $a) cmp lc($voices{$b}{display} // $b)
    } keys %voices;
    splice(@voice_keys, 3) if @voice_keys > 3;
    my @top_voices = map {
        [ $voices{$_}{display} // $_, int($voices{$_}{messages} // 0) ]
    } @voice_keys;

    # Pass 2: one bounded day/hour cube. From these rows we derive the busiest
    # day, month and hour and the actual recorded activity span. At most
    # 366*24 rows/source are returned for a leap year.
    my (%days, %months, %hours);
    my ($first_day, $last_day);
    my $time_g = Mediabot::Helpers::channel_log_gather($self, $dbh, q{
        SELECT DATE(ts) AS day_key,
               HOUR(ts) AS hour_key,
               COUNT(*) AS messages
        FROM __CLSRC__
        WHERE id_channel = ?
          AND event_type IN ('public','action')
          AND ts >= ?
          AND ts < ?
        GROUP BY DATE(ts), HOUR(ts)
    }, [ $id_channel, $start, $end ], sub {
        my ($r) = @_;
        my $day = $r->{day_key};
        return unless defined($day) && $day =~ /\A\d{4}-\d{2}-\d{2}\z/;
        my $hour = int($r->{hour_key} // -1);
        return if $hour < 0 || $hour > 23;
        my $count = int($r->{messages} // 0);
        return if $count <= 0;
        my $month = substr($day, 5, 2);
        $days{$day}       = int($days{$day}       // 0) + $count;
        $months{$month}   = int($months{$month}   // 0) + $count;
        $hours{$hour}     = int($hours{$hour}     // 0) + $count;
        $first_day = $day if !defined($first_day) || $day lt $first_day;
        $last_day  = $day if !defined($last_day)  || $day gt $last_day;
    }, 'content');
    return unless $time_g->{live_ok} && !$time_g->{tainted};
    return unless defined($first_day) && defined($last_day);

    my $best_month = _yearbook_best_key(\%months);
    my $best_day   = _yearbook_best_key(\%days);
    my $best_hour  = _yearbook_best_key(\%hours);

    # Community tables are not part of CHANNEL_LOG archival rotation. Keep the
    # annual contribution read isolated and fail-soft: the yearbook remains
    # useful even if one optional community table is unavailable.
    my ($quote_count, $factoid_count) = (0, 0);
    my $sth_c = eval { $dbh->prepare(q{
        SELECT
            (SELECT COUNT(*)
               FROM QUOTES
              WHERE id_channel = ? AND ts >= ? AND ts < ?) AS quote_count,
            (SELECT COUNT(*)
               FROM FACTOID
              WHERE id_channel = ? AND created_at >= ? AND created_at < ?) AS factoid_count
    }) };
    if ($sth_c && eval {
        $sth_c->execute($id_channel, $start, $end, $id_channel, $start, $end)
    }) {
        my $r = eval { $sth_c->fetchrow_hashref } || {};
        $quote_count   = int($r->{quote_count}   // 0);
        $factoid_count = int($r->{factoid_count} // 0);
        eval { $sth_c->finish };
    }
    elsif ($sth_c) {
        eval { $sth_c->finish };
    }

    return {
        year          => 0 + $year,
        messages      => $messages,
        people        => $people,
        top_voices    => \@top_voices,
        best_month    => $best_month,
        best_day      => $best_day,
        best_hour     => $best_hour,
        first_day     => $first_day,
        last_day      => $last_day,
        quote_count   => $quote_count,
        factoid_count => $factoid_count,
    };
}

sub mbYearbook_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel // '';
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    unless (isIrcChannelTarget($channel)) {
        botNotice($self, $nick, 'Syntax: yearbook [YYYY]  (use it in a channel)');
        return 1;
    }

    return 1 unless eval {
        Mediabot::Helpers::chanset_enabled($self, $channel, 'OnThisDay', default => 1)
    } // 1;

    my $current_year = (localtime())[5] + 1900;
    my $year = @args ? ($args[0] // '') : ($current_year - 1);
    if (@args > 1 || $year !~ /\A\d{4}\z/ || $year < 2000 || $year > $current_year) {
        botNotice($self, $nick, "Syntax: yearbook [YYYY]  (2000-$current_year)");
        return 1;
    }
    $year = int($year);

    my $dbh = $self->{dbh};
    unless ($dbh) {
        botNotice($self, $nick, 'yearbook: database unavailable.');
        return 1;
    }

    my $channel_obj = $self->{channels}{lc $channel};
    my $id_channel  = $channel_obj ? eval { $channel_obj->get_id } : undef;
    unless (defined($id_channel) && $id_channel =~ /^\d+$/) {
        botNotice($self, $nick, 'yearbook: channel not known to the bot.');
        return 1;
    }

    my $yb = _yearbook_collect($self, $id_channel, $year);
    unless ($yb) {
        botNotice($self, $nick, "yearbook: no usable channel history found for $year.");
        return 1;
    }

    my $header = "\x{1F4D6} \x02$channel Yearbook\x02 \x{2014} $year";
    $header .= " \x{B7} year to date" if $year == $current_year;
    botPrivmsg($self, $channel, $header);

    my $month = $yb->{best_month};
    my $month_label = $month ? _yearbook_month_label($month->[0]) : '?';
    botPrivmsg($self, $channel,
        "  \x{1F4AC} " . _fmt_n($yb->{messages}) . " msgs \x{B7} "
        . "\x{1F465} " . _fmt_n($yb->{people}) . " voices \x{B7} "
        . "\x{1F4C5} busiest month: $month_label ("
        . _fmt_n($month ? $month->[1] : 0) . ')');

    my $day  = $yb->{best_day};
    my $hour = $yb->{best_hour};
    my $hour_n = $hour ? int($hour->[0]) : 0;
    my $hour_end = ($hour_n + 1) % 24;
    botPrivmsg($self, $channel,
        "  \x{1F525} peak day: " . _yearbook_day_label($day ? $day->[0] : undef)
        . ' (' . _fmt_n($day ? $day->[1] : 0) . " msgs) \x{B7} "
        . sprintf("\x{1F553} peak hour: %02d:00-%02d:00 (%s msgs)",
            $hour_n, $hour_end, _fmt_n($hour ? $hour->[1] : 0)));

    my @voice_parts = map {
        my ($vnick, $count) = @$_;
        "\x02$vnick\x02 " . _fmt_n($count)
    } @{ $yb->{top_voices} || [] };
    botPrivmsg($self, $channel,
        "  \x{1F451} top voices: " . join(" \x{B7} ", @voice_parts));

    my $tail = "  \x{1F4DC} " . _fmt_n($yb->{quote_count}) . " quotes added \x{B7} "
             . "\x{1F4DA} " . _fmt_n($yb->{factoid_count}) . ' factoids learned';
    my $full_first = sprintf('%04d-01-01', $year);
    my $full_last  = sprintf('%04d-12-31', $year);
    if (($yb->{first_day} // '') ne $full_first || ($yb->{last_day} // '') ne $full_last) {
        $tail .= " \x{B7} \x{1F5D3} recorded "
              . _yearbook_day_label($yb->{first_day}) . '-'
              . _yearbook_day_label($yb->{last_day});
    }
    botPrivmsg($self, $channel, $tail);

    return 1;
}

sub mbMemory_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;

    unless (isIrcChannelTarget($channel)) {
        botNotice($self, $nick, "Syntax: memory  (use it in a channel)");
        return;
    }

    return unless eval {
        Mediabot::Helpers::chanset_enabled($self, $channel, 'OnThisDay', default => 1)
    } // 1;

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
    if (grep { defined($_) && /\S/ } @args) {
        botNotice($self, $nick, "Syntax: memory  (no argument)");
        return;
    }

    my $dbh = $self->{dbh};
    unless ($dbh) {
        botNotice($self, $nick, "memory: database unavailable.");
        return;
    }

    my $channel_obj = $self->{channels}{lc $channel};
    my $id_channel  = $channel_obj ? eval { $channel_obj->get_id } : undef;
    unless (defined $id_channel) {
        botNotice($self, $nick, "memory: channel not known to the bot.");
        return;
    }

    my @lines = Mediabot::UserCommands::_memory_lines(
        $self, $id_channel, $channel
    );
    unless (@lines) {
        botNotice(
            $self,
            $nick,
            "No suitable channel memory older than 30 days was found."
        );
        return;
    }

    # CommandAsync captures direct botNotice() calls in the child and replays
    # them safely from the parent. queueBotNotices() must NOT be used here:
    # its timers would belong to the disposable child loop and never fire.
    botNotice($self, $nick, $_) for @lines;
    return 1;
}

sub _memory_rand_bounded {
    my ($rand_cb, $limit) = @_;
    $limit = int($limit // 0);
    return 0 if $limit <= 1;
    my $v = eval { $rand_cb->($limit) };
    $v = 0 unless defined $v && !ref($v) && $v =~ /\A\d+(?:\.\d+)?\z/;
    $v = int($v);
    $v = 0 if $v < 0;
    $v = $limit - 1 if $v >= $limit;
    return $v;
}

sub _memory_lines {
    my ($self, $id_channel, $channel_label, %opts) = @_;
    my $dbh = $self->{dbh};
    return () unless $dbh && defined $id_channel;

    my $attempts = int($opts{attempts} // 4);
    $attempts = 1 if $attempts < 1;
    $attempts = 6 if $attempts > 6;
    my $rand_cb = ref($opts{rand_cb}) eq 'CODE'
        ? $opts{rand_cb}
        : sub { rand($_[0]) };

    my ($first_uts, $last_uts);
    my $first_g = Mediabot::Helpers::channel_log_gather($self, $dbh, q{
        SELECT ts, UNIX_TIMESTAMP(ts) AS uts
        FROM __CLSRC__
        WHERE id_channel = ?
          AND event_type IN ('public','action')
          AND ts < CURDATE() - INTERVAL 30 DAY
        ORDER BY ts ASC
        LIMIT 1
    }, [ $id_channel ], sub {
        my ($r) = @_;
        return unless defined $r->{uts};
        $first_uts = 0 + $r->{uts}
            if !defined($first_uts) || $r->{uts} < $first_uts;
    }, 'content');
    return () unless $first_g->{live_ok} && defined $first_uts;

    my $last_g = Mediabot::Helpers::channel_log_gather($self, $dbh, q{
        SELECT ts, UNIX_TIMESTAMP(ts) AS uts
        FROM __CLSRC__
        WHERE id_channel = ?
          AND event_type IN ('public','action')
          AND ts < CURDATE() - INTERVAL 30 DAY
        ORDER BY ts DESC
        LIMIT 1
    }, [ $id_channel ], sub {
        my ($r) = @_;
        return unless defined $r->{uts};
        $last_uts = 0 + $r->{uts}
            if !defined($last_uts) || $r->{uts} > $last_uts;
    }, 'content');
    return () unless $last_g->{live_ok} && defined $last_uts && $last_uts >= $first_uts;

    my $span = $last_uts - $first_uts + 1;
    my ($best, %seen_day);

    ATTEMPT:
    for (1 .. $attempts) {
        my $anchor = $first_uts + _memory_rand_bounded($rand_cb, $span);
        my $hit;
        my $seek_g = Mediabot::Helpers::channel_log_gather($self, $dbh, q{
            SELECT ts, UNIX_TIMESTAMP(ts) AS uts
            FROM __CLSRC__
            WHERE id_channel = ?
              AND event_type IN ('public','action')
              AND ts >= FROM_UNIXTIME(?)
              AND ts < CURDATE() - INTERVAL 30 DAY
            ORDER BY ts ASC
            LIMIT 1
        }, [ $id_channel, $anchor ], sub {
            my ($r) = @_;
            return unless defined $r->{uts};
            $hit = $r if !$hit || $r->{uts} < $hit->{uts};
        }, 'content');
        return () unless $seek_g->{live_ok};
        next ATTEMPT unless $hit && defined $hit->{ts};

        my ($day) = $hit->{ts} =~ /\A(\d{4}-\d{2}-\d{2})/;
        next ATTEMPT unless defined $day && !$seen_day{$day}++;

        my ($msgs, $people) = (0, 0);
        my $day_g = Mediabot::Helpers::channel_log_gather($self, $dbh, q{
            SELECT COUNT(*) AS msgs, COUNT(DISTINCT nick) AS people
            FROM __CLSRC__
            WHERE id_channel = ?
              AND event_type IN ('public','action')
              AND ts >= ?
              AND ts < DATE_ADD(?, INTERVAL 1 DAY)
        }, [ $id_channel, $day, $day ], sub {
            my ($r) = @_;
            $msgs += $r->{msgs} // 0;
            my $p = $r->{people} // 0;
            $people = $p if $p > $people;  # same boundary approximation as !onthisday
        }, 'content');
        return () unless $day_g->{live_ok};
        next ATTEMPT if $msgs <= 0;

        my $cand = {
            day => $day, msgs => 0 + $msgs, people => 0 + $people,
            score => (0 + $msgs) + (5 * (0 + $people)),
        };
        $best = $cand if !$best || $cand->{score} > $best->{score};
        last ATTEMPT if $msgs >= 5 && $people >= 2;
    }
    return () unless $best;

    my $day = $best->{day};
    my %nick_counts;
    my $top_g = Mediabot::Helpers::channel_log_gather($self, $dbh, q{
        SELECT nick, COUNT(*) AS c
        FROM __CLSRC__
        WHERE id_channel = ?
          AND event_type IN ('public','action')
          AND ts >= ?
          AND ts < DATE_ADD(?, INTERVAL 1 DAY)
        GROUP BY nick
        ORDER BY c DESC
        LIMIT 10
    }, [ $id_channel, $day, $day ], sub {
        my ($r) = @_;
        $nick_counts{ $r->{nick} } += $r->{c} // 0
            if defined($r->{nick}) && length($r->{nick});
    }, 'content');
    return () unless $top_g->{live_ok};

    my $topnick = '?';
    if (%nick_counts) {
        ($topnick) = sort { $nick_counts{$b} <=> $nick_counts{$a} || $a cmp $b }
            keys %nick_counts;
    }

    my @lines = (sprintf(
        "\x{1F4FC} Memory from %s \x{2014} %s: %d messages, %d people, most active: %s.",
        $channel_label, $day, $best->{msgs}, $best->{people}, $topnick,
    ));

    my $offset = _memory_rand_bounded($rand_cb, 86400);
    my @quotes;
    for my $pass (0, 1) {
        @quotes = ();
        my ($sql, $bind) = $pass == 0
            ? (q{
                SELECT ts, nick, event_type, publictext
                FROM __CLSRC__
                WHERE id_channel = ?
                  AND event_type IN ('public','action')
                  AND ts >= FROM_UNIXTIME(UNIX_TIMESTAMP(?) + ?)
                  AND ts < DATE_ADD(?, INTERVAL 1 DAY)
                  AND CHAR_LENGTH(publictext) BETWEEN 25 AND 300
                ORDER BY ts ASC
                LIMIT 40
            }, [ $id_channel, $day, $offset, $day ])
            : (q{
                SELECT ts, nick, event_type, publictext
                FROM __CLSRC__
                WHERE id_channel = ?
                  AND event_type IN ('public','action')
                  AND ts >= ?
                  AND ts < DATE_ADD(?, INTERVAL 1 DAY)
                  AND CHAR_LENGTH(publictext) BETWEEN 25 AND 300
                ORDER BY ts ASC
                LIMIT 40
            }, [ $id_channel, $day, $day ]);

        my $quote_g = Mediabot::Helpers::channel_log_gather(
            $self, $dbh, $sql, $bind, sub { push @quotes, $_[0] }, 'content'
        );
        return () unless $quote_g->{live_ok};
        last if @quotes;
    }

    if (@quotes) {
        my $pick = $quotes[_memory_rand_bounded($rand_cb, scalar @quotes)];
        my $text = $pick->{publictext} // '';
        $text =~ s/[\r\n\0]+/ /g;
        $text = Mediabot::Helpers::truncate_utf8($text, 200, '...') if length($text) > 200;
        my $speaker = $pick->{nick} // '?';
        my $quote = ($pick->{event_type} // '') eq 'action'
            ? "* $speaker $text"
            : "<$speaker> $text";
        push @lines, "\x{1F4AC} $quote";
    }

    return @lines;
}


# =============================================================================
# mb670-B: remaining social/history command implementations extracted from
# UserCommands. Public historical symbols are imported back there so dispatch,
# plugins and existing callers keep their established namespace.
# =============================================================================

sub _profile_community_footprint {
    my ($self, $dbh, $channel, $target) = @_;
    return unless $dbh && defined $channel && defined $target;

    # mb669: registered identity is now a public, read-only Achievement API.
    # UserCommands deliberately has no private durable-identity table knowledge;
    # ambiguous aliases stay unresolved instead of being guessed here.
    my $id_user;
    if ($self->{achievements}
        && eval { $self->{achievements}->can('resolve_registered_user') }) {
        my $identity = eval {
            $self->{achievements}->resolve_registered_user($channel, $target)
        };
        if (ref($identity) eq 'HASH'
            && ($identity->{status} // '') eq 'ok'
            && defined($identity->{id_user})
            && "$identity->{id_user}" =~ /^\d+$/) {
            $id_user = 0 + $identity->{id_user};
        }
    }

    my $sth = eval { $dbh->prepare(q{
        SELECT
            (SELECT COUNT(*)
               FROM QUOTES q
               JOIN CHANNEL cq ON cq.id_channel = q.id_channel
              WHERE cq.name = ?
                AND (
                    (? IS NOT NULL AND q.id_user = ?)
                    OR q.id_user IN (
                        SELECT u.id_user FROM USER u WHERE u.nickname = ?
                    )
                )) AS quote_count,
            (SELECT COUNT(*)
               FROM FACTOID f
               JOIN CHANNEL cf ON cf.id_channel = f.id_channel
              WHERE cf.name = ?
                AND (
                    f.created_by_nick = ?
                    OR (? IS NOT NULL AND f.created_by = ?)
                    OR f.created_by IN (
                        SELECT u.id_user FROM USER u WHERE u.nickname = ?
                    )
                )) AS factoid_count
    }) };
    return unless $sth;

    my $ok = eval {
        $sth->execute(
            $channel, $id_user, $id_user, $target,
            $channel, $target, $id_user, $id_user, $target,
        )
    };
    unless ($ok) {
        eval { $sth->finish };
        return;
    }

    my $r = eval { $sth->fetchrow_hashref };
    eval { $sth->finish };
    return unless $r;

    return {
        quote_count   => int($r->{quote_count}   // 0),
        factoid_count => int($r->{factoid_count} // 0),
        (defined($id_user) ? (id_user => 0 + $id_user) : ()),
    };
}


sub mbProfil_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
    my $target  = @args ? lc(shift @args) : lc($nick);

    unless ($channel && $channel =~ /^#/) {
        botNotice($self, $nick, 'Syntax: !profil [nick]  (must be in a channel)'); return;
    }

    my $dbh = $self->{dbh};
    my %stats;

    # 1. Compte total + premier message + dernier message
    # mb576-B1: agregats par table fusionnes en Perl (somme/min/max) ;
    # days_seen est rapporte PAR TABLE et le max (= depuis le first_ts le
    # plus ancien) est conserve.
    $stats{msgs} = 0; $stats{first_ts} = ''; $stats{last_ts} = ''; $stats{days_seen} = 0;
    my $pr_agg_g = Mediabot::Helpers::channel_log_gather($self, $dbh, q{
        SELECT COUNT(*) AS msgs,
               MIN(cl.ts) AS first_ts,
               MAX(cl.ts) AS last_ts,
               TIMESTAMPDIFF(DAY, MIN(cl.ts), NOW()) AS days_seen
        FROM __CLSRC__ cl
        JOIN CHANNEL c ON c.id_channel = cl.id_channel
        WHERE c.name = ? AND cl.nick = ?
          AND cl.event_type IN ('public','action')
    }, [ $channel, $target ], sub {
        my ($r) = @_;
        $stats{msgs} += $r->{msgs} // 0;
        $stats{first_ts} = $r->{first_ts}
            if defined $r->{first_ts}
            && ($stats{first_ts} eq '' || $r->{first_ts} lt $stats{first_ts});
        $stats{last_ts} = $r->{last_ts}
            if defined $r->{last_ts}
            && ($stats{last_ts} eq '' || $r->{last_ts} gt $stats{last_ts});
        $stats{days_seen} = $r->{days_seen}
            if ($r->{days_seen} // 0) > $stats{days_seen};
    }, 'content');
    # mb578-B1: panne LIVE = echec franc — sans quoi profil declarerait
    # « no activity recorded » sur une base en panne.
    unless ($pr_agg_g->{live_ok}) {
        botNotice($self, $nick, 'Database error.');
        return;
    }

    if (($stats{msgs} // 0) == 0) {
        botPrivmsg($self, $channel, "🚫 $target: no activity recorded on $channel.");
        return 1;
    }

    # 2. Karma (depuis KARMA table)
    my $sth_k = $dbh->prepare(q{
        SELECT k.score
        FROM KARMA k
        JOIN CHANNEL c ON c.id_channel = k.id_channel
        WHERE c.name = ? AND k.nick = ?
    });
    if ($sth_k && $sth_k->execute($channel, $target)) {
        my $r = $sth_k->fetchrow_hashref; $sth_k->finish;
        $stats{karma} = $r ? ($r->{score} // 0) : 0;
    }

    # 3. Rank activité (proxy: nb de nicks plus actifs)
    # mb576-B1: comptes par nick fusionnes AVANT le seuil.
    {
        my %pr_counts;
        my $pr_rank_g = Mediabot::Helpers::channel_log_gather($self, $dbh, q{
            SELECT cl2.nick AS nick, COUNT(*) AS cnt
            FROM __CLSRC__ cl2
            JOIN CHANNEL c2 ON c2.id_channel = cl2.id_channel
            WHERE c2.name = ?
              AND cl2.nick != ?
              AND cl2.event_type IN ('public','action')
            GROUP BY cl2.nick
        }, [ $channel, $target ], sub {
            $pr_counts{ lc $_[0]->{nick} } += $_[0]->{cnt} // 0;
        }, 'content');
        unless ($pr_rank_g->{live_ok}) {
            botNotice($self, $nick, 'Database error.');
            return;
        }
        $stats{rank} = 1 + scalar grep { $pr_counts{$_} > $stats{msgs} }
            keys %pr_counts;
    }

    # 4. Heure de pointe + bloc le plus actif
    my @hours = (0) x 24;
    my $pr_hours_g = Mediabot::Helpers::channel_log_gather($self, $dbh, q{
        SELECT HOUR(cl.ts) AS h, COUNT(*) AS c
        FROM __CLSRC__ cl
        JOIN CHANNEL c ON c.id_channel = cl.id_channel
        WHERE c.name = ? AND cl.nick = ?
          AND cl.event_type IN ('public','action')
        GROUP BY HOUR(cl.ts)
    }, [ $channel, $target ], sub { $hours[ $_[0]->{h} ] += $_[0]->{c} // 0 }, 'content');
    unless ($pr_hours_g->{live_ok}) {
        botNotice($self, $nick, 'Database error.');
        return;
    }
    my $peak_h = 0; my $peak_c = 0;
    for my $h (0..23) { if ($hours[$h] > $peak_c) { $peak_c = $hours[$h]; $peak_h = $h; } }
    $stats{peak_hour}   = $peak_h;
    $stats{peak_count}  = $peak_c;

    # Mini sparkline 24h (4 blocs de 6h)
    my @blocks = (0) x 4;
    for my $h (0..23) { $blocks[ int($h/6) ] += $hours[$h]; }
    my $max_block = (sort { $b <=> $a } @blocks)[0] || 1;
    my @glyphs = ("\x{2581}","\x{2582}","\x{2583}","\x{2584}","\x{2585}","\x{2586}","\x{2587}","\x{2588}");
    my $spark = '';
    for my $b (@blocks) {
        my $ratio = $b / $max_block;
        my $idx   = int($ratio * 7);
        $idx = 0 if $idx < 0; $idx = 7 if $idx > 7;
        $spark .= $glyphs[$idx];
    }

    # 5. Trivia score
    my $sth_t = $dbh->prepare(q{
        SELECT ts.score
        FROM TRIVIA_SCORES ts
        JOIN CHANNEL c ON c.id_channel = ts.id_channel
        WHERE c.name = ? AND ts.nick = ?
    });
    if ($sth_t && $sth_t->execute($channel, $target)) {
        my $r = $sth_t->fetchrow_hashref; $sth_t->finish;
        $stats{trivia} = $r ? ($r->{score} // 0) : 0;
    }

    # 6. Achievements + progression already persisted by the Achievement
    # system. mb659 deliberately reuses these counters instead of launching
    # another CHANNEL_LOG scan from !profil.
    my $ach_count = 0;
    my $ach_total = 0;
    my $ach_progress = {};
    my $ach_next = '';
    if ($self->{achievements}) {
        my $ach  = $self->{achievements};
        my $unl  = $ach->get_for_nick($target, $channel);
        my $defs = $ach->list_definitions;
        $ach_count = scalar keys %$unl;
        # mb658: !profil must not disclose locked secret achievements through
        # the denominator. A secret joins the visible total only after unlock.
        $ach_total = scalar grep {
            !$defs->{$_}{hidden} || exists $unl->{$_}
        } keys %$defs;

        # progress_for_nick() reads the already-loaded Achievement registry.
        # With the DB backend, get_for_nick() above has also pinned the durable
        # profile lookup in cache, so this adds no new historical aggregation.
        $ach_progress = eval { $ach->progress_for_nick($target, $channel) } || {};

        # Reuse the same spoiler-safe ordering as !achievements progress.
        # Locked mb658 secrets are filtered inside next_goals().
        my $goals = eval { $ach->next_goals($target, $channel, 1) } || [];
        if (@$goals) {
            $ach_next = _ach_goal_line($ach, $defs, $goals->[0]);
        }
    }

    # 7. mb665 Community Footprint. The helper is deliberately separate from
    # the three CHANNEL_LOG gathers above and fails soft if the optional social
    # read cannot be completed.
    my $community = Mediabot::UserCommands::_profile_community_footprint($self, $dbh, $channel, $target) || {};

    # 8. Formats lisibles
    my $first_s = ($stats{first_ts} && $stats{first_ts} =~ /^(\d{4}-\d{2}-\d{2})/) ? $1 : '?';
    my $last_ago = '?';
    if ($stats{last_ts} && $stats{last_ts} =~ /^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})/) {
        require Time::Local;
        my $ep = eval { Time::Local::timelocal($6,$5,$4,$3,$2-1,$1-1900) };
        if ($ep) {
            my $diff = time() - $ep;
            $last_ago = $diff < 60        ? "${diff}s ago"
                      : $diff < 3600      ? sprintf('%dm ago',  int($diff/60))
                      : $diff < 86400     ? sprintf('%dh ago',  int($diff/3600))
                      :                     sprintf('%dd ago',  int($diff/86400));
        }
    }

    # 9. Karma sign (vert/rouge)
    my $karma_sign = '0';
    if (defined $stats{karma}) {
        $karma_sign = $stats{karma} > 0 ? "\x0303+$stats{karma}\x0f"
                    : $stats{karma} < 0 ? "\x0304$stats{karma}\x0f"
                    :                     '0';
    }

    # 10. Affichage final — lignes condensées et stylées
    my $rank_str = $stats{rank} ? "#$stats{rank}" : '?';
    my $reply_to = $channel;

    botPrivmsg($self, $reply_to,
        "\x{2550}\x{2550}\x{2550} \x02$target\x02 on $channel \x{2550}\x{2550}\x{2550}  "
        . "joined $first_s \x{B7} last $last_ago");

    botPrivmsg($self, $reply_to,
        sprintf("  \x{1F4AC} %s msgs (rank %s, %dd seen)  \x{B7}  \x{1F31F} karma %s  \x{B7}  \x{1F9E0} trivia %s",
            _fmt_n($stats{msgs}), $rank_str, $stats{days_seen} // 0,
            $karma_sign, $stats{trivia} // 0));

    my $peak_label = sprintf('%02dh-%02dh', $stats{peak_hour}, ($stats{peak_hour}+1)%24);
    botPrivmsg($self, $reply_to,
        sprintf("  \x{1F4C8} 24h: %s  \x{B7}  peak %s (%d msgs)",
            $spark, $peak_label, $stats{peak_count} // 0));

    # mb659: compact social/progression line. These are Achievement progress
    # values already persisted by normal feature paths, not fresh DB scans.
    my $streak_days   = int($ach_progress->{activity_streak_days} // 0);
    my $night_msgs    = int($ach_progress->{night_messages} // 0);
    my $morning_msgs  = int($ach_progress->{morning_messages} // 0);
    my $comeback_days = int($ach_progress->{comeback_days} // 0);
    botPrivmsg($self, $reply_to,
        sprintf("  \x{1F3C6} %d/%d  \x{B7}  \x{1F525} streak best %dd  \x{B7}  \x{1F319} night %s  \x{B7}  \x{1F305} early %s  \x{B7}  \x{1FA83} comeback %dd",
            $ach_count, $ach_total, $streak_days,
            _fmt_n($night_msgs), _fmt_n($morning_msgs), $comeback_days));

    if (($community->{quote_count} // 0) || ($community->{factoid_count} // 0)) {
        botPrivmsg($self, $reply_to,
            sprintf("  \x{1F9E9} community: \x{1F4DC} %s quotes  \x{B7}  \x{1F4DA} %s factoids",
                _fmt_n($community->{quote_count} // 0),
                _fmt_n($community->{factoid_count} // 0)));
    }

    botPrivmsg($self, $reply_to, "  \x{1F3AF} Next: $ach_next")
        if length $ach_next;

    return 1;
}


sub mbDashboard_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;

    unless ($channel && $channel =~ /^#/) {
        botNotice($self, $nick, 'Syntax: !dashboard  (must be in a channel)'); return;
    }

    my $dbh = $self->{dbh};
    # 1. Vue globale — total msgs, distinct nicks, période
    # mb576-B1: agregats par table fusionnes en Perl. Les nicks distincts
    # passent par un set (sommer des COUNT(DISTINCT) par table compterait
    # double un nick present en vif ET en archive).
    my %g = (total => 0, nicks => 0, since => undef, days => 0);
    my $dash_agg_g = Mediabot::Helpers::channel_log_gather($self, $dbh, q{
        SELECT COUNT(*) AS total,
               MIN(cl.ts) AS since,
               TIMESTAMPDIFF(DAY, MIN(cl.ts), NOW()) AS days
        FROM __CLSRC__ cl
        JOIN CHANNEL c ON c.id_channel = cl.id_channel
        WHERE c.name = ? AND cl.event_type IN ('public','action')
    }, [ $channel ], sub {
        my ($r) = @_;
        $g{total} += $r->{total} // 0;
        $g{since} = $r->{since}
            if defined $r->{since}
            && (!defined $g{since} || $r->{since} lt $g{since});
        $g{days} = $r->{days} if ($r->{days} // 0) > $g{days};
    }, 'content');
    # mb578-B1: panne LIVE = echec franc — sans quoi dashboard repondrait
    # « No public activity recorded ».
    unless ($dash_agg_g->{live_ok}) {
        botNotice($self, $nick, 'Database error.');
        return;
    }
    {
        my %dash_nicks;
        my $dash_n_g = Mediabot::Helpers::channel_log_gather($self, $dbh, q{
            SELECT DISTINCT cl.nick AS nick
            FROM __CLSRC__ cl
            JOIN CHANNEL c ON c.id_channel = cl.id_channel
            WHERE c.name = ? AND cl.event_type IN ('public','action')
        }, [ $channel ], sub { $dash_nicks{ lc $_[0]->{nick} } = 1 }, 'content');
        unless ($dash_n_g->{live_ok}) {
            botNotice($self, $nick, 'Database error.');
            return;
        }
        $g{nicks} = scalar keys %dash_nicks;
    }
    my $total = $g{total} // 0;
    if ($total == 0) {
        botPrivmsg($self, $channel, "🚫 No public activity recorded on $channel yet.");
        return 1;
    }
    my $since_s = ($g{since} && $g{since} =~ /^(\d{4}-\d{2}-\d{2})/) ? $1 : '?';
    my $days    = $g{days} // 1; $days = 1 if $days < 1;
    my $msgs_per_day = sprintf('%.0f', $total / $days);

    # 2. Top 5 contributeurs
    # mb576-B1: GROUP BY complet par table + fusion + top 5 Perl.
    my @top5;
    {
        my (%t5_counts, %t5_display);
        my $dash_t5_g = Mediabot::Helpers::channel_log_gather($self, $dbh, q{
            SELECT cl.nick AS nick, COUNT(*) AS c
            FROM __CLSRC__ cl
            JOIN CHANNEL c ON c.id_channel = cl.id_channel
            WHERE c.name = ? AND cl.event_type IN ('public','action')
            GROUP BY cl.nick
        }, [ $channel ], sub {
            my $k = lc $_[0]->{nick};
            $t5_display{$k} //= $_[0]->{nick};
            $t5_counts{$k} += $_[0]->{c} // 0;
        }, 'content');
        unless ($dash_t5_g->{live_ok}) {
            botNotice($self, $nick, 'Database error.');
            return;
        }
        my @t5 = sort { $t5_counts{$b} <=> $t5_counts{$a} || $a cmp $b }
            keys %t5_counts;
        splice(@t5, 5) if @t5 > 5;
        @top5 = map { sprintf('%s:%s', $t5_display{$_}, _fmt_n($t5_counts{$_})) } @t5;
    }

    # 3. Activité par jour (sparkline 7 jours, jour le plus actif)
    my $sth_d = $dbh->prepare(q{
        SELECT DATE(cl.ts) AS d, COUNT(*) AS c
        FROM CHANNEL_LOG cl
        JOIN CHANNEL c ON c.id_channel = cl.id_channel
        WHERE c.name = ? AND cl.event_type IN ('public','action')
          AND cl.ts >= NOW() - INTERVAL 7 DAY
        GROUP BY DATE(cl.ts)
        ORDER BY d
    });
    my @days7 = (0) x 7;
    my $today_epoch = time();
    if ($sth_d && $sth_d->execute($channel)) {
        while (my $r = $sth_d->fetchrow_hashref) {
            # offset depuis aujourd'hui
            if ($r->{d} =~ /^(\d{4})-(\d{2})-(\d{2})/) {
                require Time::Local;
                my $ep = eval { Time::Local::timelocal(0,0,12,$3,$2-1,$1-1900) };
                next unless $ep;
                my $offset = int(($today_epoch - $ep) / 86400);
                $offset = 0 if $offset < 0; $offset = 6 if $offset > 6;
                $days7[6 - $offset] = $r->{c};   # oldest left, today right
            }
        }
        $sth_d->finish;
    }
    my $max7 = (sort { $b <=> $a } @days7)[0] || 1;
    my @glyphs = ("\x{2581}","\x{2582}","\x{2583}","\x{2584}","\x{2585}","\x{2586}","\x{2587}","\x{2588}");
    my $spark_d = '';
    for my $d (@days7) {
        my $idx = int(($d / $max7) * 7);
        $idx = 0 if $idx < 0; $idx = 7 if $idx > 7;
        $spark_d .= $glyphs[$idx];
    }

    # 4. Heatmap globale 24h
    my $sth_h = $dbh->prepare(q{
        SELECT HOUR(cl.ts) AS h, COUNT(*) AS c
        FROM CHANNEL_LOG cl
        JOIN CHANNEL c ON c.id_channel = cl.id_channel
        WHERE c.name = ? AND cl.event_type IN ('public','action')
          AND cl.ts >= NOW() - INTERVAL 30 DAY
        GROUP BY HOUR(cl.ts)
    });
    my @hours = (0) x 24;
    if ($sth_h && $sth_h->execute($channel)) {
        while (my $r = $sth_h->fetchrow_hashref) { $hours[$r->{h}] = $r->{c}; }
        $sth_h->finish;
    }
    my $max_h = (sort { $b <=> $a } @hours)[0] || 1;
    my $spark_h = '';
    for my $h (0..23) {
        my $idx = int(($hours[$h] / $max_h) * 7);
        $idx = 0 if $idx < 0; $idx = 7 if $idx > 7;
        $spark_h .= $glyphs[$idx];
    }
    my $peak_h = 0; my $peak_c = 0;
    for my $h (0..23) { if ($hours[$h] > $peak_c) { $peak_c = $hours[$h]; $peak_h = $h; } }

    # 5. Karma vortex — top giver / top receiver des 7 derniers jours (ring buffer)
    my $klog = $self->{_karma_log}{$channel} // [];
    my $since_ts = time() - 7*86400;
    my %givers; my %receivers; my $kpos = 0; my $kneg = 0;
    for my $e (@$klog) {
        next unless ($e->{ts} // 0) >= $since_ts;
        $kpos++ if ($e->{delta} // '') eq '+1';
        $kneg++ if ($e->{delta} // '') eq '-1';
        $givers{ $e->{from} }++   if $e->{from};
        $receivers{ $e->{nick} }++ if $e->{nick};
    }
    my ($top_giver)    = sort { $givers{$b}    <=> $givers{$a} }    keys %givers;
    my ($top_receiver) = sort { $receivers{$b} <=> $receivers{$a} } keys %receivers;

    # 6. Achievements totaux unlock sur ce canal
    my $ach_unlocked = 0;
    if ($self->{achievements}) {
        $ach_unlocked = eval {
            $self->{achievements}->channel_unlock_count($channel)
        } // 0;
    }

    # 7. Active right now (nicks ayant parlé dans les 60 dernières min)
    my $sth_n = $dbh->prepare(q{
        SELECT COUNT(DISTINCT cl.nick) AS c
        FROM CHANNEL_LOG cl
        JOIN CHANNEL c ON c.id_channel = cl.id_channel
        WHERE c.name = ? AND cl.event_type IN ('public','action')
          AND cl.ts >= NOW() - INTERVAL 60 MINUTE
    });
    my $active_now = 0;
    if ($sth_n && $sth_n->execute($channel)) {
        my $r = $sth_n->fetchrow_hashref; $sth_n->finish;
        $active_now = $r ? ($r->{c} // 0) : 0;
    }

    # 8. Affichage
    my $peak_label = sprintf('%02dh', $peak_h);
    botPrivmsg($self, $channel,
        # mb629-B1: couleur seulement — mots, ordre et valeurs inchanges
        # (teuk : « pas de regression, c'est pas mal tel que c'est »).
        "\x0312\x{2550}\x{2550}\x{2550}\x0f \x02Dashboard\x02 $channel \x0312\x{2550}\x{2550}\x{2550}\x0f  "
        . "\x0314since $since_s \x{B7} $days days \x{B7} avg ${msgs_per_day}/d\x0f");

    botPrivmsg($self, $channel,
        sprintf("  \x0311\x{1F4AC}\x0f \x02%s\x02 msgs from %s nicks  \x{B7}  \x0309\x{1F50A}\x0f %d active in last 60min",
            _fmt_n($total), _fmt_n($g{nicks} // 0), $active_now));

    botPrivmsg($self, $channel,
        sprintf("  \x0308\x{1F451} top:\x0f %s", @top5 ? join("  ", @top5) : "n/a"));

    botPrivmsg($self, $channel,
        sprintf("  \x0310\x{1F4C5} 7d:\x0f %s  \x{B7}  \x0310\x{1F567} 24h:\x0f %s  peak \x02%s\x02 (%s)",
            $spark_d, $spark_h, $peak_label, _fmt_n($peak_c)));

    if (%givers || %receivers) {
        botPrivmsg($self, $channel,
            sprintf("  \x0313\x{2728} karma 7d:\x0f \x0309+%d\x0f/\x0304-%d\x0f  \x{B7}  giver: %s  \x{B7}  receiver: %s",
                $kpos, $kneg,
                $top_giver    // 'n/a',
                $top_receiver // 'n/a'));
    }

    if ($self->{achievements}) {
        my $defs_count = scalar keys %{ $self->{achievements}->list_definitions };
        botPrivmsg($self, $channel,
            sprintf("  \x0309\x{1F3C6}\x0f achievements unlocked on $channel: \x02%d\x02  \x{B7}  catalogue: %d available",
                $ach_unlocked, $defs_count));
    }

    return 1;
}


sub mbMood_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;

    unless ($channel && $channel =~ /^#/) {
        botNotice($self, $nick, 'Syntax: !mood  (must be in a channel)'); return;
    }

    # mb500: light per-nick cooldown — !mood now runs three CHANNEL_LOG scans
    # (sentiment + top talkers + peak hour), so guard against spam/DB load the
    # same way onthisday does.
    {
        my $cooldown_s = 15;
        my $now = time();
        $self->{_mood_cooldown} ||= {};
        my $lc_nick = lc($nick);
        my $last = $self->{_mood_cooldown}{$lc_nick};
        if (defined $last && ($now - $last) < $cooldown_s) {
            my $wait = $cooldown_s - ($now - $last);
            botNotice($self, $nick, "mood: please wait ${wait}s before asking again.");
            return;
        }
        $self->{_mood_cooldown}{$lc_nick} = $now;
        if (scalar(keys %{ $self->{_mood_cooldown} }) > 512) {
            for my $k (keys %{ $self->{_mood_cooldown} }) {
                delete $self->{_mood_cooldown}{$k}
                    if ($now - $self->{_mood_cooldown}{$k}) > 3600;
            }
        }
    }

    my $dbh = $self->{dbh};
    unless ($dbh) { botNotice($self, $nick, 'mood: database unavailable.'); return; }
    my $sth = $dbh->prepare(q{
        SELECT cl.publictext
        FROM CHANNEL_LOG cl
        JOIN CHANNEL c ON c.id_channel = cl.id_channel
        WHERE c.name = ?
          AND cl.event_type IN ('public','action')
          AND cl.ts >= NOW() - INTERVAL 60 MINUTE
    });
    unless ($sth && $sth->execute($channel)) {
        botNotice($self, $nick, 'Database error.'); $sth->finish if $sth; return;
    }

    # Patterns FR/EN
    my @positive = qw(
        lol mdr ptdr xptdr haha hehe hihi yep ouais ouaip oui yes yep yeah
        merci thanks thx genial cool super excellent parfait nice top
        bravo felicitations clap kiff like love amour content heureux
        happy great awesome wonderful incroyable formidable bien sympa
    );
    my @negative = qw(
        putain merde chiant ridicule nul fail rate raté echec chiotte
        wtf wtf fuck fck damn shit hell hate deteste enfer pourri craignos
        catastrophe desastre horrible affreux relou pitié non nope nah ouch
        bof beurk dégueu degueu degu rage furieux furax énervé enerve
    );
    my @question = qw(qui quoi pourquoi pourquoi comment quand quand ou où);

    my %pos_h = map { $_ => 1 } @positive;
    my %neg_h = map { $_ => 1 } @negative;
    my %q_h   = map { $_ => 1 } @question;

    my $pos = 0; my $neg = 0; my $questions = 0;
    my $exclam = 0; my $total_msgs = 0;
    my %emoji_count;

    # Emoji regex Unicode — minimal set (les principaux)
    my $emoji_re = qr/[\x{1F600}-\x{1F64F}\x{1F300}-\x{1F5FF}\x{1F680}-\x{1F6FF}\x{2600}-\x{26FF}\x{2700}-\x{27BF}]/;

    while (my $r = $sth->fetchrow_arrayref) {
        my $txt = $r->[0] // '';
        $total_msgs++;
        $exclam += () = $txt =~ /!/g;
        $questions++ if $txt =~ /\?/;
        # mb446-B1: le comptage d'emojis doit porter sur des CARACTÈRES. publictext
        # arrive en OCTETS UTF-8 ; $emoji_re utilise des codepoints (\x{1F600}...)
        # qui ne peuvent JAMAIS matcher un octet (< 256) -> le détail « top emoji »
        # n'apparaissait jamais. On décode une copie (tolérant) pour ce scan ; la
        # tokenisation des mots reste byte-safe (mb427). L'emoji retenu est un
        # caractère, cohérent avec les \x{...} déjà émis dans la sortie mood.
        my $txt_chars = Encode::decode('UTF-8', $txt, Encode::FB_DEFAULT);
        while ($txt_chars =~ /($emoji_re)/g) { $emoji_count{$1}++ }
        # Tokeniser
        # mb427-B1: tokenisation byte-safe (comme mb426) — les mots accentués
        # (positifs/négatifs français) restent entiers et matchent les
        # dictionnaires de sentiment.
        my $lower = lc($txt);
        for my $w (split /[^0-9A-Za-z_\x80-\xFF]+/, $lower) {
            next unless length($w) >= 2;
            $pos++       if $pos_h{$w};
            $neg++       if $neg_h{$w};
            $questions++ if $q_h{$w};
        }
    }
    $sth->finish;

    if ($total_msgs == 0) {
        botPrivmsg($self, $channel,
            "\x{1F321}\x{FE0F} Mood $channel (last 60min): silence total \x{1F507}");
        return 1;
    }

    # Score : ratio positif - ratio négatif, normalisé sur (-1, +1) puis projeté en %
    my $total_sent = $pos + $neg;
    my $pos_ratio  = $total_sent > 0 ? $pos / $total_sent : 0.5;

    my ($mood_label, $mood_emoji);
    if    ($pos_ratio >= 0.80) { $mood_label = 'euphoric';    $mood_emoji = "\x{1F31F}"; }
    elsif ($pos_ratio >= 0.65) { $mood_label = 'joyful';      $mood_emoji = "\x{2600}\x{FE0F}"; }
    elsif ($pos_ratio >= 0.55) { $mood_label = 'positive';    $mood_emoji = "\x{1F600}"; }
    elsif ($pos_ratio >= 0.45) { $mood_label = 'balanced';    $mood_emoji = "\x{2696}\x{FE0F}"; }
    elsif ($pos_ratio >= 0.35) { $mood_label = 'tense';       $mood_emoji = "\x{1F62C}"; }
    elsif ($pos_ratio >= 0.20) { $mood_label = 'grumpy';      $mood_emoji = "\x{1F614}"; }
    else                        { $mood_label = 'apocalyptic'; $mood_emoji = "\x{1F4A2}"; }
    if ($total_sent == 0) { $mood_label = 'neutral'; $mood_emoji = "\x{1F636}"; }

    # Energy : volume + exclamations
    my $energy_label;
    if    ($total_msgs >= 200) { $energy_label = "very high \x{26A1}"; }
    elsif ($total_msgs >= 80)  { $energy_label = "high \x{1F525}"; }
    elsif ($total_msgs >= 30)  { $energy_label = 'medium'; }
    elsif ($total_msgs >= 5)   { $energy_label = "low \x{1F634}"; }
    else                        { $energy_label = "very low \x{1F636}"; }

    # Top emoji
    my $top_emoji = '';
    if (%emoji_count) {
        my ($e) = sort { $emoji_count{$b} <=> $emoji_count{$a} } keys %emoji_count;
        $top_emoji = sprintf("top emoji: %s\x{D7}%d", $e, $emoji_count{$e});
    }

    # Score 0-100%
    my $mood_pct = int($pos_ratio * 100);

    botPrivmsg($self, $channel,
        sprintf("\x{1F321}\x{FE0F} Mood %s (last 60min): %s \x02%s\x02 %d%%  \x{B7}  energy: %s (%d msgs)",
            $channel, $mood_emoji, $mood_label, $mood_pct, $energy_label, $total_msgs));

    my @details;
    push @details, "$pos positives"   if $pos > 0;
    push @details, "$neg negatives"   if $neg > 0;
    push @details, "$questions ?"     if $questions > 0;
    push @details, "$exclam !"        if $exclam > 0;
    push @details, $top_emoji         if $top_emoji;
    botPrivmsg($self, $channel, "  " . join(' | ', @details)) if @details;

    # mb498: "pulse" line — WHO is driving the last 60 min and WHEN the channel
    # peaked today. Turns mood (sentiment) into a fuller read of the room.
    # Best-effort: never blocks the mood answer.
    {
        my @pulse;

        # top talkers over the same 60-minute window as the mood scan
        my $sth_tt = $dbh->prepare(q{
            SELECT cl.nick AS nick, COUNT(*) AS c
            FROM CHANNEL_LOG cl
            JOIN CHANNEL c ON c.id_channel = cl.id_channel
            WHERE c.name = ?
              AND cl.event_type IN ('public','action')
              AND cl.ts >= NOW() - INTERVAL 60 MINUTE
            GROUP BY cl.nick
            ORDER BY c DESC
            LIMIT 3
        });
        if ($sth_tt && eval { $sth_tt->execute($channel) }) {
            my @tt;
            while (my $r = $sth_tt->fetchrow_hashref) {
                push @tt, "$r->{nick} ($r->{c})";
            }
            $sth_tt->finish;
            push @pulse, "driven by: " . join(', ', @tt) if @tt;
        }

        # busiest hour of the current local day
        my $sth_pk = $dbh->prepare(q{
            SELECT HOUR(cl.ts) AS h, COUNT(*) AS c
            FROM CHANNEL_LOG cl
            JOIN CHANNEL c ON c.id_channel = cl.id_channel
            WHERE c.name = ?
              AND cl.event_type IN ('public','action')
              AND cl.ts >= CURDATE()
            GROUP BY HOUR(cl.ts)
            ORDER BY c DESC
            LIMIT 1
        });
        if ($sth_pk && eval { $sth_pk->execute($channel) }) {
            if (my $r = $sth_pk->fetchrow_hashref) {
                push @pulse, sprintf("peak today: %02dh-%02dh (%d msgs)",
                    $r->{h}, ($r->{h} + 1) % 24, $r->{c}) if defined $r->{h};
            }
            $sth_pk->finish;
        }

        botPrivmsg($self, $channel, "  " . join("  \x{B7}  ", @pulse)) if @pulse;
    }

    # Hook achievement (mb610-B1: progression persistante)
    $self->{_mood_count}{$nick}++;
    if ($self->{achievements}) {
        my $cnt = _ach_progress($self, 'mood', $nick, $channel)
               // ($self->{_mood_count}{$nick} // 0);
        eval { $self->{achievements}->check_mood($nick, $channel, $cnt) };
        if ($@) { $self->{logger}->log(1, "achievements check_mood error: $@") }
    }

    # Note: le check polyphony a été déplacé dans Achievements::check_msg (mb118)
    # pour ne plus dépendre d'un trigger explicite via !mood.

    $self->{metrics}->inc('mediabot_mood_total', { channel => $channel }) if $self->{metrics};
    return 1;
}


sub mbLeaderboard_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    unless ($channel && $channel =~ /^#/) {
        botNotice($self, $nick, 'Syntax: !leaderboard [msgs|karma|trivia|duels|achievs] [24h|7d|30d]');
        return 1;
    }

    my %cat_alias = (
        msg          => 'msgs',
        msgs         => 'msgs',
        message      => 'msgs',
        messages     => 'msgs',
        karma        => 'karma',
        trivia       => 'trivia',
        duel         => 'duels',
        duels        => 'duels',
        achiev       => 'achievs',
        achievs      => 'achievs',
        achievement  => 'achievs',
        achievements => 'achievs',
        all          => '',
        alltime      => '',
        total        => '',
    );

    my $only = '';
    my $period_arg = '';
    my $full_out = 0;

    for my $arg (@args) {
        next unless defined $arg && $arg ne '';
        my $a = lc($arg);

        if ($a =~ /^\d+[hdw]$/) {
            $period_arg = $a;
            next;
        }

        if (exists $cat_alias{$a}) {
            $only = $cat_alias{$a};
            next;
        }

        # mb629-B1: 'full' rend l'ancienne mise en page, une ligne par
        # categorie. Le defaut est desormais compact — cinq lignes d'affilee
        # sur un canal, c'est un mur, et tout le monde n'aime pas ca.
        if ($a eq 'full' || $a eq 'long') { $full_out = 1; next; }
        if ($a eq 'compact' || $a eq 'short') { $full_out = 0; next; }

        botNotice($self, $nick,
            'Syntax: !leaderboard [msgs|karma|trivia|duels|achievs] [24h|7d|30d] [full]');
        return 1;
    }

    my ($period_label, $period_num, $period_unit_sql) = ('', undef, undef);
    if ($period_arg ne '' && $period_arg =~ /^(\d+)([hdw])$/) {
        my ($n, $unit) = ($1, $2);
        if ($n < 1) {
            botNotice($self, $nick, 'Leaderboard period must be at least 1 unit.');
            return 1;
        }

        # mb121-B1: clamp on the converted value (hours or days), not on the
        # raw input. Without this, `100w` would generate INTERVAL 700 DAY which
        # bypasses the intended 365-day ceiling.
        my $max_units = $unit eq 'h' ? 365 * 24       # ~1 year in hours
                       : $unit eq 'd' ? 365           # 1 year in days
                       :                52;           # 1 year in weeks (52w = 364d)
        if ($n > $max_units) {
            botNotice($self, $nick,
                "Leaderboard period must be <= ${max_units}${unit} (1 year cap).");
            return 1;
        }

        if ($unit eq 'h') {
            $period_num      = $n;
            $period_unit_sql = 'HOUR';
            $period_label    = "${n}h";
        }
        elsif ($unit eq 'd') {
            $period_num      = $n;
            $period_unit_sql = 'DAY';
            $period_label    = "${n}d";
        }
        else {
            $period_num      = $n * 7;
            $period_unit_sql = 'DAY';
            $period_label    = "${n}w";
        }
    }

    if ($period_arg ne '' && $only && $only !~ /^(?:msgs|karma)$/) {
        botNotice($self, $nick, 'Period filters are currently supported for leaderboard msgs and karma only.');
        return 1;
    }

    my $dbh = $self->{dbh};

    my $period_suffix = $period_label ? " last $period_label" : '';
    my $cl_period_sql = $period_label ? " AND cl.ts >= NOW() - INTERVAL $period_num $period_unit_sql" : '';
    my $kl_period_sql = $period_label ? " AND kl.ts >= NOW() - INTERVAL $period_num $period_unit_sql" : '';

    # --- Top 3 messages -----------------------------------------------------
    # mb574-B1: la section msgs est une carriere (sauf periode explicite)
    # -> vif + archive.
    my @msgs_top;
    if (!$only || $only eq 'msgs') {
        # mb576-B1: GROUP BY complet par table puis fusion par nick — un
        # LIMIT 3 par branche fausserait le podium (un 4e des deux cotes
        # peut etre 1er global). Chaque requete est un index scan groupe.
        my (%lb_counts, %lb_display);
        my $lb_g = Mediabot::Helpers::channel_log_gather($self, $dbh, qq{
            SELECT cl.nick AS nick, COUNT(*) AS msg_count
            FROM __CLSRC__ cl
            JOIN CHANNEL c ON c.id_channel = cl.id_channel
            WHERE c.name = ? AND cl.event_type IN ('public','action')
              $cl_period_sql
            GROUP BY cl.nick
        }, [ $channel ], sub {
            my $k = lc $_[0]->{nick};
            $lb_display{$k} //= $_[0]->{nick};
            $lb_counts{$k} += $_[0]->{msg_count} // 0;
        }, 'content');
        # mb578-B1: panne LIVE = echec franc — plus jamais un podium msgs
        # silencieusement omis pendant que les autres sections s'affichent.
        unless ($lb_g->{live_ok}) {
            botNotice($self, $nick, 'Database error.');
            return;
        }
        my @sorted = sort { $lb_counts{$b} <=> $lb_counts{$a} || $a cmp $b } keys %lb_counts;
        splice(@sorted, 3) if @sorted > 3;
        @msgs_top = map { [ $lb_display{$_}, $lb_counts{$_} ] } @sorted;
    }

    # --- Top 3 karma --------------------------------------------------------
    my @karma_top;
    if (!$only || $only eq 'karma') {
        if ($period_label) {
            my $sth = $dbh->prepare(qq{
                SELECT kl.nick, SUM(kl.delta) AS score
                FROM KARMA_LOG kl
                JOIN CHANNEL c ON c.id_channel = kl.id_channel
                WHERE c.name = ?
                  $kl_period_sql
                GROUP BY kl.nick
                HAVING score <> 0
                ORDER BY score DESC, kl.nick ASC
                LIMIT 3
            });
            if ($sth && $sth->execute($channel)) {
                while (my $r = $sth->fetchrow_hashref) {
                    push @karma_top, [$r->{nick}, sprintf('%+d', $r->{score} || 0)];
                }
                $sth->finish;
            }
        }
        else {
            my $sth = $dbh->prepare(q{
                SELECT k.nick, k.score
                FROM KARMA k
                JOIN CHANNEL c ON c.id_channel = k.id_channel
                WHERE c.name = ?
                ORDER BY k.score DESC
                LIMIT 3
            });
            if ($sth && $sth->execute($channel)) {
                while (my $r = $sth->fetchrow_hashref) {
                    push @karma_top, [$r->{nick}, $r->{score}];
                }
                $sth->finish;
            }
        }
    }

    # Period mode without an explicit category deliberately reports only sources
    # with reliable timestamps.
    my $show_alltime_sections = !$period_label;

    # --- Top 3 trivia -------------------------------------------------------
    my @trivia_top;
    if ($show_alltime_sections && (!$only || $only eq 'trivia')) {
        my $sth = $dbh->prepare(q{
            SELECT ts.nick, ts.score
            FROM TRIVIA_SCORES ts
            JOIN CHANNEL c ON c.id_channel = ts.id_channel
            WHERE c.name = ?
            ORDER BY ts.score DESC
            LIMIT 3
        });
        if ($sth && $sth->execute($channel)) {
            while (my $r = $sth->fetchrow_hashref) {
                push @trivia_top, [$r->{nick}, $r->{score}];
            }
            $sth->finish;
        }
    }

    # --- Top 3 duels (mémoire) ----------------------------------------------
    my @duel_top;
    if ($show_alltime_sections && (!$only || $only eq 'duels')) {
        my $dst = $self->{_duel_stats}{$channel} // {};
        my @sorted = sort {
            ($dst->{$b}{wins} // 0) <=> ($dst->{$a}{wins} // 0)
            || $a cmp $b
        } keys %$dst;
        for my $n (@sorted[0..2]) {
            next unless defined $n;
            push @duel_top, [$n, ($dst->{$n}{wins} // 0)];
        }
    }

    # --- Top 3 achievements -------------------------------------------------
    my @ach_top;
    if ($show_alltime_sections && (!$only || $only eq 'achievs')) {
        if ($self->{achievements}) {
            my $top = eval {
                $self->{achievements}->top_on_channel($channel, 3)
            } || [];
            @ach_top = map { [ $_->{nick}, $_->{count} ] } @$top;
        }
    }

    # --- Mise en forme (mb629) ---------------------------------------------
    # Couleur par categorie : elle rend le bloc lisible d'un coup d'oeil sans
    # rien ajouter en hauteur. Codes mIRC choisis pour rester lisibles sur
    # fond clair COMME sur fond sombre (ni blanc, ni noir, ni jaune pale).
    my %cat_style = (
        msgs    => [ "\x0311", "\x{1F4AC}", 'msgs'    ],
        karma   => [ "\x0308", "\x{1F31F}", 'karma'   ],
        trivia  => [ "\x0313", "\x{1F9E0}", 'trivia'  ],
        duels   => [ "\x0304", "\x{2694}\x{FE0F}", 'duels' ],
        achievs => [ "\x0309", "\x{1F3C6}", 'achievs' ],
    );
    my @medals = ("\x{1F947}", "\x{1F948}", "\x{1F949}");   # 🥇 🥈 🥉

    # Un segment = une categorie complete, tenant sur une portion de ligne.
    # Le premier est medaille et gras ; les suivants restent sobres, sinon
    # la ligne devient illisible a force de decorations.
    my $segment = sub {
        my ($top, $key) = @_;
        return undef unless ref $top eq 'ARRAY' && @$top;
        my ($colour, $emoji, $label) = @{ $cat_style{$key} };
        my @parts;
        for my $i (0 .. $#{$top}) {
            my ($n, $v) = @{ $top->[$i] };
            my $val = _fmt_n($v);
            push @parts, $i == 0
                ? "$medals[0] \x02$n\x02 $val"
                : "$n $val";
        }
        # Le point median en LITTERAL : ce fichier a « use utf8 », et une
        # sequence \x{...} entre apostrophes serait imprimee telle quelle.
        return "$colour$emoji $label\x0f " . join(' · ', @parts);
    };

    my @segments;
    push @segments, [ 'msgs',    $segment->(\@msgs_top,   'msgs')    ];
    push @segments, [ 'karma',   $segment->(\@karma_top,  'karma')   ];
    push @segments, [ 'trivia',  $segment->(\@trivia_top, 'trivia')  ];
    push @segments, [ 'duels',   $segment->(\@duel_top,   'duels')   ];
    push @segments, [ 'achievs', $segment->(\@ach_top,    'achievs') ];
    @segments = grep { defined $_->[1] } @segments;

    my $header = "\x{1F3C5} \x02Leaderboard\x02 $channel"
        . ($only ? " \x0314[$only]\x0f" : '')
        . ($period_suffix ? " \x0314[$period_suffix]\x0f" : '');
    botPrivmsg($self, $channel, $header);

    my $any = scalar @segments;

    if ($full_out) {
        # Mise en page historique : une categorie par ligne.
        botPrivmsg($self, $channel, '  ' . $_->[1]) for @segments;
    }
    else {
        # mb629-B1: compactage — on remplit chaque ligne jusqu'a une limite
        # SURE pour IRC (512 octets moins l'enveloppe), en comptant les
        # OCTETS et non les caracteres : emojis et couleurs pesent plus que
        # leur largeur a l'ecran, et une ligne coupee par le serveur casse
        # une sequence de couleur au milieu.
        # Un client IRC enroule une ligne longue : viser ~190 octets donne
        # deux a trois categories par ligne, soit deux lignes lisibles au
        # lieu d'un pave unique ou de cinq lignes d'affilee.
        my $budget = 190;
        my @lines;
        my $cur = '';
        for my $seg (@segments) {
            my $piece = $seg->[1];
            my $sep   = length($cur) ? '   ' : '  ';
            if (_irc_bytes($cur) && _irc_bytes($cur . $sep . $piece) > $budget) {
                push @lines, $cur;
                $cur = '  ' . $piece;
            }
            else {
                $cur .= $sep . $piece;
            }
        }
        push @lines, $cur if length $cur;
        botPrivmsg($self, $channel, $_) for @lines;
    }

    if ($period_label && !$only) {
        botPrivmsg($self, $channel,
            "  \x0314\x{2139} Period mode covers timestamped categories only: msgs and karma.\x0f");
    }

    botPrivmsg($self, $channel, "  (no data yet)") unless $any;
    return 1;
}




sub mbChronos_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    unless ($channel && $channel =~ /^#/) {
        botNotice($self, $nick, 'Syntax: !chronos [short|full]  (must be in a channel)'); return;
    }

    my $mode = @args ? lc($args[0] // '') : 'full';
    if ($mode eq 'brief') { $mode = 'short'; }
    if ($mode ne '' && $mode ne 'short' && $mode ne 'full') {
        botNotice($self, $nick, 'Syntax: !chronos [short|full]');
        return 1;
    }

    my $dbh = $self->{dbh};
    # 1. Premier message du canal (avec auteur)
    # mb576-B1: LIMIT 1 par table, la fusion garde le plus ANCIEN (il vit
    # generalement dans l'archive).
    my $first;
    my $ch_first_g = Mediabot::Helpers::channel_log_gather($self, $dbh, q{
        SELECT cl.nick, cl.ts, cl.publictext
        FROM __CLSRC__ cl
        JOIN CHANNEL c ON c.id_channel = cl.id_channel
        WHERE c.name = ? AND cl.event_type IN ('public','action')
        ORDER BY cl.ts ASC
        LIMIT 1
    }, [ $channel ], sub {
        my ($r) = @_;
        $first = $r
            if !$first
            || (defined $r->{ts} && $r->{ts} lt ($first->{ts} // ''));
    }, 'content');
    # mb578-B1: panne LIVE = echec franc, AVANT le test « No history
    # found » — une base en panne n'est pas un canal sans histoire.
    unless ($ch_first_g->{live_ok}) {
        botNotice($self, $nick, 'Database error.');
        return;
    }
    unless ($first) {
        botPrivmsg($self, $channel, "\x{1F4DC} No history found on $channel.");
        return 1;
    }

    # 2. Dernier message — LIMIT 1 par table, fusion = le plus recent.
    my $last;
    my $ch_last_g = Mediabot::Helpers::channel_log_gather($self, $dbh, q{
        SELECT cl.nick, cl.ts
        FROM __CLSRC__ cl
        JOIN CHANNEL c ON c.id_channel = cl.id_channel
        WHERE c.name = ? AND cl.event_type IN ('public','action')
        ORDER BY cl.ts DESC
        LIMIT 1
    }, [ $channel ], sub {
        my ($r) = @_;
        $last = $r
            if !$last
            || (defined $r->{ts} && $r->{ts} gt ($last->{ts} // ''));
    }, 'content');
    unless ($ch_last_g->{live_ok}) {
        botNotice($self, $nick, 'Database error.');
        return;
    }

    # 3. Jour record — GROUP BY complet par table, fusion += (le jour de
    # bascule vif/archive doit sommer ses deux moities), max Perl.
    my $best_day;
    {
        my %day_counts;
        my $ch_day_g = Mediabot::Helpers::channel_log_gather($self, $dbh, q{
            SELECT DATE(cl.ts) AS d, COUNT(*) AS c
            FROM __CLSRC__ cl
            JOIN CHANNEL c ON c.id_channel = cl.id_channel
            WHERE c.name = ? AND cl.event_type IN ('public','action')
            GROUP BY DATE(cl.ts)
        }, [ $channel ], sub { $day_counts{ $_[0]->{d} } += $_[0]->{c} // 0 }, 'content');
        unless ($ch_day_g->{live_ok}) {
            botNotice($self, $nick, 'Database error.');
            return;
        }
        for my $d (sort keys %day_counts) {
            $best_day = { d => $d, c => $day_counts{$d} }
                if !$best_day || $day_counts{$d} > $best_day->{c};
        }
    }

    # 4. Heure record — meme patron (le token __CLSRC__ coexiste sans
    # danger avec les % de DATE_FORMAT, contrairement a un sprintf).
    my $best_hour;
    {
        my %hour_counts;
        my $ch_hour_g = Mediabot::Helpers::channel_log_gather($self, $dbh, q{
            SELECT DATE_FORMAT(cl.ts, '%Y-%m-%d %H:00') AS h, COUNT(*) AS c
            FROM __CLSRC__ cl
            JOIN CHANNEL c ON c.id_channel = cl.id_channel
            WHERE c.name = ? AND cl.event_type IN ('public','action')
            GROUP BY DATE_FORMAT(cl.ts, '%Y-%m-%d %H:00')
        }, [ $channel ], sub { $hour_counts{ $_[0]->{h} } += $_[0]->{c} // 0 }, 'content');
        unless ($ch_hour_g->{live_ok}) {
            botNotice($self, $nick, 'Database error.');
            return;
        }
        for my $h (sort keys %hour_counts) {
            $best_hour = { h => $h, c => $hour_counts{$h} }
                if !$best_hour || $hour_counts{$h} > $best_hour->{c};
        }
    }

    # 5. Karma all-time leader
    my $sth5 = $dbh->prepare(q{
        SELECT k.nick, k.score
        FROM KARMA k
        JOIN CHANNEL c ON c.id_channel = k.id_channel
        WHERE c.name = ?
        ORDER BY k.score DESC
        LIMIT 1
    });
    my $karma_leader;
    if ($sth5 && $sth5->execute($channel)) {
        $karma_leader = $sth5->fetchrow_hashref; $sth5->finish;
    }

    # 6. Trivia champion
    my $sth6 = $dbh->prepare(q{
        SELECT ts.nick, ts.score
        FROM TRIVIA_SCORES ts
        JOIN CHANNEL c ON c.id_channel = ts.id_channel
        WHERE c.name = ?
        ORDER BY ts.score DESC
        LIMIT 1
    });
    my $trivia_champ;
    if ($sth6 && $sth6->execute($channel)) {
        $trivia_champ = $sth6->fetchrow_hashref; $sth6->finish;
    }

    # 7. Total quotes
    my $sth7 = $dbh->prepare(q{
        SELECT COUNT(*) AS c
        FROM QUOTES q
        JOIN CHANNEL c ON c.id_channel = q.id_channel
        WHERE c.name = ?
    });
    my $quote_count = 0;
    if ($sth7 && $sth7->execute($channel)) {
        my $r = $sth7->fetchrow_hashref; $sth7->finish;
        $quote_count = $r ? ($r->{c} // 0) : 0;
    }

    # === Affichage ASCII timeline ============================================
    my $first_d = ($first->{ts} =~ /^(\d{4}-\d{2}-\d{2})/) ? $1 : '?';
    my $last_d  = ($last && $last->{ts} =~ /^(\d{4}-\d{2}-\d{2})/) ? $1 : '?';

    if ($mode eq 'short') {
        my $genesis = $first->{nick} // '?';
        my $last_nick = ($last && $last->{nick}) ? $last->{nick} : '?';

        my @parts;
        push @parts, "genesis $first_d by $genesis";
        push @parts, "peak day $best_day->{d} (" . _fmt_n($best_day->{c}) . " msgs)" if $best_day;
        push @parts, "karma king $karma_leader->{nick} (" . sprintf('%+d', $karma_leader->{score}) . ")" if $karma_leader;
        push @parts, "trivia $trivia_champ->{nick} (" . _fmt_n($trivia_champ->{score}) . ")" if $trivia_champ && $trivia_champ->{score} > 0;
        push @parts, _fmt_n($quote_count) . " quote(s)" if $quote_count > 0;

        botPrivmsg($self, $channel,
            "\x{1F4DC} \x02Chronos\x02 $channel \x{2014} " . join('  |  ', @parts));
        botPrivmsg($self, $channel,
            "\x{1F4CD} now: last activity $last_d by $last_nick  |  use: chronos full");

        $self->{metrics}->inc('mediabot_chronos_total', { channel => $channel }) if $self->{metrics};
        return 1;
    }

    botPrivmsg($self, $channel,
        "\x{1F4DC} \x02Chronos\x02 $channel \x{2014} a saga in chapters");

    # Premier message (avec extrait tronqué)
    my $first_text = $first->{publictext} // '';
    # mb441-B1: troncature UTF-8-safe (publictext en octets UTF-8) via le helper
    # partagé mb429 — un substr brut à 60 octets coupait un accent en deux.
    $first_text = Mediabot::Helpers::truncate_utf8($first_text, 60);
    botPrivmsg($self, $channel,
        "  \x{1F30C}  \x02$first_d\x02  Genesis  \x{2014}  $first->{nick}: \"$first_text\"");

    # Jour record
    if ($best_day) {
        botPrivmsg($self, $channel,
            sprintf("  \x{1F389}  \x02%s\x02  Peak day  \x{2014}  %s messages in 24h",
                $best_day->{d}, _fmt_n($best_day->{c})));
    }

    # Heure record
    if ($best_hour) {
        botPrivmsg($self, $channel,
            sprintf("  \x{1F525}  \x02%s\x02  Peak hour  \x{2014}  %s messages in 60min",
                $best_hour->{h}, _fmt_n($best_hour->{c})));
    }

    # Karma leader
    if ($karma_leader) {
        botPrivmsg($self, $channel,
            sprintf("  \x{1F451}  \x02all-time\x02  Karma king  \x{2014}  %s (%+d)",
                $karma_leader->{nick}, $karma_leader->{score}));
    }

    # Trivia champion
    if ($trivia_champ && $trivia_champ->{score} > 0) {
        botPrivmsg($self, $channel,
            sprintf("  \x{1F9E0}  \x02all-time\x02  Trivia champion  \x{2014}  %s (%s correct)",
                $trivia_champ->{nick}, _fmt_n($trivia_champ->{score})));
    }

    # Quotes
    if ($quote_count > 0) {
        botPrivmsg($self, $channel,
            sprintf("  \x{1F4DD}  \x02all-time\x02  Quote vault  \x{2014}  %s quote(s) preserved",
                _fmt_n($quote_count)));
    }

    # Last message
    if ($last) {
        my $last_ago = '?';
        if ($last->{ts} =~ /^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})/) {
            require Time::Local;
            my $ep = eval { Time::Local::timelocal($6,$5,$4,$3,$2-1,$1-1900) };
            if ($ep) {
                my $diff = time() - $ep;
                $last_ago = $diff < 60        ? "${diff}s ago"
                          : $diff < 3600      ? sprintf('%dm ago',  int($diff/60))
                          : $diff < 86400     ? sprintf('%dh ago',  int($diff/3600))
                          :                     sprintf('%dd ago',  int($diff/86400));
            }
        }
        botPrivmsg($self, $channel,
            "  \x{1F4CD}  \x02$last_d\x02  Now  \x{2014}  last activity $last_ago ($last->{nick})");
    }

    $self->{metrics}->inc('mediabot_chronos_total', { channel => $channel }) if $self->{metrics};
    return 1;
}



sub _recap_text {
    my ($lang, $key, $fallback) = @_;
    my $fn = Mediabot::External::Claude->can('ai_lang_text') or return $fallback;
    my $text = eval { $fn->($lang, $key) };
    return (defined $text && length $text) ? $text : $fallback;
}


sub _recap_parse {
    my (@args) = @_;
    my %o = (ai => 0, window => undef, lang => undef, bad_lang => undef,
             unknown => [], duplicate => [], typos => []);

    # mb624-B1: la langue reste extraite par l'API PARTAGEE de mb609 — recopier
    # sa regle ici recreerait exactement la divergence qu'elle a supprimee. Le
    # repli inline ne sert que si le module Claude n'est pas charge (tests hors
    # contexte IA) ; il ne connait donc que le trio nu.
    if (my $extract = Mediabot::External::Claude->can('extract_ai_lang_token')) {
        my ($forced, $bad, @rest) = $extract->(@args);
        ($o{lang}, $o{bad_lang}) = ($forced, $bad);
        @args = @rest;
    }

    for my $raw (@args) {
        my $a = lc($raw // '');
        next unless length $a;

        if ($a eq 'ai') { $o{ai} = 1 }
        elsif ($a =~ /^(\d+)([hm])$/) {
            if (defined $o{window}) { push @{ $o{duplicate} }, $raw; next }
            $o{window} = $a;
        }
        elsif ($a =~ /^lang[=:]([a-z]{2})$/) {
            my $code = $1;
            if ($code =~ /\A(?:en|fr|es)\z/) { $o{lang} = $code }
            else                             { $o{bad_lang} = $code }
        }
        elsif ($a =~ /\A(?:en|fr|es)\z/) { $o{lang} = $a }
        else {
            # Une fenetre mal ecrite (30min, 2hours, 2 h) doit etre dite,
            # sinon l'utilisateur croit avoir choisi sa fenetre.
            if ($a =~ /^\d+\s*[a-z]+$/) {
                push @{ $o{typos} }, [ $raw, ($a =~ /^(\d+)\s*h/ ? "$1h" : ($a =~ /^(\d+)/ ? "$1m" : 'Nm')) ];
                next;
            }
            if (my $near = Mediabot::Helpers::suggest_keyword($a, @Mediabot::UserCommands::RECAP_KEYWORDS, qw(en fr es))) {
                push @{ $o{typos} }, [ $raw, $near ];
                next;
            }
            push @{ $o{unknown} }, $raw;
        }
    }
    return \%o;
}


sub _ach_progress {
    my ($self, $kind, $nick, $channel) = @_;
    my $ach = $self->{achievements} or return undef;
    return undef unless $ach->can('bump_progress');
    my $value = eval { $ach->bump_progress($kind, $nick, $channel) };
    if ($@) {
        eval { $self->{logger}->log(1, "achievements progress error: $@") };
        return undef;
    }
    return $value;
}


sub mbRecap_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;
    my $channel = $ctx->channel;

    # !recap n'a de sens que dans un canal (le "quoi de neuf ICI").
    unless (isIrcChannelTarget($channel)) {
        botNotice($self, $nick, $_) for @Mediabot::UserCommands::RECAP_USAGE_LINES;
        botNotice($self, $nick, 'recap se lance dans un canal.');
        return;
    }

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
    @args = grep { defined && $_ ne '' } @args;

    # mb609-B1: meme regle de langue que 'ai summary' — et la MEME
    # implementation (Claude::extract_ai_lang_token / resolve_ai_lang),
    # pour que les deux commandes ne puissent pas diverger.
    # Le module Claude est charge paresseusement : on passe par can() comme
    # le fait deja le chemin IA plus bas. Sans lui, aucun jeton n'est extrait
    # et la langue reste celle du canal — le comportement historique.
    # mb624-B1: lecture stricte, ordre libre, fautes annoncees.
    my $ro = _recap_parse(@args);
    if (@{ $ro->{typos} }) {
        for my $t (@{ $ro->{typos} }) {
            botNotice($self, $nick, sprintf(
                "recap: unknown option '%s' - did you mean \x02%s\x02?",
                $t->[0], $t->[1]));
        }
        botNotice($self, $nick, $Mediabot::UserCommands::RECAP_USAGE_LINES[0]);
        return;
    }
    if (@{ $ro->{unknown} } || @{ $ro->{duplicate} }) {
        my @bad = (@{ $ro->{unknown} }, @{ $ro->{duplicate} });
        botNotice($self, $nick, sprintf('recap: %s: %s',
            (@bad > 1 ? 'unknown or duplicate options' : 'unknown option'),
            join(', ', map { "'$_'" } @bad)));
        botNotice($self, $nick, $Mediabot::UserCommands::RECAP_USAGE_LINES[0]);
        return;
    }
    my ($forced_lang, $bad_lang) = ($ro->{lang}, $ro->{bad_lang});
    my $want_ai    = $ro->{ai};
    my $window_arg = $ro->{window};
    my $resolve = Mediabot::External::Claude->can('resolve_ai_lang');
    my $recap_lang = $resolve
        ? $resolve->($self, $channel, $forced_lang)
        : (eval { Mediabot::Helpers::channel_lang($self, $channel) } || 'en');
    if (defined $bad_lang) {
        botNotice($self, $nick,
            "recap: unsupported language '$bad_lang' (en, fr, es).");
        botNotice($self, $nick, $Mediabot::UserCommands::RECAP_USAGE_LINES[0]);
        return;
    }

    # --- configuration (avec valeurs par défaut sûres) ---
    my $cfg = sub {
        my ($key, $default) = @_;
        my $v = eval { $self->{conf}->get("main.$key") };
        return (defined $v && $v ne '') ? $v : $default;
    };
    my $max_h      = int($cfg->('RECAP_MAX_H',       24));
    my $default_h  = int($cfg->('RECAP_DEFAULT_H',    6));
    my $max_rows   = int($cfg->('RECAP_MAX_ROWS',  2000));
    my $cooldown_s = int($cfg->('RECAP_COOLDOWN_S',   30));
    $max_h     = 24   if $max_h     <= 0;
    $default_h = 6    if $default_h <= 0;
    $max_rows  = 2000 if $max_rows  <= 0;

    # --- cooldown par nick (mémoire bornée, best-effort) ---
    my $now = time();
    $self->{_recap_cooldown} ||= {};
    my $lc_nick = lc($nick);
    if ($cooldown_s > 0) {
        my $last = $self->{_recap_cooldown}{$lc_nick};
        if (defined $last && ($now - $last) < $cooldown_s) {
            my $wait = $cooldown_s - ($now - $last);
            botNotice($self, $nick, "recap: please wait ${wait}s before asking again.");
            return;
        }
        $self->{_recap_cooldown}{$lc_nick} = $now;
        # purge opportuniste pour borner la mémoire
        if (scalar(keys %{ $self->{_recap_cooldown} }) > 512) {
            for my $k (keys %{ $self->{_recap_cooldown} }) {
                delete $self->{_recap_cooldown}{$k}
                    if ($now - $self->{_recap_cooldown}{$k}) > 3600;
            }
        }
    }

    my $dbh = $self->{dbh};
    unless ($dbh) {
        botNotice($self, $nick, "recap: database unavailable.");
        return;
    }

    # --- résoudre id_channel ---
    my $channel_obj = $self->{channels}{lc $channel};
    my $id_channel = $channel_obj ? eval { $channel_obj->get_id } : undef;
    unless (defined $id_channel) {
        botNotice($self, $nick, "recap: channel not known to the bot.");
        return;
    }

    # --- déterminer la fenêtre (en secondes) ---
    my $window_s;
    my $window_label;
    if (defined $window_arg) {
        if    ($window_arg =~ /^(\d+)h$/) { $window_s = $1 * 3600; }
        elsif ($window_arg =~ /^(\d+)m$/) { $window_s = $1 * 60;   }
        $window_label = $window_arg;
    }
    else {
        # depuis la dernière activité connue de l'appelant (USER_SEEN)
        my $seen_epoch;
        my $sth_seen = $dbh->prepare(
            'SELECT UNIX_TIMESTAMP(seen_at) FROM USER_SEEN WHERE nick = ? LIMIT 1');
        if ($sth_seen && $sth_seen->execute($lc_nick)) {
            ($seen_epoch) = $sth_seen->fetchrow_array;
            $sth_seen->finish;
        }
        if (defined $seen_epoch && $seen_epoch > 0 && $seen_epoch <= $now) {
            $window_s = $now - $seen_epoch;
            $window_label = "since you were last seen";
        }
        else {
            $window_s = $default_h * 3600;
            $window_label = "${default_h}h";
        }
    }

    # borne haute
    my $max_s = $max_h * 3600;
    if ($window_s > $max_s) {
        $window_s = $max_s;
        $window_label = "${max_h}h (capped)";
    }
    $window_s = 60 if $window_s < 60;   # au moins une minute

    # --- lire les messages de la fenêtre (index composite id_channel, ts) ---
    my $sth = $dbh->prepare(q{
        SELECT nick, publictext, UNIX_TIMESTAMP(ts) AS t
        FROM CHANNEL_LOG
        WHERE id_channel = ?
          AND ts >= DATE_SUB(NOW(), INTERVAL ? SECOND)
          AND event_type IN ('public','action')
        ORDER BY ts ASC
        LIMIT ?
    });
    unless ($sth && $sth->execute($id_channel, $window_s, $max_rows)) {
        botNotice($self, $nick, "recap: could not read the channel log.");
        return;
    }

    my @rows;
    my %by_nick;
    my ($first_t, $last_t);
    while (my $r = $sth->fetchrow_hashref) {
        # ne pas recaper les propres messages de l'appelant
        next if lc($r->{nick}) eq $lc_nick;
        push @rows, $r;
        $by_nick{ $r->{nick} }++;
        $first_t //= $r->{t};
        $last_t = $r->{t};
    }
    $sth->finish;

    my $msg_count = scalar @rows;
    if ($msg_count == 0) {
        botNotice($self, $nick, "recap ($window_label): nothing much happened on $channel — no messages from others.");
        return;
    }

    # --- résumé IA optionnel ---
    if ($want_ai) {
        my $can_ai = 0;
        my $api_key = eval { $self->{conf}->get('anthropic.API_KEY') };
        $can_ai = 1 if defined $api_key && $api_key ne '';
        if ($can_ai && Mediabot::External::Claude->can('claudeAI')) {
            # Construire un transcript borné pour le prompt.
            my $transcript = '';
            for my $r (@rows) {
                my $line = "<$r->{nick}> " . ($r->{publictext} // '');
                $line = substr($line, 0, 300);
                last if length($transcript) + length($line) + 1 > 6000;
                $transcript .= $line . "\n";
            }
            # mb609-B1: la langue est desormais EXPLICITE. « la meme langue
            # que la conversation » laissait le modele deviner — et un canal
            # bilingue obtenait un resume au hasard.
            my $lang_name = Mediabot::External::Claude::ai_lang_name($recap_lang);
            my $prompt = "Summarize this IRC channel conversation in 3-5 concise bullet points, "
                       . "in $lang_name. Only the summary, no preamble.\n\n"
                       . $transcript;
            my $ai_ok = eval {
                Mediabot::External::Claude::claudeAI(
                    $self, $prompt, $nick, undef,
                    sub {
                        my ($text) = @_;
                        return unless defined $text && $text ne '';
                        # mb504: cap the number of emitted lines. A long AI reply
                        # must never flood; keep it to a sane maximum and signal
                        # truncation rather than spilling dozens of notices.
                        my $ai_max_lines = 12;
                        my $sent_lines = 0;
                        for my $line (split /\n/, $text) {
                            next if $line =~ /^\s*$/;
                            if ($sent_lines >= $ai_max_lines) {
                                botNotice($self, $nick,
                                    _recap_text($recap_lang, 'recap_truncated',
                                        'recap: summary truncated (too long).'));
                                last;
                            }
                            botNotice($self, $nick, $line);
                            $sent_lines++;
                        }
                    },
                );
                1;
            };
            if ($ai_ok) {
                $self->{metrics}->inc('mediabot_recap_total', { channel => $channel, mode => 'ai' })
                    if $self->{metrics};
                return 1;
            }
            # sinon : repli sur le statistique ci-dessous
            botNotice($self, $nick,
                _recap_text($recap_lang, 'recap_unavailable',
                    'recap: AI summary unavailable, showing stats instead.'));
        }
        else {
            botNotice($self, $nick,
                _recap_text($recap_lang, 'recap_notconf',
                    'recap: AI not configured, showing stats instead.'));
        }
    }

    # --- résumé statistique ---
    my $span_min = defined($first_t) && defined($last_t) && $last_t >= $first_t
        ? int(($last_t - $first_t) / 60) : 0;

    # top parleurs (jusqu'à 5)
    my @top = sort { $by_nick{$b} <=> $by_nick{$a} || lc($a) cmp lc($b) } keys %by_nick;
    my $ntalkers = scalar @top;
    @top = @top[0 .. 4] if @top > 5;
    my $top_str = join(', ', map { "$_ ($by_nick{$_})" } @top);

    botNotice($self, $nick,
        "recap $channel ($window_label): $msg_count message(s) from $ntalkers nick(s)"
        . ($span_min > 0 ? " over ~${span_min} min." : "."));
    botNotice($self, $nick, "Top: $top_str") if $top_str ne '';

    # échantillon : première et dernière lignes, tronquées
    if (@rows) {
        my $first = $rows[0];
        my $last  = $rows[-1];
        my $trim = sub { my $s = shift // ''; $s =~ s/[\r\n\0]+/ /g; length($s) > 200 ? substr($s,0,197)."..." : $s };
        botNotice($self, $nick, "First: <$first->{nick}> " . $trim->($first->{publictext}));
        if (@rows > 1) {
            botNotice($self, $nick, "Last:  <$last->{nick}> " . $trim->($last->{publictext}));
        }
        botNotice($self, $nick, "Tip: !recap ai for a natural-language summary.")
            if !$want_ai;
    }

    $self->{metrics}->inc('mediabot_recap_total', { channel => $channel, mode => 'stats' })
        if $self->{metrics};

    return 1;
}


sub mbOnThisDay_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;

    unless (isIrcChannelTarget($channel)) {
        botNotice($self, $nick, "Syntax: onthisday  (use it in a channel)");
        return;
    }
    # opt-out via the same flag as recap-style history features
    return unless eval {
        Mediabot::Helpers::chanset_enabled($self, $channel, 'OnThisDay', default => 1)
    } // 1;

    # light per-nick cooldown (reuse a dedicated bucket)
    my $cooldown_s = 20;
    my $now = time();
    $self->{_otd_cooldown} ||= {};
    my $lc_nick = lc($nick);
    my $last = $self->{_otd_cooldown}{$lc_nick};
    if (defined $last && ($now - $last) < $cooldown_s) {
        my $wait = $cooldown_s - ($now - $last);
        botNotice($self, $nick, "onthisday: please wait ${wait}s before asking again.");
        return;
    }
    $self->{_otd_cooldown}{$lc_nick} = $now;
    if (scalar(keys %{ $self->{_otd_cooldown} }) > 512) {
        for my $k (keys %{ $self->{_otd_cooldown} }) {
            delete $self->{_otd_cooldown}{$k}
                if ($now - $self->{_otd_cooldown}{$k}) > 3600;
        }
    }

    my $dbh = $self->{dbh};
    unless ($dbh) { botNotice($self, $nick, "onthisday: database unavailable."); return; }

    my $channel_obj = $self->{channels}{lc $channel};
    my $id_channel  = $channel_obj ? eval { $channel_obj->get_id } : undef;
    unless (defined $id_channel) {
        botNotice($self, $nick, "onthisday: channel not known to the bot.");
        return;
    }

    # mb499: optional explicit date argument. Accept MM-DD or MM/DD (also a
    # lone D/DD is not accepted — need both fields). Defaults to today.
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
    my %date_opts;
    if (@args && defined $args[0] && $args[0] ne '') {
        my $arg = $args[0];
        if ($arg =~ m{^\s*(\d{1,2})[-/.](\d{1,2})\s*$}) {
            my ($mm, $dd) = ($1 + 0, $2 + 0);
            # basic per-month day validation (29 Feb allowed: some year had it)
            my @maxd = (31,29,31,30,31,30,31,31,30,31,30,31);
            unless ($mm >= 1 && $mm <= 12 && $dd >= 1 && $dd <= $maxd[$mm - 1]) {
                botNotice($self, $nick, "onthisday: invalid date '$arg' (use MM-DD, e.g. 12-25).");
                return;
            }
            %date_opts = (month => $mm, day => $dd);
        }
        else {
            botNotice($self, $nick, "onthisday: unrecognized date '$arg' (use MM-DD, e.g. 01-01).");
            return;
        }
    }

    my @lines = Mediabot::UserCommands::_onthisday_lines($self, $id_channel, $channel, %date_opts);
    unless (@lines) {
        my $when = %date_opts ? "on that date" : "on this day";
        botNotice($self, $nick, "Nothing recorded on this channel $when in earlier years — yet.");
        return;
    }

    return queueBotNotices($self, $nick, @lines);
}


sub _onthisday_lines {
    my ($self, $id_channel, $channel_label, %opts) = @_;
    my $dbh = $self->{dbh};
    return () unless $dbh && defined $id_channel;

    # mb499: optional explicit calendar date (month/day). When omitted, use
    # today (CURDATE) exactly as before — the daily digest relies on this.
    my $has_date = defined $opts{month} && defined $opts{day};
    my ($month, $day) = $has_date ? ($opts{month}, $opts{day}) : ();

    # mb627-B1: pour les requetes qui visent UNE journee precise (annee connue),
    # MONTH(ts)=? AND DAY(ts)=? AND YEAR(ts)=? designe exactement la plage
    # [jour 00:00, lendemain 00:00). L'ecrire ainsi rend l'index (id_channel, ts)
    # utilisable la ou trois fonctions autour de la colonne l'interdisaient.
    # Un 29 fevrier inexistant rend NULL des deux cotes : aucune ligne, comme
    # avec l'ancienne comparaison. La requete de BALAYAGE des annees, elle,
    # cherche le meme jour SUR TOUTES les annees : elle ne peut pas devenir une
    # plage et garde donc sa forme (commentee sur place).
    my $day_range_expr = $has_date
        ? "STR_TO_DATE(CONCAT(?, '-', ?, '-', ?), '%Y-%m-%d')"
        : "STR_TO_DATE(CONCAT(?, DATE_FORMAT(CURDATE(), '-%m-%d')), '%Y-%m-%d')";
    # Les binds de la plage, dans l'ordre, pour UNE occurrence de l'expression.
    my $day_range_binds = sub {
        my ($year) = @_;
        return $has_date ? ($year, $month, $day) : ($year);
    };
    my $day_range_sql = "ts >= $day_range_expr AND ts < $day_range_expr + INTERVAL 1 DAY";

    # Month/day SQL expression + bind values, shared by all three queries.
    my ($md_expr, @md_bind);
    if ($has_date) {
        $md_expr = 'MONTH(ts) = ? AND DAY(ts) = ?';
        @md_bind = ($month, $day);
    }
    else {
        $md_expr = 'MONTH(ts) = MONTH(CURDATE()) AND DAY(ts) = DAY(CURDATE())';
        @md_bind = ();
    }

    # "Historical only" bound. For today, exclude the current day. For an
    # explicit date, exclude the current year only when that date hasn't
    # occurred yet this year (a future MM-DD), so a past date this year counts.
    my $year_bound = '';
    if (!$has_date) {
        $year_bound = ' AND ts < CURDATE()';
    }
    else {
        # exclude current year if (month,day) is today or still ahead this year
        $year_bound = ' AND (YEAR(ts) < YEAR(CURDATE()) '
                    . 'OR (? < MONTH(CURDATE()) OR (? = MONTH(CURDATE()) AND ? < DAY(CURDATE()))))';
    }
    my @year_bound_bind = $has_date ? ($month, $month, $day) : ();

    # mb570-B1: onthisday lit le VIF puis l'ARCHIVE (mb569) et fusionne par
    # annee — archiver le vieux public ne coupe plus la memoire du canal.
    # L'archive est best-effort : non configuree, table absente ou droits
    # manquants => comportement historique exact. Une annee vit normalement
    # d'un seul cote (l'archivage deplace par age) ; en cas de chevauchement
    # les messages s'additionnent et 'people' prend le max (approximation
    # honnete sur quelques jours de bascule).
    my %by_year;   # y => { msgs, people, src => {live=>1, archive=>1} }
    my $collect = sub {
        my ($table, $src) = @_;
        my $q = eval { $dbh->prepare(qq{
            SELECT YEAR(ts)               AS y,
                   COUNT(*)               AS msgs,
                   COUNT(DISTINCT nick)   AS people
            FROM $table
            WHERE id_channel = ?
              AND event_type IN ('public','action')
              -- mb627-B1: celle-ci cherche le meme jour SUR TOUTES les annees :
              -- aucune plage ne peut l'exprimer, la forme fonctionnelle reste
              -- (et le GROUP BY YEAR(ts) l'impose de toute facon).
              AND $md_expr$year_bound
            GROUP BY YEAR(ts)
            ORDER BY y DESC
        }) };
        return unless $q && eval { $q->execute($id_channel, @md_bind, @year_bound_bind) };
        while (my $r = $q->fetchrow_hashref) {
            my $slot = $by_year{ $r->{y} } //= { y => $r->{y}, msgs => 0, people => 0, src => {} };
            $slot->{msgs}  += $r->{msgs};
            $slot->{people} = $r->{people} if $r->{people} > $slot->{people};
            $slot->{src}{$src} = 1;
        }
        $q->finish;
        return;
    };
    $collect->('CHANNEL_LOG', 'live');
    my $archive_table = Mediabot::Helpers::channel_log_archive_table($self);
    $collect->($archive_table, 'archive') if $archive_table;

    my @years = sort { $b->{y} <=> $a->{y} } values %by_year;
    return () unless @years;

    # human label for the date being shown
    my $date_label = '';
    if ($has_date) {
        my @mon = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);
        my $mname = ($month >= 1 && $month <= 12) ? $mon[$month - 1] : sprintf('%02d', $month);
        $date_label = sprintf(' (%s %d)', $mname, $day);
    }

    my @lines;
    my $total = 0; $total += $_->{msgs} for @years;
    my $span  = @years == 1 ? "$years[0]{y}" : "$years[-1]{y}-$years[0]{y}";
    push @lines, "On this day on $channel_label$date_label ($span): $total message(s) across " . scalar(@years) . " year(s).";

    my $shown = 0;
    for my $r (@years) {
        last if $shown >= 5;
        # mb570-B1: le top nick vient de la table ou vit l'annee ; annee a
        # cheval -> les deux, sommees en Perl.
        my %nick_counts;
        my @tables_for_year;
        push @tables_for_year, 'CHANNEL_LOG'  if $r->{src}{live};
        push @tables_for_year, $archive_table if $archive_table && $r->{src}{archive};
        for my $t (@tables_for_year) {
            my $tq = eval { $dbh->prepare(qq{
                SELECT nick, COUNT(*) AS c
                FROM $t
                WHERE id_channel = ?
                  AND event_type IN ('public','action')
                  AND $day_range_sql
                GROUP BY nick ORDER BY c DESC LIMIT 3
            }) };
            next unless $tq && eval { $tq->execute($id_channel,
                $day_range_binds->($r->{y}), $day_range_binds->($r->{y})) };
            while (my $row = $tq->fetchrow_hashref) {
                $nick_counts{ $row->{nick} } += $row->{c};
            }
            $tq->finish;
        }
        my $topnick = '?';
        if (%nick_counts) {
            ($topnick) = sort { $nick_counts{$b} <=> $nick_counts{$a} || $a cmp $b }
                keys %nick_counts;
        }
        push @lines, sprintf("  %d: %d msg, %d people, most active: %s",
            $r->{y}, $r->{msgs}, $r->{people}, $topnick);
        $shown++;
    }

    # mb570-B1: la citation d'epoque vient elle aussi de la table ou vit
    # l'annee la plus recente (vif et/ou archive).
    my $ry = $years[0]{y};
    my @cand;
    my @quote_tables;
    push @quote_tables, 'CHANNEL_LOG'  if $years[0]{src}{live};
    push @quote_tables, $archive_table if $archive_table && $years[0]{src}{archive};
    @quote_tables = ('CHANNEL_LOG') unless @quote_tables;
    for my $qt (@quote_tables) {
        my $rm = eval { $dbh->prepare(qq{
            SELECT nick, publictext
            FROM $qt
            WHERE id_channel = ?
              AND event_type IN ('public','action')
              AND $day_range_sql
              AND CHAR_LENGTH(publictext) BETWEEN 25 AND 300
            ORDER BY CHAR_LENGTH(publictext) DESC
            LIMIT 8
        }) };
        next unless $rm && eval { $rm->execute($id_channel,
            $day_range_binds->($ry), $day_range_binds->($ry)) };
        while (my $mr = $rm->fetchrow_hashref) { push @cand, $mr; }
        $rm->finish;
    }
    {
        if (@cand) {
            my $pick = $cand[int(rand(scalar @cand))];
            my $text = $pick->{publictext} // '';
            $text =~ s/[\r\n\0]+/ /g;
            $text = Mediabot::Helpers::truncate_utf8($text, 200, '...') if length($text) > 200;
            push @lines, "From $ry — <$pick->{nick}> $text";
        }
    }

    return @lines;
}


sub mbMilestone_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;

    unless (isIrcChannelTarget($channel)) {
        botNotice($self, $nick, "Syntax: milestone  (use it in a channel)");
        return;
    }

    # mb503: light per-nick cooldown — milestone runs two CHANNEL_LOG scans;
    # guard against spam the same way onthisday/mood do.
    {
        my $cooldown_s = 15;
        my $now = time();
        $self->{_milestone_cooldown} ||= {};
        my $lc_nick = lc($nick);
        my $last = $self->{_milestone_cooldown}{$lc_nick};
        if (defined $last && ($now - $last) < $cooldown_s) {
            my $wait = $cooldown_s - ($now - $last);
            botNotice($self, $nick, "milestone: please wait ${wait}s before asking again.");
            return;
        }
        $self->{_milestone_cooldown}{$lc_nick} = $now;
        if (scalar(keys %{ $self->{_milestone_cooldown} }) > 512) {
            for my $k (keys %{ $self->{_milestone_cooldown} }) {
                delete $self->{_milestone_cooldown}{$k}
                    if ($now - $self->{_milestone_cooldown}{$k}) > 3600;
            }
        }
    }

    my $dbh = $self->{dbh};
    unless ($dbh) { botNotice($self, $nick, "milestone: database unavailable."); return; }

    my $channel_obj = $self->{channels}{lc $channel};
    my $id_channel  = $channel_obj ? eval { $channel_obj->get_id } : undef;
    unless (defined $id_channel) {
        botNotice($self, $nick, "milestone: channel not known to the bot.");
        return;
    }

    # total public messages + how long the channel has been logging
    # mb576-B1: COUNT/MIN par table, fusion Perl (somme, minimum).
    my $row;
    my $ms_g = Mediabot::Helpers::channel_log_gather($self, $dbh, q{
        SELECT COUNT(*) AS total,
               MIN(ts)  AS first_ts,
               UNIX_TIMESTAMP(MIN(ts)) AS first_uts
        FROM __CLSRC__ cl
        WHERE id_channel = ?
          AND event_type IN ('public','action')
    }, [ $id_channel ], sub {
        my ($r) = @_;
        $row //= { total => 0, first_ts => undef, first_uts => undef };
        $row->{total} += $r->{total} // 0;
        if (defined $r->{first_uts}
            && (!defined $row->{first_uts} || $r->{first_uts} < $row->{first_uts})) {
            $row->{first_uts} = $r->{first_uts};
            $row->{first_ts}  = $r->{first_ts};
        }
    }, 'content');
    unless ($ms_g->{live_ok}) {
        botNotice($self, $nick, "milestone: lookup failed.");
        return;
    }

    my $total = $row ? ($row->{total} // 0) : 0;
    if ($total <= 0) {
        botPrivmsg($self, $channel, "No messages logged yet on $channel — the journey starts now!");
        return 1;
    }

    # next round milestone: 1k steps below 100k, 100k steps at/above 1M-ish.
    my $next = _milestone_next($total);
    my $remaining = $next - $total;

    # recent daily rate over the last 30 days -> ETA
    my $rate_sth = $dbh->prepare(q{
        SELECT COUNT(*) AS c
        FROM CHANNEL_LOG
        WHERE id_channel = ?
          AND event_type IN ('public','action')
          AND ts >= NOW() - INTERVAL 30 DAY
    });
    my $per_day = 0;
    if ($rate_sth && $rate_sth->execute($id_channel)) {
        my $rr = $rate_sth->fetchrow_hashref;
        $rate_sth->finish;
        my $last30 = $rr ? ($rr->{c} // 0) : 0;
        $per_day = $last30 / 30 if $last30 > 0;
    }

    my $pct = $next > 0 ? int(($total / $next) * 100) : 0;

    my @bits;
    push @bits, sprintf("\x02%s\x02: %s public messages logged", $channel, _group_int($total));
    my $last_milestone = _milestone_last($total);
    if ($last_milestone > 0 && $last_milestone != $total) {
        push @bits, sprintf(" \x{B7} last passed %s", _group_int($last_milestone));
    }
    elsif ($last_milestone > 0 && $last_milestone == $total) {
        # exactly on a round number right now — celebrate it
        push @bits, sprintf(" \x{B7} \x02just hit %s!\x02", _group_int($total));
    }
    botPrivmsg($self, $channel, join('', @bits));

    my $line2 = sprintf("  next milestone: %s (%s to go, %d%%)",
        _group_int($next), _group_int($remaining), $pct);
    if ($per_day >= 0.5) {
        my $days = $remaining / $per_day;
        $line2 .= sprintf(" \x{B7} ~%s at %s msg/day",
            _humanize_days($days), _group_int(int($per_day + 0.5)));
    }
    botPrivmsg($self, $channel, $line2);

    # a touch of history: when did it all start
    if (defined $row->{first_uts}) {
        my $age_days = int((time() - $row->{first_uts}) / 86400);
        my $since = $row->{first_ts} // '';
        $since =~ s/ .*$//;   # keep the date part
        botPrivmsg($self, $channel,
            sprintf("  logging since %s (%s) \x{B7} lifetime average %s msg/day",
                $since, _humanize_days($age_days),
                _group_int($age_days > 0 ? int($total / $age_days + 0.5) : $total)));
    }
    return 1;
}


sub _milestone_next {
    my ($n) = @_;
    my $step = $n < 10_000    ? 1_000
             : $n < 100_000   ? 5_000
             : $n < 1_000_000 ? 50_000
             :                  100_000;
    my $next = (int($n / $step) + 1) * $step;
    return $next;
}


sub _milestone_last {
    my ($n) = @_;
    my $step = $n < 10_000    ? 1_000
             : $n < 100_000   ? 5_000
             : $n < 1_000_000 ? 50_000
             :                  100_000;
    my $last = int($n / $step) * $step;
    return $last;   # 0 if below the first step
}


sub _group_int {
    my ($n) = @_;
    $n = int($n // 0);
    1 while $n =~ s/^(-?\d+)(\d{3})/$1,$2/;
    return $n;
}


sub _humanize_days {
    my ($d) = @_;
    $d = 0 if !defined $d || $d < 0;
    return sprintf("%d day%s", $d, $d == 1 ? '' : 's') if $d < 45;
    if ($d < 365) {
        my $m = int($d / 30 + 0.5);
        return sprintf("%d month%s", $m, $m == 1 ? '' : 's');
    }
    my $y = $d / 365;
    return sprintf("%.1f years", $y);
}


1;
