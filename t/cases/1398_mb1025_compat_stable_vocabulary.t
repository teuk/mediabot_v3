use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP;
my $dir=tempdir('mb1025-compat-XXXXXX',TMPDIR=>1,CLEANUP=>1);
my $child="$dir/compat.pl";
open my $fh,'>',$child or die $!;
print {$fh} <<'CHILD';
use strict;
use warnings;
use utf8;
use DBI;
use Encode qw(encode);
use JSON::PP;
use Mediabot::Stats::Affinity;
my (@public,@notices,@audit,@flags);
my ($mode,$encoding);
my $history=DBI->connect('dbi:SQLite:dbname=:memory:','','',
 {RaiseError=>1,PrintError=>0,AutoCommit=>1,sqlite_unicode=>1});
$history->do('CREATE TABLE history(nick TEXT,publictext TEXT,ts TEXT)');
my $insert=$history->prepare('INSERT INTO history VALUES(?,?,?)');
{
 package Mediabot::UserCommands;
 sub botPrivmsg {push @public,[$_[1],$_[2]]}
 sub botNotice {push @notices,[$_[1],$_[2]]}
 sub logBot {push @audit,[$_[2],$_[3],$_[4]]}
 package Mediabot::Helpers;
 no warnings 'redefine';
 sub chanset_enabled {1}
 sub channel_log_gather {
  my ($self,$dbh,$sql,$bind,$callback,$scope)=@_;
  die 'wrong channel/scope' unless $bind->[0] eq '#test' && $scope eq 'content';
  if ($sql=~/HOUR/) {$callback->({nick=>$_,h=>12,c=>100},'CHANNEL_LOG') for qw(alice bob)}
  else {
   # Exercise the real driver boundary, with the same stored TEXT rows read
   # once as UTF-8 bytes and once as decoded characters.
   $history->{sqlite_unicode}=$encoding eq 'characters'?1:0;
   my $sth=$history->prepare('SELECT publictext,ts FROM history WHERE nick=? ORDER BY ts DESC LIMIT 5000');
   $sth->execute($bind->[1]);
   while (my $row=$sth->fetchrow_hashref) {
    push @flags,utf8::is_utf8($row->{publictext})?1:0;
    $callback->($row,'CHANNEL_LOG');
   }
   $sth->finish;
  }
  return {live_ok=>1};
 }
 # The independent co-presence component remains empty in this fixture.
 package MB1025DB;
 sub prepare {bless {},'MB1025Statement'}
 package MB1025Statement;
 sub execute {1}
 sub fetchrow_hashref {undef}
 sub finish {1}
 package MB1025Context;
 sub bot {$_[0]{bot}}
 sub nick {'Observer'}
 sub channel {'#test'}
 sub args {['Alice','Bob']}
 sub message {'!compat Alice Bob'}
}
sub text_for {
 my ($who)=@_;
 my @words=map {sprintf('common%03d',$_)} 0..99;
 push @words,map {sprintf('z%s%03d',$who,$_)} 0..99;
 @words=reverse @words if $mode eq 'reverse';
 unshift @words, ('zz'.$who) x 200 if $mode eq 'frequency';
 @words=qw(shared words) if $mode eq 'small';
 @words=() if $mode eq 'empty';
 return join(' ',@words) if $mode=~/^(?:ties|reverse|frequency|small|empty)$/;
 return $who eq 'alice' ? "ÉLÈVE CAFÉ CŒUR РАБОТА 東京大学"
  : "élève cafe\x{301} cœur работа 東京大学" if $mode eq 'unicode';
 return $who eq 'alice' ? "PONT—ROSE,planète🙂" : 'pont rose planète'
  if $mode eq 'punctuation';
 return $who eq 'alice' ? "CAFÉ COEUR RÊVE" : "cafe\x{301} coeur re\x{302}ve"
  if $mode eq 'canonical';
 return '😀😀😀😀 ✨✨✨✨' if $mode eq 'emoji';
 return $who eq 'alice' ? 'café' : 'cafe' if $mode eq 'distinct_accents';
 return $who eq 'alice' ? 'ÉTÉ ÉTÉ' : "e\x{301}te\x{301}"
  if $mode eq 'short';
 return $who eq 'alice' ? encode('ISO-8859-1','CAFÉ RÊVE') : 'café rêve'
  if $mode eq 'legacy';
 die 'unknown fixture';
}
my %out;
for my $next_mode (qw(ties reverse frequency small empty unicode punctuation canonical emoji short distinct_accents legacy)) {
 $mode=$next_mode;
 for my $next_encoding (qw(bytes characters)) {
  $encoding=$next_encoding;
  @public=();@notices=();@audit=();@flags=();
  $history->{sqlite_unicode}=1;
  $history->do('DELETE FROM history');
  for my $who (qw(alice bob)) {
   my $text=text_for($who);
   $insert->bind_param(1,$who);
   if ($mode eq 'legacy' && $who eq 'alice') {
    $insert->bind_param(2,$text,DBI::SQL_BLOB());
   } else {$insert->bind_param(2,$text,DBI::SQL_VARCHAR())}
   $insert->bind_param(3,'2026-11-04 12:00:00');$insert->execute;
  }
  my $bot={dbh=>bless({},'MB1025DB')};
  my $ctx=bless {bot=>$bot},'MB1025Context';
  my (@warnings,$ok);
  {local $SIG{__WARN__}=sub {push @warnings,@_};$ok=eval {Mediabot::Stats::Affinity::mbCompat_ctx($ctx);1}}
  my $error=$@;
  my ($vocab)=map {$_->[1]=~/vocab ([0-9]+)\/30/ ? 0+$1 : ()} @public;
  my ($hours)=map {$_->[1]=~/hours ([0-9]+)\/30/ ? 0+$1 : ()} @public;
  my ($percent)=map {$_->[1]=~/\x02([0-9]+)%\x02/ ? 0+$1 : ()} @public;
  $out{$mode}{$encoding}={ok=>$ok?1:0,error=>"$error",warnings=>\@warnings,
   vocab=>$vocab,hours=>$hours,percent=>$percent,notices=>[@notices],
   flags=>[@flags],targets=>[map {$_->[0]} @public],audit=>[@audit],
   compat_count=>$bot->{_compat_count}{Observer}};
  # Detach captured containers before the next invocation reuses them.
  $out{$mode}{$encoding}{warnings}=[@warnings];
 }
}
$insert->finish;$history->disconnect;
print JSON::PP->new->canonical->utf8->encode(\%out);
CHILD
close $fh or die $!;
sub native_1398 {
 my ($seed)=@_;local $ENV{PERL_HASH_SEED}=$seed;local $ENV{PERL_PERTURB_KEYS}=2;
 open my $pipe,'-|',$^X,'-I.','-It/lib',$child or die $!;
 local $/;my $raw=<$pipe>;close $pipe or die 'native compatibility child failed';return decode_json($raw);
}
# Four seeded processes replace the old fourteen; every process runs the
# existing ordering controls and both real DBI encodings of Unicode cases.
my @seeds=('0','1','42','123456789');
my @runs=map {native_1398($_)} @seeds;
my @tied=map {$_->{ties}{bytes}} @runs;
is_deeply([map {$_->{vocab}} @tied],[(30)x4],
 'more than 100 equally frequent words use the same lexical cutoff under different Perl hash seeds');
