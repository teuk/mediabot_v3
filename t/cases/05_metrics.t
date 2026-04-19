# t/cases/05_metrics.t
# =============================================================================
#  Tests unitaires de Mediabot::Metrics
#  - activation / désactivation (enabled flag)
#  - _declare, set, inc, add, get
#  - label serialization (_labels_key)
#  - render_prometheus : format, HELP/TYPE, valeurs, labels
#  - _log : niveaux symboliques et numériques (C1 fix)
#  - métriques non déclarées : appels silencieux
# =============================================================================

use strict;
use warnings;
BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../..";   # racine projet
}
use Mediabot::Metrics;
use Mediabot::Log;

return sub {
    my ($assert) = @_;

    # -------------------------------------------------------------------------
    # Helpers
    # -------------------------------------------------------------------------
    my $silent_logger = Mediabot::Log->new(debug_level => -1);

    my $make_metrics = sub {
        my (%args) = @_;
        return Mediabot::Metrics->new(
            enabled => $args{enabled} // 1,
            logger  => $args{logger}  // $silent_logger,
            # pas de loop → start_http_server() ne sera pas appelé
        );
    };

    # -------------------------------------------------------------------------
    # 1. enabled / disabled
    # -------------------------------------------------------------------------
    {
        my $m = $make_metrics->(enabled => 0);
        $assert->ok(!$m->enabled, 'disabled: enabled() retourne faux');

        # toutes les ops sont no-op quand disabled
        $assert->ok(!defined($m->get('mediabot_up')), 'disabled: get() retourne undef');
        $assert->ok(!$m->set('mediabot_up', 42),      'disabled: set() retourne faux');
        $assert->ok(!$m->inc('mediabot_up'),           'disabled: inc() retourne faux');

        my $out = $m->render_prometheus();
        $assert->like($out, qr/disabled/, 'disabled: render_prometheus indique disabled');
    }

    # -------------------------------------------------------------------------
    # 2. enabled par défaut
    # -------------------------------------------------------------------------
    {
        my $m = $make_metrics->();
        $assert->ok($m->enabled, 'enabled: enabled() retourne vrai');
    }

    # -------------------------------------------------------------------------
    # 3. _declare + set + get basiques
    # -------------------------------------------------------------------------
    {
        my $m = $make_metrics->();
        $m->declare('test_gauge', 'gauge', 'Test gauge metric');

        $assert->ok(!defined($m->get('test_gauge')), 'get avant set: undef');
        $m->set('test_gauge', 42);
        $assert->is($m->get('test_gauge'), 42, 'set/get: valeur scalaire');

        $m->set('test_gauge', 0);
        $assert->is($m->get('test_gauge'), 0, 'set 0: valeur nulle');

        $m->set('test_gauge', 99);
        $assert->is($m->get('test_gauge'), 99, 'set: écrase la valeur précédente');
    }

    # -------------------------------------------------------------------------
    # 4. inc et add
    # -------------------------------------------------------------------------
    {
        my $m = $make_metrics->();
        $m->declare('test_counter', 'counter', 'Test counter');

        $m->inc('test_counter');
        $assert->is($m->get('test_counter'), 1, 'inc: première incrémentation');

        $m->inc('test_counter');
        $m->inc('test_counter');
        $assert->is($m->get('test_counter'), 3, 'inc: trois incrémentations');

        $m->add('test_counter', 10);
        $assert->is($m->get('test_counter'), 13, 'add: ajoute une valeur');

        $m->add('test_counter', 0);
        $assert->is($m->get('test_counter'), 13, 'add 0: ne change pas la valeur');
    }

    # -------------------------------------------------------------------------
    # 5. Labels — set/get/inc avec labels
    # -------------------------------------------------------------------------
    {
        my $m = $make_metrics->();
        $m->declare('test_labelled', 'counter', 'Labelled metric');

        $m->set('test_labelled', 5,  { channel => '#foo' });
        $m->set('test_labelled', 10, { channel => '#bar' });

        $assert->is($m->get('test_labelled', { channel => '#foo' }), 5,
            'labels: get #foo');
        $assert->is($m->get('test_labelled', { channel => '#bar' }), 10,
            'labels: get #bar');
        $assert->ok(!defined($m->get('test_labelled', { channel => '#baz' })),
            'labels: get inconnu = undef');

        $m->inc('test_labelled', { channel => '#foo' });
        $assert->is($m->get('test_labelled', { channel => '#foo' }), 6,
            'labels: inc incrémente le bon label');
        $assert->is($m->get('test_labelled', { channel => '#bar' }), 10,
            'labels: inc ne touche pas les autres');
    }

    # -------------------------------------------------------------------------
    # 6. Labels multiples et ordre déterministe
    # -------------------------------------------------------------------------
    {
        my $m = $make_metrics->();
        $m->declare('test_multi_label', 'counter', 'Multi-label');

        my $labels_a = { channel => '#test', command => 'help' };
        my $labels_b = { command => 'help',  channel => '#test' };  # ordre inversé

        $m->set('test_multi_label', 7, $labels_a);
        # même clé de labels (triés alphabétiquement) → même entrée
        $assert->is($m->get('test_multi_label', $labels_b), 7,
            'labels: ordre des clés déterministe');
    }

    # -------------------------------------------------------------------------
    # 7. Métrique non déclarée — appels silencieux
    # -------------------------------------------------------------------------
    {
        my $m = $make_metrics->();

        # inc/set/add sur une métrique inconnue ne doit pas mourir
        my $r_inc = eval { $m->inc('undeclared_metric'); 1 };
        $assert->ok($r_inc, 'métrique non déclarée: inc() ne meurt pas');

        my $r_set = eval { $m->set('undeclared_metric', 42); 1 };
        $assert->ok($r_set, 'métrique non déclarée: set() ne meurt pas');

        $assert->ok(!defined($m->get('undeclared_metric')),
            'métrique non déclarée: get() retourne undef');
    }

    # -------------------------------------------------------------------------
    # 8. render_prometheus — format Prometheus text
    # -------------------------------------------------------------------------
    {
        my $m = $make_metrics->();
        $m->declare('mybot_requests_total', 'counter', 'Total requests');
        $m->declare('mybot_connected',      'gauge',   'Connection status');

        $m->set('mybot_requests_total', 42);
        $m->set('mybot_connected', 1);

        my $out = $m->render_prometheus();

        $assert->like($out, qr/# HELP mybot_requests_total Total requests/,
            'render: HELP pour counter');
        $assert->like($out, qr/# TYPE mybot_requests_total counter/,
            'render: TYPE counter');
        $assert->like($out, qr/mybot_requests_total 42/,
            'render: valeur counter');
        $assert->like($out, qr/# TYPE mybot_connected gauge/,
            'render: TYPE gauge');
        $assert->like($out, qr/mybot_connected 1/,
            'render: valeur gauge');
    }

    # -------------------------------------------------------------------------
    # 9. render_prometheus — valeurs avec labels
    # -------------------------------------------------------------------------
    {
        my $m = $make_metrics->();
        $m->declare('mybot_channel_lines', 'counter', 'Lines per channel');

        $m->set('mybot_channel_lines', 100, { channel => '#foo' });
        $m->set('mybot_channel_lines', 200, { channel => '#bar' });

        my $out = $m->render_prometheus();

        $assert->like($out, qr/mybot_channel_lines\{channel="#foo"\} 100/,
            'render: label channel=#foo');
        $assert->like($out, qr/mybot_channel_lines\{channel="#bar"\} 200/,
            'render: label channel=#bar');
    }

    # -------------------------------------------------------------------------
    # 10. render_prometheus — échappement des labels (guillemets, backslash)
    # -------------------------------------------------------------------------
    {
        my $m = $make_metrics->();
        $m->declare('mybot_escape_test', 'gauge', 'Escape test');

        $m->set('mybot_escape_test', 1, { cmd => 'say "hello"' });
        my $out = $m->render_prometheus();

        $assert->like($out, qr/cmd="say \\"hello\\""/, 'render: guillemets échappés');
    }

    # -------------------------------------------------------------------------
    # 11. render_prometheus — uptime recalculé dynamiquement
    # -------------------------------------------------------------------------
    {
        my $m = $make_metrics->();
        my $out1 = $m->render_prometheus();
        sleep(1);
        my $out2 = $m->render_prometheus();

        my ($u1) = $out1 =~ /mediabot_uptime_seconds (\d+)/;
        my ($u2) = $out2 =~ /mediabot_uptime_seconds (\d+)/;
        $assert->ok(defined $u1 && defined $u2 && $u2 >= $u1,
            'uptime: croît entre deux appels à render_prometheus');
    }

    # -------------------------------------------------------------------------
    # 12. _log — niveaux symboliques et numériques (C1 regression test)
    # -------------------------------------------------------------------------
    {
        # Logger qui capture les niveaux reçus via référence
        my @captured;
        my $cap_ref = \@captured;
        my $capture_logger = bless { cap => $cap_ref }, 'CapLog2';
        {
            no warnings qw(redefine once);
            *CapLog2::log = sub { my ($s,$lv,$msg) = @_; push @{$s->{cap}}, { level => $lv, msg => $msg } };
            *CapLog2::can = sub { 1 };
        }

        my $m = Mediabot::Metrics->new(enabled => 1, logger => $capture_logger);

        $m->_log('INFO',  'test info message');
        $m->_log('ERROR', 'test error message');
        $m->_log(0,       'test numeric 0');
        $m->_log(1,       'test numeric 1');

        $assert->ok(scalar(@captured) == 4, '_log: 4 appels capturés');

        $assert->is($captured[0]{level}, 0, '_log("INFO") → niveau 0');
        $assert->is($captured[1]{level}, 1, '_log("ERROR") → niveau 1');
        $assert->is($captured[2]{level}, 0, '_log(0) → niveau 0 inchangé');
        $assert->is($captured[3]{level}, 1, '_log(1) → niveau 1 inchangé');
    }

    # -------------------------------------------------------------------------
    # 13. set_build_info — ne meurt pas, expose 1 dans la sortie
    # -------------------------------------------------------------------------
    {
        my $m = $make_metrics->();
        eval { $m->set_build_info(version => '3.2-dev', network => 'Undernet', nick => 'mediabot') };
        $assert->ok(!$@, 'set_build_info: pas d\'exception');

        my $out = $m->render_prometheus();
        $assert->like($out, qr/mediabot_build_info\{.*version="3\.2-dev".*\} 1/,
            'set_build_info: version dans le rendu');
    }

};
