use strict;
use warnings;
use Mediabot::UserCommands ();
use Mediabot::Helpers ();
use Mediabot::User ();
{
 package MB1272::Logger; sub log {}
 package MB1272::Message; sub prefix { $_[0]{prefix} }
 package MB1272::Auth;
 sub hostmask_matches { (1,'*!*@host',undef,10) }
 sub maybe_autologin { (0,'disabled') }
 package MB1272::Bot;
 sub _dbg_auth_snapshot {}
 sub _ensure_logged_in_state {}
 package MB1272::DB;
 sub prepare {
  my ($db,$sql)=@_;
  return if $sql =~ /^UPDATE/ && $db->{failure} eq 'prepare';
  return bless {db=>$db,sql=>$sql},'MB1272::Statement';
 }
 package MB1272::Statement;
 sub execute {
  my ($s,@bind)=@_; $s->{bind}=\@bind;
  if ($s->{sql} =~ /^UPDATE/) {
   $s->{db}{bind}=\@bind;
   return 0 if $s->{db}{failure} eq 'execute';
   $s->{db}{role}=$bind[0];
  }
  return 1;
 }
 sub fetchrow_hashref {
  my ($s)=@_; return if $s->{read}++;
  if ($s->{sql} =~ /FROM USER_LEVEL/) {
   return $s->{bind}[0]==1 ? {level=>1,description=>'Master'} : {level=>3,description=>'User'};
  }
  $s->{db}{reads}++;
  return {id_user=>42,nickname=>'Target',auth=>1,id_user_level=>$s->{db}{role},hostmasks=>'*!*@host'};
 }
 sub err { 0 }
 sub finish {
  my ($s)=@_;
  die "finish after update\n" if $s->{sql} =~ /^UPDATE/ && $s->{db}{failure} eq 'finish';
  return 1;
 }
}
return sub {
 my ($a)=@_;
 # Replace the symbol locally, not DBI's read-only magical scalar value.
 local *DBI::errstr;
 $DBI::errstr='simulated SQL failure';
 for my $case (['demote',1,3,''],['promote',3,1,''],['prepare',1,3,'prepare'],
               ['execute',1,3,'execute'],['finish',1,3,'finish']) {
  my ($name,$old,$new,$failure)=@$case;
  my $db=bless {role=>$old,failure=>$failure,reads=>0},'MB1272::DB';
  my $auth=bless {sessions=>{live=>42}},'MB1272::Auth';
  my $channel_cache={"42\0#test"=>{ts=>time,val=>450}};
  my $bot=bless {dbh=>$db,logger=>bless({},'MB1272::Logger'),auth=>$auth,
                _uchan_level_cache=>$channel_cache},'MB1272::Bot';
  my @messages=map {bless {prefix=>$_},'MB1272::Message'} ('OldNick!ident@host','NewNick!ident@host');
  my @cached=map {Mediabot::Helpers::get_user_from_message($bot,$_)} @messages;
  $a->is($cached[0]->has_level('Administrator'),$old==1?1:0,"$name: native role decision before update");
  my $unrelated=Mediabot::User->new({id_user=>99,nickname=>'Other'});
  $bot->{_user_cache}{'Other!i@elsewhere'}=$unrelated;
  $bot->{_user_cache_ts}{'Other!i@elsewhere'}=time;
  my ($result,$error);
  eval {$result=Mediabot::UserCommands::setUserLevel($bot,'tArGeT',$new);1} or $error=$@;
  my $success=$failure ne 'prepare' && $failure ne 'execute';
  if ($failure eq 'finish') {
   $a->is($error,"finish after update\n","$name: original cleanup failure remains visible");
  } else {
   $a->is(defined($error)?1:0,0,"$name: setter returns without an unexpected exception");
   $a->is($result,$success?1:0,"$name: setter retains success/failure result");
  }
  $a->is(scalar keys %{$bot->{_user_cache}},$success?0:3,"$name: all fullmask aliases expire only after successful execution");
  $a->is(scalar keys %{$bot->{_user_cache_ts}},$success?0:3,"$name: cache timestamps have the same lifetime");
  for my $i (0,1) {
   my $user=Mediabot::Helpers::get_user_from_message($bot,$messages[$i]);
   $a->is($user->has_level('Administrator'),($success?$new:$old)==1?1:0,"$name: alias $i sees the confirmed global role");
   $a->is($user->is_authenticated,1,"$name: role change does not log alias $i out");
  }
  $a->is($db->{reads},$success?4:2,"$name: fresh lookups only when invalidated");
  $a->is($bot->{auth},$auth,"$name: Auth owner retained");
  $a->is($auth->{sessions}{live},42,"$name: existing session retained");
  $a->is($bot->{_uchan_level_cache},$channel_cache,"$name: channel grants retained");
  $a->is(join(',',@{$db->{bind}}),"$new,tArGeT","$name: SQL bindings unchanged") unless $failure eq 'prepare';
 }
};
