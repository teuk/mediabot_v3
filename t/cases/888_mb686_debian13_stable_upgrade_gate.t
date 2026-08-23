# t/cases/888_mb686_debian13_stable_upgrade_gate.t
# =============================================================================
# MB686 — Debian 13 CI must build a real stable-3.3 DB, preserve released
# migrations as immutable history, apply only post-3.3 migrations through the
# supported helper, and finish with strict zero drift.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;
use File::Temp qw(tempdir tempfile);

sub _slurp_888 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $workflow = _slurp_888(File::Spec->catfile('.', '.github', 'workflows', 'debian13.yml'));
    my $helper   = _slurp_888(File::Spec->catfile('.', 'install', 'db_migrate.sh'));
    my $dbdoc    = _slurp_888(File::Spec->catfile('.', 'docs', 'DB_MIGRATIONS.md'));
    my $migdoc   = _slurp_888(File::Spec->catfile('.', 'install', 'migrations', 'README.md'));
    my $readme   = _slurp_888(File::Spec->catfile('.', 'README.md'));

    $assert->like(
        $workflow,
        qr/persist-credentials:\s*false\s*\n\s*# MB686:.*?\n\s*fetch-depth:\s*0/s,
        'Debian 13 checkout fetches the stable tag without persisting credentials',
    );
    $assert->like(
        $workflow,
        qr/name:\s*Trust the Debian 13 container checkout for Git metadata reads.*?git config --global --add safe\.directory "\$GITHUB_WORKSPACE".*?git -C "\$GITHUB_WORKSPACE" rev-parse --show-toplevel/s,
        'Debian 13 container explicitly trusts and verifies only its checkout path before Git metadata reads',
    );
    $assert->unlike(
        $workflow,
        qr/^\s*git\s+config\b[^\n]*\bsafe\.directory\b\s+["']?\*["']?\s*$/m,
        'Debian 13 CI never executes wildcard safe.directory trust',
    );

    $assert->like(
        $workflow,
        qr/name:\s*Exercise stable 3\.3 to current database upgrade/,
        'workflow has a dedicated real stable-upgrade step',
    );
    $assert->like(
        $workflow,
        qr/STABLE_REF=3\.3.*?git show "\$\{STABLE_REF\}:VERSION".*?= 3\.3/s,
        'upgrade gate pins and verifies the real stable 3.3 Git identity',
    );
    $assert->like(
        $workflow,
        qr/name:\s*Exercise stable 3\.3 to current database upgrade.*?mariadbd\s+\\.*?mysqladmin\s+\\.*?ping --silent/s,
        'stable-upgrade step starts and readiness-checks its own MariaDB process',
    );
    $assert->like(
        $workflow,
        qr/git archive --format=tar "\$STABLE_REF" -- install\/mediabot\.sql install\/migrations/s,
        'stable schema and migration inventory are exported from the Git tag rather than a fixture',
    );
    $assert->like(
        $workflow,
        qr/comm -23 "\$STABLE_FILES" "\$CURRENT_FILES".*?migration present in stable 3\.3 disappeared/s,
        'gate fails if a released migration disappears',
    );
    $assert->like(
        $workflow,
        qr/stable_sha=.*?current_sha=.*?released migration was modified after stable 3\.3/s,
        'gate checksum-protects migrations already published in stable 3.3',
    );
    $assert->like(
        $workflow,
        qr/comm -13 "\$STABLE_FILES" "\$CURRENT_FILES" >"\$NEW_FILES".*?test -s "\$NEW_FILES"/s,
        'gate derives the post-3.3 migration set from real Git inventories',
    );
    $assert->like(
        $workflow,
        qr/grep -nFx "\$migration" install\/migrations\/README\.md.*?ORDERED_NEW/s,
        'post-stable migrations are ordered from the authoritative migration README',
    );
    $assert->like(
        $workflow,
        qr/CREATE DATABASE \$\{UPGRADE_DB\} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci/s,
        'gate creates a dedicated real MariaDB upgrade database',
    );
    $assert->like(
        $workflow,
        qr/"\$STABLE_ROOT\/install\/mediabot\.sql"/,
        'upgrade DB starts from the released stable schema',
    );
    $assert->like(
        $workflow,
        qr/PRE_MIGRATION_RC=\$\?.*?test "\$PRE_MIGRATION_RC" -eq 1/s,
        'current strict checker must detect drift before post-3.3 migrations',
    );
    $assert->like(
        $workflow,
        qr/chmod 0600 "\$ROOT_CNF"/,
        'CI migration credential/options file is private',
    );
    $assert->like(
        $workflow,
        qr/install\/db_migrate\.sh\s+\\\s*--defaults-extra-file "\$ROOT_CNF".*?"\$UPGRADE_DB".*?install\/migrations\/\$migration/s,
        'CI applies every post-stable migration through the real migration helper',
    );
    $assert->like(
        $workflow,
        qr/MEDIABOT_DB_SOCKET=\/run\/mysqld\/mysqld\.sock.*?check_schema_drift\.pl --strict --types --indexes/s,
        'post-migration gate finishes with the current strict schema/type/index checker',
    );
    $assert->like(
        $workflow,
        qr/-f '\^\(.*?887_\|888_.*?\)'/,
        'Debian 13 workflow includes the MB686 contract',
    );

    $assert->like(
        $helper,
        qr/--defaults-extra-file FILE/,
        'migration helper documents secure non-interactive option-file mode',
    );
    $assert->like(
        $helper,
        qr/\[ ! -f "\$DEFAULTS_EXTRA_FILE" \] \|\| \[ -L "\$DEFAULTS_EXTRA_FILE" \]/,
        'migration helper rejects missing files and symlinks',
    );
    $assert->like(
        $helper,
        qr/8#\$DEFAULTS_MODE & 077/,
        'migration helper rejects group/other permissions on the option file',
    );
    $assert->like(
        $helper,
        qr/MYSQL_CMD\+=\("--defaults-extra-file=\$DEFAULTS_EXTRA_FILE"\)/,
        'defaults-extra-file is passed as a mysql option without exposing credentials',
    );
    $assert->like(
        $helper,
        qr/else\s+MYSQL_CMD\+=\(-u "\$MYSQL_USER" -p\)/s,
        'historical interactive user/password prompt mode remains available',
    );

    # Dynamic argument-order/non-disclosure guard with a fake mysql binary.
    my $tmp = tempdir(CLEANUP => 1);
    my $bin = File::Spec->catdir($tmp, 'bin');
    mkdir $bin or die "mkdir $bin: $!";
    my $args = File::Spec->catfile($tmp, 'args.txt');
    my $fake = File::Spec->catfile($bin, 'mysql');
    open my $fh, '>', $fake or die "$fake: $!";
    print {$fh} <<'FAKE_MYSQL';
#!/usr/bin/env bash
printf '%s\n' "$@" >"$MB686_ARGS"
exit 0
FAKE_MYSQL
    close $fh;
    chmod 0755, $fake or die "chmod $fake: $!";

    my ($cfh, $cnf) = tempfile(DIR => $tmp);
    print {$cfh} "[client]\nuser=root\nsocket=/tmp/fake.sock\n";
    close $cfh;
    chmod 0600, $cnf or die "chmod $cnf: $!";

    local $ENV{PATH} = "$bin:$ENV{PATH}";
    local $ENV{MB686_ARGS} = $args;
    my $rc = system(
        'bash', 'install/db_migrate.sh',
        '--defaults-extra-file', $cnf,
        'mb686_test',
        'install/migrations/20260724_lang_chansets.sql',
    );
    $assert->is($rc >> 8, 0,
        'private defaults-file migration mode is non-interactive and succeeds with fake mysql');

    my $argv = _slurp_888($args);
    my @argv = split /\n/, $argv;
    $assert->is($argv[0], "--defaults-extra-file=$cnf",
        'mysql receives defaults-extra-file as its first option');
    $assert->unlike($argv, qr/^\-p(?:$|=)/m,
        'non-interactive migration mode never adds mysql -p');
    $assert->like($argv, qr/^--default-character-set=utf8mb4$/m,
        'migration helper keeps explicit utf8mb4 client charset');
    $assert->like($argv, qr/^mb686_test$/m,
        'migration helper targets the requested database');

    chmod 0644, $cnf or die "chmod $cnf: $!";
    my $bad_rc = system(
        'bash', 'install/db_migrate.sh',
        '--defaults-extra-file', $cnf,
        'mb686_test',
        'install/migrations/20260724_lang_chansets.sql',
    );
    $assert->ok(($bad_rc >> 8) != 0,
        'migration helper rejects a group/world-readable option file');

    $assert->like(
        $dbdoc,
        qr/^## Debian 13 stable-upgrade CI gate$/m,
        'database migration guide documents the stable-upgrade CI proof',
    );
    $assert->like(
        $dbdoc,
        qr/actual stable `3\.3` Git tag.*?strict drift checker.*?detect/s,
        'database guide explains the real stable baseline and pre-migration drift requirement',
    );
    $assert->like(
        $migdoc,
        qr/^## Released migration immutability$/m,
        'migration inventory documents released migration immutability',
    );
    $assert->like(
        $migdoc,
        qr/--defaults-extra-file \/root\/\.mediabot-mysql\.cnf/,
        'migration inventory documents secure helper automation',
    );
    $assert->like(
        $readme,
        qr/real stable\s+`3\.3` database schema from the Git tag.*?Released migration files.*?immutable/s,
        'README describes the stable upgrade and immutable-migration CI guarantees',
    );
    $assert->like(
        $readme,
        qr/manual end-to-end fresh install on a dedicated Debian 13\s+VM is still required before final 3\.5 acceptance/s,
        'README keeps the manual Debian 13 VM acceptance boundary explicit',
    );
};
