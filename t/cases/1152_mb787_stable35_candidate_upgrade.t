# MB787 — the 3.7 candidate has an exact, fail-closed stable 3.5 lineage.
use strict;
use warnings;
use utf8;
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);

sub _write_1152 {
    my ($path, $data) = @_;
    my (undef, $directory) = File::Spec->splitpath($path);
    make_path($directory);
    open my $fh, '>:encoding(UTF-8)', $path or die "$path: $!";
    print {$fh} $data;
    close $fh or die "$path: $!";
}

sub _run_1152 {
    my ($log, @argv) = @_;
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        open STDOUT, '>:encoding(UTF-8)', $log or die "$log: $!";
        open STDERR, '>&', STDOUT or die "dup stderr: $!";
        exec { $argv[0] } @argv or die "exec $argv[0]: $!";
    }
    waitpid($pid, 0);
    return $? >> 8;
}

sub _read_1152 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;
    my $workflow = _read_1152('.github/workflows/debian13.yml');
    $assert->like($workflow, qr/Exercise stable 3\.3 to current database upgrade/,
        'historical 3.3 upgrade gate remains present');
    $assert->like($workflow,
        qr/Exercise stable 3\.5 to 3\.7 rehearsal database upgrade\n\s+if: env\.MEDIABOT_CANDIDATE_VERSION == '3\.7'/,
        '3.5 gate runs only for 3.7 rehearsal candidates');
    $assert->like($workflow,
        qr/qualify_37_upgrade\.sh"\s+\\\s+--repo "\$GITHUB_WORKSPACE"\s+\\\s+--candidate "\$MEDIABOT_CANDIDATE_ROOT"/,
        'CI uses the extracted candidate and the real Git history');

    my $temp = tempdir('mb787-lineage-XXXXXX', TMPDIR => 1, CLEANUP => 1);
    my $repo = File::Spec->catdir($temp, 'repo');
    my $candidate = File::Spec->catdir($temp, 'candidate');
    make_path("$repo/install/migrations", "$candidate/install/migrations");
    my $log = "$temp/output.log";
    my $base = '20260905_base.sql';
    my $next = '20260909_next.sql';
    my $stable_order = "## Current migration order\n\n```text\n$base\n```\n";
    my $candidate_order = "## Current migration order\n\n```text\n$base\n$next\n```\n";
    my $script = File::Spec->rel2abs('tools/qualify_37_upgrade.sh');

    _write_1152("$repo/VERSION", "3.5\n");
    _write_1152("$repo/install/mediabot.sql", "CREATE TABLE sample (id INT);\n");
    _write_1152("$repo/install/migrations/$base", "SELECT 1;\n");
    _write_1152("$repo/install/migrations/README.md", $stable_order);
    for my $args (
        ['init', '-q', $repo],
        ['-C', $repo, 'config', 'user.name', 'MB787 test'],
        ['-C', $repo, 'config', 'user.email', 'mb787@example.invalid'],
        ['-C', $repo, 'add', '.'],
        ['-C', $repo, 'commit', '-qm', 'stable 3.5'],
        ['-C', $repo, 'tag', '-am', 'stable 3.5', '3.5'],
    ) {
        my $rc = _run_1152($log, 'git', @$args);
        die "git setup failed: " . _read_1152($log) if $rc;
    }
    _write_1152("$repo/VERSION", "3.6dev-20260925_134735\n");
    _write_1152("$repo/install/migrations/$next", "SELECT 2;\n");
    _write_1152("$repo/install/migrations/README.md", $candidate_order);
    for my $args (['-C', $repo, 'add', '.'],
                  ['-C', $repo, 'commit', '-qm', 'candidate 3.7']) {
        my $rc = _run_1152($log, 'git', @$args);
        die "git candidate setup failed: " . _read_1152($log) if $rc;
    }
    _write_1152("$candidate/VERSION", "3.6dev-20260925_134735\n");
    _write_1152("$candidate/install/mediabot.sql", "CREATE TABLE sample (id INT);\n");
    _write_1152("$candidate/install/migrations/$base", "SELECT 1;\n");
    _write_1152("$candidate/install/migrations/$next", "SELECT 2;\n");
    _write_1152("$candidate/install/migrations/README.md", $candidate_order);
    my @invocation = ('bash', $script, '--repo', $repo, '--candidate', $candidate,
        '--lineage-only');
    # The real workflows inject GITHUB_SHA for their own checkout. A disposable
    # fixture has a different HEAD and must still validate in lineage-only mode.
    local $ENV{GITHUB_SHA} = 'f' x 40;
    my $rc = _run_1152($log, @invocation);
    $assert->is($rc, 0, 'released and candidate migration histories align');
    $assert->like(_read_1152($log), qr/MB787_LINEAGE=OK stable=3\.5.*migrations=1\n\Q$next\E\n/,
        'only the newly ordered migration is selected');
    $assert->ok(_run_1152($log, 'bash', $script, '--repo', $repo,
            '--candidate', $candidate) != 0,
        'a local lineage check cannot start the database trial');

    _write_1152("$candidate/install/migrations/$base", "SELECT 99;\n");
    $assert->ok(_run_1152($log, @invocation) != 0,
        'rewriting a released 3.5 migration fails closed');
    _write_1152("$candidate/install/migrations/$base", "SELECT 1;\n");

    _write_1152("$candidate/install/migrations/README.md",
        "## Current migration order\n\n```text\n$base\n$next\n$next\n```\n");
    $assert->ok(_run_1152($log, @invocation) != 0,
        'duplicate public migration order fails closed');
    _write_1152("$candidate/install/migrations/README.md", $candidate_order);

    _write_1152("$candidate/install/migrations/unlisted.sql", "SELECT 3;\n");
    $assert->ok(_run_1152($log, @invocation) != 0,
        'an unlisted candidate SQL migration fails closed');
    unlink "$candidate/install/migrations/unlisted.sql" or die $!;

    unlink "$candidate/install/migrations/$base" or die $!;
    $assert->ok(_run_1152($log, @invocation) != 0,
        'missing released 3.5 migration fails closed');
    _write_1152("$candidate/install/migrations/$base", "SELECT 1;\n");

    _write_1152("$candidate/VERSION", "3.5\n");
    $assert->ok(_run_1152($log, @invocation) != 0,
        'stable-version archive cannot masquerade as a rehearsal');
};
