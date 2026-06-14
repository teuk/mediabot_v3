#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

use lib '.';
use Mediabot::ScriptRunner;

my $tmp = tempdir(CLEANUP => 1);
my $script_dir = "$tmp/scripts";
make_path($script_dir);

my $script = "$script_dir/ok.pl";
open my $fh, '>', $script or die "cannot write $script: $!";
print {$fh} <<'SCRIPT';
use strict;
use warnings;
my $stdin = do { local $/; <STDIN> };
print '{"actions":[{"type":"log","text":"stdin ok"}]}';
SCRIPT
close $fh;
chmod 0755, $script;

my $runner = Mediabot::ScriptRunner->new(
    script_dir       => $script_dir,
    timeout          => 3,
    max_stdin_bytes  => 4096,
    max_stdout_bytes => 65536,
);

is($runner->max_stdin_bytes, 4096, 'constructor accepts bounded max_stdin_bytes');

my $low = Mediabot::ScriptRunner->new(script_dir => $script_dir, max_stdin_bytes => 1);
is($low->max_stdin_bytes, 1024, 'constructor clamps max_stdin_bytes lower bound');

my $high = Mediabot::ScriptRunner->new(script_dir => $script_dir, max_stdin_bytes => 999999999);
is($high->max_stdin_bytes, 4194304, 'constructor clamps max_stdin_bytes upper bound');

my $plan = $runner->run_dry('ok.pl', 'public_command', command => 'ok', channel => '#test');
ok(ref($plan) eq 'HASH' && $plan->{ok}, 'build_execution_plan still succeeds');
is($plan->{max_stdin_bytes}, 4096, 'execution plan carries max_stdin_bytes');

my $result = $runner->run_plan($plan);
ok($result->{ok}, 'normal stdin payload still runs successfully');
is_deeply($result->{response}{actions}, [ { type => 'log', text => 'stdin ok' } ], 'normal response actions preserved');

my %too_big_plan = %$plan;
$too_big_plan{stdin} = 'X' x (4096 + 1);
my $too_big = $runner->run_plan(\%too_big_plan);
ok(!$too_big->{ok}, 'oversized stdin is rejected before execution');
is($too_big->{error}, 'stdin too large', 'oversized stdin returns explicit error');
is_deeply($too_big->{response}{errors}, [ 'stdin too large' ], 'oversized stdin response is structured');
is_deeply($too_big->{response}{actions}, [], 'oversized stdin exposes no actions');

my %huge_cap_plan = %$plan;
$huge_cap_plan{stdin} = 'Y' x (4194304 + 1);
$huge_cap_plan{max_stdin_bytes} = 999999999;
my $huge_cap = $runner->run_plan(\%huge_cap_plan);
ok(!$huge_cap->{ok}, 'handcrafted huge max_stdin_bytes is clamped at runtime');
is($huge_cap->{error}, 'stdin too large', 'runtime clamp error remains explicit');

my $source = do {
    open my $sfh, '<', 'Mediabot/ScriptRunner.pm' or die $!;
    local $/;
    <$sfh>;
};

like($source, qr/mb246-B1/, 'ScriptRunner source contains mb246 stdin cap marker');
unlike($source, qr/\bsystem\s*(?:\(| )|\bqx\s*(?:\/|\(|\{)|`[^`]+`/, 'stdin cap guard does not introduce shell execution');

done_testing();
