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

my $script = "$script_dir/echo_ok.pl";
open my $fh, '>', $script or die "cannot write $script: $!";
print {$fh} <<'SCRIPT';
use strict;
use warnings;
my $stdin = do { local $/; <STDIN> };
print q({"actions":[{"type":"log","text":"scalar stdin accepted"}]});
SCRIPT
close $fh;
chmod 0755, $script;

my $runner = Mediabot::ScriptRunner->new(
    script_dir       => $script_dir,
    timeout          => 3,
    max_stdout_bytes => 65536,
);

my $payload = $runner->build_event_payload('public_command', command => 'echo_ok');
my $plan = $runner->build_execution_plan('echo_ok.pl', $payload);
ok($plan->{ok}, 'normal execution plan is valid');

my $normal = $runner->run_plan({ %$plan, stdin => '{"hello":"world"}' });
ok($normal->{ok}, 'scalar stdin still executes normally');
is_deeply($normal->{response}{actions}, [ { type => 'log', text => 'scalar stdin accepted' } ], 'scalar stdin response is preserved');

my %array_stdin = %$plan;
$array_stdin{stdin} = [ 'not', 'scalar' ];
my $array_result = $runner->run_plan(\%array_stdin);
ok(!$array_result->{ok}, 'array-ref stdin is rejected before execution');
is($array_result->{error}, 'stdin must be scalar', 'array-ref stdin error is explicit');
is_deeply($array_result->{response}{actions}, [], 'array-ref stdin exposes no actions');

my %hash_stdin = %$plan;
$hash_stdin{stdin} = { bad => 1 };
my $hash_result = $runner->run_plan(\%hash_stdin);
ok(!$hash_result->{ok}, 'hash-ref stdin is rejected before execution');
is($hash_result->{error}, 'stdin must be scalar', 'hash-ref stdin error is explicit');
is_deeply($hash_result->{response}{errors}, [ 'stdin must be scalar' ], 'hash-ref stdin response is structured');

my $source = do {
    local $/;
    open my $sfh, '<', "$Bin/../../Mediabot/ScriptRunner.pm" or die $!;
    <$sfh>;
};

like($source, qr/mb257-B1: stdin is part of the internal execution-plan contract/, 'ScriptRunner source contains mb257 stdin scalar marker');
unlike($source, qr/`[^`]+`|\bqx\s*(?:\/|\(|\{)|\bsystem\s*(?:\(|\s)/, 'mb257 stdin scalar guard does not introduce shell execution');

done_testing();
