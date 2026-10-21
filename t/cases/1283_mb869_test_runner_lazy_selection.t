use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Spec;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Copy qw(copy);
use File::Basename qw(basename);
use FastValidation qw(fast_lane_sentinels);

# Run the actual launcher against a private miniature catalogue. Instrument the
# real classifier to verify which files are read, without timing assertions or
# adding temporary failing cases to the project's live t/cases catalogue.
my $root = File::Spec->rel2abs("$Bin/../..");
my $tmp = tempdir('mb869-lazy-XXXXXX', TMPDIR => 1, CLEANUP => 1);
make_path("$tmp/t/cases", "$tmp/probe");
copy("$root/t/test_commands.pl", "$tmp/t/test_commands.pl") or die $!;
sub write_case {
    my ($name, $text) = @_;
    open my $fh, '>', "$tmp/t/cases/$name" or die $!;
    print {$fh} $text;
    close $fh or die $!;
}
write_case('a_native.t', q{return sub {$_[0]->ok(1, 'native one'); $_[0]->ok(1, 'native two')};});
write_case('b_tap.t', 'print "1..3\nok 1 - standalone one\nok 2 - standalone two\nok 3 - standalone three\n"; exit 0;');
write_case('c_database.t', "# SELECT is a classifier touchpoint; this fixture opens no database.\nreturn sub {\$_[0]->ok(1, 'database contract')};\n");
open my $probe, '>', "$tmp/probe/MB869Trace.pm" or die $!;
print {$probe} <<'PROBE';
package MB869Trace;
use strict;
use warnings;
use TestClassifier ();
use File::Basename qw(basename);
my $classify = \&TestClassifier::classify_test_file;
no warnings 'redefine';
*TestClassifier::classify_test_file = sub {
    open my $fh, '>>', $ENV{MB869_TRACE_PATH} or die $!;
    print {$fh} basename($_[0]), "\n";
    close $fh or die $!;
    return $classify->(@_);
};
1;
PROBE
close $probe or die $!;

