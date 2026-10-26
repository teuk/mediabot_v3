# MB960: run the real updater with real Git URL rewrites, entirely offline.
use strict;
use warnings;
use utf8;
use Test::More;
use File::Path qw(make_path remove_tree);
use File::Temp qw(tempdir);
use Cwd qw(abs_path);
use JSON::PP ();

sub slurp_1336 {
    open my $fh, '<:raw', $_[0] or die "$_[0]: $!";
    local $/;
    return <$fh>;
}
sub write_1336 {
    my ($path, $content, $mode) = @_;
    open my $fh, '>:raw', $path or die "$path: $!";
    print {$fh} $content;
    close $fh or die "$path: $!";
    chmod $mode, $path or die "chmod $path: $!";
}
sub run_1336 {
    my ($cwd, @command) = @_;
    my $log = "$cwd.command.log";
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if (!$pid) {
        chdir $cwd or die "chdir $cwd: $!";
        open STDOUT, '>:raw', $log or die "$log: $!";
        open STDERR, '>&', STDOUT or die "dup stderr: $!";
        exec { $command[0] } @command or die "exec: $!";
    }
    waitpid($pid, 0);
    my $rc = $?;
    my $output = slurp_1336($log);
    unlink $log;
    return ($rc, $output);
}
sub must_1336 {
    my ($cwd, @command) = @_;
    my ($rc, $output) = run_1336($cwd, @command);
    die "fixture command failed ($rc): @command\n$output" if $rc;
    $output =~ s/\r?\n\z//;
    return $output;
}
sub commit_1336 {
    my ($repo, $version) = @_;
    write_1336("$repo/VERSION", "$version\n", 0644);
    must_1336($repo, 'git', 'add', '.');
    must_1336($repo, 'git', '-c', 'commit.gpgsign=false', 'commit', '-qm', $version);
    return must_1336($repo, 'git', 'rev-parse', 'HEAD');
}

my $deploy = slurp_1336('install/deploy_update.sh');
my $tmp = tempdir('mb960-XXXXXX', TMPDIR => 1, CLEANUP => 1);
$tmp = abs_path($tmp);
local %ENV = %ENV;
delete @ENV{grep { /\AGIT_/ || /\AMEDIABOT_UPDATE_/ } keys %ENV};
$ENV{GIT_CONFIG_NOSYSTEM} = 1;
$ENV{GIT_CONFIG_GLOBAL} = '/dev/null';
$ENV{GIT_TERMINAL_PROMPT} = 0;
# Even a broken rewrite cannot open the network during this regression.
$ENV{GIT_ALLOW_PROTOCOL} = 'file';
$ENV{LC_ALL} = 'C';

my $source = "$tmp/canonical repository";
make_path("$source/install", "$source/Mediabot");
write_1336("$source/install/deploy_update.sh", $deploy, 0755);
# Config is a fixture; Git, clone, validation, rotation and status are real.
write_1336("$source/Mediabot/Conf.pm", <<'CONF', 0644);
package Mediabot::Conf;
sub new { bless {}, shift }
sub get { undef }
1;
CONF
write_1336("$source/mediabot.pl", "use strict; use warnings; 1;\n", 0644);
must_1336($source, 'git', 'init', '-q', '--initial-branch=master');
must_1336($source, 'git', 'config', 'user.name', 'MB960 Fixture');
must_1336($source, 'git', 'config', 'user.email', 'mb960@example.invalid');
my $old = commit_1336($source, '3.6dev-mb960-old');
my $canonical = "file://$source";

