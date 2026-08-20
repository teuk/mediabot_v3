package Mediabot::CommunityState;

# =============================================================================
# Mediabot::CommunityState
# =============================================================================
# mb677: cohesive extraction of community-state commands from UserCommands.
#
# The historical Mediabot::UserCommands symbols remain imported there so the
# dispatcher, plugins, tests and external callers keep the same API while the
# implementation lives here. Runtime helper trampolines deliberately resolve
# through Mediabot::UserCommands so existing local mocks/overrides keep working.
# =============================================================================

use strict;
use warnings;
use utf8;
use Exporter 'import';
use Time::Local ();
use Mediabot::Helpers ();

our @EXPORT_OK = qw(
    mbRemind_ctx
    mbRemindList_ctx
    mbRemindCancel_ctx
    mbRemindSnooze_ctx
    deliverReminders
    mbPoll_ctx
    mbVote_ctx
    mbPollResult_ctx
    mbPollStop_ctx
    mbPollExtend_ctx
    mbPollStatus_ctx
    mbPollVoters_ctx
    mbUnvote_ctx
    _notes_ensure_loaded
    mbNote_ctx
    mbNotes_ctx
    _factoid_id_channel
    _factoid_enabled
    mbLearn_ctx
    mbWhatis_ctx
    mbForget_ctx
    mbFactoids_ctx
    mbFactoid_ctx
);

# Compatibility bridges: resolve through UserCommands at CALL time. This is
# intentional: old tests/plugins may locally override these historical symbols.
sub botPrivmsg            { goto &Mediabot::UserCommands::botPrivmsg }
sub botNotice             { goto &Mediabot::UserCommands::botNotice }
sub logBot                { goto &Mediabot::UserCommands::logBot }
sub _seconds_to_human     { goto &Mediabot::UserCommands::_seconds_to_human }
sub isIrcChannelTarget    { goto &Mediabot::UserCommands::isIrcChannelTarget }
sub truncate_utf8         { goto &Mediabot::UserCommands::truncate_utf8 }
sub getIdUserChannelLevel { goto &Mediabot::UserCommands::getIdUserChannelLevel }

