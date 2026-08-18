#!/usr/bin/perl
use strict;
use warnings;

use FindBin;
use Getopt::Long;
use File::Temp qw(tempdir);
use Time::HiRes ();
use POSIX qw(_exit);

use lib "$FindBin::Bin/lib";
use FastValidation qw(fast_lane_sentinels);

binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

my $jobs = 2;
my $plan_only = 0;
my $expect_assertions;
my $help = 0;

GetOptions(
    'jobs=i'              => \$jobs,
    'plan-only'           => \$plan_only,
    'expect-assertions=i' => \$expect_assertions,
    'help|h'              => \$help,
) or die _usage();

if ($help) {
    print _usage();
    exit 0;
}

die "--jobs must be between 2 and 4\n"
    if $jobs < 2 || $jobs > 4;

die "--expect-assertions must be a positive integer\n"
    if defined($expect_assertions) && $expect_assertions < 1;

my $root   = "$FindBin::Bin/..";
my $runner = "$FindBin::Bin/test_commands.pl";

my $selection = _discover_fast_selection($runner, $root);
my @selected = sort keys %$selection;
die "fast lane discovery returned no test files\n" unless @selected;

my %sentinel = map { $_ => 1 } fast_lane_sentinels();

for my $name (sort keys %sentinel) {
    die "mandatory fast sentinel missing from selected lane: $name\n"
        unless exists $selection->{$name};
}

my (@serial, @parallel);
for my $name (@selected) {
    if ($sentinel{$name}) {
        push @serial, $name;
        next;
    }

    my $primary = $selection->{$name}{primary} // '';
    die "non-sentinel fast file is not primary PURE: $name ($primary)\n"
        unless $primary eq 'PURE';

    push @parallel, $name;
}

die "parallel candidate set is empty\n" unless @parallel;
die "serial sentinel set is empty\n" unless @serial;

my @shards = map { [] } 1 .. $jobs;
for my $i (0 .. $#parallel) {
    push @{ $shards[$i % $jobs] }, $parallel[$i];
}

for my $i (0 .. $#shards) {
    die "parallel shard " . ($i + 1) . " is empty\n"
        unless @{ $shards[$i] };
}

my %coverage;
$coverage{$_}++ for @serial;
for my $shard (@shards) {
    $coverage{$_}++ for @$shard;
}

die "parallel plan coverage mismatch\n"
    unless scalar(keys %coverage) == scalar(@selected);

