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
sub event {
 my ($name,@args)=@_;push @{$state->{events}},[$name,@args];
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
  return {%$r};
 }
 sub finish {main::event('finish');return $main::state->{false_finish}?0:1}
 package MB1248::Logger;
 sub log {main::event('log',$_[1],$_[2])}
 package MB1248::Bot;
 sub get_user_from_message {Mediabot::Helpers::get_user_from_message(@_)}
 sub clear_user_cache {Mediabot::Helpers::clear_user_cache(@_)}
 sub _dbg_auth_snapshot {main::event($_[1]);}
 sub _ensure_logged_in_state {main::event('ensure');}
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
  $state->{auth_args}=\%args;return bless {},$class;
 };
 local *Mediabot::Auth::hostmask_matches=sub {
  my ($auth,$row,$mask)=@_;event('match',$row->{id_user},$mask);
  return defined($row->{score})?(1,'fixture-mask',undef,$row->{score}):(0,undef,undef,-1);
 };
 local *Mediabot::User::new=sub {event('user_new');bless {%{$_[1]}},'MB1248::User'};
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
}
done_testing;
