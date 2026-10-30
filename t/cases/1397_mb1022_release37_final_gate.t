use strict;
use warnings;
use utf8;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);

binmode Test::More->builder->output, ':encoding(UTF-8)';
binmode Test::More->builder->failure_output, ':encoding(UTF-8)';
my $tmp=tempdir('mb1022-gate-XXXXXX',TMPDIR=>1,CLEANUP=>1);
my $repo="$tmp/repo";my $candidate="$tmp/candidate";
make_path("$repo/install/migrations","$candidate/install/migrations");
my $helper=abs_path('tools/qualify_37_upgrade.sh');
sub read_1397 {open my $f,'<:encoding(UTF-8)',$_[0] or die $!;local $/;return <$f>}
sub write_1397 {my ($p,$s)=@_;open my $f,'>:encoding(UTF-8)',$p or die $!;print {$f} $s;close $f or die $!}
sub run_1397 {
    my (@args)=@_;my $file="$tmp/output";my $pid=fork();die $! unless defined $pid;
    if (!$pid) {open STDOUT,'>',$file or die $!;open STDERR,'>&',STDOUT or die $!;exec {$args[0]} @args;die $!}
    waitpid($pid,0);my $rc=$? >> 8;return [$rc,read_1397($file)];
}
sub git_1397 {my $r=run_1397('git','-C',$repo,@_);die $r->[1] if $r->[0];return $r->[1]}
sub commit_1397 {git_1397('add','.');git_1397('-c','commit.gpgsign=false','commit','--no-verify','-qm','isolated gate fixture')}
my $workflow=read_1397('.github/workflows/debian13.yml');
my ($selector)=$workflow =~ /(case "\$SOURCE_VERSION" in\n.*?^\s+esac)/ms;
die 'version selector missing' unless $selector;
my $script=$selector."\nprintf '%s|%s|%s|%s\\n' \"\$CANDIDATE_VERSION\" \"\$CANDIDATE_KIND\" \"\$CANDIDATE_BASE\" \"\${CANDIDATE_ARGS[*]}\"\n";
{
    my @got;
    local $ENV{CANDIDATE_SHORT}='123456abcdef';
    for my $version ('3.4dev-20260101_010203','3.5','3.6dev-20261030_080000','3.7','3.8dev-20261030_130708') {
        local $ENV{SOURCE_VERSION}=$version;push @got,run_1397('bash','-c',$script);
    }
    is_deeply(\@got,[[0,"3.5|rehearsal|mediabot_v3-3.5-rehearsal-123456abcdef|--rehearsal\n"],
        [0,"3.5|stable|mediabot_v3-3.5|\n"],[0,"3.7|rehearsal|mediabot_v3-3.7-rehearsal-123456abcdef|--rehearsal\n"],
        [0,"3.7|stable|mediabot_v3-3.7|\n"],
        [0,"3.9|rehearsal|mediabot_v3-3.9-rehearsal-123456abcdef|--rehearsal\n"]],
        'actual CI selector preserves released identities and keeps 3.6/3.8 development candidates non-publishable');
}
{
    my @rc;local $ENV{CANDIDATE_SHORT}='123456abcdef';
    for my $version ('','3.7dev','3.7-rc1','3.10dev','4.0') {
        local $ENV{SOURCE_VERSION}=$version;push @rc,run_1397('bash','-c',$script)->[0];
    }
    is_deeply(\@rc,[(1)x5],'unknown and provisional identities cannot silently enter the stable path');
}
local $ENV{GITHUB_ACTIONS}='';local $ENV{CI}='';
write_1397("$repo/VERSION","3.5\n");
write_1397("$repo/install/mediabot.sql","CREATE TABLE sample(id INT);\n");
write_1397("$repo/install/migrations/base.sql","SELECT 1;\n");
write_1397("$repo/install/migrations/README.md","## Current migration order\n\n```text\nbase.sql\n```\n");
git_1397('init','-q');git_1397('config','user.name','MB1022 test');git_1397('config','user.email','mb1022@example.invalid');
commit_1397();git_1397('-c','tag.gpgsign=false','tag','-am','isolated stable fixture','3.5');
my $order="## Current migration order\n\n```text\nbase.sql\nnext.sql\n```\n";
for my $root ($repo,$candidate) {
    write_1397("$root/VERSION","3.6dev-20261030_080000\n");
    write_1397("$root/CHANGELOG.md","## [Unreleased] — 3.6dev\n");
    write_1397("$root/install/mediabot.sql","CREATE TABLE sample(id INT);\n");
    write_1397("$root/install/migrations/base.sql","SELECT 1;\n");
    write_1397("$root/install/migrations/next.sql","SELECT 2;\n");
    write_1397("$root/install/migrations/README.md",$order);
}
commit_1397();
my @args=('bash',$helper,'--repo',$repo,'--candidate',$candidate);
my $dev=run_1397(@args,'--lineage-only');
ok(!$dev->[0] && $dev->[1] =~ /MB787_LINEAGE=OK stable=3\.5 candidate=3\.6dev.*migrations=1\nnext\.sql/,
    'real 3.5 migration lineage still accepts an exported development candidate');