# ---------------------------------------------------------------------------
# mbRemind_ctx --- !remind <nick> <message>
# Store a memo in DB; deliver it next time the target nick speaks.
# Requires table: CREATE TABLE REMINDERS (
#   id_reminder INT AUTO_INCREMENT PRIMARY KEY,
#   id_channel INT NOT NULL,
#   from_nick VARCHAR(64) NOT NULL,
#   to_nick VARCHAR(64) NOT NULL,
#   message VARCHAR(512) NOT NULL,
#   created_at DATETIME DEFAULT NOW(),
#   delivered TINYINT DEFAULT 0
# );
# ---------------------------------------------------------------------------
sub mbRemind_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # V9: !remind show — see reminders set FOR the caller (by others)
    if (@args && lc($args[0]) eq 'show') {
        my ($sth_s, @bind_s);
        if (defined $channel && $channel =~ /^#/) {
            $sth_s = $self->{dbh}->prepare(q{
                SELECT r.id_reminder, r.from_nick, r.message, r.created_at
                FROM REMINDERS r
                JOIN CHANNEL c ON c.id_channel = r.id_channel
                WHERE c.name = ? AND r.to_nick = ? AND r.delivered = 0
                ORDER BY r.id_reminder ASC LIMIT 10
            });
            @bind_s = ($channel, lc($nick));
        } else {
            # mb90-B1: en PM, chercher sur tous les canaux
            $sth_s = $self->{dbh}->prepare(q{
                SELECT r.id_reminder, r.from_nick, r.message, r.created_at
                FROM REMINDERS r
                WHERE r.to_nick = ? AND r.delivered = 0
                ORDER BY r.id_reminder ASC LIMIT 10
            });
            @bind_s = (lc($nick));
        }
        if ($sth_s && $sth_s->execute(@bind_s)) {
            my @rows;
            while (my $r = $sth_s->fetchrow_hashref) { push @rows, $r; }
            $sth_s->finish;
            if (@rows) {
                botNotice($self, $nick, 'Reminders set for you:');
                for my $r (@rows) {
                    botNotice($self, $nick, "  [#$r->{id_reminder}] from $r->{from_nick}: $r->{message}");
                }
            } else {
                botNotice($self, $nick, 'No pending reminders set for you.');
            }
        }
        return 1;
    }

    # K1: subcommands list and cancel
    if (@args && lc($args[0]) eq 'list') {
        my ($sth_l, @bind_l);
        if (defined $channel && $channel =~ /^#/) {
            $sth_l = $self->{dbh}->prepare(q{
                SELECT r.id_reminder, r.to_nick, r.message, r.created_at
                FROM REMINDERS r
                JOIN CHANNEL c ON c.id_channel = r.id_channel
                WHERE c.name = ? AND r.from_nick = ? AND r.delivered = 0
                ORDER BY r.id_reminder ASC LIMIT 10
            });
            @bind_l = ($channel, lc($nick));
        } else {
            # mb90-B1: en PM, chercher sur tous les canaux
            $sth_l = $self->{dbh}->prepare(q{
                SELECT r.id_reminder, r.to_nick, r.message, r.created_at
                FROM REMINDERS r
                WHERE r.from_nick = ? AND r.delivered = 0
                ORDER BY r.id_reminder ASC LIMIT 10
            });
            @bind_l = (lc($nick));
        }
        if ($sth_l && $sth_l->execute(@bind_l)) {
            my @rows;
            while (my $r = $sth_l->fetchrow_hashref) { push @rows, $r; }
            $sth_l->finish;
            if (@rows) {
                botNotice($self, $nick, 'Pending reminders:');
                for my $r (@rows) {
                    botNotice($self, $nick,
                        "  [#$r->{id_reminder}] for $r->{to_nick}: $r->{message}");
                }
            } else {
                botNotice($self, $nick, 'No pending reminders.');
            }
        }
        return 1;
    }

    if (@args && lc($args[0]) eq 'cancel') {
        my $id = $args[1];
        unless (defined $id && $id =~ /^\d+$/) {
            botNotice($self, $nick, 'Syntax: remind cancel <id>  (use remind list)');
            return;
        }
        my $sth_del = $self->{dbh}->prepare(q{
            DELETE FROM REMINDERS
            WHERE id_reminder = ? AND from_nick = ? AND delivered = 0
        });
        if ($sth_del && $sth_del->execute($id, lc($nick))) {
            my $rows = $sth_del->rows; $sth_del->finish;
            if ($rows > 0) {
                botNotice($self, $nick, "Reminder #$id cancelled.");
                logBot($self, $ctx->message, $channel, 'remind_cancel', $id);
            } else {
                botNotice($self, $nick, "Reminder #$id not found or already delivered.");
            }
        }
        return 1;
    }

    # X6: !remind ! <nick> <msg> — high-priority reminder
    my $remind_urgent = (@args && $args[0] eq '!') ? do { shift @args; 1 } : 0;

    # mb87-IMP1: !remind daily HH:MM <msg> — rappel récurrent quotidien (auto-recréé à la livraison)
    my $remind_daily = 0;
    my $daily_hhmm   = '';
    if (@args && lc($args[0]) eq 'daily') {
        shift @args;
        if (@args && $args[0] =~ /^(\d{1,2}):(\d{2})$/) {
            my ($hh, $mm) = (int($1), int($2));
            if ($hh < 24 && $mm < 60) {
                $daily_hhmm  = sprintf('%02d:%02d', $hh, $mm);
                $remind_daily = 1;
                shift @args;
            } else {
                botNotice($self, $nick, "Invalid time for daily remind. Use: remind daily HH:MM <nick> <msg>");
                return;
            }
        } else {
            botNotice($self, $nick, "Syntax: remind daily HH:MM <nick> <message>");
            return;
        }
    }

    # mb90-IMP1: !remind weekly <DOW> HH:MM <nick> <msg> — rappel récurrent hebdomadaire
    my $remind_weekly = 0;
    my $weekly_dow    = '';   # 0=Sun..6=Sat
    my $weekly_hhmm   = '';
    if (@args && lc($args[0]) eq 'weekly') {
        shift @args;
        my %dow_map = ( sun => 0, mon => 1, tue => 2, wed => 3, thu => 4, fri => 5, sat => 6,
                        sunday=>0, monday=>1, tuesday=>2, wednesday=>3, thursday=>4, friday=>5, saturday=>6,
                        lun=>1, mar=>2, mer=>3, jeu=>4, ven=>5, sam=>6, dim=>0 );
        if (@args && exists $dow_map{lc($args[0])}) {
            $weekly_dow = $dow_map{lc(shift @args)};
            if (@args && $args[0] =~ /^(\d{1,2}):(\d{2})$/) {
                my ($hh, $mm) = (int($1), int($2));
                if ($hh < 24 && $mm < 60) {
                    $weekly_hhmm  = sprintf('%02d:%02d', $hh, $mm);
                    $remind_weekly = 1;
                    shift @args;
                } else {
                    botNotice($self, $nick, "Invalid time. Use: remind weekly <day> HH:MM <nick> <msg>");
                    return;
                }
            } else {
                botNotice($self, $nick, "Syntax: remind weekly <day> HH:MM <nick> <msg>  (day: mon, tue, wed...)");
                return;
            }
        } else {
            botNotice($self, $nick, "Syntax: remind weekly <day> HH:MM <nick> <msg>  (day: mon, tue, wed...)");
            return;
        }
    }

    my $target  = shift @args;
    my $message = join(' ', @args);
    $message =~ s/^\s+|\s+$//g;
    $message = '[!] ' . $message if $remind_urgent;
    # mb87-IMP1: tag daily pour réinsertion automatique lors de la livraison
    $message = "[daily:$daily_hhmm] $message" if $remind_daily;
    # mb90-IMP1: tag weekly pour réinsertion hebdomadaire
    $message = "[weekly:$weekly_dow:$weekly_hhmm] $message" if $remind_weekly;

    # mb161-B2: calculer la PREMIERE occurrence des le depart.
    #
    # Avant ce fix, un `!remind daily 09:00 bob standup` cree a 14h00
    # n'inserait AUCUN tag [at:TS] -> deliverReminders le delivrait
    # immediatement (des que bob parlait, ex. 14h05) au lieu d'attendre
    # 09:00 le lendemain. Seules les RE-insertions (apres premiere
    # livraison) portaient le [at:TS] correct. Idem weekly : cree un mardi
    # pour 'weekly mon 10:00', il partait le mardi meme au premier message.
    #
    # On reutilise exactement la meme logique de calcul que la reinsertion
    # dans deliverReminders pour garantir la coherence.
    if ($remind_daily) {
        my ($hh, $mm) = split /:/, $daily_hhmm;
        my @now = localtime(time());
        my $today_delta = ($hh * 3600 + $mm * 60)
                        - ($now[2] * 3600 + $now[1] * 60 + $now[0]);
        my $next_secs = $today_delta > 60 ? $today_delta : $today_delta + 86400;
        my $first_ts  = time() + $next_secs;
        $message =~ s/^(\[daily:\d{2}:\d{2}\])\s*/$1 [at:$first_ts] /;
    }
    elsif ($remind_weekly) {
        my ($hh, $mm) = split /:/, $weekly_hhmm;
        my @now     = localtime(time());
        my $cur_dow = $now[6];  # 0=Sun..6=Sat
        my $days_ahead  = ($weekly_dow - $cur_dow + 7) % 7;
        my $time_offset = ($hh * 3600 + $mm * 60) - ($now[2] * 3600 + $now[1] * 60 + $now[0]);
        # Meme jour : si l'heure est deja passee (ou < 60s), reporter d'une semaine
        $days_ahead = 7 if $days_ahead == 0 && $time_offset <= 60;
        my $first_ts = time() + ($days_ahead * 86400) + $time_offset;
        $message =~ s/^(\[weekly:\d:\d{2}:\d{2}\])\s*/$1 [at:$first_ts] /;
    }

    unless (defined $target && $target ne '' && $message ne '') {
        botNotice($self, $nick, "Syntax: remind <nick> <msg>  |  remind daily HH:MM <nick> <msg>  |  remind weekly <day> HH:MM <nick> <msg>  |  remind list  |  remind cancel <id>");
        return;
    }

    # IMP8: limit pending reminders per sender (max 10) to prevent spam
    {
        my $sth_cnt = $self->{dbh}->prepare(q{
            SELECT COUNT(*) AS cnt FROM REMINDERS
            WHERE from_nick = ? AND delivered = 0
        });
        if ($sth_cnt && $sth_cnt->execute(lc($nick))) {
            my $r = $sth_cnt->fetchrow_hashref;
            $sth_cnt->finish;
            if (($r->{cnt} // 0) >= 10) {
                botNotice($self, $nick,
                    "You already have 10 pending reminders. Cancel some before adding more.");
                return 1;
            }
        }
    }

    if (length($message) > 512) {
        botNotice($self, $nick, "Message too long (max 512 chars).");
        return;
    }

    if (lc($target) eq lc($nick)) {
        botNotice($self, $nick, "You can't remind yourself.");
        return;
    }

    # mb92-B3: valider que le nick destinataire est connu (nicklist canal OU USER_SEEN)
    # On évite de créer des reminders pour des nicks fantômes mal orthographiés.
    {
        my $target_known = 0;
        # 1. Vérifier la nicklist en mémoire (le plus rapide)
        if (defined $channel && $channel =~ /^#/) {
            my @chan_nicks = eval { $self->gethChannelsNicksOnChan($channel) };
            $target_known = 1 if grep { defined($_) && lc($_) eq lc($target) } @chan_nicks;
        }
        # 2. Sinon, vérifier USER_SEEN (nick a déjà parlé sur un canal commun)
        unless ($target_known) {
            my $sth_seen = $self->{dbh}->prepare(
                'SELECT 1 FROM USER_SEEN WHERE nick = ? LIMIT 1'
            );
            if ($sth_seen && $sth_seen->execute(lc($target))) {
                $target_known = 1 if $sth_seen->fetchrow_array;
                $sth_seen->finish;
            }
        }
        # 3. Sinon, vérifier la table USER (nick enregistré)
        unless ($target_known) {
            my $sth_user = $self->{dbh}->prepare(
                'SELECT 1 FROM USER WHERE nickname = ? LIMIT 1'
            );
            if ($sth_user && $sth_user->execute(lc($target))) {
                $target_known = 1 if $sth_user->fetchrow_array;
                $sth_user->finish;
            }
        }
        unless ($target_known) {
            botNotice($self, $nick,
                "Unknown nick '$target'. The remind was not created.");
            return;
        }
    }

    # Q2: parse optional delay prefix — 'dans 2h', 'in 30m', 'dans 1h30', 'at HH:MM', 'in Nd/Nw'
    my $delay_secs = 0;
    if ($message =~ s/^(?:dans|in)\s+(\d+)h(?:(\d+)m)?\s+//i) {
        $delay_secs = $1 * 3600 + ($2 // 0) * 60;
    } elsif ($message =~ s/^(?:dans|in)\s+(\d+)m\s+//i) {
        $delay_secs = $1 * 60;
    } elsif ($message =~ s/^(?:dans|in)\s+(\d+)d\s+//i) {
        # mb87-B1: support 'in Nd' (jours)
        $delay_secs = $1 * 86400;
    } elsif ($message =~ s/^(?:dans|in)\s+(\d+)w\s+//i) {
        # mb87-B1: support 'in Nw' (semaines)
        $delay_secs = $1 * 7 * 86400;
    } elsif ($message =~ s/^tomorrow\s+//i) {
        $delay_secs = 86400;
    } elsif ($message =~ s/^at\s+(\d{1,2}):(\d{2})\s+//i) {
        # mb87-B1: 'at HH:MM' — prochaine occurrence de l'heure (aujourd'hui ou demain)
        my ($hh, $mm) = (int($1), int($2));
        if ($hh < 24 && $mm < 60) {
            my @now = localtime(time());
            my $today_delta = ($hh * 3600 + $mm * 60)
                            - ($now[2] * 3600 + $now[1] * 60 + $now[0]);
            # Si < 60s dans le futur, reporter à demain (évite un remind quasi-immédiat)
            $delay_secs = $today_delta > 60 ? $today_delta : $today_delta + 86400;
        } else {
            botNotice($self, $nick, "Invalid time. Use: at HH:MM (00:00-23:59)");
            return;
        }
    }
    if ($delay_secs > 0) {
        # Prefix message with delivery timestamp so deliverReminders can filter
        my $deliver_at = time() + $delay_secs;
        $message = "[at:$deliver_at] $message";
    }

    # Fetch id_channel inline (getIdChannel is in ChannelCommands scope)
    # mb414-R1: id canal via le helper central (cache d'abord, mb411).
    my $id_channel = Mediabot::Helpers::channel_id_cached($self, $channel);
    unless ($id_channel) {
        botNotice($self, $nick, "Channel not found.");
        return;
    }

    my $sth = $self->{dbh}->prepare(q{
        INSERT INTO REMINDERS (id_channel, from_nick, to_nick, message)
        VALUES (?, ?, ?, ?)
    });
    unless ($sth && $sth->execute($id_channel, lc($nick), lc($target), $message)) {
        $self->{logger}->log(1, "mbRemind_ctx() SQL error: $DBI::errstr");
        botNotice($self, $nick, "Database error.");
        return;
    }
    $sth->finish;

    # S2: include delay info in confirmation
    # mb161-IMP1: pour daily/weekly, afficher la premiere occurrence calculee
    # (le [at:TS] insere par mb161-B2) au lieu d'un message generique.
    my $delay_info = '';
    if ($delay_secs > 0) {
        $delay_info = ' (due in ' . Mediabot::UserCommands::_seconds_to_human($delay_secs) . ')';
    }
    elsif (($remind_daily || $remind_weekly) && $message =~ /\[at:(\d+)\]/) {
        my $first_in = $1 - time();
        $delay_info = ' (first delivery in ' . Mediabot::UserCommands::_seconds_to_human($first_in) . ')'
            if $first_in > 0;
    }
    botNotice($self, $nick, "Reminder set for $target$delay_info.");
    logBot($self, $ctx->message, $channel, 'remind', "$target: $message");
    return 1;
}

# ---------------------------------------------------------------------------
# deliverReminders($self, $nick, $channel)
# Called from mbCommandPublic on every message; delivers pending reminders.
# ---------------------------------------------------------------------------
sub deliverReminders {
    my ($self, $nick, $channel) = @_;

    $self->{logger}->log(4, "deliverReminders() nick=$nick chan=$channel");
    # Q2: helper to check if a remind message has a future [at:TS] tag
    # Returns undef if not yet due, or stripped message if due/no tag
    # (Inline — not a separate sub to avoid scope issues)

    # S3/fix: ensure DB connection alive before using dbh
    my $dbh = eval { $self->{db}->ensure_connected } // $self->{dbh};
    return unless $dbh;
    # mb414-R1: id canal via le helper central (cache d'abord, mb411).
    my $id_channel = Mediabot::Helpers::channel_id_cached($self, $channel);
    return unless $id_channel;

    # mb161-B1: scan large puis filtrer, au lieu de LIMIT 3 brut.
    #
    # Avant ce fix, le SELECT prenait les 3 plus anciens reminders pending
    # (ORDER BY created_at ASC LIMIT 3) PUIS filtrait les [at:TS] non-dus en
    # Perl. Si les 3 plus anciens etaient tous des reminders programmes dans
    # le futur (daily/weekly re-crees, ou 'remind in 7d'), ils monopolisaient
    # les 3 slots a chaque appel -> les reminders normaux plus recents
    # n'etaient JAMAIS delivres tant que les anciens n'etaient pas dus
    # (famine pouvant durer des jours).
    #
    # On scanne maintenant jusqu'a 20 rows et on ne delivre que les 3
    # premiers DUS, ce qui preserve la limite anti-flood de 3 par message.
    my $sth = $dbh->prepare(q{
        SELECT id_reminder, from_nick, message, created_at
        FROM REMINDERS
        WHERE id_channel = ? AND to_nick = ? AND delivered = 0
        ORDER BY created_at ASC
        LIMIT 20
    });
    return unless $sth && $sth->execute($id_channel, lc($nick));

    my @candidates;
    while (my $row = $sth->fetchrow_hashref) { push @candidates, $row; }
    $sth->finish;
    return unless @candidates;

    # mb161-B1: filtrer les non-dus AVANT de constituer la liste de livraison.
    my @pending;
    for my $row (@candidates) {
        if ($row->{message} =~ /\[at:(\d+)\]/) {
            next if time() < $1;   # pas encore du -> on ne le compte pas
        }
        push @pending, $row;
        last if @pending >= 3;     # limite anti-flood preservee
    }
    return unless @pending;

    for my $r (@pending) {
        # mb161-B1: le skip des non-dus est desormais fait en amont (boucle
        # @candidates). Ici on strip seulement les tags [at:TS] du message
        # avant livraison.
        if ($r->{message} =~ /\[at:(\d+)\]/) {
            $r->{message} =~ s/\s*\[at:\d+\]\s*/ /g;
            $r->{message} =~ s/^\s+|\s+$//g;
        }
        # H/fix: mark delivered BEFORE sending — prevents double delivery on crash
        my $sth_up = $dbh->prepare(q{
            UPDATE REMINDERS SET delivered = 1 WHERE id_reminder = ?
        });
        # C2/fix: test execute return
        if ($sth_up) {
            unless ($sth_up->execute($r->{id_reminder})) {
                $self->{logger}->log(1, "deliverReminders: UPDATE failed for id=$r->{id_reminder}: $DBI::errstr");
                $sth_up->finish;
                next;  # skip send if we can't mark delivered
            }
            $sth_up->finish;
        } else { next; }  # can't prepare → skip
        # IMP15: show how long ago the reminder was set
        my $ago_str = '';
        if ($r->{created_at} && $r->{created_at} =~ /^(\d{4})-(\d{2})-(\d{2})/) {
            require Time::Local;
            my ($y,$mo,$d) = ($1,$2,$3);
            my $epoch = eval { Time::Local::timelocal(0,0,12,$d,$mo-1,$y-1900) };
            if ($epoch) {
                my $diff = time() - $epoch;
                my $dy = int($diff/31536000); my $dm = int(($diff%31536000)/2592000);
                my $dd = int(($diff%2592000)/86400);
                $ago_str = $dy  ? ", ${dy}y ${dm}m ago"
                         : $dm  ? ", ${dm}m ${dd}d ago"
                         : $dd  ? ", ${dd}d ago" : '';
            }
        }
        # mb91-B1: strip les tags récurrents du message affiché
        my $display_msg = $r->{message};
        my $recur_tag = '';
        if ($display_msg =~ s/^\[daily:(\d{2}:\d{2})\]\s*//) {
            $recur_tag = " [daily $1]";
        } elsif ($display_msg =~ s/^\[weekly:(\d):(\d{2}:\d{2})\]\s*//) {
            my @dn = qw(Sun Mon Tue Wed Thu Fri Sat);
            $recur_tag = " [weekly $dn[$1] $2]";
        }
        botPrivmsg($self, $channel,
            "$nick: reminder from $r->{from_nick} ($r->{created_at}$ago_str)$recur_tag: $display_msg");

        # mb87-IMP1 / mb88-R1: si le remind est daily, le re-créer pour le lendemain
        # mb90-IMP1: si le remind est weekly, le re-créer pour la semaine suivante
        # Guard: ne réinsérer que si delivered=1 (livré normalement), pas delivered=2 (annulé)
        my $was_cancelled = 0;
        {
            my $sth_chk = $dbh->prepare('SELECT delivered FROM REMINDERS WHERE id_reminder = ?');
            if ($sth_chk && $sth_chk->execute($r->{id_reminder})) {
                my $chk = $sth_chk->fetchrow_hashref; $sth_chk->finish;
                $was_cancelled = 1 if $chk && ($chk->{delivered} // 0) == 2;
            }
        }
        if (!$was_cancelled && $r->{message} =~ /^\[daily:(\d{2}:\d{2})\]\s*(.*)/) {
            my ($hhmm, $real_msg) = ($1, $2);
            my ($hh, $mm) = split /:/, $hhmm;
            my @now = localtime(time());
            my $today_delta = ($hh * 3600 + $mm * 60)
                            - ($now[2] * 3600 + $now[1] * 60 + $now[0]);
            my $next_secs   = $today_delta > 60 ? $today_delta : $today_delta + 86400;
            my $next_ts     = time() + $next_secs;
            my $next_msg    = "[daily:$hhmm] [at:$next_ts] $real_msg";
            eval {
                my $sth_daily = $dbh->prepare(q{
                    INSERT INTO REMINDERS (id_channel, from_nick, to_nick, message)
                    VALUES (?, ?, ?, ?)
                });
                $sth_daily->execute($id_channel, $r->{from_nick}, lc($nick), $next_msg)
                    if $sth_daily;
                $sth_daily->finish if $sth_daily;
            };
            $self->{logger}->log(3, "daily remind re-scheduled for $nick at $hhmm (next: $next_ts)")
                unless $@;
        } elsif (!$was_cancelled && $r->{message} =~ /^\[weekly:(\d):(\d{2}:\d{2})\]\s*(.*)/) {
            # mb90-IMP1: réinsertion hebdomadaire — calcul du prochain occurrence du DOW+HH:MM
            my ($target_dow, $hhmm, $real_msg) = ($1, $2, $3);
            my ($hh, $mm) = split /:/, $hhmm;
            my @now    = localtime(time());
            my $cur_dow = $now[6];  # 0=Sun..6=Sat
            my $days_ahead = ($target_dow - $cur_dow + 7) % 7;
            $days_ahead = 7 if $days_ahead == 0;  # même jour → semaine suivante
            my $day_secs    = $days_ahead * 86400;
            my $time_offset = ($hh * 3600 + $mm * 60) - ($now[2] * 3600 + $now[1] * 60 + $now[0]);
            my $next_ts     = time() + $day_secs + $time_offset;
            my $next_msg    = "[weekly:$target_dow:$hhmm] [at:$next_ts] $real_msg";
            eval {
                my $sth_wk = $dbh->prepare(q{
                    INSERT INTO REMINDERS (id_channel, from_nick, to_nick, message)
                    VALUES (?, ?, ?, ?)
                });
                $sth_wk->execute($id_channel, $r->{from_nick}, lc($nick), $next_msg) if $sth_wk;
                $sth_wk->finish if $sth_wk;
            };
            $self->{logger}->log(3, "weekly remind re-scheduled for $nick at dow=$target_dow $hhmm (next: $next_ts)")
                unless $@;
        }  # end recurring remind block
    }  # end for @pending
}  # end sub deliverReminders

# ---------------------------------------------------------------------------
# mbRemindList_ctx --- !remindlist
# Show pending reminders sent by the calling nick.
# ---------------------------------------------------------------------------
sub mbRemindList_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;

    my ($sth, @bind_rl);
    if (defined $channel && $channel =~ /^#/) {
        $sth = $self->{dbh}->prepare(q{
            SELECT r.id_reminder, r.to_nick, r.message, r.created_at
            FROM REMINDERS r
            JOIN CHANNEL c ON c.id_channel = r.id_channel
            WHERE r.from_nick = ? AND c.name = ? AND r.delivered = 0
            ORDER BY r.created_at ASC
        });
        @bind_rl = (lc($nick), $channel);
    } else {
        # mb90-B1: en PM, afficher tous les reminders cross-canal
        $sth = $self->{dbh}->prepare(q{
            SELECT r.id_reminder, r.to_nick, r.message, r.created_at
            FROM REMINDERS r
            WHERE r.from_nick = ? AND r.delivered = 0
            ORDER BY r.created_at ASC
        });
        @bind_rl = (lc($nick));
    }
    unless ($sth && $sth->execute(@bind_rl)) {
        botNotice($self, $nick, 'Database error.');
        $sth->finish if $sth;
        return;
    }
    my @rows;
    while (my $r = $sth->fetchrow_hashref) { push @rows, $r; }
    $sth->finish;

    unless (@rows) {
        botNotice($self, $nick, 'No pending reminders.');
        return 1;
    }

    # CC7: enriched listing — remaining time + urgent flag
    my $total = scalar(@rows);
    botNotice($self, $nick, "$total pending reminder(s) you have set:");
    for my $r (@rows) {
        my $msg = $r->{message} // '';
        # mb90-B2: strip [daily:HH:MM] et [weekly:DOW:HH:MM] FIRST et noter séparément
        my $daily_tag = '';
        if ($msg =~ s/^\[daily:(\d{2}:\d{2})\]\s*//) {
            $daily_tag = " [daily $1]";
        } elsif ($msg =~ s/^\[weekly:(\d):(\d{2}:\d{2})\]\s*//) {
            my @dow_names = qw(Sun Mon Tue Wed Thu Fri Sat);
            $daily_tag = " [weekly $dow_names[$1] $2]";
        }
        # BX-12/fix: strip [at:TS], detect remaining [at:TS] (après daily)
        my $due_str = '';
        $msg =~ s/\s*\[at:(\d+)\]\s*/ /g;  # strip tous les [at:TS]
        $msg =~ s/^\s+|\s+$//g;
        # Recalculer due_str depuis le message original si [at:TS] présent
        if ($r->{message} =~ /\[at:(\d+)\]/) {
            my $sl = $1 - time();
            $due_str = $sl > 0
                ? ' [in ' . _seconds_to_human($sl) . ']'
                : ' [overdue ' . _seconds_to_human(-$sl) . ' ago]';
        }
        my $urgent = ($msg =~ /^\[!\]/) ? ' [URGENT]' : '';
        $msg =~ s/^\[!\]\s*//;
        botNotice($self, $nick, sprintf('  #%d -> %s%s%s: "%s"%s',
            $r->{id_reminder}, $r->{to_nick}, $due_str, $daily_tag, $msg, $urgent));
    }
    return 1;
}


# ---------------------------------------------------------------------------
# mbRemindSnooze_ctx --- !remindsnooze <id> <+delay>  (FF7)
# Postpone a pending reminder. Delay format: 1h, 30m, 2h30m, 1d.
# ---------------------------------------------------------------------------
sub mbRemindSnooze_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    my ($id, $delay_str) = (shift @args, shift @args);
    unless (defined $id && $id =~ /^\d+$/ && defined $delay_str) {
        botNotice($self, $nick, 'Syntax: remindsnooze <id> <delay>  (e.g. 10 30m or 3 2h)');
        return;
    }
    # Parse delay: 1h30m, 45m, 2d, etc.
    my $secs = 0;
    $secs += $1 * 86400 if $delay_str =~ /(\d+)d/;
    $secs += $1 * 3600  if $delay_str =~ /(\d+)h/;
    $secs += $1 * 60    if $delay_str =~ /(\d+)m/;
    $secs += $1         if $delay_str =~ /(\d+)s/;
    unless ($secs > 0) {
        botNotice($self, $nick, "Invalid delay '$delay_str'. Use 1h, 30m, 2h30m, 1d...");
        return;
    }
    my $new_ts = time() + $secs;

    # Keep snooze SQL simple and portable: fetch current message, rewrite the
    # [at:TS] prefix in Perl, then update the message with a normal placeholder.
    my $sth2 = $self->{dbh}->prepare(
        'UPDATE REMINDERS SET message = ? WHERE id_reminder = ? AND from_nick = ? AND delivered = 0'
    );
    # Fetch current message first
    my $sth_get = $self->{dbh}->prepare(
        'SELECT message FROM REMINDERS WHERE id_reminder = ? AND from_nick = ? AND delivered = 0'
    );
    unless ($sth_get && $sth_get->execute($id, lc($nick))) {
        botNotice($self, $nick, 'DB error.'); return;
    }
    my $row = $sth_get->fetchrow_hashref; $sth_get->finish;
    unless ($row) {
        botNotice($self, $nick, "Reminder #$id not found or already delivered."); return;
    }
    my $msg = $row->{message} // '';
    # mb88-R2: strip [at:TS] où qu'il soit dans le message (pas seulement en début)
    # Cas daily: "[daily:09:00] [at:1234] texte" → strip le [at:...] interne aussi
    $msg =~ s/^\[at:\d+\]\s*//;       # strip en début (cas standard)
    $msg =~ s/\s*\[at:\d+\]\s*/ /g;   # strip partout ailleurs (cas daily + snooze)
    $msg =~ s/^\s+|\s+$//g;           # trim
    my $new_msg = "[at:$new_ts] $msg";
    unless ($sth2 && $sth2->execute($new_msg, $id, lc($nick))) {
        botNotice($self, $nick, 'DB error updating reminder.'); return;
    }
    $sth2->finish;
    my $hm = sprintf('%dh%02dm', int($secs/3600), int(($secs%3600)/60));
    botNotice($self, $nick, "Reminder #$id snoozed for $hm.");
    return 1;
}

