# t/cases/1018_mb718_debian13_readiness_roadmap.t
# =============================================================================
# mb718 — the public 3.5 roadmap closes the Debian 13 administrator repair,
# carries its one observed variance into the production migration gate and
# preserves least privilege plus the project's single-full release policy.
# =============================================================================

use strict;
use warnings;
use utf8;

sub _slurp_1018 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $roadmap = _slurp_1018('docs/ROADMAP_3.5.md');
    my $change  = _slurp_1018('CHANGELOG.md');

    $assert->like($roadmap, qr/^# Mediabot 3\.5 readiness roadmap$/m,
        'mb718: roadmap identifies the 3.5 readiness target');
    $assert->like($roadmap,
        qr/current stable release remains\s+3\.3.*development remains on the `3\.4dev` line/s,
        'mb718: stable and development identities remain explicit');
    $assert->like($roadmap,
        qr/No 3\.5 tag, stable version change or public release archive is made\s+implicitly/s,
        'mb718: roadmap cannot publish a release implicitly');

    for my $mb (713 .. 718) {
        $assert->like($roadmap, qr/^\| MB\Q$mb\E \| Complete\b/m,
            "mb718: MB$mb evidence is recorded as complete");
    }
    $assert->unlike($roadmap, qr/^\| MB718 \| P0 \|/m,
        'mb718: completed administrator repair is absent from the remaining path');
    $assert->like($roadmap, qr/^\| MB719 \| P0 \| Root grants are captured/m,
        'mb718: production schema work is a separate pending gate');

    $assert->like($roadmap,
        qr/normalized 52 owners, reduced 40 schema differences to zero.*restored the original 40-difference state/s,
        'mb718: clone migration and restore evidence are factual');
    $assert->like($roadmap,
        qr/does not qualify a production migration/s,
        'mb718: clone success grants no live authority');

    $assert->like($roadmap,
        qr/application database credentials least-privileged/s,
        'mb718: least privilege is a release principle');
    $assert->like($roadmap,
        qr/did not receive `CREATE`, `ALTER`,\s+`DROP`, `GRANT OPTION`/s,
        'mb718: application credentials cannot become schema administrator');
    $assert->like($roadmap,
        qr/restored `root\@localhost` to `unix_socket` authentication.*every\s+Mediabot database identity unchanged/s,
        'mb718: root socket repair and application boundary are explicit');
    $assert->like($roadmap,
        qr/normal root client, a client with\s+defaults disabled and the Debian maintenance client path all authenticated/s,
        'mb718: working administrator client paths are recorded');
    $assert->like($roadmap,
        qr/internal `access`\s+field.*`SHOW GRANTS FOR root\@localhost`/s,
        'mb718: privilege representation variance becomes an MB719 grant check');
    $assert->like($roadmap,
        qr/not a reason for\s+further MB718 host intervention/s,
        'mb718: the repair loop is explicitly closed');

    $assert->like($roadmap,
        qr/Each following round must either change the repository or\s+close one named release gate/s,
        'mb718: later rounds must produce a concrete release result');
    $assert->like($roadmap,
        qr/do not repeat a lane that\s+already passed/s,
        'mb718: existing validation evidence is reused');

    $assert->like($roadmap,
        qr/Run a full suite only when\s+the matching commit is imminent.*one final full suite/s,
        'mb718: single-full policy remains explicit');
    $assert->like($roadmap,
        qr/^\| MB726 \| Final \|.*operator gives an explicit release decision \|$/m,
        'mb718: renumbered final release still requires an operator decision');

    my @entries = $change =~ /^###\s+mb718\b.*$/gmi;
    $assert->is(scalar(@entries), 1,
        'mb718: current Unreleased changelog contains one MB718 entry');
    $assert->like($change,
        qr/### mb718 .*?database administration a host prerequisite.*?single-full policy/s,
        'mb718: changelog records the roadmap and authority boundary');
};
