use strict;
use warnings;
use Test::More;
use DBI;
use File::Temp qw(tempdir);
use IPC::Open3;
use Symbol qw(gensym);
use JSON::PP qw(decode_json);
use Cwd qw(abs_path);
my $tmp=tempdir(CLEANUP=>1);my $dbfile="$tmp/database.sqlite";my $conf="$tmp/bot.conf";
my $dbh=DBI->connect("dbi:SQLite:dbname=$dbfile",'','',{RaiseError=>1,PrintError=>0});
$dbh->do('CREATE TABLE CHANSET_LIST(id_chanset_list INTEGER PRIMARY KEY,chanset TEXT UNIQUE)');
$dbh->do('CREATE TABLE CHANNEL(id_channel INTEGER PRIMARY KEY,name TEXT UNIQUE)');
$dbh->do('CREATE TABLE CHANNEL_SET(id_channel_set INTEGER PRIMARY KEY,id_channel INTEGER,id_chanset_list INTEGER)');
$dbh->do("INSERT INTO CHANSET_LIST VALUES(1,'chatGPT')");$dbh->do("INSERT INTO CHANNEL VALUES(1,'#pilot'),(2,'#other')");
$dbh->do('INSERT INTO CHANNEL_SET VALUES(1,1,1)');$dbh->disconnect;
open my $f,'>',$conf or die $!;print {$f} <<'CONF';
[meta_ai]
ENABLED=1
CHANNELS=#pilot #other
[mysql]
MAIN_PROG_DDBNAME=offline_test
MAIN_PROG_DBUSER=offline_test
MAIN_PROG_DBPASS=YOUR_DATABASE_TEST_SECRET
CONF
close $f;chmod 0600,$conf;
open $f,'>',"$tmp/MB842Bootstrap.pm" or die $!;print {$f} <<'MODULE';
package MB842Bootstrap;
use strict;
use warnings;
use DBI;
no warnings 'redefine';
my $connect=\&DBI::connect;my $do=\&DBI::db::do;
*DBI::connect=sub {
 my ($class,$dsn,@args)=@_;
 die 'unexpected network attempt' unless $dsn =~ /^DBI:MariaDB:/;
 my $dbh=$connect->($class,'dbi:SQLite:dbname='.$ENV{MB842_TEST_DB},'','',{RaiseError=>1,PrintError=>0});
 $dbh->sqlite_create_function('DATABASE',0,sub {'offline_test'});
 $dbh->sqlite_create_function('GET_LOCK',2,sub {1});
 $dbh->sqlite_create_function('RELEASE_LOCK',1,sub {1});
 return $dbh;
};
*DBI::db::do=sub {
 my ($dbh,$sql,@rest)=@_;
 $sql='BEGIN TRANSACTION' if $sql eq 'START TRANSACTION READ ONLY';
 return $do->($dbh,$sql,@rest);
};
1;
MODULE
close $f;
sub run842 {
 my (@args)=@_;local $ENV{MB842_TEST_DB}=$dbfile;
 local $ENV{PERL5LIB}=join(':',$tmp,abs_path('.'),$ENV{PERL5LIB}//'');
 local $ENV{PERL5OPT}='-MMB842Bootstrap';
 my $err=gensym;my $pid=open3(undef,my $out,$err,$^X,'tools/meta_ai_channels.pl',@args);
 local $/;my $text=(<$out>//'').(<$err>//'');waitpid($pid,0);return ($?>>8,$text);
}
my ($exit,$text)=run842('--conf',$conf,'--json','--adopt-legacy');
is($exit,0,'private owner can preview channel initialization');
my $r=decode_json($text);ok($r->{ok} && !$r->{applied} && !$r->{registered},'default CLI mode reports a read-only unregistered policy');
is_deeply($r->{adopt},['#pilot'],'CLI preview adopts only eligible legacy channels');
is_deeply($r->{omitted},['#other'],'CLI preview reports ineligible channel');
unlike($text,qr/YOUR_DATABASE_TEST_SECRET|offline_test/,'CLI JSON contains no credential or database name');
($exit,$text)=run842('--conf',$conf,'--json','--adopt-legacy','--apply');
is($exit,0,'explicit CLI apply succeeds on isolated existing tables');
$r=decode_json($text);ok($r->{ok} && $r->{applied} && $r->{created},'apply distinguishes actual first registration');
is_deeply($r->{active},['#pilot'],'CLI apply retains eligible old channel');
($exit,$text)=run842('--conf',$conf,'--json','--adopt-legacy','--apply');
$r=decode_json($text);ok($exit==0 && !$r->{created} && !@{$r->{adopted}},'repeated CLI apply does not replay adoption');
chmod 0644,$conf;($exit,$text)=run842('--conf',$conf,'--json');
ok($exit!=0,'publicly readable private config is refused');
unlike($text,qr/YOUR_DATABASE_TEST_SECRET|offline_test/,'failure JSON remains private');
($exit,$text)=run842('--help');is($exit,0,'help needs neither configuration nor network');
like($text,qr/read-only preview/,'help explains the default read-only mode');
done_testing;
