# MB725 — Debian 13 must exercise the exact candidate archive and prove that
# the representative stable upgrade is both restorable and deterministic.

use strict;
use warnings;
use utf8;

sub _slurp_1043 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $workflow = _slurp_1043('.github/workflows/debian13.yml');
    my $readme = _slurp_1043('README.md');
    my $dbdoc = _slurp_1043('docs/DB_MIGRATIONS.md');
    my $release = _slurp_1043('docs/RELEASING.md');
    my $roadmap = _slurp_1043('docs/ROADMAP_3.5.md');

    $assert->like($workflow, qr/^\s*- name: Build and unpack the exact 3\.5 candidate$/m,
        'mb725: Debian 13 builds the exact candidate archive');
    $assert->like($workflow,
        qr/tools\/build_release_artifacts\.sh\s+\\.*?--version "\$CANDIDATE_VERSION"\s+\\.*?--ref "\$GITHUB_SHA"\s+\\.*?--dest "\$CANDIDATE_ARTIFACTS"\s+\\.*?"\$\{CANDIDATE_ARGS\[@\]\}"/s,
        'mb725: candidate build pins version, commit, destination and selected mode');
    $assert->like($workflow,
        qr/3\.4dev\|3\.4dev-\*\).*?CANDIDATE_ARGS=\(--rehearsal\).*?3\.5\).*?CANDIDATE_ARGS=\(\)/s,
        'mb727: Debian 13 accepts rehearsal candidates and the exact stable commit');
    $assert->like($workflow,
        qr/CANDIDATE_KIND" = rehearsal.*?Rehearsal: yes \(not publishable\).*?Rehearsal: no/s,
        'mb727: archive metadata must match the selected candidate kind');
    $assert->like($workflow, qr/sha256sum --quiet -c.*?sha512sum --quiet -c.*?gzip -t.*?xz -t/s,
        'mb725: candidate manifests and both archive formats are verified');
    $assert->like($workflow,
        qr/tar -xzf "\$CANDIDATE_ARTIFACTS\/\$\{CANDIDATE_BASE\}\.tar\.gz".*?test ! -e "\$CANDIDATE_ROOT\/\.git"/s,
        'mb725: the tested tree is extracted from the archive and contains no Git metadata');
    $assert->like($workflow, qr/MEDIABOT_CANDIDATE_ROOT=%s.*?>>"\$GITHUB_ENV"/s,
        'mb725: the extracted candidate root becomes the following steps authority');
    $assert->like($workflow,
        qr/name: Build and verify runtime Perl dependencies on Debian 13.*?cd "\$MEDIABOT_CANDIDATE_ROOT"/s,
        'mb725: dependencies are resolved from the extracted candidate');
    $assert->like($workflow,
        qr/name: Exercise fresh non-root configuration generation.*?cd "\$MEDIABOT_CANDIDATE_ROOT".*?tar -cf - \./s,
        'mb725: the fresh install tree is copied only from the extracted candidate');
    $assert->like($workflow,
        qr/bash \/home\/mediabot\/mediabot_v3\/install\/systemd_install\.sh/s,
        'mb725: systemd installation uses the extracted fresh-install tree');
    $assert->like($workflow,
        qr/name: Exercise stable 3\.3 to current database upgrade.*?cd "\$MEDIABOT_CANDIDATE_ROOT"/s,
        'mb725: current migration and drift authorities come from the extracted candidate');
    $assert->like($workflow,
        qr/git -C "\$GITHUB_WORKSPACE" (?:show|archive).*?"\$STABLE_REF"/s,
        'mb725: only stable 3.3 history is read from the checkout');

    $assert->like($workflow,
        qr/dump_upgrade_database\(\).*?mariadb-dump\s+\\\s+--defaults-extra-file="\$ROOT_CNF"\s+\\.*?--single-transaction.*?--skip-comments.*?--order-by-primary.*?--skip-extended-insert/s,
        'mb725: logical rollback evidence is private and deterministic');
    my $pre_dump = index($workflow, 'dump_upgrade_database "$PRE_UPGRADE_DUMP"');
    my $first_apply = index($workflow, 'Applying post-3.3 migration:');
    my $migrated_dump = index($workflow, 'dump_upgrade_database "$MIGRATED_DUMP"');
    $assert->ok($pre_dump >= 0 && $first_apply > $pre_dump,
        'mb725: the stable database is backed up before the first migration');
    $assert->ok($migrated_dump > $first_apply,
        'mb725: the first migrated state is captured after strict validation');
    $assert->like($workflow,
        qr/DROP DATABASE \$\{UPGRADE_DB\}.*?CREATE DATABASE \$\{UPGRADE_DB\}.*?<"\$PRE_UPGRADE_DUMP".*?dump_upgrade_database "\$ROLLBACK_REDUMP".*?cmp --silent "\$PRE_UPGRADE_DUMP" "\$ROLLBACK_REDUMP"/s,
        'mb725: rollback recreates and byte-compares the stable logical state');
    $assert->like($workflow,
        qr/ROLLBACK_DRIFT_RC=\$\?.*?test "\$ROLLBACK_DRIFT_RC" -eq 1.*?MB725_ROLLBACK=OK/s,
        'mb725: rollback also restores the expected pre-migration drift');
    $assert->like($workflow,
        qr/Reapplying post-3\.3 migration:.*?check_schema_drift\.pl --strict --types --indexes.*?dump_upgrade_database "\$REAPPLIED_DUMP".*?cmp --silent "\$MIGRATED_DUMP" "\$REAPPLIED_DUMP".*?MB725_REAPPLY=OK/s,
        'mb725: the ordered migration is replayed and produces the same final database');
    $assert->like($workflow,
        qr/cleanup_upgrade\(\).*?"\$PRE_UPGRADE_DUMP" "\$MIGRATED_DUMP".*?"\$ROLLBACK_REDUMP" "\$REAPPLIED_DUMP"/s,
        'mb725: all private disposable dumps are removed by the step trap');
    $assert->like($workflow,
        qr/name: Run Debian 13 fresh-install contracts.*?\.github is.*?export-ignored.*?cd "\$GITHUB_WORKSPACE".*?1043_/s,
        'mb725: workflow contracts remain in the checkout and include this boundary');

    $assert->like($readme,
        qr/exact\s+(?:non-publishable rehearsal )?archive.*?rollback.*?reapplication/s,
        'mb725: README documents archive identity and upgrade recovery evidence');
    $assert->like($dbdoc,
        qr/pre-upgrade logical dump.*?restored.*?byte-for-byte.*?reapplied/s,
        'mb725: database guide documents the rollback and deterministic replay');
    $assert->like($release,
        qr/^## MB725 Debian 13 candidate acceptance$/m,
        'mb725: release guide names the candidate acceptance gate');
    $assert->like($roadmap,
        qr/\| MB726 \| Complete \|.*?\n\| MB725 \| Complete \|/s,
        'mb725: roadmap records both release rehearsal and final technical gate as complete');
    $assert->unlike($workflow, qr/\bgit\s+(?:add|commit|push|tag)\b/,
        'mb725: Debian 13 acceptance never mutates Git or publishes a release');
};
