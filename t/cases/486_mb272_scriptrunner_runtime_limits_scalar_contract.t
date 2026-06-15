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

my $script = "$script_dir/ok.pl";
open my $fh, '>', $script or die "cannot write $script: $!";
print {$fh} <<'PL_SCRIPT';
use strict;
use warnings;
my $stdin = do { local $/; <STDIN> };
print q({"actions":[{"type":"log","text":"runtime limits accepted"}]});
PL_SCRIPT
close $fh;
chmod 0755, $script;

my $runner = Mediabot::ScriptRunner->new(
    script_dir       => $script_dir,
    timeout          => 3,
    max_stdout_bytes => 65536,
);

my $payload = $runner->build_event_payload('public_command', command => 'ok');
my $plan = $runner->build_execution_plan('ok.pl', $payload);
ok($plan->{ok}, 'normal execution plan is valid');

my $normal = $runner->run_plan({
    %$plan,
    timeout          => '3',
    max_stdin_bytes  => '4096',
    max_stdout_bytes => '4096',
    max_stderr_bytes => '4096',
});
ok($normal->{ok}, 'scalar runtime limits still execute normally');
is_deeply($normal->{response}{actions}, [ { type => 'log', text => 'runtime limits accepted' } ], 'valid scalar limits preserve script response');

for my $key (qw(timeout max_stdin_bytes max_stdout_bytes max_stderr_bytes)) {
    my %array_plan = %$plan;
    $array_plan{$key} = [ 1 ];
    my $array_result = $runner->run_plan(\%array_plan);
    ok(!$array_result->{ok}, "$key array ref is rejected before execution");
    is($array_result->{error}, "$key must be scalar", "$key array ref error is explicit");
    is_deeply($array_result->{response}{actions}, [], "$key array ref exposes no actions");

    my %hash_plan = %$plan;
    $hash_plan{$key} = { bad => 1 };
    my $hash_result = $runner->run_plan(\%hash_plan);
    ok(!$hash_result->{ok}, "$key hash ref is rejected before execution");
    is($hash_result->{error}, "$key must be scalar", "$key hash ref error is explicit");
    is_deeply($hash_result->{response}{errors}, [ "$key must be scalar" ], "$key hash ref response is structured");
}

my $source = do {
    local $/;
    open my $sfh, '<', "$Bin/../../Mediabot/ScriptRunner.pm" or die $!;
    <$sfh>;
};

like($source, qr/mb272-B1: runtime execution limits are part of the run_plan contract/, 'ScriptRunner source contains mb272 runtime limit marker');
unlike($source, qr/`[^`]+`|\bqx\s*(?:\/|\(|\{)|\bsystem\s*(?:\(|\s)/, 'mb272 runtime limit guard does not introduce shell execution');

done_testing();
