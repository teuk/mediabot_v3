package Mediabot::Users::AchievementView;

use strict;
use warnings;
use utf8;
use Exporter 'import';

our @EXPORT_OK = qw(mbAchievements_ctx _ach_bar _ach_num _ach_goal_line);

# Keep the historical facade's transport hooks replaceable after either load order.
sub botNotice  { goto &Mediabot::UserCommands::botNotice }
sub botPrivmsg { goto &Mediabot::UserCommands::botPrivmsg }

# ---------------------------------------------------------------------------
# mbAchievements_ctx --- !achievements [nick|list|all|top]
# ---------------------------------------------------------------------------
# mb612-B1: barre de progression compacte, sûre pour IRC (12 cases, pas de
# caractere large qui casse l'alignement selon le client).
sub _ach_bar {
    my ($pct) = @_;
    $pct = 0   unless defined $pct && $pct =~ /\A\d+\z/;
    $pct = 100 if $pct > 100;
    my $filled = int(($pct * 12) / 100);
    return "\x02[\x02" . ('=' x $filled) . ('.' x (12 - $filled)) . "\x02]\x02";
}

# Nombres lisibles : 137, 1.2k, 45k, 150k.
sub _ach_num {
    my ($n) = @_;
    return 0 unless defined $n;
    return $n if $n < 1000;
    return sprintf('%.1fk', $n / 1000) =~ s/\.0k\z/k/r if $n < 100_000;
    return int($n / 1000) . 'k';
}

# Une ligne d'objectif : emoji, nom colore par rarete, valeurs, pourcentage.
sub _ach_goal_line {
    my ($ach, $defs, $g) = @_;
    my $a   = $defs->{ $g->{id} } or return '';
    my $col = $ach->rarity_color($a->{rarity});
    my $rst = $col ? "\x0f" : '';
    return sprintf('%s %s%s%s %s/%s (%d%%)',
        $a->{emoji}, $col, $a->{name}, $rst,
        _ach_num($g->{current}), _ach_num($g->{threshold}), $g->{pct});
}

