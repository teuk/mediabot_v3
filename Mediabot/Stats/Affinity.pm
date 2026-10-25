package Mediabot::Stats::Affinity;

use strict;
use warnings;
use utf8;
use Exporter 'import';
use Mediabot::Helpers ();

our @EXPORT_OK = qw(mbCompat_ctx);

# Keep call-time compatibility with the established transport and progress hooks.
sub botPrivmsg { goto &Mediabot::UserCommands::botPrivmsg }
sub botNotice  { goto &Mediabot::UserCommands::botNotice }
sub logBot     { goto &Mediabot::UserCommands::logBot }
sub _ach_progress { goto &Mediabot::UserCommands::_ach_progress }

# Channel affinity from hours, vocabulary, karma and adjacent messages.
sub mbCompat_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    unless ($channel && $channel =~ /^#/) {
        botNotice($self, $nick, 'Syntax: !compat <nick1> [nick2]  (must be in a channel)'); return;
    }

    # mb118-IMP2: gate par chanset +Games
    unless (Mediabot::Helpers::chanset_enabled($self, $channel, 'Games', default => 1)) {
        botNotice($self, $nick, "Games are disabled on $channel (chanset -Games)");
        return;
    }

    unless (@args >= 1) {
        botNotice($self, $nick, 'Syntax: !compat <nick1> [nick2]');
        return;
    }

    my $n1 = lc($args[0]);
    my $n2 = @args >= 2 ? lc($args[1]) : lc($nick);

    if ($n1 eq $n2) {
        botPrivmsg($self, $channel, "$nick: a nick has 100% compatibility with itself \x{1F9D8}");
        return 1;
    }

    my $dbh = $self->{dbh};
    # === Dimension 1 : Recouvrement horaire (24 buckets) ====================
    # mb576-B1: GROUP BY par table, les buckets s'additionnent en Perl.
    my %hours = ($n1 => [(0)x24], $n2 => [(0)x24]);
    my %total_msgs = ($n1 => 0, $n2 => 0);
    my $compat_h_g = Mediabot::Helpers::channel_log_gather($self, $dbh, q{
        SELECT cl.nick AS nick, HOUR(cl.ts) AS h, COUNT(*) AS c
        FROM __CLSRC__ cl
        JOIN CHANNEL c ON c.id_channel = cl.id_channel
        WHERE c.name = ? AND cl.nick IN (?, ?)
          AND cl.event_type IN ('public','action')
        GROUP BY cl.nick, HOUR(cl.ts)
    }, [ $channel, $n1, $n2 ], sub {
        my $r = $_[0];
        my $who = lc($r->{nick});
        return unless exists $hours{$who};
        # += : les buckets des deux tables s'additionnent (fusion mb576).
        $hours{$who}[$r->{h}] += $r->{c};
        $total_msgs{$who} += $r->{c};
    }, 'content');
    # mb578-B1: panne LIVE = echec franc — sans quoi compat pretendrait
    # qu'un nick n'a aucune activite.
    unless ($compat_h_g->{live_ok}) {
        botNotice($self, $nick, 'Database error.');
        return;
    }

    if ($total_msgs{$n1} == 0 || $total_msgs{$n2} == 0) {
        my $absent = $total_msgs{$n1} == 0 ? $n1 : $n2;
        botPrivmsg($self, $channel, "\x{1F50D} $absent: no activity recorded on $channel.");
        return 1;
    }

    # Normalise et calcule overlap (formule : 1 - 0.5*sum(|p1-p2|))
    my @p1 = map { $hours{$n1}[$_] / $total_msgs{$n1} } 0..23;
    my @p2 = map { $hours{$n2}[$_] / $total_msgs{$n2} } 0..23;
    my $diff = 0;
    $diff += abs($p1[$_] - $p2[$_]) for 0..23;
    my $hour_overlap = 1.0 - ($diff / 2.0);  # 0..1
    my $hour_score   = int($hour_overlap * 30);

    # === Dimension 2 : Vocabulaire commun (jaccard sur top 100 mots) =========
    # Fenêtre : derniers 50k msgs par nick pour rester rapide
    my %words;
    for my $who ($n1, $n2) {
        # mb576-B1: LIMIT par table puis fusion triee — l'echantillon reste
        # « les 5000 plus recents » tous volumes confondus.
        my @w_rows;
        my $compat_w_g = Mediabot::Helpers::channel_log_gather($self, $dbh, q{
            SELECT cl.publictext, cl.ts
            FROM __CLSRC__ cl
            JOIN CHANNEL c ON c.id_channel = cl.id_channel
            WHERE c.name = ? AND cl.nick = ?
              AND cl.event_type IN ('public','action')
            ORDER BY cl.ts DESC
            LIMIT 5000
        }, [ $channel, $who ], sub { push @w_rows, $_[0] }, 'content');
        # mb578-B1: le score jaccard serait faux sur un vocabulaire ampute.
        unless ($compat_w_g->{live_ok}) {
            botNotice($self, $nick, 'Database error.');
            return;
        }
        @w_rows = sort { ($b->{ts} // '') cmp ($a->{ts} // '') } @w_rows;
        splice(@w_rows, 5000) if @w_rows > 5000;
        my %w_counts;
        for my $wr (@w_rows) {
            my $txt = lc($wr->{publictext} // '');
            # mb427-B1: tokenisation byte-safe (comme mb426). publictext est
            # en OCTETS UTF-8 (DBI ne décode pas) ; l'ancien
            # s/[^\w\s\x{00C0}-\x{017F}]/ /g gardait même un octet parasite
            # (café -> "caf\xC3"). Les octets >= 0x80 comptent comme lettres.
            for my $w (split /[^0-9A-Za-z_\x80-\xFF]+/, $txt) {
                next unless length($w) >= 4;
                $w_counts{$w}++;
            }
        }
        # Garder top 100 mots
        my @top = (sort { $w_counts{$b} <=> $w_counts{$a} } keys %w_counts)[0..99];
        @top = grep { defined } @top;
        $words{$who} = { map { $_ => 1 } @top };
    }
    my $intersect = 0;
    my $union     = 0;
    my %all_words = map { $_ => 1 } (keys %{$words{$n1}}, keys %{$words{$n2}});
    for my $w (keys %all_words) {
        $union++;
        $intersect++ if $words{$n1}{$w} && $words{$n2}{$w};
    }
    my $jaccard    = $union > 0 ? $intersect / $union : 0;
    my $vocab_score = int($jaccard * 30);

    # === Dimension 3 : Échanges karma mutuels (ring buffer) =================
    my $klog = $self->{_karma_log}{$channel} // [];
    my $karma_n1_to_n2 = 0; my $karma_n2_to_n1 = 0;
    my $karma_n1_to_n2_pos = 0; my $karma_n2_to_n1_pos = 0;
    for my $e (@$klog) {
        my $from = lc($e->{from} // '');
        my $to   = lc($e->{nick} // '');
        my $delta = $e->{delta} // '';
        if    ($from eq $n1 && $to eq $n2) { $karma_n1_to_n2++; $karma_n1_to_n2_pos++ if $delta eq '+1' }
        elsif ($from eq $n2 && $to eq $n1) { $karma_n2_to_n1++; $karma_n2_to_n1_pos++ if $delta eq '+1' }
    }
    my $karma_score = 0;
    if ($karma_n1_to_n2 + $karma_n2_to_n1 > 0) {
        # Réciprocité : si les deux donnent → bonus
        my $reciprocity = ($karma_n1_to_n2 > 0 && $karma_n2_to_n1 > 0) ? 1.0 : 0.5;
        my $positivity  = ($karma_n1_to_n2_pos + $karma_n2_to_n1_pos)
                        / ($karma_n1_to_n2 + $karma_n2_to_n1);
        my $volume      = ($karma_n1_to_n2 + $karma_n2_to_n1) >= 10 ? 1.0 : (($karma_n1_to_n2 + $karma_n2_to_n1) / 10);
        $karma_score = int(20 * $reciprocity * $positivity * $volume);
    }

    # === Dimension 4 : Co-présence (msgs dans 5min suivant l'autre) ==========
    # Requête : compter les paires de messages adjacents (n1 puis n2 dans 5min, et inversement)
    my $sth_co = $dbh->prepare(q{
        SELECT cl.nick, UNIX_TIMESTAMP(cl.ts) AS u
        FROM CHANNEL_LOG cl
        JOIN CHANNEL c ON c.id_channel = cl.id_channel
        WHERE c.name = ? AND cl.nick IN (?, ?)
          AND cl.event_type IN ('public','action')
          AND cl.ts >= NOW() - INTERVAL 90 DAY
        ORDER BY cl.ts ASC
    });
    my $copresence = 0;
    if ($sth_co && $sth_co->execute($channel, $n1, $n2)) {
        my $last_nick = '';
        my $last_ts   = 0;
        while (my $r = $sth_co->fetchrow_hashref) {
            my $cur = lc($r->{nick});
            if ($last_nick ne '' && $last_nick ne $cur && ($r->{u} - $last_ts) <= 300) {
                $copresence++;
            }
            $last_nick = $cur;
            $last_ts   = $r->{u};
        }
        $sth_co->finish;
    }
    # 100 paires d'échanges proches = 20 points max
    my $copres_score = $copresence >= 100 ? 20 : int($copresence / 5);

    # === Score final =========================================================
    my $total_score = $hour_score + $vocab_score + $karma_score + $copres_score;
    $total_score = 100 if $total_score > 100;
    $total_score = 0   if $total_score < 0;

    # Interprétation
    my ($verdict, $emoji) =
          $total_score >= 85 ? ('moitiés indissociables',       "\x{1F495}")
        : $total_score >= 70 ? ('âmes sœurs IRC',               "\x{1F49E}")
        : $total_score >= 55 ? ('complices solides',            "\x{1F91D}")
        : $total_score >= 40 ? ('complices à temps partiel',    "\x{1F60A}")
        : $total_score >= 25 ? ('interactions limitées',        "\x{1F44B}")
        : $total_score >= 10 ? ('chemins qui se croisent',      "\x{1F914}")
        :                       ('deux mondes parallèles',       "\x{1F30C}");

    # Barre de progression Unicode
    my $bar_filled = int($total_score / 5);   # 0..20
    my $bar = "\x{2588}" x $bar_filled . "\x{2591}" x (20 - $bar_filled);

    botPrivmsg($self, $channel,
        sprintf("%s \x02%s\x02 \x{2194} \x02%s\x02 : \x02%d%%\x02  %s",
            $emoji, $n1, $n2, $total_score, $verdict));
    botPrivmsg($self, $channel, "  [$bar]");
    botPrivmsg($self, $channel,
        sprintf("  \x{1F551} hours %d/30  \x{B7}  \x{1F4DD} vocab %d/30  \x{B7}  "
              . "\x{2728} karma %d/20  \x{B7}  \x{1F500} co-presence %d/20",
            $hour_score, $vocab_score, $karma_score, $copres_score));

    # Détails enrichis
    my @details;
    push @details, sprintf("%d common words", $intersect) if $intersect > 0;
    push @details, sprintf("%d karma exchanges", $karma_n1_to_n2 + $karma_n2_to_n1) if ($karma_n1_to_n2 + $karma_n2_to_n1) > 0;
    push @details, sprintf("%d adjacent msg pairs (90d)", $copresence) if $copresence > 0;
    botPrivmsg($self, $channel, "  " . join("  \x{B7}  ", @details)) if @details;

    # Hook achievement (mb610-B1: progression persistante)
    $self->{_compat_count}{$nick}++;
    if ($self->{achievements}) {
        my $cnt = _ach_progress($self, 'compat', $nick, $channel)
               // ($self->{_compat_count}{$nick} // 0);
        eval { $self->{achievements}->check_compat($nick, $channel, $cnt) };
        if ($@) { $self->{logger}->log(1, "achievements check_compat error: $@") }
    }

    $self->{metrics}->inc('mediabot_compat_total', { channel => $channel }) if $self->{metrics};
    logBot($self, $ctx->message, $channel, 'compat', "$n1 vs $n2 = $total_score%");
    return 1;
}

1;