# ---------------------------------------------------------------------------
# mbRemindCancel_ctx --- !remind cancel <id>
# Cancel a pending reminder by ID (must be from the calling nick).
# ---------------------------------------------------------------------------
sub mbRemindCancel_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    my $id = shift @args;
    # EE6: !remindcancel all — cancel all pending reminders set by caller
    if (defined $id && lc($id) eq 'all') {
        my $sth_a = $self->{dbh}->prepare(q{
            UPDATE REMINDERS SET delivered = 1
            WHERE from_nick = ? AND delivered = 0
        });
        unless ($sth_a && $sth_a->execute(lc($nick))) {
            botNotice($self, $nick, 'DB error.'); return;
        }
        my $rows = $sth_a->rows; $sth_a->finish;
        botNotice($self, $nick, "$rows pending reminder(s) cancelled.");
        return 1;
    }
    unless (defined $id && $id =~ /^\d+$/) {
        botNotice($self, $nick, 'Syntax: remind cancel <id>|all  (see !remindlist)');
        return;
    }

    my $sth = $self->{dbh}->prepare(q{
        UPDATE REMINDERS SET delivered = 2
        WHERE id_reminder = ? AND from_nick = ? AND delivered = 0
    });
    unless ($sth && $sth->execute($id, lc($nick))) {
        botNotice($self, $nick, 'Database error.');
        $sth->finish if $sth;
        return;
    }
    my $rows = $sth->rows;
    $sth->finish;

    if ($rows > 0) {
        botNotice($self, $nick, "Reminder #$id cancelled.");
    } else {
        botNotice($self, $nick, "Reminder #$id not found or already delivered.");
    }
    return 1;
}

