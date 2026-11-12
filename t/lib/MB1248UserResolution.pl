use strict;
use warnings;
use Test::More;
our $now;
BEGIN { $now=100; *CORE::GLOBAL::time=sub { $now } }
use Mediabot::Helpers ();
use Mediabot::Auth ();
use Mediabot::User ();
use Mediabot::Context ();

# This file runs only in a fresh interpreter: its clock never changes the runner.
our ($state,$error);
my @traces;
my $native_match = Mediabot::Auth->can('hostmask_matches');
sub event {
 my ($name,@args)=@_;push @{$state->{events}},[$name,@args];
 $now=$state->{advance}{$name} if exists $state->{advance}{$name};
 die $error if ($state->{fail}//'') eq $name;
}
{
 package MB1248::Message; sub prefix {$_[0]{prefix}}
 package MB1248::DB;
 sub prepare {main::event('prepare',$_[1]);return if $main::state->{false_prepare};bless {},'MB1248::Statement'}
 package MB1248::Statement;
 sub execute {main::event('execute',@_[1..$#_]);return $main::state->{false_execute}?0:'0E0'}
 sub fetchrow_hashref {
  main::event('fetch');my $r=shift @{$main::state->{remaining}};return unless $r;
  if ($main::state->{reuse_row}) {
   %{$main::state->{shared_row}}=%$r;return $main::state->{shared_row};
  }
  return {%$r};
 }
 sub finish {main::event('finish');return $main::state->{false_finish}?0:1}
 package MB1248::Logger;
 sub log {
  main::event('log',$_[1],$_[2]);
  my $stage=$_[2]=~/cache hit/?'cache':$_[2]=~/Matched user id=/?'matched':$_[2]=~/SQL Error/?'sql':$_[2]=~/No user matched/?'absent':'initial';
  die $main::error if ($main::state->{log_fail}//'') eq $stage;
 }
 package MB1248::Bot;
 sub get_user_from_message {Mediabot::Helpers::get_user_from_message(@_)}
 sub clear_user_cache {Mediabot::Helpers::clear_user_cache(@_)}
 sub _dbg_auth_snapshot {main::event($_[1]);}
 sub _ensure_logged_in_state {main::event('ensure');}
 package MB1249::NoAuto;
 our @ISA=('MB1248::User');
 sub can {return if $_[1] eq 'maybe_autologin';UNIVERSAL::can(@_)}
 package MB1248::User;
 sub load_level {main::event('level')}
 sub maybe_autologin {main::event('auto')}
 sub id {$_[0]{id_user}}
 sub nickname {$_[0]{nickname}}
 sub level_description {'User'}
}
sub setup {
 my (%opts)=@_;$now=100;$error=bless {},'MB1248::Error';
 $state={events=>[],rows=>[{id_user=>1,nickname=>'alice',score=>10}],%opts};
 push @traces, $state->{events};
 $state->{remaining}=[@{$state->{rows}}];
 return bless {dbh=>bless({},'MB1248::DB'),logger=>bless({},'MB1248::Logger'),metrics=>{}},'MB1248::Bot';
}
sub message {bless {prefix=>$_[0]},'MB1248::Message'}
sub resolve {$_[0]->get_user_from_message(message($_[1]//'Alice!ident@host'))}
sub ops {[map {$_->[0]} grep {$_->[0] ne 'log'} @{$state->{events}}]}
sub count_op {my ($n)=@_;scalar grep {$_->[0] eq $n} @{$state->{events}}}
{
 no warnings 'redefine';no warnings 'once';
 my $diagnostic='fixture DB error';local *DBI::errstr=\$diagnostic;
 local *Mediabot::Auth::new=sub {
  my ($class,%args)=@_;event('auth_new');
  $state->{auth_args}=\%args;return bless {%args},$class;
 };
 local *Mediabot::Auth::hostmask_matches=sub {
  my ($auth,$row,$mask)=@_;event('match',$row->{id_user},$mask);
  return $native_match->(@_) if $state->{native_match};
  return defined($row->{score})?(1,'fixture-mask',undef,$row->{score}):(0,undef,undef,-1);
 };
 local *Mediabot::User::new=sub {event('user_new');bless {%{$_[1]}},($state->{no_auto}?'MB1249::NoAuto':'MB1248::User')};
 my $b=setup();my $u=resolve($b);
 is($u->id,1,'native Helpers resolves selected user');
 is_deeply(ops(),[qw(auth_new prepare execute fetch match fetch finish user_new level pre-auto auto post-auto ensure post-ensure return)],'native lookup and callback order');
 is($state->{auth_args}{bot},$b,'lazy Auth receives bot');
 is($state->{auth_args}{metrics},$b->{metrics},'lazy Auth receives metrics');
 my ($sql)=map {$_->[1]} grep {$_->[0] eq 'prepare'} @{$state->{events}};
 like($sql,qr/GROUP_CONCAT\(uh\.hostmask ORDER BY uh\.id_user_hostmask SEPARATOR ','\)/,'hostmask order retained');
 like($sql,qr/LEFT JOIN USER_HOSTMASK/,'users without hostmasks retained');
 like($sql,qr/ORDER BY u.id_user/,'user order retained');
 unlike($sql,qr/password/i,'lookup excludes credential material');
 is($b->{_user_cache_ts}{'Alice!ident@host'},100,'timestamp captured at lookup start');
 $now=104;is(resolve($b),$u,'same cached object below TTL');is(count_op('prepare'),1,'fresh cache avoids SQL');
 $now=105;$state->{remaining}=[@{$state->{rows}}];my $u2=resolve($b);
 isnt($u2,$u,'exact TTL gets a new object');is(count_op('prepare'),2,'exact TTL rereads');is(count_op('auth_new'),1,'existing Auth reused');
 $now=90;is(resolve($b),$u2,'characterize current rollback freshness without changing policy');
 $state->{remaining}=[@{$state->{rows}}];resolve($b,'alice!ident@host');is(count_op('prepare'),3,'fullmask case variants use separate keys');
 $b->clear_user_cache('Alice!ident@host');ok(!exists $b->{_user_cache}{'Alice!ident@host'} && !exists $b->{_user_cache_ts}{'Alice!ident@host'},'scoped clear removes object and timestamp');
 ok(exists $b->{_user_cache}{'alice!ident@host'},'scoped clear retains other key');
 $b->clear_user_cache();is_deeply($b->{_user_cache},{},'global clear objects');is_deeply($b->{_user_cache_ts},{},'global clear timestamps');
 $b=setup();ok(!defined $b->get_user_from_message(undef),'missing message refused');is_deeply(ops(),[],'missing message does no work');
 $b=setup(rows=>[]);ok(!defined resolve($b),'unmatched user absent');ok(!defined resolve($b),'absence remains absent');is(count_op('prepare'),2,'Helpers does not cache absence');
 my $c=Mediabot::Context->new(bot=>$b,message=>message('Alice!ident@host'));
 $c->user;$c->user;is(count_op('prepare'),3,'Context separately memoizes absence');
 my $c2=Mediabot::Context->new(bot=>$b,message=>message('Alice!ident@host'));$c2->user;is(count_op('prepare'),4,'another Context can resolve again');
 $b=setup(rows=>[]);resolve($b,'');my @match=grep {$_->[0] eq 'match'} @{$state->{events}};is(scalar @match,0,'empty prefix with no users stays unmatched');
 for my $case (
  ['best',[{id_user=>1,nickname=>'a',score=>2},{id_user=>2,nickname=>'b',score=>9}],2,'x!i@host'],
  ['tie',[{id_user=>1,nickname=>'a',score=>9},{id_user=>2,nickname=>'b',score=>9}],1,'x!i@host'],
  ['cloak',[{id_user=>1,nickname=>'ALICE'}],1,'x!i@Alice.users.undernet.org'],
  ['cloak spoof',[{id_user=>1,nickname=>'alice'}],undef,'x!i@alice.users.undernet.org.evil'],
  ['mask beats cloak',[{id_user=>1,nickname=>'alice'},{id_user=>2,nickname=>'b',score=>9}],2,'x!i@alice.users.undernet.org']) {
  my ($label,$rows,$want,$mask)=@$case;$b=setup(rows=>$rows);my $got=resolve($b,$mask);is($got?$got->id:undef,$want,$label);
 }
 for my $fail (qw(auth_new prepare execute fetch match finish user_new level pre-auto auto post-auto ensure post-ensure return)) {
  $b=setup(fail=>$fail);my $caught;eval {resolve($b);1} or $caught=$@;
  is($caught,$error,"$fail retains exception object");
  my $published=exists $b->{_user_cache}{'Alice!ident@host'};
  is($published?1:0,$fail eq 'return'?1:0,"$fail cache publication boundary");
  my $trace=ops();is($trace->[-1],$fail,"$fail stops subsequent operations");
 }
 for my $key (qw(false_prepare false_execute)) {
  $b=setup($key=>1);ok(!defined resolve($b),"$key refuses resolution");is(count_op('finish'),0,"$key preserves legacy no-finish behavior");
  ok(!exists $b->{_user_cache}{'Alice!ident@host'},"$key never caches failure");
  ok(grep($_->[0] eq 'log' && $_->[2]=~/SQL Error: fixture DB error/,@{$state->{events}}),"$key retains DB diagnostic");
 }
 $b=setup(false_finish=>1);ok(resolve($b),'false finish retains successful resolution');
 # Exercise real Auth invalidation, independently of its constructor stub.
 $b->{logged_in_by_nick}{alice}=1;$b->{sessions}{alice}=1;$b->{users_by_nick}{alice}=1;
 my $auth=bless {bot=>$b},'Mediabot::Auth';
 $auth->_invalidate_bot_session('alice',{hostmask=>'Alice!ident@host'});
 ok(!exists $b->{_user_cache}{'Alice!ident@host'},'real Auth invalidates Helpers cache');
 ok(!exists $b->{sessions}{alice} && !exists $b->{logged_in_by_nick}{alice} && !exists $b->{users_by_nick}{alice},'real Auth removes session aliases');
 # MB1251: real Auth matching across the selection boundary.
 for my $case (
  ['specific mask',[{id_user=>1,nickname=>'broad',hostmasks=>'*!ident@host'},{id_user=>2,nickname=>'exact',hostmasks=>'Alice!ident@host'}],2,'Alice!ident@host'],
  ['equal masks',[{id_user=>1,nickname=>'first',hostmasks=>'Alice!ident@host'},{id_user=>2,nickname=>'second',hostmasks=>'Alice!ident@host'}],1,'Alice!ident@host'],
  ['real cloak',[{id_user=>1,nickname=>'ALICE',hostmasks=>''}],1,'x!i@Alice.users.undernet.org'],
  ['real spoof',[{id_user=>1,nickname=>'alice',hostmasks=>''}],undef,'x!i@alice.users.undernet.org.evil']) {
  my ($label,$rows,$want,$mask)=@$case;$b=setup(native_match=>1,rows=>$rows);
  my $found=resolve($b,$mask);is($found?$found->id:undef,$want,"native Auth: $label");
  is(count_op('match'),scalar(@$rows),"native Auth: $label evaluates each row once");
  my @order=map {$_->[0]} grep {$_->[0] eq 'fetch' || $_->[0] eq 'match' || $_->[0] eq 'finish'} @{$state->{events}};
  is_deeply(\@order,[(map {('fetch','match')} @$rows),'fetch','finish'],"native Auth: $label preserves streaming order");
 }

 # MB1249: publication, borrowed rows and optional callbacks.
 for my $stage (qw(initial cache sql absent matched)) {
  $b=setup(log_fail=>$stage,rows=>$stage eq 'absent'?[]:[{id_user=>1,nickname=>'alice',score=>10}],false_execute=>$stage eq 'sql');
  my $cached=bless {id_user=>99},'MB1248::User';
  if ($stage eq 'cache') {$b->{_user_cache}{'Alice!ident@host'}=$cached;$b->{_user_cache_ts}{'Alice!ident@host'}=100}
  my $caught;eval {resolve($b);1} or $caught=$@;
  is($caught,$error,"$stage logger exception retains identity");
  my $published=$stage eq 'cache' || $stage eq 'matched';
  is(exists($b->{_user_cache}{'Alice!ident@host'})?1:0,$published?1:0,"$stage logger cache boundary");
  is(exists($b->{_user_cache_ts}{'Alice!ident@host'})?1:0,$published?1:0,"$stage logger timestamp boundary");
  is(count_op('return'),0,"$stage logger failure prevents return callback");
  if ($stage eq 'matched') {
   my $held=$b->{_user_cache}{'Alice!ident@host'};delete $state->{log_fail};
   is(resolve($b),$held,'matched logger failure leaves already-published object reusable');
   is(count_op('prepare'),1,'reuse after diagnostic failure performs no new query');
  }
 }
 for my $prefix (undef,'') {
  $b=setup(rows=>[{id_user=>1,nickname=>'alice'}]);
  ok(!defined $b->get_user_from_message(message($prefix)),'undefined/empty prefix with rows does not invent a cloak identity');
  my ($match)=grep {$_->[0] eq 'match'} @{$state->{events}};
  is($match->[2],'','matcher receives empty fullmask');
  is(count_op('user_new'),0,'no user is built for unmatched empty prefix');
 }
 $b=setup(no_auto=>1);$u=resolve($b);
 ok($u,'user without optional autologin resolves');is(count_op('auto'),0,'optional autologin is skipped');
 is(count_op('ensure'),1,'session synchronization still runs without autologin');
 is($b->{_user_cache}{'Alice!ident@host'},$u,'optional callback absence still publishes user');
 $b=setup(advance=>{auto=>110});$u=resolve($b);
 is($now,110,'lookup fixture advances clock during autologin');
 is($b->{_user_cache_ts}{'Alice!ident@host'},100,'slow lookup retains start-time cache age');
 $state->{remaining}=[@{$state->{rows}}];resolve($b);is(count_op('prepare'),2,'slow lookup can already be expired on next access');
 $b=setup(reuse_row=>1,shared_row=>{},rows=>[{id_user=>1,nickname=>'winner',score=>10},{id_user=>2,nickname=>'loser',score=>1}]);
 $u=resolve($b);is($u->id,1,'winning row is copied before cursor storage is reused');is($u->nickname,'winner','copied winner retains its own fields');
 $state->{shared_row}{nickname}='mutated';is($u->nickname,'winner','later row mutation cannot alter selected user');
 $b=setup();$c=Mediabot::Context->new(bot=>$b,message=>message('Alice!ident@host'));$u=$c->user;
 $b->clear_user_cache();$now=200;
 is($c->user,$u,'Context retains its own positive memo after global cache clear');
 is(count_op('prepare'),1,'same Context does not repeat lookup');
 $state->{remaining}=[@{$state->{rows}}];$c2=Mediabot::Context->new(bot=>$b,message=>message('Alice!ident@host'));
 isnt($c2->user,$u,'new Context resolves after global cache clear');
 $b->{_user_cache}{'Other!i@host'}='other';$b->{_user_cache_ts}{'Other!i@host'}=200;
 $b->{sessions}{other}=1;$b->{users_by_nick}{other}=1;$b->{logged_in_by_nick}{other}=1;
 $auth=bless {bot=>$b},'Mediabot::Auth';
 $auth->_invalidate_bot_session('alice',{hostmask=>'Alice!ident@host'});
 is($b->{_user_cache}{'Other!i@host'},'other','known-session invalidation preserves another hostmask');
 ok($b->{sessions}{other} && $b->{users_by_nick}{other} && $b->{logged_in_by_nick}{other},'known-session invalidation preserves other aliases');
 $auth->_invalidate_bot_session('alice',{});
 is_deeply($b->{_user_cache},{},'missing session hostmask clears all Helpers objects');
 is_deeply($b->{_user_cache_ts},{},'missing session hostmask clears all Helpers timestamps');
 ok($b->{sessions}{other},'global cache clear does not erase unrelated session aliases');

}
# Optional differential trace for release verification; normal runner writes no file.
if (@ARGV) {
 require JSON::PP;
 open my $fh, '>:raw', $ARGV[0] or die $!;
 print {$fh} JSON::PP->new->utf8->canonical->encode(\@traces);
 close $fh or die $!;
}
done_testing;
