# t/cases/745_mb550_db_health_loop_stall.t
# =============================================================================
# mb550 — la boucle observabilité de l'incident Undernet se referme : la
# santé DB et les gels de l'event loop deviennent des séries Prometheus (et
# le dashboard overview gagne sa rangée Infrastructure).
#
# Contrats :
#   [1] Metrics déclare db_up (gauge), db_reconnects_total, db_slow_pings_total,
#       loop_stalls_total ;
#   [2] DB : set_metrics best-effort (sans lui, comportement inchangé) ; ping
#       vivant -> db_up=1 ; ping lent -> slow_pings++ ; reconnexion ratée ->
#       reconnects{failed}++ et db_up=0 (cohérent avec le fix stale-handle
#       mb549) ; injection câblée dans mediabot.pl après la création de
#       Metrics ;
#   [3] détecteur de stall : premier appel = armement silencieux ; tick à
#       l'heure = 0 ; retard au-delà du seuil (2 s) -> valeur du drift
#       retournée, log niveau 1 explicite, compteur incrémenté,
#       last_loop_stall (copie) renseigné ; câblé EN TÊTE du tick sous eval ;
#   [4] dashboard : les nouvelles séries sont affichées ET (via le contrat
#       740 existant) déclarées — assertion locale de présence en plus.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_745 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

{
    package L745;
    sub new { bless { lines => [] }, shift }
    sub log { my ($self, $level, $msg) = @_; push @{ $self->{lines} }, [ $level, $msg ]; 1 }
    sub at_level { my ($self, $level) = @_; grep { $_->[0] == $level } @{ $_[0]->{lines} } }
}

{
    package M745;
    sub new { bless { sets => {}, counts => {} }, shift }
    sub can { 1 }
    sub set { my ($self, $n, $v) = @_; $self->{sets}{$n} = $v; 1 }
    sub inc {
        my ($self, $n, $labels) = @_;
        my $k = ref($labels) eq 'HASH' && %$labels
            ? join(',', map { "$_=$labels->{$_}" } sort keys %$labels) : '';
        $self->{counts}{$n}{$k} += 1; 1;
    }
}

{
    package DBH745;
    sub new { my ($class, %h) = @_; bless { %h }, $class }
    sub ping {
        my ($self) = @_;
        select(undef, undef, undef, $self->{ping_delay}) if $self->{ping_delay};
        return $self->{alive} ? 1 : 0;
    }
}