# ---------------------------------------------------------------------------
# mbPoll_ctx --- !poll <question> | opt1 | opt2 ...
# mbVote_ctx --- !vote <n>


# ---------------------------------------------------------------------------
# mbPollVoters_ctx --- !pollvoters  (EE7)
# Show detailed vote breakdown. Requires Master level.
# ---------------------------------------------------------------------------
sub mbPollVoters_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    return unless $ctx->require_level('Master');
    my $poll = $self->{_polls}{$channel};
    unless ($poll && %{ $poll->{votes} // {} }) {
        botNotice($self, $nick, 'No poll or no votes on this channel.'); return 1;
    }
    botNotice($self, $nick,
        "Vote breakdown for \"$poll->{question}\":");
    # Group voters by option index
    my %by_opt;
    for my $voter (sort keys %{ $poll->{votes} }) {
        my $idx = $poll->{votes}{$voter};
        push @{ $by_opt{$idx} }, $voter;
    }
    for my $idx (sort { $a <=> $b } keys %by_opt) {
        my $label   = $poll->{options}[$idx] // "option $idx";
        my @voters  = @{ $by_opt{$idx} };
        botNotice($self, $nick,
            sprintf('  [%d] %s (%d): %s',
                $idx+1, $label, scalar @voters, join(', ', @voters)));
    }
    return 1;
}

