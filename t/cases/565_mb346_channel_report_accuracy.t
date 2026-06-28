# t/cases/565_mb346_channel_report_accuracy.t
# =============================================================================
# mb346 — Exactitude des rapports daily/weekly.
#
# Deux données étaient fausses :
#  1) "Top speakers" comptait COUNT(*) sur CHANNEL_LOG sans filtrer event_type :
#     join/part/quit/mode/kick/notice étaient comptés comme des messages.
#     -> on filtre event_type IN ('public','action') (convention !words/seen).
#  2) "Top karma" lisait KARMA.score (cumul ALL-TIME) sous une étiquette
#     "Daily"/"Weekly" : aucune borne de temps. -> on somme les deltas horodatés
#     de KARMA_LOG sur la fenêtre (24h / 7j).
#
# Pas de DBI/SQLite réel dans le bac à sable : on valide (a) la SÉMANTIQUE par
# une simulation pure-Perl qui montre l'écart ancienne/nouvelle approche, et
# (b) la présence des bonnes clauses SQL dans mediabot.pl.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;
use List::Util qw(sum0);

# --- Sémantique "speakers" -------------------------------------------------
# CHANNEL_LOG fixture : [nick, event_type]
sub _speakers_old { # COUNT(*) tous événements
    my ($rows) = @_;
    my %c; $c{$_->[0]}++ for @$rows;
    return \%c;
}
sub _speakers_new { # event_type IN ('public','action')
    my ($rows) = @_;
    my %c;
    for (@$rows) { $c{$_->[0]}++ if $_->[1] eq 'public' || $_->[1] eq 'action'; }
    return \%c;
}

# --- Sémantique "karma" ----------------------------------------------------
# KARMA_LOG fixture : [nick, delta, age_days]  (age en jours dans le passé)
# KARMA (cumul) fixture : { nick => score_all_time }
sub _karma_old { # ancien : score cumulé all-time
    my ($cum) = @_;
    return { %$cum };
}
sub _karma_new { # nouveau : SUM(delta) sur la fenêtre window_days
    my ($log, $window_days) = @_;
    my %net;
    for (@$log) {
        next unless $_->[2] <= $window_days;   # ts >= NOW() - INTERVAL window
        $net{$_->[0]} += $_->[1];
    }
    delete $net{$_} for grep { $net{$_} == 0 } keys %net;   # HAVING net <> 0
    return \%net;
}

sub _slurp_565 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    # === 1. Speakers : les événements non-message ne doivent pas compter ===
    my @clog = (
        ['alice','public'], ['alice','public'], ['alice','action'],   # alice: 3 vrais
        ['bob','join'], ['bob','part'], ['bob','join'], ['bob','quit'],# bob: 0 message, 4 events
        ['bob','public'],                                              # bob: 1 vrai
        ['carol','mode'], ['carol','kick'],                           # carol: 0 message
    );
    my $old_sp = _speakers_old(\@clog);
    my $new_sp = _speakers_new(\@clog);

    # Ancien : bob gonflé à 5 (join/part/quit + 1 public), carol 2, alice 3
    $assert->is($old_sp->{bob}, 5, 'témoin: ancien compte gonfle bob (events non-message)');
    $assert->is($old_sp->{carol}, 2, 'témoin: ancien compte carol qui n\'a rien dit');
    # Nouveau : seuls les public/action
    $assert->is($new_sp->{alice}, 3, 'nouveau: alice 3 vrais messages');
    $assert->is($new_sp->{bob}, 1, 'nouveau: bob 1 vrai message (pas 5)');
    $assert->ok(!exists $new_sp->{carol}, 'nouveau: carol absente (0 message)');

    # === 2. Karma : variation de la fenêtre, pas le cumul all-time ===
    # KARMA_LOG : dan +1 il y a 2j, +1 il y a 0.5j ; eve -1 il y a 0.5j ;
    #             frank +1 il y a 30j (hors fenêtre 7j)
    my @klog = (
        ['dan',  +1, 2],
        ['dan',  +1, 0.5],
        ['eve',  -1, 0.5],
        ['frank',+1, 30],
    );
    # KARMA cumulatif all-time (ce que l'ancien rapport montrait)
    my %cum = ( dan => 50, eve => 40, frank => 999 );

    my $old_k = _karma_old(\%cum);
    my $new_k7 = _karma_new(\@klog, 7);    # weekly
    my $new_k1 = _karma_new(\@klog, 1);    # daily (24h)

    # Ancien : frank domine avec 999 (cumul), alors qu'il n'a rien fait cette semaine
    $assert->is($old_k->{frank}, 999, 'témoin: ancien karma montre le cumul all-time (999)');
    # Nouveau 7j : dan +2, eve -1, frank ABSENT (hors fenêtre)
    $assert->is($new_k7->{dan}, 2, 'weekly: dan net +2 sur 7j');
    $assert->is($new_k7->{eve}, -1, 'weekly: eve net -1 sur 7j (négatif inclus)');
    $assert->ok(!exists $new_k7->{frank}, 'weekly: frank exclu (changement hors 7j)');
    # Nouveau 24h : dan +1 (seul l'évènement à 0.5j compte), eve -1
    $assert->is($new_k1->{dan}, 1, 'daily: dan net +1 sur 24h');
    $assert->is($new_k1->{eve}, -1, 'daily: eve net -1 sur 24h');

    # === 3. Scan de source mediabot.pl ===
    my $src = _slurp_565(File::Spec->catfile('.', 'mediabot.pl'));

    my ($daily) = $src =~ /(name\s*=>\s*'daily_channel_report'.*?autostart)/s;
    $daily //= '';
    $assert->like($daily, qr/event_type IN \('public','action'\)/, 'daily speakers: filtre event_type');
    $assert->like($daily, qr/FROM KARMA_LOG/,                        'daily karma: utilise KARMA_LOG');
    $assert->like($daily, qr/SUM\(delta\)\s+AS\s+net/,              'daily karma: SUM(delta)');
    $assert->like($daily, qr/INTERVAL 1 DAY/,                        'daily karma: fenêtre 24h');

    my ($weekly) = $src =~ /(name\s*=>\s*'weekly_channel_report'.*?autostart)/s;
    $weekly //= '';
    $assert->like($weekly, qr/event_type IN \('public','action'\)/, 'weekly speakers: filtre event_type');
    $assert->like($weekly, qr/FROM KARMA_LOG kl/,                    'weekly karma: utilise KARMA_LOG');
    $assert->like($weekly, qr/SUM\(kl\.delta\)\s+AS\s+net/,         'weekly karma: SUM(delta)');
    $assert->like($weekly, qr/kl\.ts >= NOW\(\) - INTERVAL 7 DAY/,  'weekly karma: fenêtre 7j');
    $assert->unlike($weekly, qr/SELECT k\.nick, k\.score FROM KARMA k/, 'weekly karma: plus de cumul all-time');

    $assert->like($src, qr/mb346-B1/, 'tag mb346-B1 présent');
};
