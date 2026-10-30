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
use JSON::PP;
use Mediabot::Stats::Affinity;
my (@public,@notices,@audit);
my $mode=$ARGV[0];
{
 package Mediabot::UserCommands;
 sub botPrivmsg {push @public,[$_[1],$_[2]]}
 sub botNotice {push @notices,[$_[1],$_[2]]}
 sub logBot {push @audit,[$_[2],$_[3],$_[4]]}
 package Mediabot::Helpers;
 sub chanset_enabled {1}
 sub channel_log_gather {
  my ($self,$dbh,$sql,$bind,$callback,$scope)=@_;
  die 'wrong channel/scope' unless $bind->[0] eq '#test' && $scope eq 'content';
  if ($sql=~/HOUR/) {$callback->({nick=>$_,h=>12,c=>100},'CHANNEL_LOG') for qw(alice bob)}
  else {
   my $who=$bind->[1];
   my @words=map {sprintf('common%03d',$_)} 0..99;
   push @words,map {sprintf('z%s%03d',$who,$_)} 0..99;
   @words=reverse @words if $mode eq 'reverse';
   unshift @words, ('zz'.$who) x 200 if $mode eq 'frequency';
   @words=qw(shared words) if $mode eq 'small';
   @words=() if $mode eq 'empty';
   $callback->({publictext=>join(' ',@words),ts=>'2026-10-30 12:00:00'},'CHANNEL_LOG');
  }
  return {live_ok=>1};
 }
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
my $bot={dbh=>bless({},'MB1025DB')};
my $ctx=bless {bot=>$bot},'MB1025Context';
my (@warnings,$ok);
{local $SIG{__WARN__}=sub {push @warnings,@_};$ok=eval {Mediabot::Stats::Affinity::mbCompat_ctx($ctx);1}}
my $error=$@;
my ($vocab)=map {$_->[1]=~/vocab ([0-9]+)\/30/ ? 0+$1 : ()} @public;
my ($hours)=map {$_->[1]=~/hours ([0-9]+)\/30/ ? 0+$1 : ()} @public;
my ($percent)=map {$_->[1]=~/\x02([0-9]+)%\x02/ ? 0+$1 : ()} @public;
print JSON::PP->new->canonical->utf8->encode({ok=>$ok?1:0,error=>"$error",warnings=>\@warnings,
 vocab=>$vocab,hours=>$hours,percent=>$percent,notices=>\@notices,
 targets=>[map {$_->[0]} @public],audit=>\@audit,compat_count=>$bot->{_compat_count}{Observer}});
CHILD
close $fh or die $!;
sub native_1398 {
 my ($seed,$mode)=@_;local $ENV{PERL_HASH_SEED}=$seed;local $ENV{PERL_PERTURB_KEYS}=2;
 open my $pipe,'-|',$^X,'-I.','-It/lib',$child,$mode or die $!;
 local $/;my $raw=<$pipe>;close $pipe or die 'native compatibility child failed';return decode_json($raw);
}
my @seeds=('0','1','42','123456789');
my @tied=map {native_1398($_,'ties')} @seeds;
is_deeply([map {$_->{vocab}} @tied],[(30)x4],
 'more than 100 equally frequent words use the same lexical cutoff under different Perl hash seeds');
is_deeply([map {[$_->{percent},$_->{hours},$_->{compat_count}]} @tied],[(map {[60,30,1]} @seeds)],
 'identical histories keep the same final score, hour component and command accounting after restart');
is_deeply([map {$_->{vocab}} map {native_1398($_,'reverse')} @seeds],[(30)x4],
 'word insertion order cannot change the retained vocabulary or its overlap');
is_deeply([map {$_->{vocab}} map {native_1398($_,'frequency')} @seeds],[(29)x4],
 'frequency still takes precedence over lexical order and the top-100 bound is preserved');
is_deeply([map {my $r=native_1398('42',$_);[$r->{vocab},$r->{percent}]} qw(small empty)],
 [[30,60],[0,30]],'small and empty vocabularies retain their existing scores');
is_deeply([map {[$_->{ok},$_->{error},$_->{warnings},$_->{notices},$_->{targets},$_->{audit}]} @tied],
 [(map {[1,'',[],[],[('#test')x4],[['#test','compat','alice vs bob = 60%']]]} @seeds)],
 'native output and audit stay channel-scoped, complete and free from warnings or private failures');
done_testing;
