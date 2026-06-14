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

my $marker = "$tmp/evil-ran.marker";

my $ok_script = "$script_dir/ok.pl";
open my $okfh, '>', $ok_script or die "cannot write $ok_script: $!";
print {$okfh} <<'OKPL';
use strict;
use warnings;
print q({"actions":[{"type":"log","text":"safe"}]});
OKPL
close $okfh;
chmod 0755, $ok_script;

my $evil_script = "$script_dir/evil.pl";
open my $evfh, '>', $evil_script or die "cannot write $evil_script: $!";
print {$evfh} 'use strict; use warnings; open my $fh, ' . "'>', '$marker'; " . q{print {$fh} 'ran'; close $fh; print q({"actions":[]});
};
close $evfh;
chmod 0755, $evil_script;

my $runner = Mediabot::ScriptRunner->new(
    script_dir       => $script_dir,
    timeout          => 3,
    max_stdout_bytes => 65536,
);

my $payload = $runner->build_event_payload('public_command', command => 'ok');
my $plan = $runner->build_execution_plan('ok.pl', $payload);
ok($plan->{ok}, 'normal execution plan is valid');

my $good = $runner->run_plan({ %$plan });
ok($good->{ok}, 'validated execution plan still runs normally');
ok(ref($good->{response}) eq 'HASH', 'normal run still returns decoded response');
is(scalar @{ $good->{response}{actions} || [] }, 1, 'normal run still preserves script actions');

my %evil_command_plan = (%$plan);
$evil_command_plan{command} = [ $^X, $evil_script ];
my $evil_command = $runner->run_plan(\%evil_command_plan);
ok(!$evil_command->{ok}, 'run_plan rejects argv that does not match validated script');
like($evil_command->{error} || '', qr/command does not match validated script path/, 'argv mismatch error is explicit');
ok(!-e $marker, 'rejected argv plan did not execute the alternate script');

my %shell_plan = (%$plan);
$shell_plan{command} = [ '/bin/sh', '-c', "echo ran > '$marker'" ];
my $shell = $runner->run_plan(\%shell_plan);
ok(!$shell->{ok}, 'run_plan rejects shell argv injection');
like($shell->{error} || '', qr/command does not match validated script path/, 'shell argv rejection is explicit');
ok(!-e $marker, 'rejected shell argv did not execute');

my %missing_script_plan = (%$plan);
delete $missing_script_plan{script};
my $missing = $runner->run_plan(\%missing_script_plan);
ok(!$missing->{ok}, 'run_plan rejects plan without script identity');
like($missing->{error} || '', qr/missing script/, 'missing script identity error is explicit');

my %language_mismatch = (%$plan);
$language_mismatch{language} = 'python';
my $lang = $runner->run_plan(\%language_mismatch);
ok(!$lang->{ok}, 'run_plan rejects language mismatch');
like($lang->{error} || '', qr/language mismatch/, 'language mismatch error is explicit');

my %path_mismatch = (%$plan);
$path_mismatch{full_path} = "$script_dir/other.pl";
my $path = $runner->run_plan(\%path_mismatch);
ok(!$path->{ok}, 'run_plan rejects full path mismatch');
like($path->{error} || '', qr/full path mismatch/, 'full path mismatch error is explicit');

my $source = do {
    local $/;
    open my $sfh, '<', "$Bin/../../Mediabot/ScriptRunner.pm" or die $!;
    <$sfh>;
};

like($source, qr/mb241-B1: run_plan is an execution boundary/, 'ScriptRunner source contains mb241 argv guard marker');
unlike($source, qr/`[^`]+`|\bqx\s*(?:\/|\(|\{)|\bsystem\s*(?:\(|\s)/, 'mb241 run_plan guard does not introduce shell execution');

done_testing();
