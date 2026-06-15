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

{
    package Local::MB278::Stringy;
    use overload '""' => sub { $_[0]->{value} }, fallback => 1;
    sub new { bless { value => $_[1] }, $_[0] }
}

my $tmp = tempdir(CLEANUP => 1);
my $script_dir = "$tmp/scripts";
make_path($script_dir);

my $marker = "$tmp/mb278-ran.marker";
my $script = "$script_dir/ok.pl";
open my $fh, '>', $script or die "cannot write $script: $!";
print {$fh} <<"OKPL";
use strict;
use warnings;
open my \$mfh, '>', '$marker' or die \$!;
print {\$mfh} 'ran';
close \$mfh;
print q({"ok":true,"actions":[]});
OKPL
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

unlink $marker;
my $good = $runner->run_plan({ %$plan, command => [ @{ $plan->{command} } ] });
ok($good->{ok}, 'normal scalar execution plan still runs');
ok(-e $marker, 'normal scalar plan actually executed the test script');
unlink $marker;

my %script_ref_plan = (%$plan, command => [ @{ $plan->{command} } ]);
$script_ref_plan{script} = [ 'ok.pl' ];
my $script_ref = $runner->run_plan(\%script_ref_plan);
ok(!$script_ref->{ok}, 'run_plan rejects non-scalar script identity');
is($script_ref->{error}, 'script path must be scalar', 'script identity ref returns explicit scalar error');
ok(!-e $marker, 'script identity ref plan did not execute');

my %language_ref_plan = (%$plan, command => [ @{ $plan->{command} } ]);
$language_ref_plan{language} = Local::MB278::Stringy->new('perl');
my $language_ref = $runner->run_plan(\%language_ref_plan);
ok(!$language_ref->{ok}, 'run_plan rejects non-scalar language identity even if it stringifies to perl');
is($language_ref->{error}, 'execution plan language must be scalar', 'language ref returns explicit scalar error');
ok(!-e $marker, 'language ref plan did not execute');

my %full_path_ref_plan = (%$plan, command => [ @{ $plan->{command} } ]);
$full_path_ref_plan{full_path} = Local::MB278::Stringy->new($plan->{full_path});
my $full_path_ref = $runner->run_plan(\%full_path_ref_plan);
ok(!$full_path_ref->{ok}, 'run_plan rejects non-scalar full_path identity even if it stringifies to the validated path');
is($full_path_ref->{error}, 'execution plan full path must be scalar', 'full_path ref returns explicit scalar error');
ok(!-e $marker, 'full_path ref plan did not execute');

my %argv_ref_plan = (%$plan, command => [ @{ $plan->{command} } ]);
$argv_ref_plan{command}[0] = Local::MB278::Stringy->new($plan->{command}[0]);
my $argv_ref = $runner->run_plan(\%argv_ref_plan);
ok(!$argv_ref->{ok}, 'run_plan rejects argv refs even if they stringify to the expected interpreter');
is($argv_ref->{error}, 'execution plan command arguments must be scalar', 'argv ref returns explicit scalar error');
ok(!-e $marker, 'argv ref plan did not execute');

my %argv_path_ref_plan = (%$plan, command => [ @{ $plan->{command} } ]);
$argv_path_ref_plan{command}[-1] = Local::MB278::Stringy->new($plan->{full_path});
my $argv_path_ref = $runner->run_plan(\%argv_path_ref_plan);
ok(!$argv_path_ref->{ok}, 'run_plan rejects script argv refs even if they stringify to the expected path');
is($argv_path_ref->{error}, 'execution plan command arguments must be scalar', 'script argv ref returns explicit scalar error');
ok(!-e $marker, 'script argv ref plan did not execute');

my $source = do {
    local $/;
    open my $sfh, '<', "$Bin/../../Mediabot/ScriptRunner.pm" or die $!;
    <$sfh>;
};

like($source, qr/mb278-B1/, 'ScriptRunner source contains mb278 scalar helper marker');
like($source, qr/mb278-B2/, 'ScriptRunner source contains mb278 execution identity marker');
like($source, qr/mb278-B3/, 'ScriptRunner source contains mb278 argv marker');
unlike($source, qr/`[^`]+`|\bqx\s*(?:\/|\(|\{)|\bsystem\s*(?:\(|\s)/, 'mb278 execution-plan guard does not introduce shell execution');

done_testing();
