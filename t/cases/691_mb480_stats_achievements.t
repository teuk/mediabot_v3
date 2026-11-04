use strict;
use warnings;
use Test::More;
use JSON::PP;

# Run the real stats handler once per scenario in one isolated process, so
# timezone and frozen-clock controls cannot affect unrelated tests.
my $probe=<<'NATIVE';
use strict;
use warnings;
use utf8;
our $stats_now=0;
BEGIN {*CORE::GLOBAL::time=sub {$main::stats_now}}
use DBI;
use JSON::PP;
use POSIX qw(strftime tzset);
use Time::Local qw(timegm);
use Mediabot::UserCommands;
use Mediabot::Context;
use Mediabot::Stats::Activity;
{
 package Stats97::Conf;
 sub get {return { 'mysql.CHANNEL_LOG_ARCHIVE_DBNAME'=>'history',
   'mysql.CHANNEL_LOG_ARCHIVE_CONTENT_DAYS'=>30,
   'mysql.CHANNEL_LOG_ARCHIVE_PRESENCE_DAYS'=>30 }->{$_[1]}}
 package Stats97::Channel;
 sub get_id {1}
 sub get_timezone {'UTC'}
 package Stats97::Achievements;
 sub get_for_nick {
  my ($s,$nick,$channel)=@_;push @{$s->{calls}},[$nick,$channel];
  die "fixture achievements unavailable\n" if $s->{fail};
  return $s->{data}{lc($nick)."\0".lc($channel)} // {};
 }
}
my (@public,@notices,@audit);
no warnings qw(redefine once);
local *Mediabot::UserCommands::botPrivmsg=sub {push @public,[@_[1,2]];1};
local *Mediabot::UserCommands::botNotice=sub {push @notices,[@_[1,2]];1};
local *Mediabot::UserCommands::logBot=sub {push @audit,[@_[2,3,4]];1};
local *Mediabot::UserCommands::getIdUser=sub {$_[1] eq 'alice'?7:0};
sub run {
 my (%a)=@_;
 local $ENV{TZ}=$a{tz}//'UTC';tzset();
 $stats_now=$a{now}//timegm(0,0,12,4,10,2026);
 my $offset=$a{sql_offset}//0;
 my $stamp=sub {strftime('%Y-%m-%d %H:%M:%S',gmtime($_[0]+$offset))};
 my $dbh=DBI->connect('dbi:SQLite:dbname=:memory:','','',
  {RaiseError=>1,PrintError=>0,AutoCommit=>1,sqlite_unicode=>1});
 $dbh->sqlite_create_function('UNIX_TIMESTAMP',1,sub {
  my ($s)=@_;return undef unless defined $s;
  return undef if $a{epoch} && $a{epoch} eq 'missing';
  return 'unavailable' if $a{epoch} && $a{epoch} eq 'malformed';
  my ($y,$m,$d,$h,$min,$sec)=$s=~/^(\d{4})-(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)$/;
  return undef unless defined $sec;
  return timegm($sec,$min,$h,$d,$m-1,$y)-$offset;
 });
 $dbh->sqlite_create_function('REGEXP',2,sub {
  my ($pattern,$value)=@_;return defined($value) && $value=~/$pattern/?1:0;
 });
 $dbh->do('CREATE TABLE CHANNEL(id_channel INTEGER,name TEXT)');
 $dbh->do("INSERT INTO CHANNEL VALUES(1,'#test')");
 $dbh->do('CREATE TABLE CHANNEL_LOG(id_channel INTEGER,nick TEXT,ts TEXT,event_type TEXT,publictext TEXT)');
 $dbh->do("ATTACH DATABASE ':memory:' AS history");
 $dbh->do('CREATE TABLE history.CHANNEL_LOG_ARCHIVE(id_channel INTEGER,nick TEXT,ts TEXT,event_type TEXT,publictext TEXT)');
 $dbh->do('CREATE TABLE USER_SEEN(nick TEXT,seen_at TEXT,event_type TEXT)');
 $dbh->do('CREATE TABLE KARMA(id_channel INTEGER,nick TEXT,score INTEGER)');
 $dbh->do("INSERT INTO KARMA VALUES(1,'alice',7)");
 $dbh->do('CREATE TABLE USER(id_user INTEGER,id_user_level INTEGER)');
 $dbh->do('CREATE TABLE USER_LEVEL(id_user_level INTEGER,description TEXT)');
 $dbh->do("INSERT INTO USER VALUES(7,1)");$dbh->do("INSERT INTO USER_LEVEL VALUES(1,'User')");
 my $first=$a{zero}?0:$stats_now-(3*86400+10*3600+1200);
 my $last=$stats_now-3*3600-1200;
 my $seen=$stats_now-13*3600-1200;
 if ($a{future}) {($first,$last,$seen)=map {$stats_now+$_} (3600,7200,10800)}
 my @rows=(['CHANNEL_LOG',$last,'public','hello'],
   ['history.CHANNEL_LOG_ARCHIVE',$first,'join',undef],
   ['history.CHANNEL_LOG_ARCHIVE',$a{future}?$last+3600:$last-86400,'public','older message']);
 @rows=reverse @rows if $a{reverse};
 unless ($a{empty}) {
  for my $row (@rows) {
   my ($table,$epoch,$type,$text)=@$row;
   $dbh->do("INSERT INTO $table VALUES(1,'alice',?,?,?)",undef,$stamp->($epoch),$type,$text);
  }
  $dbh->do("INSERT INTO CHANNEL_LOG VALUES(1,'bob',?,'public','other')",undef,$stamp->($last+300));
  $dbh->do("INSERT INTO USER_SEEN VALUES('alice',?,'quit')",undef,$stamp->($seen));
 }
 my $ach=$a{without_ach}?undef:bless({calls=>[],fail=>$a{ach_fail},
  data=>{$a{no_ach}?(): ("alice\0#test"=>{1=>111,2=>222,3=>333})}},'Stats97::Achievements');
 my $bot={dbh=>$dbh,conf=>bless({},'Stats97::Conf'),
  channels=>{'#test'=>bless({},'Stats97::Channel')},achievements=>$ach};
 my $ctx=Mediabot::Context->new(bot=>$bot,nick=>$a{self}?'Alice':'Observer',
  channel=>'#test',command=>'stats',args=>['Alice'],message=>'!stats Alice');
 @public=();@notices=();@audit=();my (@warnings,$result);
 my $ok=eval {local $SIG{__WARN__}=sub {push @warnings,@_};
  $result=Mediabot::Stats::Activity::mbStats_ctx($ctx);1};
 my $out={ok=>$ok?1:0,result=>$result,error=>"$@",warnings=>\@warnings,
  public=>[@public],notices=>[@notices],audit=>[@audit],
  ach_calls=>$ach?$ach->{calls}:[],first=>$stamp->($first),last=>$stamp->($last),seen=>$stamp->($seen)};
 $dbh->disconnect;return $out;
}
my %out;
my @now=(timegm(0,0,12,4,10,2026),timegm(0,30,1,29,2,2026),
 timegm(0,30,1,25,9,2026),timegm(0,0,12,1,5,2026));