for my $case (
    ['file', $canonical],
    ['https', 'https://example.invalid/team/mediabot_v3'],
    ['ssh', 'git@example.invalid:team/mediabot_v3.git'],
) {
    my ($name, $configured) = @$case;
    my $live = "$tmp/mb960-$name";
    must_1336($tmp, 'git', 'clone', '-q', $source, $live);
    must_1336($live, 'git', 'reset', '--hard', $old);
    must_1336($live, 'git', 'remote', 'set-url', 'origin', $configured);
    # Git fetch uses the first URL. A trailing URL must never become the clone.
    must_1336($live, 'git', 'config', '--add', 'remote.origin.url', "$tmp/absent-origin");
    write_1336("$live/mediabot.conf", "# private fixture\n", 0600);
    make_path("$live/plugin-data", { mode => 0700 });
    write_1336("$live/plugin-data/scores.json", "{\"total\":13}\n", 0600);

    my $mirror = "$tmp/mirror-$name";
    must_1336($tmp, 'git', 'clone', '-q', $source, $mirror);
    must_1336($mirror, 'git', 'config', 'user.name', 'MB960 Fixture');
    must_1336($mirror, 'git', 'config', 'user.email', 'mb960@example.invalid');
    my $target = commit_1336($mirror, "3.6dev-mb960-$name");

    {
        local $ENV{GIT_CONFIG_COUNT} = 1;
        local $ENV{GIT_CONFIG_KEY_0} = "url.file://$mirror.insteadOf";
        local $ENV{GIT_CONFIG_VALUE_0} = $configured;
        is(must_1336($live, 'git', 'remote', 'get-url', 'origin'), "file://$mirror",
            "$name: transport resolves to the disposable mirror");
        my ($rc, $output) = run_1336($live, 'bash', 'install/deploy_update.sh');
        is($rc, 0, "$name: real updater completes through the rewrite") or diag $output;
    }
    is(must_1336($live, 'git', 'rev-parse', 'HEAD'), $target,
        "$name: candidate actually came from the mirror, not canonical HEAD");
    is(must_1336($live, 'git', 'config', '--get-all', 'remote.origin.url'), $configured,
        "$name: installed origin retains the first configured URL");
    is(must_1336($live, 'git', 'remote', 'get-url', 'origin'), $configured,
        "$name: effective origin returns to canonical after rewrite expires");
    is(slurp_1336("$live/plugin-data/scores.json"), "{\"total\":13}\n",
        "$name: saved points survive rotation");
    is(slurp_1336("$live/mediabot.conf"), "# private fixture\n",
        "$name: private configuration survives rotation");
    is(must_1336("$live.1", 'git', 'rev-parse', 'HEAD'), $old,
        "$name: previous source remains in its archive");
    my $status = JSON::PP->new->decode(slurp_1336("$tmp/.mb960-$name.update-status.json"));
    is($status->{state}, 'success', "$name: durable status confirms success");

    remove_tree($mirror);
    if ($name eq 'file') {
        my $next = commit_1336($source, '3.6dev-mb960-next');
        my ($rc, $output) = run_1336($live, 'bash', 'install/deploy_update.sh');
        is($rc, 0, 'second update works after the mirror is deleted') or diag $output;
        is(must_1336($live, 'git', 'rev-parse', 'HEAD'), $next,
            'second update fetches the new canonical revision');
        is(slurp_1336("$live/plugin-data/scores.json"), "{\"total\":13}\n",
            'saved points also survive the second rotation');
    }
}

# Missing or empty origins fail before cloning or rotating the current tree.
for my $empty (0, 1) {
    my $live = "$tmp/mb960-missing-$empty";
    must_1336($tmp, 'git', 'clone', '-q', $source, $live);
    must_1336($live, 'git', 'config', '--unset-all', 'remote.origin.url');
    must_1336($live, 'git', 'config', '--add', 'remote.origin.url', '') if $empty;
    write_1336("$live/mediabot.conf", "# unchanged\n", 0600);
    my $head = must_1336($live, 'git', 'rev-parse', 'HEAD');
    my ($rc, $output) = run_1336($live, 'bash', 'install/deploy_update.sh');
    isnt($rc, 0, "empty=$empty: origin failure is explicit");
    like($output, qr/Git remote 'origin' is not configured/,
        "empty=$empty: missing-origin reason is retained");
    is(must_1336($live, 'git', 'rev-parse', 'HEAD'), $head,
        "empty=$empty: source is untouched");
    ok(!-e "$live.1", "empty=$empty: no release rotation");
}
done_testing;
