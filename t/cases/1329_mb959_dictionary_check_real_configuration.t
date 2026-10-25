use strict;
use warnings;
use utf8;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);
use Digest::SHA qw(sha256_hex);
use POSIX ();
use Mediabot::Conf;
use Mediabot::Plugin::DictionaryV3;

my $tmp=tempdir(CLEANUP=>1);
my $root=abs_path('.');
my $conf="$tmp/mediabot.conf";
my $trace="$tmp/driver-called";
sub write_conf {
    my ($body)=@_;
    open my $fh,'>',$conf or die $!;
    print {$fh} $body;close $fh or die $!;chmod 0600,$conf;
}
my $body="[mysql]\nMAIN_PROG_DBHOST=localhost\nMAIN_PROG_DBUSER=reader\nMAIN_PROG_DBPASS=private_fixture_only\nMAIN_PROG_DBPORT=3306\n";
write_conf($body);
my $native=Mediabot::Conf->new(undef,$conf);
my $settings=Mediabot::Plugin::DictionaryV3->settings($native);
is($settings->{database},'DICT','real native configuration selects DICT');
is($settings->{user},'reader','native mysql credentials are available to the core reader');
is($settings->{host},'127.0.0.1','native loader retains the normal TCP convention');
is($settings->{pass},'private_fixture_only','private password is read without a compatibility mock');

# This stub is confined to this isolated test process and its child. It replaces
# only the native SQL transport; the tool, native configuration loader and solver
# are executed unchanged. Any real database access is impossible in this test.
make_path("$tmp/driver");
open my $driver,'>',"$tmp/driver/DBI.pm" or die $!;
print {$driver} <<'DRIVER';
package DBI;
use strict;use warnings;
sub connect {
    my ($class,$dsn,$user,$pass,$attrs)=@_;
    open my $trace,'>',$ENV{MB959_CHECK_TRACE} or die $!;print {$trace} "called\n";close $trace;
    die "native private_fixture_only failure\n" if $ENV{MB959_CHECK_FAIL};
    die "wrong database\n" unless $dsn =~ /database=DICT;/;
    die "wrong credentials\n" unless $user eq 'reader' && $pass eq 'private_fixture_only';
    return bless {},'MB959::CheckDB';
}
package MB959::CheckDB;
sub do {1}
sub disconnect {1}
sub begin_work {1}
sub rollback {1}
sub selectall_arrayref {[{Key_name=>'sorted',Column_name=>'sorted',Seq_in_index=>1}]}
sub prepare {bless {},'MB959::CheckStatement'}
package MB959::CheckStatement;
sub execute {
    my ($self,@bind)=@_;
    my %wanted=map {$_=>1} @bind;
    $self->{rows}=$wanted{'AEEINORSTT'} ? [['ORIENTATES','AEEINORSTT']] : [];
    return 1;
}
sub fetchrow_arrayref {shift @{$_[0]{rows}}}
sub finish {1}
1;
DRIVER
close $driver;

sub run_tool {
    my (%opts)=@_;
    local $ENV{MB959_CHECK_TRACE}=$trace;
    local $ENV{MB959_CHECK_FAIL}=$opts{fail} ? 1 : '';
    unlink $trace if -e $trace;
    my $pid=open my $pipe,'-|';
    die $! unless defined $pid;
    if (!$pid) {
        open STDERR,'>&',STDOUT or POSIX::_exit(125);
        exec($^X,"-I$tmp/driver","-I$root",'tools/dictionary_check.pl','--conf',$conf)
            or POSIX::_exit(126);
    }
    local $/;my $out=<$pipe>//'';close $pipe;my $rc=$? >> 8;
    return ($rc,$out);
}
my $before=sha256_hex(do {open my $f,'<',$conf or die $!;local $/;<$f>});
my ($rc,$out)=run_tool();
is($rc,0,'standalone dictionary check accepts an actual production-format config');
ok(-f $trace,'check reaches the SQL boundary after native configuration parsing');
like($out,qr/DICT\.DICT.*maximum 10 lettres : ORIENTATES/,'real tool completes the solver path');
unlike($out,qr/private_fixture_only/,'successful probe never prints a password');
is(sha256_hex(do {open my $f,'<',$conf or die $!;local $/;<$f>}),$before,'probe preserves private configuration bytes');
is((stat($conf))[2]&0777,0600,'probe preserves private configuration permissions');

($rc,$out)=run_tool(fail=>1);
is($rc,1,'failed native connection remains a failing probe');
ok(-f $trace,'connection failure is distinguished from configuration rejection');
unlike($out,qr/private_fixture_only/,'failed connection does not expose credentials');
like($out,qr/dictionary_connection\. Voir docs\/LONGEST_WORD_PLUGIN\.md/,'failure points to the document actually shipped');

write_conf($body."\n[dictionary]\nPORT=not-a-number\n");
($rc,$out)=run_tool();
is($rc,1,'invalid private override is refused');
ok(!-e $trace,'invalid override is rejected before touching the SQL transport');
done_testing;