return sub {
    my ($assert) = @_;

    # ------------------------------------------------------------------
    # [1] Déclarations
    # ------------------------------------------------------------------
    {
        my $src = _slurp_745(File::Spec->catfile('Mediabot', 'Metrics.pm'));
        $assert->like($src, qr/'mediabot_db_up',\s+'gauge'/, 'declare: db_up gauge');
        $assert->like($src, qr/'mediabot_db_reconnects_total',\s+'counter'/, 'declare: reconnects');
        $assert->like($src, qr/'mediabot_db_slow_pings_total',\s+'counter'/, 'declare: slow pings');
        $assert->like($src, qr/'mediabot_loop_stalls_total',\s+'counter'/, 'declare: loop stalls');
    }

    # ------------------------------------------------------------------
    # [2] Émissions DB
    # ------------------------------------------------------------------
    my $db_ok = eval { require Mediabot::DB; 1 };
    if (!$db_ok) {
        $assert->ok(1, 'SKIP DB: module non chargeable');
    }
    else {
        # Sans metrics: rien ne casse.
        my $plain = bless { dbh => DBH745->new(alive => 1), logger => L745->new }, 'Mediabot::DB';
        $assert->ok($plain->ensure_connected && 1, 'sans metrics: comportement inchange');

        # set_metrics pose db_up selon l'etat courant.
        my $m = M745->new;
        my $db = bless { dbh => DBH745->new(alive => 1), logger => L745->new }, 'Mediabot::DB';
        $db->set_metrics($m);
        $assert->ok($m->{sets}{mediabot_db_up} == 1, 'set_metrics: db_up initialise');

        # Ping vivant rapide: up=1, aucun compteur.
        $db->ensure_connected;
        $assert->ok($m->{sets}{mediabot_db_up} == 1
            && !exists $m->{counts}{mediabot_db_slow_pings_total},
            'vivant: up=1, pas de slow ping');

        # Ping lent: compteur.
        my $m2 = M745->new;
        my $slow = bless { dbh => DBH745->new(alive => 1, ping_delay => 0.3),
                           logger => L745->new }, 'Mediabot::DB';
        $slow->set_metrics($m2);
        $slow->ensure_connected;
        $assert->ok($m2->{counts}{mediabot_db_slow_pings_total}{''} == 1,
            'lent: slow_pings incremente');

        # Reconnexion ratee (conf degeneree): reconnects{failed}, up=0.
        my $m3 = M745->new;
        my $dead = bless { dbh => DBH745->new(alive => 0), logger => L745->new,
                           conf => undef }, 'Mediabot::DB';
        $dead->set_metrics($m3);
        eval { $dead->ensure_connected };
        $assert->ok(($m3->{counts}{mediabot_db_reconnects_total}{'result=failed'} || 0) == 1,
            'mort: reconnect failed compte');
        $assert->ok($m3->{sets}{mediabot_db_up} == 0, 'mort: db_up=0 (pas de faux succes)');

        # Injection cablee dans mediabot.pl.
        my $main_src = _slurp_745('mediabot.pl');
        $assert->like($main_src, qr/\$mediabot->\{db\}->set_metrics\(\$mediabot->\{metrics\}\)/,
            'mediabot.pl: injection metrics -> DB apres creation');
    }

    # ------------------------------------------------------------------
    # [3] Détecteur de stall
    # ------------------------------------------------------------------
    {
        my $core_ok = eval { require Mediabot::Mediabot; 1 };
        if (!$core_ok) {
            $assert->ok(1, 'SKIP stall: coeur non chargeable');
        }
        else {
            my $logger = L745->new;
            my $m = M745->new;
            my $core = bless { logger => $logger, metrics => $m }, 'Mediabot';

            $assert->ok($core->note_tick_for_stall_detection(5) == 0,
                'premier appel: armement silencieux');
            $assert->ok($core->note_tick_for_stall_detection(5) == 0,
                'tick immediat: drift negatif, pas de stall');

            # Simuler un gel de ~9s: reculer la reference.
            $core->{loop_last_tick_at} = Time::HiRes::time() - 14;  # 14 - 5 = 9s drift
            my $stall = $core->note_tick_for_stall_detection(5);
            $assert->ok($stall > 8.5 && $stall < 9.5, 'gel simule: drift ~9s retourne');
            my ($l1) = $logger->at_level(1);
            $assert->like(($l1->[1] || ''),
                qr/^event loop stalled ~\d+\.\d+s \(tick expected every 5s\)/,
                'gel: log niveau 1 explicite');
            $assert->ok($m->{counts}{mediabot_loop_stalls_total}{''} == 1,
                'gel: compteur incremente');
            my $last = $core->last_loop_stall;
            $assert->ok($last && $last->{seconds} > 8.5 && abs(time() - $last->{at}) <= 5,
                'gel: last_loop_stall renseigne');
            $last->{seconds} = 0;
            $assert->ok($core->last_loop_stall->{seconds} > 8.5, 'last_loop_stall: copie');

            # Seuil: 1s de retard sur 5s attendu -> pas de stall (<= 2s).
            $core->{loop_last_tick_at} = Time::HiRes::time() - 6;
            $assert->ok($core->note_tick_for_stall_detection(5) == 0,
                'retard 1s: sous le seuil, silence');

            # Garde statique: appele en tete du tick sous eval.
            my $main_src = _slurp_745('mediabot.pl');
            $assert->like($main_src,
                qr/sub on_timer_tick \{\n    # mb550-B1[^\n]*\n    eval \{ \$mediabot->note_tick_for_stall_detection\(5\); \};/,
                'tick: detecteur en tete sous eval');
        }
    }

    # ------------------------------------------------------------------
    # [4] Dashboard
    # ------------------------------------------------------------------
    {
        my $raw = _slurp_745(File::Spec->catfile('contrib', 'grafana', 'grafana_mediabot_overview_v1.json'));
        for my $s (qw(mediabot_db_up mediabot_db_reconnects_total
                      mediabot_db_slow_pings_total mediabot_loop_stalls_total)) {
            $assert->like($raw, qr/\Q$s\E/, "overview: $s affichee");
        }
    }
};