for my $name (@selected) {
    die "parallel plan duplicate/missing file: $name\n"
        unless ($coverage{$name} // 0) == 1;
}

_print_plan(
    selected => \@selected,
    serial   => \@serial,
    parallel => \@parallel,
    shards   => \@shards,
    jobs     => $jobs,
);

exit 0 if $plan_only;

my $tmpdir = tempdir('mediabot-fast-parallel-XXXXXX', TMPDIR => 1, CLEANUP => 1);
my $wall_started = Time::HiRes::time();

print "\nParallel PURE stage\n";
print "-" x 72 . "\n";

my @children;
for my $i (0 .. $#shards) {
    my $number = $i + 1;
    my $log = "$tmpdir/shard-$number.log";
    my $regex = _exact_name_regex($shards[$i]);

    my $pid = fork();
    die "cannot fork parallel shard $number: $!\n" unless defined $pid;

    if ($pid == 0) {
        open STDOUT, '>:raw', $log or _exit(254);
        open STDERR, '>&', STDOUT or _exit(254);
        chdir $root or _exit(254);
        {
            no warnings 'exec';
            exec(
                $^X,
                $runner,
                '--fast',
                '--filter', $regex,
            );
        }
        _exit(254);
    }

    push @children, {
        pid   => $pid,
        shard => $number,
        files => scalar(@{ $shards[$i] }),
        log   => $log,
    };
}

my @results;
for my $child (@children) {
    waitpid($child->{pid}, 0);
    my $status = $?;
    my $result = _read_result(
        label  => "parallel shard $child->{shard}",
        status => $status,
        log    => $child->{log},
        files  => $child->{files},
    );
    push @results, $result;
}

for my $result (sort { $a->{label} cmp $b->{label} } @results) {
    _print_result($result);
}

my @failed = grep { !$_->{ok} } @results;
if (@failed) {
    for my $result (@failed) {
        _print_log_tail($result->{log}, 80);
    }
    die "parallel PURE stage failed\n";
}

print "\nSerial sentinel stage\n";
print "-" x 72 . "\n";

my $serial_log = "$tmpdir/sentinels.log";
my $serial_regex = _exact_name_regex(\@serial);
my $serial_status = _run_sync(
    log  => $serial_log,
    root => $root,
    cmd  => [
        $^X,
        $runner,
        '--fast',
        '--filter', $serial_regex,
    ],
);

my $serial_result = _read_result(
    label  => 'serial sentinels',
    status => $serial_status,
    log    => $serial_log,
    files  => scalar(@serial),
);
_print_result($serial_result);

if (!$serial_result->{ok}) {
    _print_log_tail($serial_log, 120);
    die "serial sentinel stage failed\n";
}

push @results, $serial_result;

my $passed = 0;
my $total  = 0;
$passed += $_->{passed} for @results;
$total  += $_->{total}  for @results;

die "aggregate assertion count is not fully passing ($passed/$total)\n"
    unless $passed == $total;

if (defined $expect_assertions && $total != $expect_assertions) {
    die "aggregate assertion count mismatch: expected "
        . "$expect_assertions, got $total\n";
}

my $wall = Time::HiRes::time() - $wall_started;

print "\nFast parallel pilot result\n";
print "=" x 72 . "\n";
printf "Files       : %d\n", scalar(@selected);
printf "Assertions  : %d/%d\n", $passed, $total;
printf "Jobs        : %d\n", $jobs;
printf "Wall time   : %.3fs\n", $wall;
print  "Contract    : opt-in pilot; NOT equivalent to the full suite\n";
print  "Verdict     : FAST_PARALLEL_PILOT=OK\n";

exit 0;

sub _discover_fast_selection {
    my ($runner_path, $project_root) = @_;

    my $pid = open(my $fh, '-|');
    die "cannot launch fast-lane discovery: $!\n" unless defined $pid;

    if ($pid == 0) {
        open STDERR, '>&', STDOUT or _exit(254);
        chdir $project_root or _exit(254);
        {
            no warnings 'exec';
            exec(
                $^X,
                $runner_path,
                '--fast',
                '--list-selected',
            );
        }
        _exit(254);
    }

    local $/;
    my $out = <$fh> // '';
    close $fh;
    my $status = $?;

    die "fast-lane discovery failed:\n$out\n"
        if $status != 0;

    my %selected;
    for my $line (split /\n/, $out) {
        next unless $line =~ /^\s*(PURE|FILESYSTEM|PROCESS|DB|NETWORK)\s+.*\s+(\S+\.t)\s*$/;
        $selected{$2} = {
            primary => $1,
        };
    }

    return \%selected;
}

sub _exact_name_regex {
    my ($names) = @_;
    return '^(?:' . join('|', map { quotemeta($_) } @$names) . ')$';
}

sub _run_sync {
    my (%args) = @_;
    my $log  = $args{log};
    my $root = $args{root};
    my $cmd  = $args{cmd};

    my $pid = fork();
    die "cannot fork serial stage: $!\n" unless defined $pid;

    if ($pid == 0) {
        open STDOUT, '>:raw', $log or _exit(254);
        open STDERR, '>&', STDOUT or _exit(254);
        chdir $root or _exit(254);
        {
            no warnings 'exec';
            exec(@$cmd);
        }
        _exit(254);
    }

    waitpid($pid, 0);
    return $?;
}

sub _read_result {
    my (%args) = @_;

    open my $fh, '<:raw', $args{log}
        or die "cannot read $args{log}: $!\n";
    local $/;
    my $out = <$fh> // '';
    close $fh;

    my @summary = ($out =~ /PASSED\s*:\s*(\d+)\/(\d+)\s*\((\d+)s\)/g);
    my ($passed, $total, $seconds);

    if (@summary >= 3) {
        ($passed, $total, $seconds) = @summary[-3 .. -1];
    }

    my $signal = $args{status} & 127;
    my $exit   = $args{status} >> 8;

    my $ok = !$signal
        && $exit == 0
        && defined($passed)
        && defined($total)
        && $passed == $total;

    return {
        label   => $args{label},
        files   => $args{files},
        log     => $args{log},
        signal  => $signal,
        exit    => $exit,
        passed  => defined($passed) ? 0 + $passed : 0,
        total   => defined($total) ? 0 + $total : 0,
        seconds => defined($seconds) ? 0 + $seconds : 0,
        ok      => $ok ? 1 : 0,
    };
}

sub _print_plan {
    my (%args) = @_;

    print "\nFast parallel pilot plan\n";
    print "-" x 72 . "\n";
    printf "Selected fast files : %d\n", scalar(@{ $args{selected} });
    printf "Parallel PURE files : %d\n", scalar(@{ $args{parallel} });
    printf "Serial sentinels    : %d\n", scalar(@{ $args{serial} });
    printf "Parallel jobs       : %d\n", $args{jobs};

    for my $i (0 .. $#{ $args{shards} }) {
        printf "  shard %d            : %d file(s)\n",
            $i + 1,
            scalar(@{ $args{shards}[$i] });
    }

    print "Policy              : only non-sentinel primary PURE files overlap\n";
    print "Sentinels           : always run in a separate serial stage\n";
    print "Scope               : opt-in pilot; NOT equivalent to full suite\n";
}

sub _print_result {
    my ($result) = @_;
    printf "%-20s files=%-4d assertions=%d/%d runner=%ds rc=%d%s\n",
        $result->{label},
        $result->{files},
        $result->{passed},
        $result->{total},
        $result->{seconds},
        $result->{exit},
        $result->{signal} ? " signal=$result->{signal}" : '';
}

sub _print_log_tail {
    my ($path, $lines) = @_;

    open my $fh, '<:raw', $path or return;
    my @all = <$fh>;
    close $fh;

    my $start = @all > $lines ? @all - $lines : 0;
    print "\n--- tail $path ---\n";
    print @all[$start .. $#all] if @all;
}

sub _usage {
    return <<'USAGE';
Usage: perl t/fast_parallel.pl [options]

  --jobs <2..4>             Number of concurrent PURE shards (default: 2)
  --plan-only               Show the deterministic plan without running tests
  --expect-assertions <n>   Fail unless aggregate passing assertions equal n
  --help, -h                Show this help

The pilot reuses the committed MB661 --fast selection. Only non-sentinel tests
whose selected primary class is PURE are overlapped. Mandatory sentinels run in
a separate serial stage. This is opt-in and is NOT equivalent to the full suite.
USAGE
}