# ---------------------------------------------------------------------------
# mbPollStatus_ctx --- !pollstatus  (W8)
# Show live poll results without closing the poll.
# ---------------------------------------------------------------------------
sub mbPollStatus_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my $poll = $self->{_polls}{$channel};
    unless ($poll && $poll->{active}) {
        botPrivmsg($self, $channel, 'No active poll.'); return 1;
    }
    my $total = scalar keys %{ $poll->{votes} };
    # mb160-B1: appliquer les poids en mode weighted (BB7).
    my $weighted = $poll->{weighted} ? 1 : 0;
    my $weights  = $poll->{weights}  || [];
    my $weighted_label = $weighted ? ' [weighted]' : '';
    botPrivmsg($self, $channel, "\"$poll->{question}\"${weighted_label} -- $total vote(s) so far:");
    my $weighted_total = 0;
    if ($weighted) {
        for my $idx (0 .. $#{ $poll->{options} }) {
            my $voters = scalar grep { $_ == $idx } values %{ $poll->{votes} };
            my $w      = $weights->[$idx] // 1;
            $weighted_total += $voters * $w;
        }
    }
    for my $idx (0 .. $#{ $poll->{options} }) {
        my $voters = scalar grep { $_ == $idx } values %{ $poll->{votes} };
        if ($weighted) {
            my $w     = $weights->[$idx] // 1;
            my $score = $voters * $w;
            my $pct   = $weighted_total > 0 ? int($score * 100 / $weighted_total) : 0;
            botPrivmsg($self, $channel, sprintf('  [%d] %s (x%d): %d=%d (%d%%)',
                $idx+1, $poll->{options}[$idx], $w, $voters, $score, $pct));
        } else {
            my $pct = $total > 0 ? int($voters * 100 / $total) : 0;
            botPrivmsg($self, $channel, sprintf('  [%d] %s: %d (%d%%)',
                $idx+1, $poll->{options}[$idx], $voters, $pct));
        }
    }
    return 1;
}


# ---------------------------------------------------------------------------
# mbUnvote_ctx --- !unvote  (Y6)
# ---------------------------------------------------------------------------
sub mbUnvote_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my $poll    = $self->{_polls}{$channel};
    unless ($poll && $poll->{active}) {
        botPrivmsg($self, $channel, 'No active poll.'); return 1;
    }
    unless (exists $poll->{votes}{lc $nick}) {
        botNotice($self, $nick, 'You have not voted yet.'); return 1;
    }
    delete $poll->{votes}{lc $nick};
    my $total = scalar keys %{ $poll->{votes} };
    botPrivmsg($self, $channel,
        "$nick cancelled their vote ($total vote(s) remaining).");
    return 1;
}

sub mbPollExtend_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
    my $extra   = ($args[0] // 0) =~ /^(\d+)$/ ? int($args[0]) : 60;
    $extra = 10 if $extra < 10; $extra = 600 if $extra > 600;
    my $poll = $self->{_polls}{$channel};
    unless ($poll && $poll->{active}) {
        botPrivmsg($self, $channel, 'No active poll.'); return 1;
    }
    # mb431-B1: si la deadline est déjà passée (l'expiration est paresseuse,
    # le sondage reste actif tant que personne n'a voté après l'échéance),
    # repartir de maintenant. Sinon `deadline_passée + $extra` restait dans le
    # passé -> "remaining" négatif et aucune vraie réouverture du vote.
    my $base = $poll->{deadline} // time();
    $base = time() if $base < time();
    $poll->{deadline} = $base + $extra;
    Mediabot::Helpers::botPrivmsg($self, $channel,
        sprintf('Poll extended by %ds (%ds remaining).', $extra, $poll->{deadline} - time()));
    return 1;
}

