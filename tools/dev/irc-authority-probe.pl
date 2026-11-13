#!/usr/bin/env perl
# MB1276: bounded characterization, not a live login or IRCv3 handshake.
# Run from the repository root: perl -I. tools/dev/irc-authority-probe.pl
use strict;
use warnings;
use Test::More;
use Mediabot::Helpers ();
use Mediabot::Auth ();
use Mediabot::LoginCommands ();
{
 package MB1276::Logger; sub log {}
 package MB1276::Message; sub prefix {$_[0]{prefix}}
 package MB1276::Bot;
 sub _dbg_auth_snapshot {}
 sub _ensure_logged_in_state {Mediabot::LoginCommands::_ensure_logged_in_state(@_)}
 sub clear_user_cache {Mediabot::Helpers::clear_user_cache(@_)}
 package MB1276::DB;
 sub prepare {bless {db=>$_[0],sql=>$_[1]},'MB1276::Statement'}
 sub selectrow_array {$_[0]{auth}}
 package MB1276::Statement;
 sub execute {
  my ($s,@bind)=@_;$s->{bind}=\@bind;
  $s->{db}{lookups}++ if $s->{sql}=~/GROUP_CONCAT/;
  return 1;
 }
 sub fetchrow_hashref {
  my ($s)=@_;return if $s->{read}++;
  return {level=>1,description=>'Master'} if $s->{sql}=~/FROM USER_LEVEL/;
  return {id_user=>7,nickname=>'Registered',username=>'password-login',
   id_user_level=>2,auth=>$s->{db}{auth},hostmasks=>'*!ident@old.example,*!ident@new.example'};
 }
 sub fetchrow_arrayref {
  my ($s)=@_;my @m=('*!ident@old.example','*!ident@new.example');
  my $i=$s->{mask_read}++;return $i<@m ? [$m[$i]] : undef;
 }
 sub finish {1}
 sub err {0}
}
my $db=bless {auth=>1,lookups=>0},'MB1276::DB';
my $bot=bless {dbh=>$db,logger=>bless({},'MB1276::Logger')},'MB1276::Bot';
sub resolve {
 my ($mask)=@_;
 return Mediabot::Helpers::get_user_from_message($bot,bless({prefix=>$mask},'MB1276::Message'));
}
my $old=resolve('Old!ident@old.example');
ok($old && $old->is_authenticated,'matched account with auth=1 resolves authenticated');
is($db->{lookups},1,'first prefix opens candidate query');
is(resolve('Old!ident@old.example'),$old,'identical prefix uses the existing short cache');
my $new=resolve('New!ident@new.example');
ok($new && $new!=$old,'changed prefix gets another native User object');
is($db->{lookups},2,'changed host/nick cannot hit the old prefix cache');
ok($new->is_authenticated,'CHARACTERIZED POLICY: another allowed mask inherits account-wide auth=1');
is($bot->{auth}{sessions}{new}{id_user},7,'native reconciliation records the new matching session');
ok(!defined resolve('New!ident@unlisted.example'),'unlisted host cannot inherit a match solely from the nick');
is($db->{lookups},3,'unlisted prefix was evaluated separately');
$db->{auth}=0;
$bot->clear_user_cache;
my $logged_out=resolve('Next!ident@new.example');
ok($logged_out && !$logged_out->is_authenticated,'password-only account with auth=0 stays unauthenticated');
# Auth session keys currently use lc, independently of negotiated IRC casemapping.
my $auth=Mediabot::Auth->new(dbh=>$db);
$auth->set_session_user('Nick[',{id_user=>7,hostmask=>'Nick[!i@h'});
is($auth->rename_session('Nick{','Other'),0,'CHARACTERIZED LIMIT: RFC-equivalent punctuation is not an Auth key match');
ok(exists $auth->{sessions}{'nick['},'unmatched rename does not silently rewrite durable/account identity');
ok($auth->rename_session('Nick[','Other'),'exact observed source spelling can migrate');
is($auth->{sessions}{other}{hostmask},'Other!i@h','migration rewrites the live nick in its hostmask');
done_testing;