is_deeply([map {[$_->{percent},$_->{hours},$_->{compat_count}]} @tied],[(map {[60,30,1]} @seeds)],
 'identical histories keep the same final score, hour component and command accounting after restart');
is_deeply([map {$_->{reverse}{bytes}{vocab}} @runs],[(30)x4],
 'word insertion order cannot change the retained vocabulary or its overlap');
is_deeply([map {$_->{frequency}{bytes}{vocab}} @runs],[(29)x4],
 'frequency still takes precedence over lexical order and the top-100 bound is preserved');
is_deeply([map {my $r=$runs[2]{$_}{bytes};[$r->{vocab},$r->{percent}]} qw(small empty)],
 [[30,60],[0,30]],'small and empty vocabularies retain their existing scores');
is_deeply([map {[$_->{ok},$_->{error},$_->{warnings},$_->{notices},$_->{targets},$_->{audit}]} @tied],
 [(map {[1,'',[],[],[('#test')x4],[['#test','compat','alice vs bob = 60%']]]} @seeds)],
 'native output and audit stay channel-scoped, complete and free from warnings or private failures');
my (@unicode,@separators,@contracts);
for my $run (@runs) {
 for my $name (qw(unicode punctuation canonical legacy)) {
  for my $encoding (qw(bytes characters)) {
   my $x=$run->{$name}{$encoding};
   push @unicode,[$x->{vocab},$x->{percent},$x->{hours}];
   push @contracts,[$x->{ok},$x->{error},$x->{warnings},$x->{notices},$x->{compat_count}];
   push @contracts,[$x->{flags},$encoding eq 'bytes'?[0,0]:$name eq 'legacy'?[0,1]:[1,1]];
  }
 }
 for my $name (qw(emoji short distinct_accents)) {
  for my $encoding (qw(bytes characters)) {
   my $x=$run->{$name}{$encoding};
   push @separators,[$x->{vocab},$x->{percent}];
   push @contracts,[$x->{ok},$x->{error},$x->{warnings},$x->{notices},$x->{compat_count}];
  }
 }
}
is_deeply(\@unicode,[(map {[30,60,30]} 1..32)],
 'MB1096 real DBI bytes and characters agree for accents, canonical forms, non-Latin words and legacy bytes');
my $contracts_ok=1;
for my $x (@contracts) {
 if (@$x==2) {$contracts_ok=0 unless encode_json($x->[0]) eq encode_json($x->[1])}
 else {$contracts_ok=0 unless encode_json($x) eq encode_json([1,'',[],[],1])}
}
is_deeply([\@separators,$contracts_ok], [[(map {[0,30]} 1..24)],1],
 'MB1096 emoji and short words earn no points, distinct accents stay distinct, and accounting stays unchanged');
done_testing;
