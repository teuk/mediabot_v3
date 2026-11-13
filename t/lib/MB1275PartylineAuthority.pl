use strict;
use warnings;
use DBI;
use Mediabot::UserCommands ();
use Mediabot::Context ();
use Mediabot::User ();
use Mediabot::Partyline ();
use Mediabot::Partyline::Privileged ();
{
 package MB1275::Logger; sub log {}
 package MB1275::Conf; sub get { $_[1] eq 'main.PARTYLINE_EVAL_ENABLED' ? 1 : undef }
 package MB1275::Stream;
 sub write { push @{$_[0]{lines}},$_[1] }
 sub close_now { $_[0]{closed}++ }
 package MB1275::Party;
 our @ISA=('Mediabot::Partyline');
 sub _write_runtime_status { $_[0]{on_close}->() if $_[0]{on_close} }
}
return sub {
 my ($a)=@_;
 for my $mode (qw(demote promote unchanged delete missing_role db_failure uid_reuse cleanup_failure)) {
  my $db=DBI->connect('dbi:SQLite:dbname=:memory:','','',{RaiseError=>1,PrintError=>0});
  $db->do('CREATE TABLE USER (id_user INTEGER, nickname TEXT COLLATE NOCASE, id_user_level INTEGER)');
  $db->do('CREATE TABLE USER_LEVEL (id_user_level INTEGER, level INTEGER)');
  $db->do('INSERT INTO USER_LEVEL VALUES (1,0),(2,1),(3,3)');
  my $old=$mode eq 'promote'?1:0;
  $db->do('INSERT INTO USER VALUES (7,?,?),(9,?,1)',undef,'Target',$old+1,'Other');
  my $bot={dbh=>$db,logger=>bless({},'MB1275::Logger'),conf=>bless({},'MB1275::Conf')};
  my $party=$bot->{partyline}=bless {bot=>$bot,users=>{},streams=>{}},'MB1275::Party';
  my (@sessions,@streams);
  for my $id (7,8,9) {
   my $session=$party->{users}{$id}={authenticated=>1,login=>$id==9?'Other':'tArGeT',
    id_user=>$id==9?9:7,level=>$id==9?0:$old,level_desc=>'privileged'};
   my $stream=$party->{streams}{$id}=bless {lines=>[]},'MB1275::Stream';
   push @sessions,$session;push @streams,$stream;
   $party->{"_eval_pending_$id"}={code=>'1'};
  }
  my $watch=bless {party=>$party,session=>$sessions[0],stream=>$streams[0],
    state=>{},id=>7,pid=>$$,render=>sub {'secret local frame'}},'Mediabot::Partyline::ShellWatch';
  $sessions[0]{shell_watch}=$watch;
  my $retired_before_callback=0;
  $party->{on_close}=sub {
   $retired_before_callback= !$sessions[0]{authenticated} && !$sessions[1]{authenticated};
   die "fixture cleanup failure\n" if $mode eq 'cleanup_failure';
  };
  if ($mode =~ /^(demote|promote|unchanged|cleanup_failure)$/) {
   $a->is(Mediabot::UserCommands::setUserLevel($bot,'TARGET',$mode eq 'promote' || $mode eq 'unchanged'?1:3),1,"$mode: native mutation succeeds");
  } else {
   if ($mode eq 'delete') {
    $db->do('CREATE TABLE USER_CHANNEL (id_user INTEGER)');
    $db->do('CREATE TABLE USER_HOSTMASK (id_user INTEGER)');
    $db->do('CREATE TABLE USER_SEEN (nick TEXT)');
    my $principal=Mediabot::User->new({id_user=>1,nickname=>'Operator',auth=>1});
    $principal->{level_desc}='Master';
    my $ctx=Mediabot::Context->new(bot=>$bot,nick=>'Operator',channel=>'#local',command=>'deluser',args=>['Target']);
    $ctx->{user}=$principal; $ctx->{_user_fetched}=1;
    no warnings qw(redefine once);
    local *Mediabot::UserCommands::botNotice=sub {};
    local *Mediabot::UserCommands::logBot=sub {};
    Mediabot::UserCommands::delUser_ctx($ctx);
    $a->is($sessions[0]{authenticated},1,'delete: confirmation alone retains console');
    Mediabot::UserCommands::delUser_ctx($ctx);
    $a->is($db->selectrow_array('SELECT count(*) FROM USER WHERE id_user=7'),0,'delete: real committed account deletion');
   }
   $db->do('UPDATE USER SET id_user_level=99 WHERE id_user=7') if $mode eq 'missing_role';
   $db->do('UPDATE USER SET id_user=70 WHERE id_user=7') if $mode eq 'uid_reuse';
   $db->do('DROP TABLE USER_LEVEL') if $mode eq 'db_failure';
   $party->refresh_account_authority unless $mode eq 'delete';
  }
  my $revoke=$mode ne 'unchanged';
  $a->is($sessions[0]{authenticated}?1:0,$revoke?0:1,"$mode: first console authority");
  $a->is($sessions[1]{authenticated}?1:0,$revoke?0:1,"$mode: second console authority");
  $a->is(exists($party->{_eval_pending_7})?1:0,$revoke?0:1,"$mode: pending eval retired");
  $a->is($streams[0]{closed}//0,$revoke?1:0,"$mode: old transport closed once");
  $a->is($sessions[2]{authenticated}?1:0,$mode eq 'db_failure'?0:1,"$mode: independently confirmed account preserved");
  $a->is($retired_before_callback?1:0,$revoke?1:0,"$mode: aliases revoked before cleanup callbacks");
  if ($revoke) {
   $watch->_tick;
   $a->is(exists($watch->{render})?1:0,0,"$mode: delayed renderer released");
   $a->is(scalar @{$streams[0]{lines}},0,"$mode: retained watch emits no frame");
  }
  delete @$watch{qw(party session stream state)};
  delete $sessions[0]{shell_watch};
  # Retained references cannot arm the native privileged action after revocation.
  my $retained={bot=>$bot,users=>{7=>$sessions[0]}};
  Mediabot::Partyline::Privileged::_cmd_eval($retained,$streams[0],7,'1');
  $a->is(exists($retained->{_eval_pending_7})?1:0,$revoke?0:1,"$mode: native Owner gate sees revoked role");
 }
};
