# t/cases/397_mb161_reminder_starvation_and_first_occurrence.t
# =============================================================================
# Tests des corrections mb161 :
#
#   - B1 : deliverReminders prenait les 3 plus anciens reminders pending
#          (ORDER BY created_at ASC LIMIT 3) PUIS filtrait les [at:TS] non
#          dus en Perl. Si les 3 plus anciens etaient tous programmes dans
#          le futur (daily/weekly re-crees, 'remind in 7d'), ils
#          monopolisaient les slots a chaque appel -> famine : les
#          reminders normaux plus recents n'etaient jamais delivres.
#          Fix : scan jusqu'a 20 rows, filtrer les non-dus, livrer max 3 DUS.
#
#   - B2 : a la creation, un remind daily/weekly n'inserait AUCUN [at:TS]
#          pour la premiere occurrence -> delivre immediatement au prochain
#          message du destinataire au lieu d'attendre l'heure programmee.
#          Fix : calculer la premiere occurrence a la creation (meme logique
#          que la reinsertion dans deliverReminders).
# =============================================================================

use strict;
use warnings;

return sub {
    my ($assert) = @_;

    my $NOW = time();

    # =========================================================================
    # B1 : selection des reminders a livrer
    # =========================================================================

    # Simulation de la selection buggy : LIMIT 3 (created ASC) puis skip
    my $select_buggy = sub {
        my (@db) = @_;
        my @lim3 = @db > 3 ? @db[0..2] : @db;
        return grep {
            my $due = 1;
            $due = ($NOW >= $1) if $_->{message} =~ /\[at:(\d+)\]/;
            $due;
        } @lim3;
    };

    # Simulation de la selection fixee : scan 20, filtre, max 3 dus
    my $select_fixed = sub {
        my (@db) = @_;
        my @cand = @db > 20 ? @db[0..19] : @db;
        my @out;
        for my $r (@cand) {
            if ($r->{message} =~ /\[at:(\d+)\]/) { next if $NOW < $1; }
            push @out, $r;
            last if @out >= 3;
        }
        return @out;
    };

    # -------------------------------------------------------------------------
    # Cas 1 : famine totale — 3 anciens futurs bloquent 2 dus plus recents
    # -------------------------------------------------------------------------
    {
        my @db = (
            { id => 1, message => "[daily:09:00] [at:" . ($NOW+86000) . "] standup" },
            { id => 2, message => "[at:" . ($NOW+600000) . "] check in 7d" },
            { id => 3, message => "[weekly:1:10:00] [at:" . ($NOW+200000) . "] weekly" },
            { id => 4, message => "urgent: call charlie" },
            { id => 5, message => "buy milk" },
        );
        my @b = $select_buggy->(@db);
        my @f = $select_fixed->(@db);
        $assert->(scalar(@b) == 0,
            "B1 REGRESSION-POC: 3 anciens futurs monopolisent -> 0 delivre");
        $assert->(scalar(@f) == 2,
            "B1 FIX: les 2 reminders dus (4,5) sont delivres");
        $assert->($f[0]{id} == 4 && $f[1]{id} == 5,
            "B1 FIX: ordre created_at preserve (4 puis 5)");
    }

    # -------------------------------------------------------------------------
    # Cas 2 : limite anti-flood 3 preservee
    # -------------------------------------------------------------------------
    {
        my @db = map { { id => $_, message => "msg $_" } } 1..6;
        my @f = $select_fixed->(@db);
        $assert->(scalar(@f) == 3,
            "B1 FIX: max 3 reminders par passage (anti-flood preserve)");
        $assert->($f[0]{id} == 1 && $f[2]{id} == 3,
            "B1 FIX: les 3 PLUS ANCIENS dus en premier");
    }

    # -------------------------------------------------------------------------
    # Cas 3 : melange dus / non-dus intercales
    # -------------------------------------------------------------------------
    {
        my @db = (
            { id => 1, message => "[at:" . ($NOW+500) . "] futur1" },
            { id => 2, message => "du tout de suite" },
            { id => 3, message => "[at:" . ($NOW-10) . "] deja du (passe)" },
            { id => 4, message => "[at:" . ($NOW+900) . "] futur2" },
            { id => 5, message => "autre du" },
        );
        my @f = $select_fixed->(@db);
        $assert->(scalar(@f) == 3,
            "B1 FIX: 3 dus parmi les 5 (2 futurs skip)");
        my %got = map { $_->{id} => 1 } @f;
        $assert->($got{2} && $got{3} && $got{5},
            "B1 FIX: ids 2,3,5 delivres (1 et 4 attendent leur heure)");
    }

    # -------------------------------------------------------------------------
    # Cas 4 : compat — pas de tag [at:] du tout (cas le plus courant)
    # -------------------------------------------------------------------------
    {
        my @db = ( { id => 1, message => "simple reminder" } );
        my @b = $select_buggy->(@db);
        my @f = $select_fixed->(@db);
        $assert->(scalar(@b) == 1 && scalar(@f) == 1,
            "B1 compat: reminder sans tag delivre des les 2 versions");
    }

    # =========================================================================
    # B2 : premiere occurrence daily/weekly a la creation
    # =========================================================================

    # Calcul de la premiere occurrence daily (logique du fix)
    my $first_daily_ts = sub {
        my ($hh, $mm, $fake_now) = @_;
        my @now = localtime($fake_now);
        my $today_delta = ($hh * 3600 + $mm * 60)
                        - ($now[2] * 3600 + $now[1] * 60 + $now[0]);
        my $next_secs = $today_delta > 60 ? $today_delta : $today_delta + 86400;
        return $fake_now + $next_secs;
    };

    # Calcul de la premiere occurrence weekly (logique du fix)
    my $first_weekly_ts = sub {
        my ($target_dow, $hh, $mm, $fake_now) = @_;
        my @now     = localtime($fake_now);
        my $cur_dow = $now[6];
        my $days_ahead  = ($target_dow - $cur_dow + 7) % 7;
        my $time_offset = ($hh * 3600 + $mm * 60) - ($now[2] * 3600 + $now[1] * 60 + $now[0]);
        $days_ahead = 7 if $days_ahead == 0 && $time_offset <= 60;
        return $fake_now + ($days_ahead * 86400) + $time_offset;
    };

    # -------------------------------------------------------------------------
    # Cas 5 : daily cree APRES l'heure cible -> premiere livraison demain
    # -------------------------------------------------------------------------
    {
        # Construire un "maintenant" a 14:00:00 precis (aujourd'hui)
        my @now = localtime($NOW);
        my $now_at_14h = $NOW - ($now[2]*3600 + $now[1]*60 + $now[0]) + 14*3600;

        my $ts = $first_daily_ts->(9, 0, $now_at_14h);
        my $delta = $ts - $now_at_14h;
        # De 14:00 a 09:00 le lendemain = 19h
        $assert->($delta == 19*3600,
            "B2 FIX: daily 09:00 cree a 14:00 -> premiere livraison dans 19h (lendemain 09:00)");
        $assert->($ts > $now_at_14h,
            "B2 FIX: [at:TS] strictement futur -> pas de livraison immediate");
    }

    # -------------------------------------------------------------------------
    # Cas 6 : daily cree AVANT l'heure cible -> premiere livraison aujourd'hui
    # -------------------------------------------------------------------------
    {
        my @now = localtime($NOW);
        my $now_at_07h = $NOW - ($now[2]*3600 + $now[1]*60 + $now[0]) + 7*3600;

        my $ts = $first_daily_ts->(9, 0, $now_at_07h);
        my $delta = $ts - $now_at_07h;
        $assert->($delta == 2*3600,
            "B2 FIX: daily 09:00 cree a 07:00 -> premiere livraison dans 2h (aujourd'hui)");
    }

    # -------------------------------------------------------------------------
    # Cas 7 : regression POC — sans [at:], delivrable immediatement
    # -------------------------------------------------------------------------
    {
        my $msg_buggy = "[daily:09:00] standup";        # creation buggy
        my $due_now = ($msg_buggy =~ /\[at:(\d+)\]/) ? ($NOW >= $1 ? 1 : 0) : 1;
        $assert->($due_now == 1,
            "B2 REGRESSION-POC: daily cree sans [at:] est delivrable immediatement");

        my $future = $NOW + 3600;
        my $msg_fixed = "[daily:09:00] [at:$future] standup";   # creation fixee
        my $due_now2 = ($msg_fixed =~ /\[at:(\d+)\]/) ? ($NOW >= $1 ? 1 : 0) : 1;
        $assert->($due_now2 == 0,
            "B2 FIX: daily cree avec [at:futur] n'est PAS delivrable immediatement");
    }

    # -------------------------------------------------------------------------
    # Cas 8 : weekly meme jour, heure pas encore passee -> aujourd'hui
    # -------------------------------------------------------------------------
    {
        my @now = localtime($NOW);
        my $cur_dow = $now[6];
        my $now_at_08h = $NOW - ($now[2]*3600 + $now[1]*60 + $now[0]) + 8*3600;

        # weekly <aujourd'hui> 10:00 cree a 08:00 -> livraison a 10:00 aujourd'hui
        my $ts = $first_weekly_ts->($cur_dow, 10, 0, $now_at_08h);
        my $delta = $ts - $now_at_08h;
        $assert->($delta == 2*3600,
            "B2 FIX: weekly <today> 10:00 cree a 08:00 -> livraison dans 2h (aujourd'hui)");
    }

    # -------------------------------------------------------------------------
    # Cas 9 : weekly meme jour, heure passee -> semaine suivante
    # -------------------------------------------------------------------------
    {
        my @now = localtime($NOW);
        my $cur_dow = $now[6];
        my $now_at_15h = $NOW - ($now[2]*3600 + $now[1]*60 + $now[0]) + 15*3600;

        # weekly <aujourd'hui> 10:00 cree a 15:00 -> dans 7j - 5h
        my $ts = $first_weekly_ts->($cur_dow, 10, 0, $now_at_15h);
        my $delta = $ts - $now_at_15h;
        $assert->($delta == 7*86400 - 5*3600,
            "B2 FIX: weekly <today> 10:00 cree a 15:00 -> semaine suivante (7j - 5h)");
    }

    # -------------------------------------------------------------------------
    # Cas 10 : weekly autre jour -> nombre de jours correct
    # -------------------------------------------------------------------------
    {
        my @now = localtime($NOW);
        my $cur_dow = $now[6];
        my $target  = ($cur_dow + 3) % 7;   # dans 3 jours
        my $now_at_12h = $NOW - ($now[2]*3600 + $now[1]*60 + $now[0]) + 12*3600;

        my $ts = $first_weekly_ts->($target, 12, 0, $now_at_12h);
        my $delta = $ts - $now_at_12h;
        $assert->($delta == 3*86400,
            "B2 FIX: weekly J+3 12:00 cree a 12:00 -> exactement 3 jours");
    }

    # -------------------------------------------------------------------------
    # Cas 11 : coherence creation vs reinsertion — meme heure cible
    # -------------------------------------------------------------------------
    {
        # La reinsertion dans deliverReminders utilise la meme formule daily :
        # next_secs = today_delta > 60 ? today_delta : today_delta + 86400
        # On verifie que les deux calculs donnent le meme [at:] pour le
        # meme instant — garantit que la 1ere livraison et les suivantes
        # arrivent a la meme heure.
        my @now = localtime($NOW);
        my $now_at_10h = $NOW - ($now[2]*3600 + $now[1]*60 + $now[0]) + 10*3600;

        my $creation_ts    = $first_daily_ts->(9, 30, $now_at_10h);
        # Reinsertion (formule deliverReminders, identique)
        my @rn = localtime($now_at_10h);
        my $rd = (9*3600 + 30*60) - ($rn[2]*3600 + $rn[1]*60 + $rn[0]);
        my $reinsert_ts = $now_at_10h + ($rd > 60 ? $rd : $rd + 86400);

        $assert->($creation_ts == $reinsert_ts,
            "B2 coherence: creation et reinsertion calculent le meme [at:TS]");
    }
};
