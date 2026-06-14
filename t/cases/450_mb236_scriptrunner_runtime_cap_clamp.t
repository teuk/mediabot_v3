#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin qw($Bin);
use lib "$Bin/../..";

use Mediabot::ScriptRunner;

my $tmp = tempdir(CLEANUP => 1);
my $script_dir = "$tmp/scripts";
make_path($script_dir);

my $script = "$script_dir/flood.pl";
open my $fh, '>', $script or die "cannot write $script: $!";
print {$fh} <<'PL';
use strict;
use warnings;
binmode STDOUT;
binmode STDERR;
print STDOUT "A" x (2 * 1024 * 1024);
print STDERR "B" x (2 * 1024 * 1024);
PL
close $fh;
chmod 0755, $script;

my $runner = Mediabot::ScriptRunner->new(
    script_dir       => $script_dir,
    timeout          => 5,
    max_stdout_bytes => 65536,
);

my $payload = $runner->build_event_payload('public_command_observed', command => 'flood');
my $plan = $runner->build_execution_plan('flood.pl', $payload);
ok($plan->{ok}, 'execution plan is valid');

# Simulate a future internal caller handing run_plan oversized caps directly.
$plan->{max_stdout_bytes} = 50 * 1024 * 1024;
$plan->{max_stderr_bytes} = 50 * 1024 * 1024;

my $result = $runner->run_plan($plan);

ok($result->{ok} == 0, 'flood script result is not a valid JSON response');
ok(length($result->{stdout}) <= 1048576, 'stdout is clamped to the hard runtime cap');
ok(length($result->{stderr}) <= 1048576, 'stderr is clamped to the hard runtime cap');
is(length($result->{stdout}), 1048576, 'stdout cap is exactly 1 MiB');
is(length($result->{stderr}), 1048576, 'stderr cap is exactly 1 MiB');
ok($result->{stdout_truncated}, 'stdout truncation flag is set');
ok($result->{stderr_truncated}, 'stderr truncation flag is set');

my $source = do {
    local $/;
    open my $sfh, '<', "$Bin/../../Mediabot/ScriptRunner.pm" or die $!;
    <$sfh>;
};

like($source, qr/mb236-B1: clamp runtime output caps/, 'ScriptRunner source contains mb236 marker');
like($source, qr/\$max_stdout\s*=\s*1048576\s+if\s+\$max_stdout\s*>\s*1048576;/, 'run_plan clamps max_stdout upper bound');
like($source, qr/\$max_stderr\s*=\s*1048576\s+if\s+\$max_stderr\s*>\s*1048576;/, 'run_plan clamps max_stderr upper bound');
unlike($source, qr/`[^`]+`|\bqx\s*(?:\/|\(|\{)|\bsystem\s*(?:\(|\s)/, 'mb236 cap fix does not introduce shell execution');

done_testing();