sub final_1397 {
    my ($heading)=@_;
    for my $root ($repo,$candidate) {
        write_1397("$root/VERSION","3.7\n");write_1397("$root/CHANGELOG.md",$heading);
    }
    commit_1397();
}
final_1397("## [3.7] — 2026-10-30\n");
my $stable=run_1397(@args,'--lineage-only');
ok(!$stable->[0] && $stable->[1] =~ /MB787_LINEAGE=OK stable=3\.5 candidate=3\.7 migrations=1\nnext\.sql/,
    'real qualifier accepts the explicit final 3.7 archive and selects only post-3.5 migrations');
{
    my @bad;
    for my $heading ("## [Unreleased] — 3.6dev\n","## [3.7] — target\n") {
        final_1397($heading);push @bad,run_1397(@args,'--lineage-only')->[0] ? 1:0;
    }
    final_1397("## [3.7] — 2026-10-30\n");
    write_1397("$candidate/VERSION","3.6dev-20261030_080000\n");
    push @bad,run_1397(@args,'--lineage-only')->[0] ? 1:0;
    write_1397("$candidate/VERSION","3.7\n");
    is_deeply(\@bad,[1,1,1],'final mode requires a dated committed release heading and matching source/archive VERSION');
}
{
    write_1397("$candidate/install/migrations/base.sql","SELECT 999;\n");
    my $changed=run_1397(@args,'--lineage-only')->[0];
    write_1397("$candidate/install/migrations/base.sql","SELECT 1;\n");
    write_1397("$candidate/install/migrations/README.md",$order =~ s/next.sql/next.sql\nnext.sql/r);
    my $duplicate=run_1397(@args,'--lineage-only')->[0];
    write_1397("$candidate/install/migrations/README.md",$order);
    is_deeply([$changed?1:0,$duplicate?1:0],[1,1],
        'final mode retains immutable released migrations and exact-once migration ordering');
}
{
    my @checks;
    for my $version ('3.6dev-20261030_080000','3.7') {
        for my $root ($repo,$candidate) {write_1397("$root/VERSION","$version\n")}
        commit_1397();
        my $local=run_1397(@args);
        push @checks,$local->[0] && $local->[1] =~ /database trial is restricted to disposable GitHub Actions CI/ ? 1:0;
        local $ENV{GITHUB_ACTIONS}='true';local $ENV{CI}='true';
        local $ENV{GITHUB_WORKSPACE}=$repo;local $ENV{GITHUB_SHA}=git_1397('rev-parse','HEAD');
        $ENV{GITHUB_SHA} =~ s/\s+\z//;
        my $wrong=run_1397(@args);
        push @checks,$wrong->[0] && $wrong->[1] =~ /requires the exact unpacked CI candidate/ ? 1:0;
    }
    is_deeply(\@checks,[1,1,1,1],
        'both phases refuse local SQL trials and wrong extracted CI roots before any MariaDB invocation');
}
{
    my $ci=read_1397('.github/workflows/ci.yml');
    ok($ci =~ /working-directory: contrib\/mbweb.*?npm test/s
        && $ci =~ /mb_architecture_inventory\.pl --check docs\/generated\/COMMAND_INVENTORY\.md/
        && $workflow =~ /--ref "\$GITHUB_SHA"/ && $workflow =~ /1397_/
        && $workflow !~ /\bgit\s+(?:add|commit|push|tag)\b/,
        'CI covers mbweb, inventory and this contract on the exact archive without publication operations');
}
done_testing;
