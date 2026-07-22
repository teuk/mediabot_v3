# t/cases/738_mb541_grafana_scriptbridge_dashboard.t
# =============================================================================
# mb541 — dashboard Grafana d'exemple pour les métriques du bridge (mb540),
# livré dans contrib/grafana/ selon les conventions du dépôt.
#
# La règle doc-truth de l'arc s'applique aux artefacts d'infra aussi : un
# dashboard qui référence des séries inexistantes ou une datasource en dur
# est un piège silencieux. Contrats :
#
#   [1] le fichier est du JSON strictement valide, avec title/uid/schemaVersion
#       et la variable de datasource DS_PROMETHEUS (convention du dossier) ;
#   [2] CHAQUE série mediabot_* référencée par une expr du dashboard est
#       réellement déclarée dans le code (croisement avec les declare du
#       plugin) — un renommage de métrique cassera CE test, pas le dashboard
#       en prod ;
#   [3] réciproquement, chaque série scriptbridge déclarée par le plugin est
#       utilisée par au moins un panel (le dashboard couvre tout mb540) ;
#   [4] aucune datasource en dur : toutes les références passent par la
#       variable ; aucun uid de datasource littéral ;
#   [5] les deux README (contrib/grafana, plugins/scripts) référencent le
#       fichier.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;
use JSON::PP ();

sub _slurp_738 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

my $dash_path = File::Spec->catfile('contrib', 'grafana', 'grafana_mediabot_scriptbridge_v1.json');

sub _walk_exprs_738 {
    my ($node, $out) = @_;
    if (ref($node) eq 'HASH') {
        push @$out, $node->{expr} if defined $node->{expr} && !ref($node->{expr});
        _walk_exprs_738($_, $out) for values %$node;
    }
    elsif (ref($node) eq 'ARRAY') {
        _walk_exprs_738($_, $out) for @$node;
    }
    return $out;
}

return sub {
    my ($assert) = @_;

    # ------------------------------------------------------------------
    # [1] JSON livre, non ignore, valide + identite + variable datasource
    # ------------------------------------------------------------------
    $assert->ok(-f $dash_path,
        'dashboard: fichier JSON livre dans le checkout');
    return unless -f $dash_path;

    my $not_ignored = 1;
    if (-d '.git') {
        $not_ignored = system(
            'git', 'check-ignore', '-q', '--', $dash_path
        ) != 0;
    }
    $assert->ok($not_ignored,
        'dashboard: fichier public non masque par .gitignore');

    my $raw = _slurp_738($dash_path);
    my $dash = eval { JSON::PP->new->decode($raw) };
    $assert->ok(ref($dash) eq 'HASH', 'dashboard: JSON strictement valide');
    return unless ref($dash) eq 'HASH';

    $assert->ok(($dash->{title} || '') =~ /Script Bridge/, 'dashboard: titre');
    $assert->ok(($dash->{uid} || '') eq 'mb-scriptbridge-v1', 'dashboard: uid stable');
    $assert->ok(($dash->{schemaVersion} || 0) >= 39, 'dashboard: schemaVersion moderne');
    $assert->ok(ref($dash->{panels}) eq 'ARRAY' && @{ $dash->{panels} } >= 6,
        'dashboard: au moins six panels');

    my @tvars = @{ ($dash->{templating} || {})->{list} || [] };
    $assert->ok((grep { ($_->{name} || '') eq 'DS_PROMETHEUS' && ($_->{type} || '') eq 'datasource' } @tvars) == 1,
        'dashboard: variable DS_PROMETHEUS (convention contrib/grafana)');

    # ------------------------------------------------------------------
    # [2]+[3] Croisement exprs <-> series declarees par le plugin
    # ------------------------------------------------------------------
    my $plugin_src = _slurp_738(File::Spec->catfile('Mediabot', 'Plugin', 'ScriptDryRun.pm'));
    my %declared;
    while ($plugin_src =~ /'declare',\s*'(mediabot_scriptbridge_[a-z_]+)'/g) {
        $declared{$1} = 1;
    }
    $assert->ok(scalar(keys %declared) == 5, 'plugin: cinq series declarees (base du croisement, mb551 inclus)');

    my $exprs = _walk_exprs_738($dash, []);
    $assert->ok(@$exprs >= 8, 'dashboard: au moins huit expressions PromQL');

    my %used;
    for my $expr (@$exprs) {
        while ($expr =~ /(mediabot_[a-z_]+)/g) {
            my $series = $1;
            # mb551: histogram exprs may reference _bucket/_sum/_count
            # synthetic series; try the full name first (real series can end
            # in _count too), then the stripped base name.
            unless ($declared{$series}) {
                (my $base = $series) =~ s/_(?:bucket|sum|count)\z//;
                $series = $base if $declared{$base};
            }
            $used{$series} = 1;
            $assert->ok($declared{$series},
                "expr -> code: la serie '$series' est declaree par le plugin");
        }
    }
    for my $series (sort keys %declared) {
        $assert->ok($used{$series},
            "code -> dashboard: la serie '$series' est utilisee par un panel");
    }

    my @mixed_timer_panels = grep {
        my @expr;
        _walk_exprs_738($_, \@expr);
        my $joined = join(' ', @expr);
        $joined =~ /rate\(mediabot_scriptbridge_timers_total/
            && $joined =~ /mediabot_scriptbridge_pending_timers/
    } @{ $dash->{panels} || [] };
    $assert->ok(!@mixed_timer_panels,
        'dashboard: aucun panel ne melange un taux de compteurs et un gauge absolu');

    # ------------------------------------------------------------------
    # [4] Aucune datasource en dur
    # ------------------------------------------------------------------
    my $ds_count = () = $raw =~ /"uid":\s*"\$\{DS_PROMETHEUS\}"/g;
    $assert->ok($ds_count >= 8, 'dashboard: les panels passent par la variable');
    my @hard = $raw =~ /"uid":\s*"([^"\$][^"]*)"/g;
    my @bad = grep { $_ ne 'mb-scriptbridge-v1' } @hard;
    $assert->ok(!@bad, 'dashboard: aucun uid de datasource en dur');

    # ------------------------------------------------------------------
    # [5] READMEs
    # ------------------------------------------------------------------
    my $contrib_readme = _slurp_738(File::Spec->catfile('contrib', 'grafana', 'README.md'));
    $assert->like($contrib_readme, qr/grafana_mediabot_scriptbridge_v1\.json/,
        'contrib/grafana/README: dashboard reference');

    my $plugins_readme = _slurp_738(File::Spec->catfile('plugins', 'scripts', 'README.md'));
    $assert->like($plugins_readme, qr/contrib\/grafana\/grafana_mediabot_scriptbridge_v1\.json/,
        'plugins/scripts/README: renvoi vers le dashboard');
};
