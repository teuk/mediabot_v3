# t/cases/746_mb551_latency_histograms.t
# =============================================================================
# mb551 — le type histogram entre dans Metrics, et deux latences deviennent
# des distributions : le traitement PRIVMSG bout-en-bout et les runs du
# bridge par origine. Grafana passe du seuil binaire (SLOW > 1 s) aux
# quantiles p50/p95.
#
# Contrats :
#   [1] type histogram : declare avec buckets (tri/dédup/validation, défauts
#       latence si absents), observe (no-op sur non-histogram/garbage),
#       rendu Prometheus : _bucket CUMULÉS dans l'ordre, le="+Inf", _sum,
#       _count — avec et sans labels ;
#   [2] ScriptRunner mesure duration_s (HiRes) sur run réel, y compris plan
#       refusé ;
#   [3] le bridge observe mediabot_scriptbridge_run_seconds{origin} quand la
#       durée est disponible (fake metrics avec observe) ;
#   [4] le wrapper PRIVMSG observe la distribution (garde statique) et le
#       histogram core est déclaré ;
#   [5] dashboards : quantiles présents, et les contrats 738/740 évolués
#       (suffixes _bucket normalisés) restent verts — vérifié par la suite.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;
use File::Temp qw(tempdir);

use Mediabot::Metrics;
use Mediabot::ScriptRunner;

sub _slurp_746 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

{ package L746; sub new { bless {}, shift } sub log { 1 } }

