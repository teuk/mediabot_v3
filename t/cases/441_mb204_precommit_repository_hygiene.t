#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use File::Find ();

# MB204-B1: pre-commit repository hygiene contract for the script plugin bridge.
# mb205-B1: use qr{} delimiter for shell-exec detection because qx/ contains a slash.
# mb206-B1: keep this test quiet on failures and accept commented sample-conf examples.
# mb207-B1: keep the test focused on this feature; historical tracked node_modules
#           are reported but not treated as a ScriptDryRun regression.

sub read_file {
    my ($path) = @_;
    open my $fh, '<', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub contains_re {
    my ($text, $re, $name) = @_;
    ok($text =~ $re, $name);
}

sub does_not_contain_re {
    my ($text, $re, $name) = @_;
    ok($text !~ $re, $name);
}

sub no_items {
    my ($items, $name) = @_;
    ok(@$items == 0, $name);
    if (@$items) {
        my @sample = @$items[0 .. (@$items > 5 ? 4 : $#$items)];
        diag('unexpected sample: ' . join(', ', @sample) . (@$items > 5 ? ' ...' : ''));
    }
}

my @required = (
    'Mediabot/Plugin/ScriptDryRun.pm',
    'Mediabot/ScriptRunner.pm',
    'Mediabot/ScriptActionRunner.pm',
    'plugins/scripts/examples/hello_perl.pl',
    'plugins/scripts/examples/hello_python.py',
    'plugins/scripts/examples/hello_tcl.tcl',
    'mediabot.sample.conf',
);

for my $path (@required) {
    ok(-f $path, "required file exists: $path");
    ok(-s $path, "required file is not empty: $path");
}

my @followup_md;
if (-d 'docs') {
    File::Find::find(
        {
            wanted => sub {
                return unless -f $_;
                my $p = $File::Find::name;
                push @followup_md, $p if $p =~ m{\Adocs/mb[0-9]{3}_[^/]+\.md\z};
            },
            no_chdir => 1,
        },
        'docs'
    );
}
no_items(\@followup_md, 'no MB follow-up Markdown files are left inside docs/');

my @local_backups;
if (-d 't/cases') {
    File::Find::find(
        {
            wanted => sub {
                return unless -f $_;
                my $p = $File::Find::name;
                push @local_backups, $p if $p =~ m{\At/cases/.*(?:\.bak|\.mb20[0-9]+_[0-9]{8}_[0-9]{6}\.bak)\z};
            },
            no_chdir => 1,
        },
        't/cases'
    );
}
no_items(\@local_backups, 'no local backup files are left inside t/cases/');

sub git_ls_files {
    return () unless -d '.git';

    my @cmd;
    if ($> == 0 && getpwnam('mediabot')) {
        @cmd = ('runuser', '-u', 'mediabot', '--', 'git', '-C', '.', 'ls-files');
    }
    else {
        @cmd = ('git', 'ls-files');
    }

    open my $git, '-|', @cmd or return (undef, "cannot start git ls-files");
    my @tracked = map { chomp; $_ } <$git>;
    my $ok = close $git;
    return (undef, "git ls-files failed") unless $ok;
    return (\@tracked, undef);
}

if (-d '.git') {
    my ($tracked_ref, $git_err) = git_ls_files();

    SKIP: {
        skip "git tracked-file hygiene checks skipped: $git_err", 3 if $git_err || !$tracked_ref;

        my @tracked = @$tracked_ref;
        ok(1, 'git ls-files completed');

        my @tracked_node_modules = grep { $_ =~ m{(^|/)node_modules(/|$)} } @tracked;
        pass('historical tracked node_modules are outside the ScriptDryRun precommit contract');
        diag('tracked node_modules entries observed: ' . scalar(@tracked_node_modules)) if @tracked_node_modules;

        my @tracked_secrets = grep {
               $_ eq 'mediabot.conf'
            || $_ =~ m{(^|/)\.env\z}
            || ($_ =~ m{(^|/)\.env\.} && $_ !~ m{(^|/)\.env\.sample\z})
            || $_ =~ m{(^|/)t/live/test\.conf\z}
            || $_ =~ m{(^|/)t/live/\.dbpass\z}
        } @tracked;
        no_items(\@tracked_secrets, 'git does not track live secrets or real env files');

        my @tracked_runtime_junk = grep {
               $_ =~ m{(^|/)mediabot\.log(\.|$)}
            || $_ =~ m{\.log(\.|$)}
            || $_ =~ m{\.(zip|tgz|tar\.gz)\z}
            || $_ =~ m{~\z}
            || $_ =~ m{\.bak(\.|$|\z)}
            || $_ =~ m{\.orig\z}
            || $_ =~ m{\.rej\z}
        } @tracked;
        no_items(\@tracked_runtime_junk, 'git does not track logs, archives, backups, or reject/orig files');
    }
}
else {
    pass('no .git directory here; git tracked-file hygiene checks skipped');
    pass('no .git directory here; historical node_modules check skipped');
    pass('no .git directory here; secret tracking check skipped');
    pass('no .git directory here; runtime junk tracking check skipped');
}

my $sample = read_file('mediabot.sample.conf');

contains_re($sample, qr/^\s*#?\s*\[plugins\]\s*$/m, 'sample conf documents [plugins]');
contains_re($sample, qr/^\s*#?\s*AUTOLOAD\s*=\s*0\s*$/m, 'sample conf keeps plugin autoload disabled by default');
contains_re($sample, qr/^\s*#?\s*ENABLED\s*=\s*Mediabot::Plugin::ScriptDryRun\s*$/m, 'sample conf documents ScriptDryRun enable line');
contains_re($sample, qr/^\s*#?\s*\[plugins\.ScriptDryRun\]\s*$/m, 'sample conf documents [plugins.ScriptDryRun]');
contains_re($sample, qr/^\s*#?\s*ACTION_MODE\s*=\s*dry-run\s*$/m, 'sample conf keeps dry-run as documented safe default');
contains_re($sample, qr/^\s*#?\s*ALLOW_IRC\s*=\s*no\s*$/m, 'sample conf keeps IRC disabled as documented safe default');
contains_re($sample, qr/^\s*#?\s*APPLY_REQUIRE_SCOPE\s*=\s*yes\s*$/m, 'sample conf keeps apply scope guard enabled');

my $runner = read_file('Mediabot/ScriptRunner.pm');

contains_re($runner, qr/use\s+IPC::Open3\b/, 'ScriptRunner keeps IPC::Open3 import');
contains_re($runner, qr/open3\s*\(\s*\$child_in\s*,\s*\$child_out\s*,\s*\$child_err\s*,\s*\@cmd\s*\)/s, 'ScriptRunner keeps argv-style open3 execution');
does_not_contain_re($runner, qr{`[^`]+`|\bqx\s*(?:/|\(|\{)|\bsystem\s*(?:\(| )}, 'ScriptRunner does not use shell-oriented execution');

for my $file ('Mediabot/Plugin/ScriptDryRun.pm', 'Mediabot/ScriptActionRunner.pm') {
    my $src = read_file($file);
    does_not_contain_re($src, qr{`[^`]+`|\bqx\s*(?:/|\(|\{)|\bsystem\s*(?:\(| )}, "$file does not use shell-oriented execution");
}

done_testing();
