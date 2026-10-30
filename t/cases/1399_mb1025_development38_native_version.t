use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use Cwd qw(abs_path getcwd);
my $commit=abs_path('commit.sh');
my $dir=tempdir('mb1025-version-XXXXXX',TMPDIR=>1,CLEANUP=>1);
my $cwd=getcwd();
system('git','init','-q',$dir)==0 or die 'local version-plan repository initialization failed';
sub read_1399 {open my $f,'<',$_[0] or die $!;local $/;return <$f>}
sub write_1399 {open my $f,'>',$_[0] or die $!;print {$f} $_[1];close $f or die $!}
sub plan_1399 {
 my (@args)=@_;my $out="$dir/output";my $pid=fork();die $! unless defined $pid;
 if (!$pid) {
  chdir $dir or die $!;open STDOUT,'>',$out or die $!;open STDERR,'>&',STDOUT or die $!;
  $ENV{COMMIT_VERSION_DATE_TAG}='20261030_130708';exec 'bash',$commit,@args,'--version-plan';die $!;
 }
 waitpid($pid,0);return [$? >> 8,read_1399($out)];
}
write_1399("$dir/VERSION","3.7\n");
my $open=plan_1399('--development','3.8');
ok($open->[0]==0 && $open->[1]=~/VERSION plan: 3\.8dev-20261030_130708/
 && read_1399("$dir/VERSION") eq "3.7\n",
 'native explicit development mode plans 3.8 from stable 3.7 without writing or contacting a remote');
my $stable=plan_1399();
ok($stable->[0]!=0 && $stable->[1]=~/stable release '3\.7'/ && read_1399("$dir/VERSION") eq "3.7\n",
 'ordinary commits still refuse to leave new work labelled as the stable 3.7 release');
write_1399("$dir/VERSION","3.8dev-20260101_010203\n");
my $next=plan_1399();
ok($next->[0]==0 && $next->[1]=~/VERSION plan: 3\.8dev-20261030_130708/
 && read_1399("$dir/VERSION") eq "3.8dev-20260101_010203\n",
 'later ordinary commits continue the native 3.8dev timestamp format without a manual version edit');
is(getcwd(),$cwd,'the version-plan trials do not change the test runner working directory');
done_testing;
