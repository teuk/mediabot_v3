package MB1244Chaninfo;
use strict;
use warnings;
use JSON::PP ();
use Mediabot::ChannelCommands ();
sub check {
 my ($ok)=@_;my $json=JSON::PP->new->canonical;my @records;
 for my $mode (qw(normal explicit master unauth denied level_throw no_user no_target unregistered no_id owner_missing owner_prepare_false owner_execute_false flags_prepare_false flags_execute_false empty_flags other_flags substring missing off raw nulls zero_rows prepare_false execute_false prepare_throw execute_throw fetch_throw notice_throw finish_throw finish_false logger_throw)) {
  my (@events,@warnings);my $error=bless {},'MB1244Chaninfo::Error';
  my $db=bless {mode=>$mode,events=>\@events,error=>$error},'MB1244Chaninfo::DB';
  my $bot={dbh=>$db,logger=>bless({db=>$db},'MB1244Chaninfo::Logger'),channels=>{'#mixed'=>bless({mode=>$mode},'MB1244Chaninfo::Channel')},_af_params=>{keep=>1}};
  $bot->{channels}={} if $mode eq 'unregistered';
  my $ctx=bless {bot=>$bot,mode=>$mode,message=>bless({},'MB1244Chaninfo::Message')},'MB1244Chaninfo::Context';
  my ($ret,$caught);
  {
   no warnings 'redefine'; no warnings 'once';
   my $diag='chaninfo DB failure';local *DBI::errstr=\$diag;
   local $SIG{__WARN__}=sub {push @warnings,@_};
   local *Mediabot::ChannelCommands::botNotice=sub {
    my ($b,$nick,$body)=@_;push @events,['notice',$nick,$body];
    die $error if $mode eq 'notice_throw' && $body=~/^Antiflood/;
   };
   local *Mediabot::ChannelCommands::logBot=sub {
    my ($b,$msg,@rest)=@_;$ok->($b==$bot && $msg==$ctx->{message},"$mode audit identity");push @events,['audit',@rest];
   };
   eval {$ret=Mediabot::ChannelCommands::userChannelInfo_ctx($ctx);1} or $caught=$@;
  }
  my $throws=$mode=~/^(prepare_throw|execute_throw|fetch_throw|notice_throw|finish_throw|logger_throw)$/;
  $ok->($throws ? ref($caught) && $caught==$error : !defined($caught),"$mode original exception behavior");
  my $early=$mode=~/^(no_target|unregistered|no_id|owner_missing|owner_prepare_false|owner_execute_false)$/;
  $ok->($early||$throws ? !defined $ret : defined($ret)&&$ret==1,"$mode return contract");
  my @notices=map {$_->[2]} grep {$_->[0] eq 'notice'} @events;
  my $target=$mode eq 'explicit'?'#MiXeD':'#MIXED';
  my @want=$mode eq 'no_target'?('Syntax: chaninfo #channel')
   :$mode eq 'unregistered'?("Channel $target does not exist")
   :$mode eq 'no_id'?("Internal error: channel object has no id for $target")
   :$mode eq 'owner_missing'?("The channel $target doesn't appear to be registered")
   :$mode=~/^owner_.*false$/?('Internal error (query failed).')
   :("$target is registered by Owner - last login: Never",'Creation date : Unknown - Description : No description','Channel timezone : UTC');
  push @want,'Chan modes : +nt - Key : private-key - Auto join : True' if $mode eq 'master';
  my $flags_ok=!$early && $mode!~/^flags_.*false$/;
  my $flood=$flags_ok && $mode ne 'empty_flags' && $mode ne 'other_flags';
  push @want, $mode eq 'other_flags'?'Channel flags +Other ':$mode eq 'substring'?'Channel flags +xANTIFLOODx ':'Channel flags +AntiFlood ' if $flags_ok && $mode ne 'empty_flags';
  my $replies=$flood && $mode!~/^(prepare_false|execute_false|prepare_throw|execute_throw|fetch_throw|logger_throw)$/;
  if ($replies) {
   my ($max,$dur,$wait)= $mode eq 'raw'?('005','030','01'):$mode eq 'nulls'?('','',''):(5,30,1);
   push @want,$mode eq 'missing'?'Antiflood parameters : not set ?':"Antiflood parameters : $max lines burst, full refill over $dur seconds, wait for $wait seconds, notification : ".($mode eq 'off'?'OFF':'ON');
  }
  $ok->($json->encode(\@notices) eq $json->encode(\@want),"$mode exact public/private notices");
  $ok->(!grep({$_->[0] eq 'notice' && $_->[1] ne 'Requester'} @events),"$mode notice target");
  my @fe=grep {$_->[0]=~/^(prepare|execute|fetch|finish)$/ && $_->[1] eq 'flood'} @events;
  $ok->(($flood?scalar(@fe)>0:!@fe),"$mode conditional flood read");
  if ($flood) {
   $ok->($fe[0][2] eq 'SELECT nbmsg_max, nbmsg, duration, timetowait, notification FROM CHANNEL_FLOOD WHERE id_channel = ? LIMIT 1',"$mode exact five-column SQL");
   for my $e (grep {$_->[0] eq 'execute'} @fe) {$ok->(@$e==3 && $e->[2]==42,"$mode literal channel ID bind")}
   my @ops=map {$_->[0]} @fe;my @expected=('prepare');
   push @expected,'execute' unless $mode=~/^prepare_(false|throw)$/;
   push @expected,'fetch' unless $mode=~/^(prepare_|execute_|logger_throw)/;
   push @expected,'finish' unless $mode=~/^(prepare_|execute_|fetch_throw|notice_throw|logger_throw)/;
   $ok->($json->encode(\@ops) eq $json->encode(\@expected),"$mode SQL cleanup order");
   if ($replies && $mode ne 'notice_throw') {
    my ($notice)=grep {$events[$_][0] eq 'notice' && $events[$_][2]=~/^Antiflood/} 0..$#events;
    my ($finish)=grep {$events[$_][0] eq 'finish' && $events[$_][1] eq 'flood'} 0..$#events;
    $ok->($finish>$notice,"$mode reply precedes finish");
   }
  }
  my @audit=grep {$_->[0] eq 'audit'} @events;
  my $audits=!$throws && $mode!~/^(no_target|owner_prepare_false|owner_execute_false)$/;
  $ok->($json->encode(\@audit) eq $json->encode($audits?[['audit',$target,'chaninfo',$target]]:[]),"$mode final audit");
  $ok->($bot->{_af_params}{keep}==1 && keys(%{$bot->{_af_params}})==1,"$mode admission cache untouched");
  $ok->($mode eq 'nulls'?@warnings==3:!@warnings,"$mode historical undefined-value warnings");
  push @records,[$mode,\@events,defined($ret)?$ret:undef,$throws?1:0,scalar @warnings];
 }
 push @records, @{check_registration($ok)};
 return \@records;
}
# The registration reader has a different failure/finish order from flood data.
sub check_registration {
 my ($ok)=@_;my @records;
 for my $mode (qw(owner_prepare_throw owner_execute_throw owner_fetch_throw owner_finish_throw owner_finish_false owner_logger_throw owner_notice_throw owner_full owner_empty)) {
  my (@events,@warnings);my $error=bless {},'MB1244Chaninfo::Error';
  my $db=bless {mode=>$mode,events=>\@events,error=>$error},'MB1244Chaninfo::DB';
  my $bot={dbh=>$db,logger=>bless({db=>$db},'MB1244Chaninfo::Logger'),channels=>{'#mixed'=>bless({mode=>$mode},'MB1244Chaninfo::Channel')}};
  my $ctx=bless {bot=>$bot,mode=>$mode,message=>bless({},'MB1244Chaninfo::Message')},'MB1244Chaninfo::Context';
  my ($ret,$caught);
  {
   no warnings 'redefine';no warnings 'once';
   my $diag='registration DB failure';local *DBI::errstr=\$diag;
   local $SIG{__WARN__}=sub {push @warnings,@_};
   local *Mediabot::ChannelCommands::botNotice=sub {push @events,['notice',$_[1],$_[2]];die $error if $mode eq 'owner_notice_throw'};
   local *Mediabot::ChannelCommands::logBot=sub {push @events,['audit',@_[2..4]]};
   eval {$ret=Mediabot::ChannelCommands::userChannelInfo_ctx($ctx);1} or $caught=$@;
  }
  my $fails=$mode=~/_throw$/;
  $ok->($fails?ref($caught)&&$caught==$error:!defined($caught),"$mode exact failure identity");
  $ok->($fails?!defined($ret):defined($ret)&&$ret==1,"$mode exact return");
  my @ops=map {$_->[0]} grep {$_->[0]=~/^(prepare|execute|fetch|finish)$/ && $_->[1] eq 'owner'} @events;
  my @want=('prepare');push @want,'execute' unless $mode eq 'owner_prepare_throw';
  push @want,'fetch' unless $mode=~/^owner_(prepare_throw|execute_throw|logger_throw|notice_throw)$/;
  push @want,'finish' unless $mode=~/^owner_(prepare_throw|execute_throw|fetch_throw|logger_throw|notice_throw)$/;
  $ok->(join(',',@ops) eq join(',',@want),"$mode exact statement order");
  my @downstream=grep {$_->[0] eq 'prepare' && $_->[1] ne 'owner'} @events;
  $ok->($fails?!@downstream:@downstream==2,"$mode downstream reads only after usable registration");
  my @notices=map {$_->[2]} grep {$_->[0] eq 'notice'} @events;
  if ($mode eq 'owner_full' || $mode eq 'owner_empty') {
   my @prefix=$mode eq 'owner_full'
    ?('#MIXED is registered by OwnerFull - last login: 2026-11-12','Creation date : 2020-01-01 - Description : Raw description','Channel timezone : Europe/Paris')
    :('#MIXED is registered by  - last login: ','Creation date :  - Description : ','Channel timezone : UTC');
   $ok->(JSON::PP->new->encode([@notices[0..2]]) eq JSON::PP->new->encode(\@prefix),"$mode raw defined values and timezone fallback");
   $ok->(!grep(/private-key/,@notices),"$mode ordinary requester sees no key");
  }
  my @logs=grep {$_->[0] eq 'log'} @events;
  $ok->($mode=~/^owner_(logger_throw|notice_throw)$/?@logs==1 && $logs[0][2]=~/SQL Error: registration DB failure \| Query: SELECT /:!@logs,"$mode SQL diagnostics");
  $ok->(!@warnings,"$mode warning free");
  push @records,[$mode,\@events,defined($ret)?$ret:undef,$fails?1:0];
 }
 return \@records;
}
package MB1244Chaninfo::DB;
sub prepare {
 my ($s,$sql)=@_;my $kind=$sql=~/FROM CHANNEL_FLOOD/?'flood':$sql=~/FROM CHANNEL_SET/?'flags':'owner';
 $sql=~s/\s+/ /g;$sql=~s/^ | $//g;push @{$s->{events}},['prepare',$kind,$sql];
 die $s->{error} if $s->{mode} eq $kind.'_prepare_throw' || $kind eq 'flood' && $s->{mode} eq 'prepare_throw';
 return if $s->{mode} eq $kind.'_prepare_false' || $kind eq 'flood' && $s->{mode} eq 'prepare_false';
 return bless {db=>$s,kind=>$kind,n=>0},'MB1244Chaninfo::Statement';
}
package MB1244Chaninfo::Statement;
sub execute {
 my ($s,@bind)=@_;my $d=$s->{db};push @{$d->{events}},['execute',$s->{kind},@bind];
 die $d->{error} if $d->{mode} eq $s->{kind}.'_execute_throw' || $s->{kind} eq 'flood' && $d->{mode} eq 'execute_throw';
 return 0 if $s->{kind} eq 'owner' && $d->{mode}=~/^owner_(logger_throw|notice_throw)$/ || $d->{mode} eq $s->{kind}.'_execute_false' || $s->{kind} eq 'flood' && $d->{mode}=~/^(execute_false|logger_throw)$/;
 return $d->{mode} eq 'zero_rows'?'0E0':1;
}
sub fetchrow_hashref {
 my ($s)=@_;my $d=$s->{db};my $m=$d->{mode};push @{$d->{events}},['fetch',$s->{kind}];
 die $d->{error} if $m eq $s->{kind}.'_fetch_throw' || $s->{kind} eq 'flood' && $m eq 'fetch_throw';
 return if $s->{n}++;
 if ($s->{kind} eq 'owner') {
  return {nickname=>'OwnerFull',last_login=>'2026-11-12',creation_date=>'2020-01-01',description=>'Raw description',timezone=>'Europe/Paris',c_key=>'private-key'} if $m eq 'owner_full';
  return {map {$_=>''} qw(nickname last_login creation_date description timezone c_key)} if $m eq 'owner_empty';
  return if $m eq 'owner_missing';return {nickname=>'Owner',c_key=>'private-key',chanmode=>'+nt',auto_join=>1}}
 if ($s->{kind} eq 'flags') {return if $m eq 'empty_flags';return {chanset=>$m eq 'other_flags'?'Other':$m eq 'substring'?'xANTIFLOODx':'AntiFlood'}}
 return if $m eq 'missing';
 my @v=$m eq 'raw'?('005','030','01'):$m eq 'nulls'?(undef,undef,undef):(5,30,1);
 return {nbmsg_max=>$v[0],duration=>$v[1],timetowait=>$v[2],nbmsg=>99,notification=>$m eq 'off'?'0':'0E0'};
}
sub finish {my $d=$_[0]{db};push @{$d->{events}},['finish',$_[0]{kind}];die $d->{error} if $d->{mode} eq $_[0]{kind}.'_finish_throw' || $_[0]{kind} eq 'flood' && $d->{mode} eq 'finish_throw';return $d->{mode}=~/^(owner_)?finish_false$/?0:1}
package MB1244Chaninfo::Logger;
sub log {my ($s,@a)=@_;$a[1]=~s/\s+/ /g;push @{$s->{db}{events}},['log',@a];die $s->{db}{error} if $s->{db}{mode}=~/^(owner_)?logger_throw$/}
package MB1244Chaninfo::Channel;
sub get_id {$_[0]{mode} eq 'no_id'?0:42}
package MB1244Chaninfo::Context;
sub bot {$_[0]{bot}}
sub nick {'Requester'}
sub message {$_[0]{message}}
sub channel {$_[0]{mode} eq 'no_target'?'Requester':'#MIXED'}
sub args {$_[0]{mode} eq 'explicit'?['#MiXeD']:[]}
sub user {return if $_[0]{mode} eq 'no_user';bless {mode=>$_[0]{mode}},'MB1244Chaninfo::User'}
package MB1244Chaninfo::User;
sub is_authenticated {$_[0]{mode} ne 'unauth'}
sub has_level {die 'level unavailable' if $_[0]{mode} eq 'level_throw';$_[0]{mode} eq 'master'}
1;