sub run_launcher {
    my (@args) = @_;
    my $trace = "$tmp/classification.log";
    unlink $trace if -e $trace;
    local $ENV{MB869_TRACE_PATH} = $trace;
    my $pid = open(my $fh, '-|');
    die "cannot launch regression probe: $!" unless defined $pid;
    if (!$pid) {
        open STDERR, '>&', STDOUT or exit 254;
        exec($^X, "-I$root", "-I$root/t/lib", "-I$tmp/probe", '-MMB869Trace',
            "$tmp/t/test_commands.pl", @args);
        exit 254;
    }
    local $/;
    my $output = <$fh> // '';
    close $fh;
    my $status = $?;
    my @classified;
    if (-e $trace) {
        open my $log, '<', $trace or die $!;
        @classified = split /\n/, (<$log> // '');
        close $log;
    }
    return ($output, $status, \@classified);
}

my ($all, $all_status, $all_reads) = run_launcher('--progress');
is($all_status, 0, 'unfiltered miniature full suite succeeds');
like($all, qr/PASSED\s*:\s*6\/6/, 'all native and standalone assertions are executed');
like($all, qr/100%\s*\[3\/3 files \| 6 tests\]/, 'full coverage and progress counters are retained');
is_deeply($all_reads, [], 'default full execution does no unused capability classification');

my ($plain, $plain_status, $plain_reads) = run_launcher('--filter', '^a_native[.]t$');
is($plain_status, 0, 'plain filtered execution succeeds');
like($plain, qr/PASSED\s*:\s*2\/2/, 'plain filter executes exactly the selected case');
is_deeply($plain_reads, [], 'plain filtered execution reads no classification metadata');

my ($list, $list_status, $list_reads) = run_launcher('--filter', '^(?:a_native|b_tap)[.]t$', '--list-selected');
is($list_status, 0, 'filtered catalogue succeeds');
is_deeply($list_reads, ['a_native.t', 'b_tap.t'], 'catalogue classifies only matching names in lexical order');
like($list, qr/PURE[^\n]*a_native[.]t/, 'native pure classification retained');
like($list, qr/PROCESS[^\n]*b_tap[.]t/, 'standalone isolation still forces PROCESS metadata');
unlike($list, qr/PASSED\s*:/, 'metadata inspection executes no test case');

my ($selected, $selected_status, $selected_reads) = run_launcher('--filter', '^c_database[.]t$', '--class', 'DB');
is($selected_status, 0, 'filtered capability execution succeeds');
is_deeply($selected_reads, ['c_database.t'], 'capability selector reads only its named candidate');
like($selected, qr/PASSED\s*:\s*1\/1/, 'capability selection retains its assertions');

my ($excluded, $excluded_status, $excluded_reads) = run_launcher('--exclude-class', 'PROCESS');
is($excluded_status, 0, 'capability exclusion succeeds');
is_deeply($excluded_reads, ['a_native.t', 'b_tap.t', 'c_database.t'], 'unfiltered capability exclusion classifies the complete catalogue');
like($excluded, qr/PASSED\s*:\s*3\/3/, 'exclusion omits only the matching standalone process case');

my ($summary, $summary_status, $summary_reads) = run_launcher('--filter', '^a_native[.]t$', '--class-summary');
is($summary_status, 0, 'filtered summary succeeds');
is_deeply($summary_reads, ['a_native.t'], 'summary reads only the filtered source');
like($summary, qr/Selected:\s*1 of 3 discovered test file/, 'summary keeps the full discovered denominator');

my ($missing, $missing_status) = run_launcher('--fast', '--filter', '^a_native[.]t$');
ok($missing_status != 0, 'narrow fast filter cannot bypass absent mandatory sentinels');
like($missing, qr/Fast validation sentinel\(s\) missing:/, 'absent-sentinel failure stays explicit');
for my $sentinel (fast_lane_sentinels()) {
    write_case($sentinel, q{return sub {$_[0]->ok(1, 'sentinel fixture')};});
}
my ($fast, $fast_status, $fast_reads) = run_launcher('--fast', '--filter', '^a_native[.]t$');
is($fast_status, 0, 'narrowed fast execution succeeds with the complete sentinel catalogue');
is_deeply($fast_reads, ['a_native.t'], 'fast selection classifies only filtered candidates after checking all sentinels');
like($fast, qr/PASSED\s*:\s*2\/2/, 'fast filter retains its original assertions');

# Re-read source metadata on every invocation; no persistent classification cache.
write_case('c_database.t', q{return sub {$_[0]->ok(1, 'now pure')};});
my ($changed, $changed_status, $changed_reads) = run_launcher('--filter', '^c_database[.]t$', '--class', 'DB');
ok($changed_status != 0, 'updated source no longer matches its old capability');
is_deeply($changed_reads, ['c_database.t'], 'changed source is freshly classified');
like($changed, qr/Aucun fichier de test selectionne/, 'empty capability selection remains a failure');

write_case('z_crash.t', q{return sub {die "regression crash\n"};});
my ($crash, $crash_status, $crash_reads) = run_launcher('--filter', '^z_crash[.]t$', '--progress');
ok($crash_status != 0, 'execution exception remains a nonzero verdict');
like($crash, qr/FAILED\s*:\s*1\/1/, 'crash contributes an assertion failure');
like($crash, qr/z_crash[.]t/, 'compact failure identifies the crashing file');
is_deeply($crash_reads, [], 'crash handling also needs no capability scan');

my ($invalid, $invalid_status, $invalid_reads) = run_launcher('--filter', '[');
ok($invalid_status != 0, 'invalid regex is rejected');
like($invalid, qr/Invalid --filter regex/, 'invalid regex retains a useful error');
is_deeply($invalid_reads, [], 'invalid regex is rejected before reading source metadata');
done_testing();
