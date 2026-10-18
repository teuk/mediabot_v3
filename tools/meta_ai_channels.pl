#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";
use Getopt::Long qw(GetOptions);
use JSON::PP ();
use Mediabot::Conf;
use Mediabot::AI::MetaPolicy qw(settings);
use Mediabot::AI::MetaActivation qw(activation_plan initialize_chanset);
my ($file,$apply,$adopt,$json,$help)=('mediabot.conf',0,0,0,0);
GetOptions('conf=s'=>\$file,'apply'=>\$apply,'adopt-legacy'=>\$adopt,'json'=>\$json,'help'=>\$help) or exit 2;
if($help){print "Usage: perl tools/meta_ai_channels.pl --conf FILE [--adopt-legacy] [--apply] [--json]\n";
 print "Default: read-only preview. --apply registers +MetaAI in existing tables; --adopt-legacy preserves only the previously enabled listed +chatGPT channels on first registration. Later runs never re-enable removed flags. No schema/configuration/service changes.\n";exit 0}
my $dbh;my $result;my $error='configuration_or_database';
my $ok=eval {
 local $SIG{__WARN__}=sub {};
 my @st=stat($file);die unless @st && -f $file && -r $file && ($st[2]&0777)==0600 && $st[4]==$>;
 my $c=Mediabot::Conf->new({},$file);my $cfg=settings($c);
 require DBI;
 my $name=$c->get('mysql.MAIN_PROG_DDBNAME')//'';my $host=$c->get('mysql.MAIN_PROG_DBHOST')//'localhost';
 my $port=$c->get('mysql.MAIN_PROG_DBPORT')//3306;my $user=$c->get('mysql.MAIN_PROG_DBUSER')//'';
 die if ref($name) || ref($host) || ref($port) || ref($user) || !length($user)
  || $name!~/\A[A-Za-z0-9_-]{1,128}\z/ || $host!~/\A[A-Za-z0-9.:-]{1,253}\z/ || $port!~/\A[0-9]{1,5}\z/;
 $host='127.0.0.1' if $host eq 'localhost';
 $dbh=DBI->connect("DBI:MariaDB:database=$name;host=$host;port=$port;mariadb_connect_timeout=5;mariadb_read_timeout=5;mariadb_write_timeout=5",
  $user,$c->get('mysql.MAIN_PROG_DBPASS')//'',{RaiseError=>1,PrintError=>0,AutoCommit=>1});
 die unless $dbh;
 if($apply){$error='data_initialization';$result=initialize_chanset($dbh,$cfg,adopt_legacy=>$adopt)}
 else {$dbh->do('START TRANSACTION READ ONLY');$result=activation_plan($dbh,$cfg);$dbh->rollback}
 $result->{applied}=$apply?1:0;$result->{adopt_requested}=$adopt?1:0;$result->{master_enabled}=$cfg->{enabled}?1:0;
 $dbh->disconnect;1;
};
unless($ok){eval {$dbh->rollback;$dbh->disconnect} if $dbh;
 if($json){print JSON::PP->new->canonical->encode({ok=>0,error=>$error}),"\n"}
 else {print "[KO] MetaAI $error check failed; no credentials or private SQL details are displayed.\n"}
 exit 1;
}
$result->{ok}=1;
if($json){print JSON::PP->new->canonical->utf8->encode($result),"\n";exit 0}
print $apply?'[OK] ':'[PLAN] ', 'MetaAI catalogue: ', $result->{registered}?'registered':'not registered',
 '; global switch: ', $result->{master_enabled}?'enabled':'disabled',"\n";
print 'Active +MetaAI channels: ',join(' ',@{$result->{active}})||'<none>',"\n";
if(!$result->{registered}){
 print 'First-registration legacy candidates: ',join(' ',@{$result->{adopt}})||'<none>',"\n";
 print 'Omitted legacy channels: ',join(' ',@{$result->{omitted}})||'<none>',"\n" if @{$result->{omitted}};
 print $adopt?'[PLAN] --apply will preserve only those candidates.':'[PLAN] --apply without --adopt-legacy enables no channel.',"\n";
}
print '[OK] Adopted: ',join(' ',@{$result->{adopted}})||'<none>',"\n" if $apply;
print $apply?'[OK] Data-only initialization completed.':'[OK] Read-only preview completed.'," No IRC, configuration save, schema change or service restart.\n";