sub mbAchievements_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    my $ach = $self->{achievements};
    unless ($ach) {
        botNotice($self, $nick, 'Achievements system not initialized.'); return;
    }

    my $defs = $ach->list_definitions;

    # !achievements list  → liste tous les achievements possibles
    if (@args && lc($args[0]) eq 'list') {
        my @order = qw(common uncommon rare epic legendary);
        my %by_rarity;
        for my $id (keys %$defs) {
            next if $defs->{$id}{hidden};   # mb658: secrets reveal themselves only on unlock
            push @{ $by_rarity{ $defs->{$id}{rarity} } }, $id;
        }
        for my $r (@order) {
            next unless $by_rarity{$r};
            my $col = $ach->rarity_color($r);
            my $rst = $col ? "\x0f" : '';
            my $count = scalar @{ $by_rarity{$r} };
            botPrivmsg($self, $nick, "${col}\x02" . uc($r) . "\x02${rst} ($count):");
            for my $id (sort @{ $by_rarity{$r} }) {
                my $a = $defs->{$id};
                botPrivmsg($self, $nick,
                    "  $a->{emoji} \x02$a->{name}\x02 — $a->{desc}");
            }
        }
        my $visible_total = scalar grep { !$defs->{$_}{hidden} } keys %$defs;
        botPrivmsg($self, $nick,
            "Total: $visible_total visible achievements available. "
          . "🔒 Secret achievements are revealed only when unlocked.");
        return 1;
    }

    # !achievements top  → classement par nombre d'achievements
    if (@args && lc($args[0]) eq 'top') {
        my $counts = $ach->count_all_nicks;
        unless (%$counts) {
            botPrivmsg($self, $channel, 'No achievements unlocked yet.'); return 1;
        }
        my @sorted = sort { $counts->{$b} <=> $counts->{$a} || $a cmp $b } keys %$counts;
        my $top    = scalar @sorted > 10 ? 10 : scalar @sorted;
        my @parts;
        for my $i (0..$top-1) {
            my $n = $sorted[$i];
            push @parts, "$n:$counts->{$n}";
        }
        botPrivmsg($self, $channel, "🏆 Top achievement hunters: " . join('  |  ', @parts));
        return 1;
    }

    # mb612-B1: !achievements progress [nick] → la grille MESURABLE, du plus
    # proche au plus lointain. Repond en notice (c'est une vue detaillee),
    # sauf si l'appelant demande explicitement le canal.
    if (@args && lc($args[0]) =~ /\A(?:progress|prog)\z/) {
        shift @args;
        my $who = @args ? lc(shift @args) : lc($nick);
        unless ($channel && $channel =~ /^#/) {
            botNotice($self, $nick, 'Syntax: !achievements progress [nick]  (in a channel)');
            return 1;
        }
        my $snap = $ach->progress_snapshot($who, $channel);
        # mb658: locked secrets must not leak through names, conditions,
        # thresholds, percentages or even a progress-bar row. Once unlocked,
        # they become ordinary visible achievements.
        my @visible = grep { !$snap->{$_}{hidden} || $snap->{$_}{unlocked} }
                      keys %$snap;
        my @locked = grep {
            !$snap->{$_}{unlocked}
            && !$snap->{$_}{hidden}
            && $snap->{$_}{measurable}
        } keys %$snap;
        my $done = grep { $snap->{$_}{unlocked} } @visible;
        unless (@locked) {
            botNotice($self, $nick,
                "$who has unlocked every visible measurable achievement on $channel. Nothing left to chase.");
            return 1;
        }
        my @sorted = sort {
            ($snap->{$b}{pct} <=> $snap->{$a}{pct})
            || ($snap->{$a}{threshold} <=> $snap->{$b}{threshold})
            || ($a cmp $b)
        } @locked;
        # Emoji litteral, comme partout ailleurs dans ce fichier : un
        # \x{...} rend la chaine « wide » et l'accent du tiret cadratin
        # ressortait alors en mojibake sur le canal.
        botNotice($self, $nick, sprintf('📊 %s on %s — %d/%d visible unlocked, %d in progress:',
            "\x02$who\x02", $channel, $done, scalar(@visible), scalar @sorted));
        my $shown = 0;
        for my $id (@sorted) {
            last if $shown >= 12;   # une notice par ligne : on borne le flood
            my $g = { id => $id, %{ $snap->{$id} } };
            botNotice($self, $nick,
                '  ' . _ach_bar($g->{pct}) . ' ' . _ach_goal_line($ach, $defs, $g));
            $shown++;
        }
        botNotice($self, $nick, sprintf('  ... and %d more (never started).',
            scalar(@sorted) - $shown)) if @sorted > $shown;
        return 1;
    }

    # !achievements all [nick]  → cross-canal
    my $cross = 0;
    if (@args && lc($args[0]) eq 'all') {
        $cross = 1; shift @args;
    }
    my $target = @args ? lc(shift @args) : lc($nick);

    my $unlocked = $cross
        ? $ach->get_for_nick_all($target)
        : $ach->get_for_nick($target, $channel);

    my $reply_to = ($channel =~ /^#/) ? $channel : $nick;

    unless (%$unlocked) {
        my $scope = $cross ? '(all channels)' : "on $channel";
        botPrivmsg($self, $reply_to,
            "$target has no achievements unlocked yet $scope. Try \x02!achievements list\x02.");
        # mb612-B1: « rien de debloque » est justement le moment ou montrer
        # ce qui est a portee — sinon la commande ne dit rien d'utile.
        if (!$cross && $channel =~ /^#/) {
            my $goals = eval { $ach->next_goals($target, $channel, 3) } || [];
            my @lines = grep { length } map { _ach_goal_line($ach, $defs, $_) } @$goals;
            botPrivmsg($self, $reply_to, '  Closest: ' . join('  |  ', @lines)) if @lines;
        }
        return 1;
    }

    # Ordre d'affichage : par rareté décroissante
    my %rarity_rank = (legendary => 5, epic => 4, rare => 3, uncommon => 2, common => 1);
    my @sorted_ids = sort {
        ($rarity_rank{ $defs->{$b}{rarity} // 'common' } // 0)
        <=>
        ($rarity_rank{ $defs->{$a}{rarity} // 'common' } // 0)
        || $a cmp $b
    } keys %$unlocked;

    my $scope_str = $cross ? ' (all channels)' : '';
    my $visible_total = scalar grep {
        !$defs->{$_}{hidden} || exists $unlocked->{$_}
    } keys %$defs;
    botPrivmsg($self, $reply_to,
        "🏆 \x02$target\x02 — " . scalar(@sorted_ids) . " / " . $visible_total
        . " visible achievements$scope_str:");

    # Afficher par groupes de 4 par ligne pour ne pas flooder
    my @cells;
    for my $id (@sorted_ids) {
        my $a   = $defs->{$id} or next;
        my $col = $ach->rarity_color($a->{rarity});
        my $rst = $col ? "\x0f" : '';
        push @cells, "$a->{emoji} ${col}$a->{name}${rst}";
    }
    while (@cells) {
        my @chunk = splice(@cells, 0, 4);
        botPrivmsg($self, $reply_to, '  ' . join('  |  ', @chunk));
    }

    # mb612-B1: et la suite ? Les 3 objectifs verrouilles les plus proches,
    # sur une seule ligne. Vue cross-canal exclue : la progression se compte
    # par canal, l'afficher a cote d'un total cross-canal serait trompeur.
    if (!$cross && $channel =~ /^#/) {
        my $goals = eval { $ach->next_goals($target, $channel, 3) } || [];
        my @lines = grep { length } map { _ach_goal_line($ach, $defs, $_) } @$goals;
        if (@lines) {
            botPrivmsg($self, $reply_to, '  Next: ' . join('  |  ', @lines));
            botPrivmsg($self, $reply_to,
                "  (\x02!achievements progress\x02 for the full ladder)");
        }
    }
    return 1;
}

1;
