use strict;
use warnings;
use DBI;
use Mediabot::UserCommands ();
use Mediabot::Context ();
use Mediabot::User ();
use Mediabot::Auth ();
use Mediabot::Helpers ();
{
 package MB1274::Bot;
 sub clear_user_cache { Mediabot::Helpers::clear_user_cache(@_) }
 package MB1274::Logger;
 sub log { $_[0]{on_success}->() if $_[0]{on_success} && $_[2] =~ /^delUser_ctx: User / }
}
return sub {
 my ($a)=@_;
 for my $mode (qw(success noauth rollback confirmation)) {
  my $db=DBI->connect('dbi:SQLite:dbname=:memory:','','',{RaiseError=>1,PrintError=>0,Warn=>0,AutoCommit=>1});
  $db->do('PRAGMA foreign_keys=ON');
  $db->do('CREATE TABLE USER (id_user INTEGER PRIMARY KEY, nickname TEXT, auth INTEGER)');
  $db->do('CREATE TABLE USER_CHANNEL (id_user INTEGER, id_channel INTEGER)');
  $db->do('CREATE TABLE USER_HOSTMASK (id_user INTEGER, hostmask TEXT)');
  $db->do('CREATE TABLE USER_SEEN (nick TEXT)');
  $db->do('CREATE TABLE GUARD (id_user INTEGER REFERENCES USER(id_user) DEFERRABLE INITIALLY DEFERRED)');
  $db->do("INSERT INTO USER VALUES (7,'Target',1),(9,'Other',1)");
  $db->do('INSERT INTO USER_CHANNEL VALUES (7,1),(9,1)');
  $db->do("INSERT INTO USER_HOSTMASK VALUES (7,'*!i\@host')");
  $db->do("INSERT INTO USER_SEEN VALUES ('target')");
  $db->do('INSERT INTO GUARD VALUES (7)') if $mode eq 'rollback';
  my $bot=bless {dbh=>$db,logger=>bless({},'MB1274::Logger'),
    _user_cache=>{'Live!i@host'=>Mediabot::User->new({id_user=>7,auth=>1})},
    _user_cache_ts=>{'Live!i@host'=>time},
    _uchan_level_cache=>{"7\0#one"=>{val=>450},"7\0#two"=>{val=>100},"70\0#one"=>{val=>500}},
  },'MB1274::Bot';
  my $auth;
  unless ($mode eq 'noauth') {
   $auth=$bot->{auth}=Mediabot::Auth->new(dbh=>$db,bot=>$bot,logger=>$bot->{logger});
   $auth->set_session_user('Live',{id_user=>7,hostmask=>'Live!i@host'});
   $auth->set_session_user('Alias',{id_user=>7,hostmask=>'Alias!i@host'});
   $auth->set_session_user('Other',{id_user=>9,hostmask=>'Other!i@other'});
  }
  my $principal=Mediabot::User->new({id_user=>1,nickname=>'Operator',auth=>1});
  $principal->{level_desc}='Master';
  my $ctx=Mediabot::Context->new(bot=>$bot,nick=>'Operator',channel=>'#test',command=>'deluser',args=>['Target']);
  $ctx->{user}=$principal; $ctx->{_user_fetched}=1;
  my $callback_retired;
  $bot->{logger}{on_success}=sub {
   $callback_retired=(!keys %{$bot->{_user_cache}} && !exists $bot->{_uchan_level_cache}{"7\0#one"}
       && (!$auth || !$auth->is_logged_in_id(7)))?1:0;
  };
  my @sql;
  $db->sqlite_trace(sub {push @sql,$_[0]});
  {
   no warnings qw(redefine once);
   local *Mediabot::UserCommands::botNotice=sub {};
   local *Mediabot::UserCommands::logBot=sub {};
   Mediabot::UserCommands::delUser_ctx($ctx);
   $a->is($db->selectrow_array('SELECT count(*) FROM USER WHERE id_user=7'),1,"$mode: confirmation leaves the account intact");
   Mediabot::UserCommands::delUser_ctx($ctx) unless $mode eq 'confirmation';
  }
  my $deleted=$mode eq 'success' || $mode eq 'noauth';
  $a->is($db->selectrow_array('SELECT count(*) FROM USER WHERE id_user=7'),$deleted?0:1,"$mode: database outcome");
  $a->is(scalar keys %{$bot->{_user_cache}},$deleted?0:1,"$mode: resolution cache follows committed outcome");
  $a->is(scalar keys %{$bot->{_user_cache_ts}},$deleted?0:1,"$mode: timestamps follow committed outcome");
  $a->is(exists($bot->{_uchan_level_cache}{"7\0#one"})?1:0,$deleted?0:1,"$mode: first channel grant");
  $a->is(exists($bot->{_uchan_level_cache}{"7\0#two"})?1:0,$deleted?0:1,"$mode: second channel grant");
  $a->is($bot->{_uchan_level_cache}{"70\0#one"}{val},500,"$mode: UID prefix cannot remove another user's grant");
  if ($auth) {
   $a->is($auth->is_logged_in_id(7)?1:0,$deleted?0:1,"$mode: Auth account state");
   $a->is(scalar(grep {$_->{id_user}==7} values %{$auth->{sessions}}),$deleted?0:2,"$mode: both live aliases");
   $a->is($auth->is_logged_in_id(9)?1:0,1,"$mode: other account stays authenticated");
  }
  $a->is($callback_retired,1,"$mode: retirement precedes success log callback") if $deleted;
  $a->is(scalar(grep {/UPDATE USER SET auth/} @sql),0,"$mode: no auth UPDATE after account deletion");
  $db->sqlite_trace(undef); $db->disconnect;
 }
};