for my $tz (qw(UTC Europe/Paris Canada/Eastern Asia/Kolkata Australia/Lord_Howe)) {
 for my $offset (0,19800,-18000) {
  for my $i (0..$#now) {
   $out{ages}{join('/',$tz,$offset,$i)}=run(tz=>$tz,sql_offset=>$offset,now=>$now[$i],reverse=>$i%2);
  }
 }
}
for my $kind (qw(no_ach without_ach ach_fail self empty future zero)) {
 $out{controls}{$kind}=run(tz=>'Canada/Eastern',$kind=>1);
}
for my $kind (qw(missing malformed)) {$out{controls}{$kind}=run(epoch=>$kind)}
print JSON::PP->new->canonical->utf8->encode(\%out);
NATIVE
open my $pipe,'-|',$^X,'-I.','-It/lib','-e',$probe or die $!;
my $raw=do {local $/;<$pipe>};close $pipe;
my $rc=$?;my $data=eval {decode_json($raw)};
ok($rc==0 && ref($data) eq 'HASH','native stats/SQLite probe completes');
if ($rc==0 && ref($data) eq 'HASH') {
 my (@bad_age,@bad_labels,@bad_contract);
 for my $key (sort keys %{$data->{ages}}) {
  my $x=$data->{ages}{$key};my $line=$x->{public}[0][1]//'';
  push @bad_age,$key unless $line=~/first seen: .*? \(3d 10h ago\)/
   && $line=~/last msg: .*? \(3h ago\)/ && $line=~/last seen: .*? \(13h ago\)/;
  push @bad_labels,$key unless index($line,"first seen: $x->{first}")>=0
   && index($line,"last msg: $x->{last}")>=0
   && index($line,"last seen: $x->{seen} (quit)")>=0;
  push @bad_contract,$key unless $x->{ok} && $x->{result}==1 && !$x->{error}
   && !@{$x->{warnings}} && !@{$x->{notices}} && @{$x->{public}}==1
   && $x->{public}[0][0] eq '#test' && $line=~/alice \(User\): 2 messages \(66\.7%\)/
   && $line=~/karma \+7/ && $line=~/rank: #1/ && $line=~/achievements: 3/
   && encode_json($x->{audit}) eq encode_json([['#test','stats','alice']])
   && encode_json($x->{ach_calls}) eq encode_json([['alice','#test']]);
 }
 is_deeply(\@bad_age,[],'MB1097 all 60 host/session timezone and DST combinations keep exact elapsed ages');
 is_deeply(\@bad_labels,[],'live/archive extrema keep their own epochs and original SQL date labels');
 is_deeply(\@bad_contract,[],'native stats preserves counts, rank, karma, achievements, channel output and audit');
 my $control=sub {$data->{controls}{$_[0]}{public}[0][1]//''};
 ok(index($control->('no_ach'),'achievements:')<0 && index($control->('without_ach'),'achievements:')<0
  && index($control->('ach_fail'),'achievements:')<0,
  'missing, empty and failed achievement providers do not fabricate a count');
 ok(index($control->('self'),'last seen:')<0 && $control->('self')=~/achievements: 3/,
  'self stats omits the current seen row while retaining channel achievements');
 ok($control->('empty')=~/0 messages/ && $control->('empty')!~/first seen:|last msg:|last seen:|rank:/,
  'empty history remains a valid result without fabricated dates or rank');
 ok($control->('future')!~/ ago\)/ && $control->('future')=~/first seen:.*last msg:.*last seen:/,
  'future SQL epochs keep their labels without negative ages');
 ok($control->('zero')=~/first seen: 1970-01-01 00:00:00 \([^)]* ago\)/,
  'epoch zero is a valid SQL timestamp rather than an absent age');
 ok($control->('missing')!~/ ago\)/ && $control->('malformed')!~/ ago\)/
  && $control->('missing')=~/first seen:.*last msg:.*last seen:/,
  'missing and malformed epoch metadata never fall back to a host timezone guess');
}
done_testing;
