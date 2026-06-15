#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP qw(decode_json);
use FindBin qw($Bin);
use lib "$Bin/../..";

use Mediabot::ScriptRunner;

my $tmp = tempdir(CLEANUP => 1);
my $script_dir = "$tmp/scripts";
make_path($script_dir);

my $marker = "$tmp/executed.marker";
my $script = "$script_dir/echo.pl";
open my $fh, '>', $script or die "cannot write $script: $!";
print {$fh} <<"PL";
use strict;
use warnings;
use JSON::PP qw(decode_json encode_json);
my \$marker = q{$marker};
my \$stdin = do { local \$/; <STDIN> };
my \$payload = decode_json(\$stdin);
open my \$mfh, '>>', \$marker or die "cannot write marker: \$!";
print {\$mfh} "executed\n";
close \$mfh;
print encode_json({ actions => [ { type => 'log', text => 'stdin object accepted' } ] });
PL
close $fh;
chmod 0755, $script;

my $runner = Mediabot::ScriptRunner->new(
    script_dir       => $script_dir,
    timeout          => 3,
    max_stdin_bytes  => 4096,
    max_stdout_bytes => 65536,
);

my $payload = $runner->build_event_payload('public_command', command => 'hello');
my $plan = $runner->build_execution_plan('echo.pl', $payload);
ok($plan->{ok}, 'normal execution plan is valid');
is(ref(decode_json($plan->{stdin})), 'HASH', 'normal plan stdin is a JSON object');

my $good = $runner->run_plan({ %$plan });
ok($good->{ok}, 'normal object stdin still executes');
is_deeply($good->{response}{actions}, [ { type => 'log', text => 'stdin object accepted' } ], 'normal response is preserved');

my $executions = sub {
    return 0 unless -e $marker;
    open my $mfh, '<', $marker or die "cannot read marker: $!";
    my @lines = <$mfh>;
    close $mfh;
    return scalar @lines;
};

is($executions->(), 1, 'valid object stdin executed the script once');

for my $case (
    [ 'plain text', 'not json' ],
    [ 'JSON array', '[]' ],
    [ 'JSON string', '"hello"' ],
    [ 'JSON number', '42' ],
    [ 'empty stdin', '' ],
) {
    my ($label, $stdin) = @$case;
    my %bad = %$plan;
    $bad{stdin} = $stdin;

    my $result = $runner->run_plan(\%bad);
    ok(!$result->{ok}, "$label stdin is rejected before execution");
    is($result->{error}, 'stdin must be JSON object', "$label stdin error is explicit");
    is_deeply($result->{response}{errors}, [ 'stdin must be JSON object' ], "$label stdin response is structured");
    is_deeply($result->{response}{actions}, [], "$label stdin exposes no actions");
    is($executions->(), 1, "$label stdin did not spawn the script");
}

my %missing = %$plan;
delete $missing{stdin};
my $missing_result = $runner->run_plan(\%missing);
ok(!$missing_result->{ok}, 'missing stdin is rejected before execution');
is($missing_result->{error}, 'stdin must be JSON object', 'missing stdin error is explicit');
is($executions->(), 1, 'missing stdin did not spawn the script');

my $source = do {
    local $/;
    open my $sfh, '<', "$Bin/../../Mediabot/ScriptRunner.pm" or die $!;
    <$sfh>;
};

like($source, qr/mb288-B1: run_plan\(\) is the last boundary before open3\(\)/, 'ScriptRunner source contains mb288 stdin JSON-object marker');
unlike($source, qr/`[^`]+`|\bqx\s*(?:\/|\(|\{)|\bsystem\s*(?:\(|\s)/, 'mb288 stdin JSON-object guard does not introduce shell execution');

done_testing();