return sub {
    my ($assert) = @_;

    # ------------------------------------------------------------------
    # [1] Type histogram complet
    # ------------------------------------------------------------------
    {
        my $m = Mediabot::Metrics->new(enabled => 1, logger => L746->new);

        $m->declare('t_lat_seconds', 'histogram', 'test latency',
            buckets => [ 1, '0.5', 1, 'garbage', -3, 2 ]);
        my $entry = $m->{metrics}{t_lat_seconds};
        $assert->ok(join(',', @{ $entry->{buckets} }) eq '0.5,1,2',
            'declare: buckets tries, dedupliques, valides');

        $m->declare('t_default_seconds', 'histogram', 'defaults');
        $assert->ok(scalar @{ $m->{metrics}{t_default_seconds}{buckets} } == 9,
            'declare: buckets par defaut (latence)');
        $m->declare('t_exp_seconds', 'histogram', 'scientific buckets',
            buckets => [ '1e-7', '1e-3' ]);
        $assert->ok(scalar @{ $m->{metrics}{t_exp_seconds}{buckets} } == 2,
            'declare: bornes en notation scientifique acceptees');

        $m->observe('t_default_seconds', 1e-7);
        $m->observe('t_lat_seconds', 0.3);
        $m->observe('t_lat_seconds', 0.75);
        $m->observe('t_lat_seconds', 1.5);
        $m->observe('t_lat_seconds', 99);
        $m->observe('t_lat_seconds', 'garbage');
        $m->observe('absent_metric', 1);
        $m->observe('t_lat_seconds', 0.6, { origin => 'x' });

        delete $m->{_render_cache};
        my $out = $m->render_prometheus;

        $assert->like($out, qr/# TYPE t_lat_seconds histogram/, 'rendu: TYPE histogram');
        $assert->like($out, qr/^t_lat_seconds_bucket\{le="0\.5"\} 1$/m, 'rendu: bucket 0.5 = 1');
        $assert->like($out, qr/^t_lat_seconds_bucket\{le="1"\} 2$/m, 'rendu: bucket 1 CUMULE = 2');
        $assert->like($out, qr/^t_lat_seconds_bucket\{le="2"\} 3$/m, 'rendu: bucket 2 cumule = 3');
        $assert->like($out, qr/^t_lat_seconds_bucket\{le="\+Inf"\} 4$/m, 'rendu: +Inf = total 4');
        $assert->like($out, qr/^t_lat_seconds_count 4$/m, 'rendu: count sans labels');
        my ($sum) = $out =~ /^t_lat_seconds_sum (\S+)$/m;
        $assert->ok(defined $sum && abs($sum - 101.55) < 0.001, 'rendu: sum exact');

        $assert->like($out, qr/^t_lat_seconds_bucket\{origin="x",le="1"\} 1$/m,
            'rendu: labels + le combines');
        $assert->like($out, qr/^t_lat_seconds_count\{origin="x"\} 1$/m,
            'rendu: count par labelset');
        $assert->like($out, qr/^t_default_seconds_count 1$/m,
            'observe: duree HiRes en notation scientifique conservee');
    }

    # ------------------------------------------------------------------
    # [2] ScriptRunner mesure la durée
    # ------------------------------------------------------------------
    {
        my $dir = tempdir('mediabot_mb551_XXXXXX', TMPDIR => 1, CLEANUP => 1);
        my $path = File::Spec->catfile($dir, 'quick.pl');
        open my $fh, '>:encoding(UTF-8)', $path or die $!;
        print {$fh} <<'FIX';
#!/usr/bin/env perl
use strict; use warnings;
use JSON::PP qw(encode_json);
print encode_json({ protocol => 'mediabot-script-v1', ok => JSON::PP::true,
    actions => [ { type => 'log', level => 'info', text => 'hi' } ] });
FIX
        close $fh;

        my $runner = Mediabot::ScriptRunner->new(script_dir => $dir, timeout => 5);
        my $r = $runner->run_script('quick.pl', 'public_command',
            channel => '#x', target => '#x', nick => 'n', args => []);
        $assert->ok($r->{ok} && defined $r->{duration_s}
            && $r->{duration_s} > 0 && $r->{duration_s} < 5,
            'run reel: duration_s mesure');

        my $bad = $runner->run_script('missing.pl', 'public_command',
            channel => '#x', target => '#x', nick => 'n', args => []);
        $assert->ok(!$bad->{ok} && defined $bad->{duration_s},
            'plan refuse: duration_s present aussi');
    }

    # ------------------------------------------------------------------
    # [3] + [4] Câblage bridge et PRIVMSG
    # ------------------------------------------------------------------
    {
        my $plugin_src = _slurp_746(File::Spec->catfile('Mediabot', 'Plugin', 'ScriptDryRun.pm'));
        $assert->like($plugin_src,
            qr/'declare', 'mediabot_scriptbridge_run_seconds', 'histogram'/,
            'bridge: histogram declare avec buckets');
        $assert->like($plugin_src,
            qr/'observe', 'mediabot_scriptbridge_run_seconds',\n\s+\$duration, \{ origin => \$origin \}/,
            'bridge: observe par origine quand la duree existe');

        my $metrics_src = _slurp_746(File::Spec->catfile('Mediabot', 'Metrics.pm'));
        $assert->like($metrics_src,
            qr/'mediabot_privmsg_processing_seconds', 'histogram'/,
            'core: histogram PRIVMSG declare');

        my $main_src = _slurp_746('mediabot.pl');
        $assert->like($main_src,
            qr/observe\('mediabot_privmsg_processing_seconds', \$elapsed_548\)/,
            'wrapper: distribution alimentee a chaque PRIVMSG');
    }

    # ------------------------------------------------------------------
    # [5] Dashboards : quantiles
    # ------------------------------------------------------------------
    {
        my $ov = _slurp_746(File::Spec->catfile('contrib', 'grafana', 'grafana_mediabot_overview_v1.json'));
        $assert->like($ov, qr/histogram_quantile\(0\.95.*privmsg_processing_seconds_bucket/s,
            'overview: p95 PRIVMSG');
        my $sb = _slurp_746(File::Spec->catfile('contrib', 'grafana', 'grafana_mediabot_scriptbridge_v1.json'));
        $assert->like($sb, qr/histogram_quantile\(0\.95.*scriptbridge_run_seconds_bucket/s,
            'scriptbridge: p95 par origine');
    }
};
