# t/cases/749_mb556_scheduler_tick_timing.t
# =============================================================================
# mb556 — le quadriptyque de traçage se ferme : les ticks nommés du scheduler
# gagnent le même chrono que PRIVMSG (mb548), l'event loop (mb550) et la
# partyline (mb552) — plus AUCUN chemin ne peut traîner en silence.
#
# Contrats :
#   [1] _run_task_callback : durée observée dans le histogram {task} à
#       chaque exécution ; tâche > 1 s -> ligne SLOW SCHEDULER niveau 3
#       avec nom et durée ; tâche rapide -> observation seule, pas de log ;
#   [2] les erreurs gardent leur sémantique : un callback qui die logge
#       toujours « Scheduler: task 'x' error » niveau 1 (message nettoyé),
#       ET sa durée est observée quand même ;
#   [3] best-effort : sans metrics, seuls les logs restent, rien ne casse ;
#   [4] les DEUX modes (periodic + calendar) passent par le helper (gardes
#       statiques : plus aucun eval direct du callback hors helper) ;
#   [5] câblage : histogram déclaré dans Metrics, set_metrics injecté dans
#       mediabot.pl, panel p95 par tâche au dashboard (couvert aussi par le
#       contrat 740).
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

use Mediabot::Scheduler;

sub _slurp_749 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

{
    package L749;
    sub new { bless { lines => [] }, shift }
    sub log { my ($self, $level, $msg) = @_; push @{ $self->{lines} }, [ $level, $msg ]; 1 }
    sub at_level { my ($self, $level) = @_; grep { $_->[0] == $level } @{ $_[0]->{lines} } }
}

{
    package M749;
    sub new { bless { observed => [] }, shift }
    sub can { 1 }
    sub observe {
        my ($self, $name, $value, $labels) = @_;
        push @{ $self->{observed} }, [ $name, $value, { %{ $labels || {} } } ];
        return 1;
    }
}

return sub {
    my ($assert) = @_;

    # ------------------------------------------------------------------
    # [1] Observation + SLOW
    # ------------------------------------------------------------------
    {
        my $logger = L749->new;
        my $m = M749->new;
        my $sched = bless { logger => $logger }, 'Mediabot::Scheduler';
        $assert->ok($sched->set_metrics($m) && $sched->{metrics} == $m,
            'set_metrics: projection attachee au scheduler');

        $sched->_run_task_callback('fast_task', sub { 1 });
        $assert->ok(@{ $m->{observed} } == 1
            && $m->{observed}[0][0] eq 'mediabot_scheduler_tick_seconds'
            && $m->{observed}[0][2]{task} eq 'fast_task'
            && $m->{observed}[0][1] < 1,
            'rapide: duree observee avec le label task');
        $assert->ok(scalar($logger->at_level(3)) == 0, 'rapide: aucun log SLOW');

        $sched->_run_task_callback('slow_task', sub { select(undef, undef, undef, 1.05); 1 });
        my ($l3) = $logger->at_level(3);
        $assert->like(($l3->[1] || ''),
            qr/^SLOW SCHEDULER: task 'slow_task' took 1\.\d+s$/,
            'lent: ligne SLOW avec nom et duree');
        $assert->ok($m->{observed}[1][1] > 1.0, 'lent: duree observee aussi');
    }

    # ------------------------------------------------------------------
    # [2] Erreurs préservées
    # ------------------------------------------------------------------
    {
        my $logger = L749->new;
        my $m = M749->new;
        my $sched = bless { logger => $logger, metrics => $m }, 'Mediabot::Scheduler';

        $sched->_run_task_callback('boom', sub { die "kaboom\nline two\n" });
        my ($l1) = $logger->at_level(1);
        $assert->like(($l1->[1] || ''),
            qr/^Scheduler: task 'boom' error: kaboom line two/,
            'die: erreur logguee niveau 1, message nettoye');
        $assert->ok(@{ $m->{observed} } == 1
            && $m->{observed}[0][2]{task} eq 'boom',
            'die: la duree est observee malgre l\'erreur');
    }

    # ------------------------------------------------------------------
    # [3] Sans metrics
    # ------------------------------------------------------------------
    {
        my $logger = L749->new;
        my $sched = bless { logger => $logger }, 'Mediabot::Scheduler';
        my $ok = eval { $sched->_run_task_callback('plain', sub { 1 }); 1 };
        $assert->ok($ok, 'sans metrics: aucun crash');
        $sched->_run_task_callback('plain_slow', sub { select(undef, undef, undef, 1.05); 1 });
        $assert->ok(scalar($logger->at_level(3)) == 1, 'sans metrics: le log SLOW reste');
    }

    # ------------------------------------------------------------------
    # [4] Les deux modes passent par le helper
    # ------------------------------------------------------------------
    {
        my $src = _slurp_749(File::Spec->catfile('Mediabot', 'Scheduler.pm'));
        my $helper_calls = () = $src =~ /->_run_task_callback\(/g;
        $assert->ok($helper_calls == 2, 'helper: appele par les deux modes (periodic + calendar)');
        $assert->like($src, qr/^sub _run_task_callback \{/m, 'helper: defini');
        my $direct_evals = () = $src =~ /eval \{ \$(?:cb|current->\{cb\})->\(\) \}/g;
        $assert->ok($direct_evals == 1,
            'plus d\'eval direct du callback hors helper (le seul restant EST le helper)');
        $assert->like($src, qr/sub set_metrics/, 'set_metrics present');
    }

    # ------------------------------------------------------------------
    # [5] Câblage
    # ------------------------------------------------------------------
    {
        my $metrics_src = _slurp_749(File::Spec->catfile('Mediabot', 'Metrics.pm'));
        $assert->like($metrics_src, qr/'mediabot_scheduler_tick_seconds', 'histogram'/,
            'Metrics: histogram declare');

        my $main_src = _slurp_749('mediabot.pl');
        my $assign_pos = index($main_src, '$mediabot->{scheduler} = $scheduler;');
        my $inject_pos = index($main_src,
            '$scheduler->set_metrics($mediabot->{metrics})');
        $assert->ok($assign_pos >= 0 && $inject_pos > $assign_pos,
            'mediabot.pl: injection metrics apres construction du scheduler');
        $assert->unlike($main_src,
            qr/\$mediabot->\{scheduler\}->set_metrics\(\$mediabot->\{metrics\}\)/,
            'mediabot.pl: aucune injection morte avant construction');

        my $ov = _slurp_749(File::Spec->catfile('contrib', 'grafana', 'grafana_mediabot_overview_v1.json'));
        $assert->like($ov, qr/scheduler_tick_seconds_bucket/, 'overview: panel p95 par tache');
    }
};