# mbPollResult_ctx --- !pollresult
# mbPollStop_ctx --- !pollstop  (Master+)
# In-memory polls, one active per channel.
# ---------------------------------------------------------------------------
sub mbPoll_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    return unless $ctx->require_level('Master');

    my $raw = join(' ', @args);
    # V2: optional leading number sets poll timeout (10–3600s, default 300)
    my $poll_timeout = 300;
    # BB7: optional 'weighted' keyword enables weighted voting mode
    my $poll_weighted = 0;
    if ($raw =~ s/^weighted\s+//i) { $poll_weighted = 1; }
    if ($raw =~ s/^(\d+)\s+//) {
        $poll_timeout = int($1); $poll_timeout = 10 if $poll_timeout < 10;
        $poll_timeout = 3600 if $poll_timeout > 3600;
    }
    my @parts = map { s/^\s+|\s+$//gr } split(/\|/, $raw);
    unless (@parts >= 3) {
        botNotice($self, $nick, 'Syntax: poll <question> | option1 | option2 ...');
        return;
    }

    my $question = shift @parts;
    # BB7: build weighted option list
    my @weighted_parts;
    for my $opt (@parts) {
        if ($poll_weighted && $opt =~ /^(.+?):(\d+)$/ && $2 >= 1 && $2 <= 10) {
            push @weighted_parts, { label => $1, weight => int($2) };
        } else {
            push @weighted_parts, { label => $opt, weight => 1 };
        }
    }
    # mb84-B3: supprimé le double inc() de poll_created_total (était appelé avant et après @weighted_parts)
    $self->{metrics}->inc('mediabot_poll_created_total') if $self->{metrics};  # Z10
    $self->{_polls}{$channel} = {
        question => $question,
        options  => [ map { $_->{label}  } @weighted_parts ],
        weights  => [ map { $_->{weight} } @weighted_parts ],
        weighted => $poll_weighted,
        votes    => {},
        started  => time(),
        deadline => time() + $poll_timeout,  # V2: configurable timeout
        active   => 1,
    };
    # mb84-B3b: $opts utilisait @parts (après shift question) au lieu des labels @weighted_parts
    my @opt_labels = map { $_->{label} } @weighted_parts;
    my $opts = join('  ', map { '[' . ($_+1) . '] ' . $opt_labels[$_] } 0..$#opt_labels);
    botPrivmsg($self, $channel, "Poll: \"$question\"  $opts  -- vote with !vote <n>");
    logBot($self, $ctx->message, $channel, 'poll', $question);  # S2/fix
    return 1;
}

sub mbVote_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    my $poll = $self->{_polls}{$channel};
    if ($poll && $poll->{active} && time() > ($poll->{deadline} // 0)) {
        $poll->{active} = 0;
        botPrivmsg($self, $channel, 'Poll expired. Use !pollresult to see results.');
        return;
    }
    unless ($poll && $poll->{active}) {
        botNotice($self, $nick, 'No active poll on this channel.'); return;
    }

    my $n = $args[0] // '';
    unless ($n =~ /^\d+$/ && $n >= 1 && $n <= scalar @{ $poll->{options} }) {
        botNotice($self, $nick, 'Vote: use !vote <number> (1 to ' . scalar(@{ $poll->{options} }) . ')');
        return;
    }

    $poll->{votes}{lc $nick} = $n - 1;
    my $choice = $poll->{options}[$n-1];
    my $total  = scalar keys %{ $poll->{votes} };
    botPrivmsg($self, $channel, "$nick voted for \"$choice\" ($total vote(s) cast)");
    # Y9: Prometheus counter for poll votes
    $self->{metrics}->inc('mediabot_poll_votes_total') if $self->{metrics};

    # U3: show live tally after each vote
    # mb160-B1: appliquer les poids quand le poll est en mode weighted (BB7).
    # Avant ce fix, $poll->{weights} etait stocke a la creation mais jamais
    # consulte dans tally/result/status -> mode 'weighted' completement dead.
    my $weighted = $poll->{weighted} ? 1 : 0;
    my $weights  = $poll->{weights}  || [];
    my @tally;
    my $weighted_total = 0;
    if ($weighted) {
        for my $idx (0 .. $#{ $poll->{options} }) {
            my $voters = scalar grep { $_ == $idx } values %{ $poll->{votes} };
            my $w = $weights->[$idx] // 1;
            $weighted_total += $voters * $w;
        }
    }
    for my $idx (0 .. $#{ $poll->{options} }) {
        my $voters = scalar grep { $_ == $idx } values %{ $poll->{votes} };
        if ($weighted) {
            my $w     = $weights->[$idx] // 1;
            my $score = $voters * $w;
            my $pct   = $weighted_total > 0 ? int($score * 100 / $weighted_total) : 0;
            push @tally, sprintf('[%d] %s (x%d): %d=%d (%d%%)',
                $idx+1, $poll->{options}[$idx], $w, $voters, $score, $pct);
        } else {
            my $pct = $total > 0 ? int($voters * 100 / $total) : 0;
            push @tally, sprintf('[%d] %s: %d (%d%%)',
                $idx+1, $poll->{options}[$idx], $voters, $pct);
        }
    }
    botPrivmsg($self, $channel, 'Live tally: ' . join('  ', @tally));
    logBot($self, $ctx->message, $channel, 'vote', $choice);  # S2/fix
    return 1;
}

sub mbPollResult_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;

    my $poll = $self->{_polls}{$channel};
    unless ($poll) {
        botNotice($self, $nick, 'No poll found for this channel.'); return;
    }

    my @options = @{ $poll->{options} };
    my %counts;
    $counts{ $poll->{votes}{$_} }++ for keys %{ $poll->{votes} };
    my $total = scalar keys %{ $poll->{votes} };

    # mb160-B1: appliquer les poids en mode weighted (BB7). Sans cette
    # branche, le mode 'weighted' du poll etait sans effet : les poids
    # etaient parses et stockes mais jamais utilises dans le tally ni la
    # determination du gagnant.
    my $weighted = $poll->{weighted} ? 1 : 0;
    my $weights  = $poll->{weights}  || [];
    my %weighted_scores;
    my $weighted_total = 0;
    if ($weighted) {
        for my $idx (0 .. $#options) {
            my $voters = $counts{$idx} // 0;
            my $w      = $weights->[$idx] // 1;
            $weighted_scores{$idx} = $voters * $w;
            $weighted_total += $voters * $w;
        }
    }

    my $status = $poll->{active} ? 'Active' : 'Closed';
    # DD8/MB306: show the winning label prominently and keep ties
    # deterministic. The previous sort started from hash keys, so equal scores
    # could select a different winner from one process to another.
    my @winner_opts;
    if ($total > 0) {
        my $best_score = -1;
        for my $idx (0 .. $#options) {
            my $score = $weighted
                ? ($weighted_scores{$idx} // 0)
                : ($counts{$idx} // 0);

            if ($score > $best_score) {
                $best_score = $score;
                @winner_opts = ($idx);
            }
            elsif ($score == $best_score) {
                push @winner_opts, $idx;
            }
        }
    }

    my $winner_str = '';
    if (@winner_opts == 1) {
        my $winner_opt   = $winner_opts[0];
        my $winner_label = $options[$winner_opt] // 'option ' . ($winner_opt + 1);
        if ($weighted && $weighted_total > 0) {
            my $wpct = sprintf('%.0f%%', 100 * ($weighted_scores{$winner_opt} // 0) / $weighted_total);
            $winner_str = "  Winner: $winner_label ($wpct weighted)";
        } else {
            my $wpct = sprintf('%.0f%%', 100 * ($counts{$winner_opt} // 0) / $total);
            $winner_str = "  Winner: $winner_label ($wpct)";
        }
    }
    elsif (@winner_opts > 1) {
        my @winner_labels = map {
            $options[$_] // 'option ' . ($_ + 1)
        } @winner_opts;
        $winner_str = '  Tie: ' . join(', ', @winner_labels);
    }
    my $weighted_label = $weighted ? ' [weighted]' : '';
    botPrivmsg($self, $channel, "$status poll${weighted_label}: \"$poll->{question}\" ($total vote(s))$winner_str");
    for my $i (0 .. $#options) {
        my $c   = $counts{$i} // 0;
        if ($weighted) {
            my $w     = $weights->[$i] // 1;
            my $score = $weighted_scores{$i} // 0;
            my $pct   = $weighted_total > 0
                ? sprintf('%.0f%%', 100 * $score / $weighted_total)
                : '0%';
            botPrivmsg($self, $channel,
                sprintf('  [%d] %-20s (x%d) %d vote(s) = %d (%s)',
                    $i+1, $options[$i], $w, $c, $score, $pct));
        } else {
            my $pct = $total > 0 ? sprintf('%.0f%%', 100 * $c / $total) : '0%';
            botPrivmsg($self, $channel,
                sprintf('  [%d] %-20s %d vote(s) (%s)', $i+1, $options[$i], $c, $pct));
        }
    }
    logBot($self, $ctx->message, $channel, 'pollresult', '');  # Q1
    return 1;
}

sub mbPollStop_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;

    return unless $ctx->require_level('Master');

    my $poll = $self->{_polls}{$channel};
    unless ($poll && $poll->{active}) {
        botNotice($self, $nick, 'No active poll.'); return;
    }
    $poll->{active} = 0;
    $self->{metrics}->inc('mediabot_poll_closed_total') if $self->{metrics};

    # MB306: keep !pollstop consistent with !pollresult.
    # The old code announced the zero-based option index as the winner and
    # ignored weighted poll scores entirely.
    my $votes    = $poll->{votes}   // {};
    my $opts     = $poll->{options} // [];
    my $weights  = $poll->{weights} // [];
    my $weighted = $poll->{weighted} ? 1 : 0;
    my $total    = scalar(keys %$votes);

    my $duration = int(time() - ($poll->{started} // time()));
    $duration = 0 if $duration < 0;
    $self->{metrics}->set('mediabot_poll_duration_seconds', $duration)
        if $self->{metrics};

    if ($total > 0) {
        my %counts;
        $counts{$votes->{$_}}++ for keys %$votes;

        my %scores;
        my $score_total = 0;
        for my $idx (0 .. $#$opts) {
            my $voters = $counts{$idx} // 0;
            my $weight = $weights->[$idx] // 1;
            my $score  = $weighted ? ($voters * $weight) : $voters;
            $scores{$idx} = $score;
            $score_total += $score;
        }

        my $best_score = -1;
        my @winners;
        for my $idx (0 .. $#$opts) {
            my $score = $scores{$idx} // 0;
            if ($score > $best_score) {
                $best_score = $score;
                @winners = ($idx);
            }
            elsif ($score == $best_score) {
                push @winners, $idx;
            }
        }

        if (@winners > 1) {
            my @labels = map { $opts->[$_] // 'option ' . ($_ + 1) } @winners;
            my $basis = $weighted ? 'weighted score' : 'votes';
            botPrivmsg($self, $channel,
                "Poll closed ($total vote(s)). Tie on $basis: "
                . join(', ', @labels)
                . ". Use !pollresult for details.");
        }
        else {
            my $winner       = $winners[0];
            my $winner_label = $opts->[$winner] // 'option ' . ($winner + 1);
            my $winner_votes = $counts{$winner} // 0;
            my $winner_score = $scores{$winner} // 0;
            my $pct = $score_total > 0
                ? int(100 * $winner_score / $score_total)
                : 0;

            my $details = $weighted
                ? "$winner_votes vote(s), weighted score $winner_score/$score_total, ${pct}%"
                : "$winner_votes/$total, ${pct}%";

            botPrivmsg($self, $channel,
                "Poll closed ($total vote(s)). Winner: $winner_label "
                . "($details). Use !pollresult for details.");
        }
    } else {
        botPrivmsg($self, $channel, "Poll closed. No votes cast.");
    }
    logBot($self, $ctx->message, $channel, 'pollstop', '');  # S2/fix
    return 1;
}

# ---------------------------------------------------------------------------
# mbNote_ctx --- !note <message>
# mbNotes_ctx --- !notes [del <id>]
# Personal notes stored in memory per nick.
# ---------------------------------------------------------------------------
# mb437-B1: charge les notes d'un nick depuis la DB dans le cache mémoire si
# celui-ci est vide (typiquement après un restart). Partagé par mbNote_ctx
# (ajout) et mbNotes_ctx (liste) : sans ce chargement côté ajout, le plafond
# de 10 notes était évalué contre une liste mémoire vide au premier !note
# suivant un redémarrage -> plafond contourné et notes au-delà de 10
# invisibles (SELECT ... LIMIT 10).
sub _notes_ensure_loaded {
    my ($self, $nick) = @_;
    my $key = lc $nick;
    return if @{ $self->{_notes}{$key} // [] };
    eval {
        my $sth = $self->{dbh}->prepare(
            'SELECT id_note, text FROM NOTE WHERE nick = ? ORDER BY id_note ASC LIMIT 10'
        );
        if ($sth && $sth->execute($key)) {
            my @db_notes;
            while (my $r = $sth->fetchrow_hashref) {
                push @db_notes, { id => $r->{id_note}, text => $r->{text} };
            }
            $sth->finish;
            $self->{_notes}{$key} = \@db_notes if @db_notes;
        }
    };
}

sub mbNote_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    my $text = join(' ', @args);
    $text =~ s/^\s+|\s+$//g;
    # FF5: enforce max note length (200 chars)
    if (length($text) > 200) {
        botNotice($self, $nick,
            sprintf('Note too long (%d chars, max 200). Please shorten it.', length($text)));
        return 1;
    }
    # mb456-B1: all note operations must see the persisted state after a
    # restart. mb437 loaded the DB before add/list, but export/search still
    # inspected the empty in-memory cache and falsely reported no notes.
    $self->{_notes}{lc $nick} //= [];
    _notes_ensure_loaded($self, $nick);

    # Y3: !note export — send all notes in one private message
    if ($text =~ /^export$/i) {
        my $notes = $self->{_notes}{lc $nick} // [];
        unless (@$notes) {
            botNotice($self, $nick, 'No notes to export.'); return 1;
        }
        my $export = join(' | ', map {
            my $n = $notes->[$_];
            my $txt = ref($n) eq 'HASH' ? ($n->{text} // '') : ($n // '');
            ($_ + 1) . ". $txt"
        } 0..$#$notes);
        botNotice($self, $nick, "Notes: $export");
        return 1;
    }

    # W7: !note search <mot> — search through notes
    if ($text =~ /^search\s+(.+)/i) {
        my $query = lc($1);
        my $notes = $self->{_notes}{lc $nick} // [];
        # mb460-B1: keep each hit's index in the FULL notes list. The displayed
        # [N] must match the index that `!notes del <N>` expects; numbering hits
        # positionally (1..@hits) pointed the user at the wrong note to delete
        # when the matches weren't the first notes.
        my @hits;
        for my $idx (0 .. $#$notes) {
            my $n   = $notes->[$idx];
            my $txt = ref($n) eq 'HASH' ? ($n->{text} // '') : ($n // '');
            push @hits, [ $idx, $n ] if lc($txt) =~ /\Q$query\E/;
        }

        unless (@hits) {
            botNotice($self, $nick, "No notes matching '$query'."); return 1;
        }

        # II17: show count + search term
        botNotice($self, $nick, scalar(@hits) . "/" . scalar(@$notes)
            . " note(s) matching '$query':");
        for my $h (@hits) {
            my ($idx, $n) = @$h;
            my $txt = ref($n) eq 'HASH' ? ($n->{text} // '') : ($n // '');
            # [idx+1] = position in the full list = the !notes del index
            botNotice($self, $nick, "  [" . ($idx + 1) . "] $txt");
        }
        return 1;
    }
    unless ($text ne '') {
        botNotice($self, $nick, 'Syntax: note <message>  or  note search <word>'); return;
    }
    # mb437/mb456: the persisted notes were loaded above before every
    # branch, including export/search and the add cap.
    if (scalar @{ $self->{_notes}{lc $nick} } >= 10) {
        botNotice($self, $nick, 'Max 10 notes reached. Delete some with !notes del <id>.'); return;
    }
    # BB1: persist note to DB — mb84-B8: récupérer last_insert_id pour stocker le vrai id DB
    my $db_note_id = undef;
    eval {
        my $sth = $self->{dbh}->prepare(
            'INSERT INTO NOTE (nick, text) VALUES (?, ?)'
        );
        if ($sth && $sth->execute(lc($nick), $text)) {
            $db_note_id = $self->{dbh}->last_insert_id(undef, undef, 'NOTE', 'id_note');
        }
        $sth->finish if $sth;
    };
    $self->{logger}->log(1, "BB1: NOTE insert failed: $@") if $@;
    # mb84-B8: utiliser l'id DB réel; fallback sur ordinal si INSERT a échoué
    my $note_id = $db_note_id // (scalar(@{ $self->{_notes}{lc $nick} }) + 1);
    push @{ $self->{_notes}{lc $nick} }, { id => $note_id, text => $text };
    my $n = scalar @{ $self->{_notes}{lc $nick} };
    botNotice($self, $nick, "Note saved (#$n total). Use !notes to list.");
    return 1;
}

sub mbNotes_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # BB1 / mb437-B1: load from DB if memory is empty (e.g. after restart)
    _notes_ensure_loaded($self, $nick);
    my $notes = $self->{_notes}{lc $nick} // [];

    # !notes del <index>
    if (@args && lc($args[0]) eq 'del') {
        my $idx = ($args[1] // 1) - 1;
        if ($idx >= 0 && $idx < scalar @$notes) {
            my $del_id = $notes->[$idx]{id};
            splice @$notes, $idx, 1;
            # BB1: delete from DB
            eval {
                my $sth = $self->{dbh}->prepare('DELETE FROM NOTE WHERE nick = ? AND id_note = ?');
                $sth->execute(lc($nick), $del_id) if $sth; $sth->finish if $sth;
            };
            botNotice($self, $nick, 'Note deleted.');
        } else {
            botNotice($self, $nick, 'Note not found.');
        }
        return 1;
    }

    unless (@$notes) {
        botNotice($self, $nick, 'No notes. Use !note <message> to add one.'); return 1;
    }
    botNotice($self, $nick, scalar(@$notes) . ' note(s):');
    for my $i (0 .. $#$notes) {
        botNotice($self, $nick, sprintf('  [%d] %s', $i+1, $notes->[$i]{text}));
    }
    return 1;
}

# ===========================================================================
# Factoids — shared per-channel key/value facts (mb476).
#   !learn <keyword> = <value>   store or update a fact (anyone can)
#   !whatis <keyword>            recall it (also increments a hit counter)
#   !forget <keyword>            delete it (author or channel op/admin)
#   !factoids [pattern]          list keywords (optionally filtered)
#
# Backed by the FACTOID table (unique per channel+keyword). Channel only.
# Gated by the +Factoids chanset (default on). Values are length-capped and
# newline-sanitised. Keyword is normalised to lowercase.
# ===========================================================================

# helper: resolve id_channel for the ctx channel, or undef.
sub _factoid_id_channel {
    my ($self, $channel) = @_;
    return undef unless isIrcChannelTarget($channel);
    my $cid = eval { Mediabot::Helpers::channel_id_cached($self, $channel) };
    return $cid if $cid;
    my $obj = $self->{channels}{lc $channel};
    return $obj ? (eval { $obj->get_id } || undef) : undef;
}

# helper: is the factoids feature enabled on this channel?
sub _factoid_enabled {
    my ($self, $channel) = @_;
    return eval {
        Mediabot::Helpers::chanset_enabled($self, $channel, 'Factoids', default => 1)
    } // 1;
}

sub mbLearn_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;

    unless (isIrcChannelTarget($channel)) {
        botNotice($self, $nick, "Syntax: learn <keyword> = <value>  (use it in a channel)");
        return;
    }
    return unless _factoid_enabled($self, $channel);

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
    my $raw  = join(' ', @args);
    $raw =~ s/^\s+|\s+$//g;

    # Format: <keyword> = <value>
    unless ($raw =~ /^(.+?)\s*=\s*(.+)$/) {
        botNotice($self, $nick, "Syntax: learn <keyword> = <value>");
        return;
    }
    my ($keyword, $value) = ($1, $2);
    $keyword =~ s/^\s+|\s+$//g;
    $keyword = lc $keyword;
    $value   =~ s/[\r\n\0]+/ /g;
    $value   =~ s/^\s+|\s+$//g;

    unless ($keyword =~ /^[a-z0-9_.\-]{1,64}$/) {
        botNotice($self, $nick, "learn: keyword must be 1-64 chars of letters/digits/_.- (no spaces).");
        return;
    }
    if ($value eq '') {
        botNotice($self, $nick, "learn: value cannot be empty.");
        return;
    }
    $value = truncate_utf8($value, 400, '');

    my $dbh = eval { $self->{db}->ensure_connected } // $self->{dbh};
    unless ($dbh) { botNotice($self, $nick, "learn: database unavailable."); return; }

    my $id_channel = _factoid_id_channel($self, $channel);
    unless ($id_channel) { botNotice($self, $nick, "learn: channel not known to the bot."); return; }

    my $uid = eval { my $u = $ctx->user; $u ? $u->id : undef };

    # UPSERT on (id_channel, keyword). On update, keep original author but
    # refresh value/updated_at (ON DUPLICATE preserves created_by/created_at).
    my $sth = $dbh->prepare(q{
        INSERT INTO FACTOID (id_channel, keyword, value, created_by, created_by_nick)
        VALUES (?, ?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE value = VALUES(value), updated_at = CURRENT_TIMESTAMP
    });
    unless ($sth && $sth->execute($id_channel, $keyword, $value, $uid, $nick)) {
        botNotice($self, $nick, "learn: could not store the factoid.");
        return;
    }
    $sth->finish;

    # mb668: derive community achievements from the persisted FACTOID/QUOTES
    # state. An update of an existing factoid therefore cannot inflate merit.
    if ($self->{achievements}) {
        my $ok = eval {
            $self->{achievements}->check_community_contributions(
                $nick, $channel, $uid
            );
            1;
        };
        if (!$ok && $self->{logger}) {
            my $err = $@ || 'unknown error';
            $err =~ s/[\r\n\0]+/ /g;
            $self->{logger}->log(
                1, "achievements community check after factoid learn failed: $err"
            );
        }
    }

    botNotice($self, $nick, "Learned '$keyword' for $channel.");
    $self->{metrics}->inc('mediabot_factoid_total', { channel => $channel, op => 'learn' })
        if $self->{metrics};
    return 1;
}

sub mbWhatis_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
    # mb477: "?keyword" quick recall passes a leading __quiet__ sentinel so that
    # a spontaneous "?word" stays silent when nothing is known (no syntax/error
    # spam), while an explicit "!whatis word" still gives feedback.
    my $quiet = (@args && $args[0] eq '__quiet__') ? 1 : 0;
    shift @args if $quiet;

    unless (isIrcChannelTarget($channel)) {
        botNotice($self, $nick, "Syntax: whatis <keyword>  (use it in a channel)") unless $quiet;
        return;
    }
    return unless _factoid_enabled($self, $channel);

    my $keyword = lc(join(' ', @args));
    $keyword =~ s/^\s+|\s+$//g;
    unless ($keyword ne '' && $keyword =~ /^[a-z0-9_.\-]{1,64}$/) {
        botNotice($self, $nick, "Syntax: whatis <keyword>") unless $quiet;
        return;
    }

    my $dbh = eval { $self->{db}->ensure_connected } // $self->{dbh};
    unless ($dbh) { botNotice($self, $nick, "whatis: database unavailable.") unless $quiet; return; }
    my $id_channel = _factoid_id_channel($self, $channel);
    unless ($id_channel) { botNotice($self, $nick, "whatis: channel not known to the bot.") unless $quiet; return; }

    my $sth = $dbh->prepare(q{
        SELECT value, created_by_nick FROM FACTOID
        WHERE id_channel = ? AND keyword = ? LIMIT 1
    });
    unless ($sth && $sth->execute($id_channel, $keyword)) {
        botNotice($self, $nick, "whatis: lookup failed.") unless $quiet;
        return;
    }
    my $row = $sth->fetchrow_hashref;
    $sth->finish;

    unless ($row) {
        botNotice($self, $nick, "I don't know '$keyword'. Teach me: learn $keyword = ...") unless $quiet;
        return;
    }

    # increment hit counter (best-effort, non-fatal)
    eval {
        my $up = $dbh->prepare('UPDATE FACTOID SET hits = hits + 1 WHERE id_channel = ? AND keyword = ?');
        $up->execute($id_channel, $keyword) if $up;
        $up->finish if $up;
    };

    botPrivmsg($self, $channel, "$keyword: $row->{value}");
    $self->{metrics}->inc('mediabot_factoid_total', { channel => $channel, op => 'whatis' })
        if $self->{metrics};
    return 1;
}

sub mbForget_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;

    unless (isIrcChannelTarget($channel)) {
        botNotice($self, $nick, "Syntax: forget <keyword>  (use it in a channel)");
        return;
    }
    return unless _factoid_enabled($self, $channel);

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
    my $keyword = lc(join(' ', @args));
    $keyword =~ s/^\s+|\s+$//g;
    unless ($keyword ne '' && $keyword =~ /^[a-z0-9_.\-]{1,64}$/) {
        botNotice($self, $nick, "Syntax: forget <keyword>");
        return;
    }

    my $dbh = eval { $self->{db}->ensure_connected } // $self->{dbh};
    unless ($dbh) { botNotice($self, $nick, "forget: database unavailable."); return; }
    my $id_channel = _factoid_id_channel($self, $channel);
    unless ($id_channel) { botNotice($self, $nick, "forget: channel not known to the bot."); return; }

    # who created it?
    my $sth = $dbh->prepare('SELECT created_by, created_by_nick FROM FACTOID WHERE id_channel = ? AND keyword = ? LIMIT 1');
    unless ($sth && $sth->execute($id_channel, $keyword)) {
        botNotice($self, $nick, "forget: lookup failed.");
        return;
    }
    my $row = $sth->fetchrow_hashref;
    $sth->finish;
    unless ($row) {
        botNotice($self, $nick, "I don't know '$keyword'.");
        return;
    }

    # permission: original author (by nick) OR a channel operator (by level).
    my $is_author = (defined $row->{created_by_nick} && lc($row->{created_by_nick}) eq lc($nick)) ? 1 : 0;
    my $is_op = 0;
    unless ($is_author) {
        my $handle = eval { my $u = $ctx->user; $u ? $u->nickname : undef };
        if (defined $handle && $handle ne '') {
            my (undef, $lvl) = eval { getIdUserChannelLevel($self, $handle, $channel) };
            # USER_CHANNEL.level is the per-channel scale; >=400 is operator+.
            $is_op = 1 if defined $lvl && $lvl >= 400;
        }
    }
    unless ($is_author || $is_op) {
        botNotice($self, $nick, "forget: only the author or a channel op can forget '$keyword'.");
        return;
    }

    my $del = $dbh->prepare('DELETE FROM FACTOID WHERE id_channel = ? AND keyword = ?');
    unless ($del && $del->execute($id_channel, $keyword)) {
        botNotice($self, $nick, "forget: delete failed.");
        return;
    }
    $del->finish;

    botNotice($self, $nick, "Forgot '$keyword' on $channel.");
    $self->{metrics}->inc('mediabot_factoid_total', { channel => $channel, op => 'forget' })
        if $self->{metrics};
    return 1;
}

sub mbFactoids_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;

    unless (isIrcChannelTarget($channel)) {
        botNotice($self, $nick, "Syntax: factoids [pattern]  (use it in a channel)");
        return;
    }
    return unless _factoid_enabled($self, $channel);

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
    my $pattern = lc(join(' ', @args));
    $pattern =~ s/^\s+|\s+$//g;

    my $dbh = eval { $self->{db}->ensure_connected } // $self->{dbh};
    unless ($dbh) { botNotice($self, $nick, "factoids: database unavailable."); return; }
    my $id_channel = _factoid_id_channel($self, $channel);
    unless ($id_channel) { botNotice($self, $nick, "factoids: channel not known to the bot."); return; }

    # mb478: "factoids top" — most consulted facts (uses the hits counter).
    if ($pattern eq 'top') {
        my $sth = $dbh->prepare(q{
            SELECT keyword, hits FROM FACTOID
            WHERE id_channel = ? AND hits > 0
            ORDER BY hits DESC, keyword ASC LIMIT 10
        });
        unless ($sth && $sth->execute($id_channel)) {
            botNotice($self, $nick, "factoids: listing failed.");
            return;
        }
        my @top;
        while (my ($k, $h) = $sth->fetchrow_array) { push @top, "$k ($h)"; }
        $sth->finish;
        unless (@top) {
            botNotice($self, $nick, "No factoids have been recalled yet on $channel.");
            return;
        }
        botNotice($self, $nick, "Top factoids on $channel: " . join(', ', @top));
        return 1;
    }

    my ($sql, @bind);
    if ($pattern ne '' && $pattern =~ /^[a-z0-9_.\-*?]{1,64}$/) {
        # translate glob to LIKE, escaping literal % and _
        my $like = '';
        for my $ch (split //, $pattern) {
            if    ($ch eq '*') { $like .= '%'; }
            elsif ($ch eq '?') { $like .= '_'; }
            elsif ($ch eq '%') { $like .= '\%'; }
            elsif ($ch eq '_') { $like .= '\_'; }
            else               { $like .= $ch; }
        }
        $sql  = 'SELECT keyword FROM FACTOID WHERE id_channel = ? AND keyword LIKE ? ORDER BY keyword ASC LIMIT 60';
        @bind = ($id_channel, $like);
    }
    else {
        $sql  = 'SELECT keyword FROM FACTOID WHERE id_channel = ? ORDER BY keyword ASC LIMIT 60';
        @bind = ($id_channel);
    }

    my $sth = $dbh->prepare($sql);
    unless ($sth && $sth->execute(@bind)) {
        botNotice($self, $nick, "factoids: listing failed.");
        return;
    }
    my @keys;
    while (my ($k) = $sth->fetchrow_array) { push @keys, $k; }
    $sth->finish;

    unless (@keys) {
        botNotice($self, $nick, $pattern ne ''
            ? "No factoids matching '$pattern' on $channel."
            : "No factoids on $channel yet. Add one: learn <keyword> = <value>");
        return;
    }
    botNotice($self, $nick, scalar(@keys) . " factoid(s) on $channel: " . join(', ', @keys));
    return 1;
}

# ---------------------------------------------------------------------------
# mbFactoid_ctx --- !factoid <keyword>
# mb478: detailed info about one factoid: value, author, created/updated dates,
# and how many times it has been recalled. Read-only, channel-gated.
# ---------------------------------------------------------------------------
sub mbFactoid_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;

    unless (isIrcChannelTarget($channel)) {
        botNotice($self, $nick, "Syntax: factoid <keyword>  (use it in a channel)");
        return;
    }
    return unless _factoid_enabled($self, $channel);

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
    my $keyword = lc(join(' ', @args));
    $keyword =~ s/^\s+|\s+$//g;
    unless ($keyword ne '' && $keyword =~ /^[a-z0-9_.\-]{1,64}$/) {
        botNotice($self, $nick, "Syntax: factoid <keyword>");
        return;
    }

    my $dbh = eval { $self->{db}->ensure_connected } // $self->{dbh};
    unless ($dbh) { botNotice($self, $nick, "factoid: database unavailable."); return; }
    my $id_channel = _factoid_id_channel($self, $channel);
    unless ($id_channel) { botNotice($self, $nick, "factoid: channel not known to the bot."); return; }

    my $sth = $dbh->prepare(q{
        SELECT value, created_by_nick,
               DATE_FORMAT(created_at, '%Y-%m-%d') AS created_d,
               DATE_FORMAT(updated_at, '%Y-%m-%d') AS updated_d,
               hits
        FROM FACTOID
        WHERE id_channel = ? AND keyword = ? LIMIT 1
    });
    unless ($sth && $sth->execute($id_channel, $keyword)) {
        botNotice($self, $nick, "factoid: lookup failed.");
        return;
    }
    my $row = $sth->fetchrow_hashref;
    $sth->finish;
    unless ($row) {
        botNotice($self, $nick, "I don't know '$keyword'.");
        return;
    }

    my $author  = defined($row->{created_by_nick}) && $row->{created_by_nick} ne ''
                ? $row->{created_by_nick} : 'unknown';
    my $created = $row->{created_d} // '?';
    my $updated = $row->{updated_d} // '?';
    my $hits    = $row->{hits} // 0;
    my $date_part = ($updated ne $created)
                  ? "created $created by $author, updated $updated"
                  : "created $created by $author";

    botNotice($self, $nick, "factoid '$keyword': $date_part, $hits recall(s).");
    botNotice($self, $nick, "value: $row->{value}");
    return 1;
}

1;
