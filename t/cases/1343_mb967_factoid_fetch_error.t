use strict;
use warnings;
use Test::More;
use DBI;
use Mediabot::Plugin::FactoidServiceV3;
{
 package MB967::DBI; our @ISA=('DBI');
 package MB967::DBI::db; our @ISA=('DBI::db');
 package MB967::DBI::st; our @ISA=('DBI::st');
 sub fetchrow_hashref {
  my ($s)=@_;
  return $s->set_err(1,'private fetch detail') if $s->{Database}{private_fault};
  return $s->SUPER::fetchrow_hashref;
 }
}
$INC{'MB967/DBI.pm'}=__FILE__;
for my $raise (0,1) {
 my $db=DBI->connect('dbi:SQLite:dbname=:memory:','','',{RootClass=>'MB967::DBI',RaiseError=>$raise,PrintError=>0});
 $db->do('CREATE TABLE CHANNEL(id_channel INTEGER,name TEXT)');
 $db->do('CREATE TABLE FACTOID(id_factoid INTEGER,id_channel INTEGER,keyword TEXT,value TEXT,created_by INTEGER,created_by_nick TEXT,created_at TEXT,updated_at TEXT,hits INTEGER)');
 $db->do(q{INSERT INTO CHANNEL VALUES(1,'#test')});
 my $s=Mediabot::Plugin::FactoidServiceV3->new(dbh=>$db);
 is_deeply($s->list(channel=>'#test')->{keywords},[],'confirmed empty list remains valid');
 $db->{private_fault}=1;
 for my $op (qw(list top by_keyword)) {
  my $r;my $ok=eval {$r=$s->$op(channel=>'#test',keyword=>'test');1};
  ok(!$ok,"$op rejects an unconfirmed read with RaiseError=$raise");
  like($@,qr/^FactoidServiceV3: data service unavailable/, 'fixed service error');
  ok(!defined $r,'no false successful result');
 }
}
done_testing;
