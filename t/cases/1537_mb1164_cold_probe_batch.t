use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use ColdProbeBatch qw(run_perl_probes);

my $rows=run_perl_probes([
    q{print "first\0\xff";print STDERR "diagnostic\n";exit 7},
    q{print 'second';exit 0},
    q{kill 9,$$},
    q{print 'x'x100_000;print STDERR 'y'x100_000},
]);
is(scalar @$rows,4,'one result per probe');
is($rows->[0]{stdout},"first\0\xff",'stdout bytes preserved');
is($rows->[0]{stderr},"diagnostic\n",'stderr kept separate');
is($rows->[0]{status},7<<8,'nonzero exit preserved as raw wait status');
is($rows->[1]{stdout},'second','input order preserved');
is($rows->[1]{status},0,'success preserved');
is($rows->[2]{status}&127,9,'signal death cannot become success');
is(length($rows->[3]{stdout}),100_000,'large stdout cannot deadlock');
is(length($rows->[3]{stderr}),100_000,'large stderr cannot deadlock');
my $timed=run_perl_probes([q{sleep 10}],timeout=>0.15);
ok($timed->[0]{timed_out},'hung probe has a deadline');
ok($timed->[0]{status},'timeout fails closed');
like($timed->[0]{stderr},qr/Cold probe timed out/,'timeout diagnosis retained');

# A file-locked counter proves actual overlap and the two-child ceiling;
# no assertion compares elapsed durations on a loaded CI worker.
my $dir=tempdir(CLEANUP=>1);
local $ENV{MB1164_COUNTER}="$dir/counter";
open my $fh,'>',"$dir/counter" or die $!;print {$fh} '0 0';close $fh;
my $code=q{
use Fcntl qw(:flock SEEK_SET);
use Time::HiRes qw(sleep time);
sub counter {
 my ($delta)=@_;
 open my $f,'+<',$ENV{MB1164_COUNTER} or die $!;
 flock($f,LOCK_EX) or die $!;
 my ($active,$max)=split / /,<$f>;
 $active+=$delta;$max=$active if $active>$max;
 seek($f,0,SEEK_SET);truncate($f,0);print {$f} "$active $max";close $f;
 return $max;
}
counter(1);my $end=time()+3;
while(counter(0)<2) {die 'no overlap' if time()>$end;sleep .01}
sleep .03;counter(-1);print 'overlapped';
};
my $parallel=run_perl_probes([($code)x4]);
is_deeply([map {$_->{status}} @$parallel],[(0)x4],'independent probes overlap successfully');
open $fh,'<',"$dir/counter" or die $!;my $counts=<$fh>;close $fh;
is($counts,'0 2','all children finish and concurrency never exceeds two');
{
 local $INC{'MB1164Warm.pm'}=__FILE__;
 my $fresh=run_perl_probes([q{die 'warm parent leaked' if $INC{'MB1164Warm.pm'};print 'cold'}]);
 is($fresh->[0]{status},0,'each child starts a fresh interpreter');
 is($fresh->[0]{stdout},'cold','parent module cache is not inherited');
}
my $serial=run_perl_probes([q{print 'one'},q{print 'two'}],jobs=>1);
is_deeply([map {$_->{stdout}} @$serial],[qw(one two)],'serial comparison mode retains all probes');
for my $jobs (0,3) {
 ok(!eval {run_perl_probes([],jobs=>$jobs);1},'unsupported concurrency rejected');
}
is_deeply(run_perl_probes([]),[],'empty batch completes without children');
# Legacy -we probes must retain global compile/runtime warnings.
for my $warnings (0,1) {
 my $probe=run_perl_probes([q{my $value; print $value; print 'done'}],warnings=>$warnings);
 is($probe->[0]{stdout},'done','warning mode preserves stdout');
 is($probe->[0]{status},0,'warning mode preserves successful exit');
 if ($warnings) {like($probe->[0]{stderr},qr/uninitialized/,'-w diagnostics retained')}
 else {is($probe->[0]{stderr},'','default cold probes do not acquire global warnings')}
}
done_testing;
