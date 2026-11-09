use strict;
use warnings;
use utf8;
use Test::More;
use Encode qw(encode);
use Mediabot::IRC::Sender ();
use Mediabot::IRC::DeferredOutput ();
use Mediabot::IRC::TextBudget ();
use FindBin qw($Bin);
open my $fh,'<:encoding(UTF-8)',"$Bin/../../Mediabot/Helpers.pm" or die $!;
my $src=do {local $/;<$fh>};
my ($guard)=$src =~ /(sub checkAntiFlood \{.*?\n\}\n)/s;die 'guard missing' unless $guard;
eval q{package MB1171::Guard;use strict;use warnings;use subs qw(time);our $now=1800000000;
sub time {$now} sub _af_conf_int {my($s,$k,$d)=@_;return $k eq 'OUTPUT_GLOBAL_MAX_MSG'?5:$d}
sub noticeConsoleChan {1} sub botPrivmsg {1}
}.$guard;die $@ if $@;
{
 package MB1171::Log;sub log {1}
 package MB1171::IRC;sub nick_folded {'bot'} sub do_PRIVMSG {my($s,%a)=@_;push @{$s->{wire}},$a{text};return 'written'}
 package Mediabot::Helpers;
 sub _sanitize_irc_text {goto &Mediabot::IRC::TextBudget::_sanitize_irc_text}
 sub _split_text_for_irc {goto &Mediabot::IRC::TextBudget::_split_text_for_irc}
 sub _is_irc_channel_target {$_[0] =~ /^#/}
 sub getIdChansetList {$_[1]}
 sub getIdChannelSet {$_[2] eq 'AntiFlood'?1:undef}
 sub checkAntiFlood {goto &MB1171::Guard::checkAntiFlood}
 sub noticeConsoleChan {1} sub logBotAction {1}
 sub _arm_flood_drain {1}
 sub _defer_flooded_send {goto &Mediabot::IRC::DeferredOutput::_defer_flooded_send}
 sub botPrivmsg {goto &Mediabot::IRC::Sender::botPrivmsg}
 sub botAction {goto &Mediabot::IRC::Sender::botAction}
}
sub bot_1171 {
 my($limit)=@_;
 return {logger=>bless({},'MB1171::Log'),irc=>bless({wire=>[]},'MB1171::IRC'),
 _af_params=>{'#test'=>{ts=>$MB1171::Guard::now,nbmsg_max=>$limit,duration=>30,timetowait=>300}},
 _badword_cache=>{'#test'=>{ts=>time(),words=>[]}}};
}
sub drain_1171 {Mediabot::IRC::DeferredOutput::_drain_flood_queue($_[0],'#test')}
for my $kind ('privmsg','action') {
 my $send=$kind eq 'action'?\&Mediabot::IRC::Sender::botAction:\&Mediabot::IRC::Sender::botPrivmsg;
 for my $bytes (0,1) {
  my $text='漢'x300; $text=encode('UTF-8',$text) if $bytes;
  my @chunks=Mediabot::IRC::TextBudget::_split_text_for_irc($text,$kind eq 'action'?391:400);
  my $bot=bot_1171(5);
  $send->($bot,'#test',$text);
  is(scalar @{$bot->{irc}{wire}},3,"$kind/$bytes: three physical lines emitted");
  is(scalar @{$bot->{_global_af}{hits}},3,"$kind/$bytes: global cost equals physical lines");
  is($bot->{_af}{'#test'}{nbmsg},3,"$kind/$bytes: channel cost equals physical lines");
  $bot=bot_1171(2);
  $send->($bot,'#test',$text);
  is(scalar @{$bot->{irc}{wire}},0,"$kind/$bytes: oversized batch has no partial immediate send");
  is(scalar @{$bot->{_flood_outq}{'#test'}{items}},3,"$kind/$bytes: batch queued as three lines");
  is($bot->{_global_af}{silenced_until},0,"$kind/$bytes: batch mismatch does not silence other channels");
  $send->($bot,'#test','tail');
  is(scalar @{$bot->{irc}{wire}},0,"$kind/$bytes: a new reply cannot overtake queued lines");
  drain_1171($bot);drain_1171($bot);drain_1171($bot);
  is(scalar @{$bot->{irc}{wire}},2,"$kind/$bytes: a reblocked line is not emitted");
  is(scalar @{$bot->{_flood_outq}{'#test'}{items}},2,"$kind/$bytes: reblocked line stays ahead of tail");
  $MB1171::Guard::now+=300;
  # Keep policy hot while testing real admission, not SQL fixtures.
  $bot->{_af_params}{'#test'}{ts}=$MB1171::Guard::now;
  drain_1171($bot);drain_1171($bot);
  my @expected=map {my $b=utf8::is_utf8($_)?encode('UTF-8',$_):$_;$kind eq 'action'?"\1ACTION $b\1":$b} (@chunks,'tail');
  is_deeply($bot->{irc}{wire},\@expected,"$kind/$bytes: resume preserves bytes, ordering and ACTION frames without replay");
 }
}
{
 my $bot=bot_1171(2);my @futures;
 is(Mediabot::IRC::Sender::botPrivmsg($bot,'#test','x'x900,{no_defer=>1,write_futures=>\@futures}),0,'no_defer refuses a batch that cannot fit');
 is_deeply([$bot->{irc}{wire},\@futures,$bot->{_flood_outq}], [[],[],undef],'no_defer refusal writes nothing and queues nothing');
 $bot=bot_1171(5);
 ok(Mediabot::IRC::Sender::botPrivmsg($bot,'#test','x'x900,{no_defer=>1,write_futures=>\@futures}),'no_defer admits a batch that fits');
 is(scalar @futures,3,'one write receipt is collected per emitted line');
}
{
 my $bot=bot_1171(1);
 Mediabot::IRC::Sender::botPrivmsg($bot,'#test',('x'x398).'BADWORD'.('y'x400));
 $bot->{_badword_cache}{'#test'}{words}=['badword'];
 drain_1171($bot) for 1..3;
 is_deeply($bot->{irc}{wire},[],'new badword spanning chunk boundary rejects all queued pieces');
 $bot=bot_1171(1);
 Mediabot::IRC::DeferredOutput::_defer_flooded_send($bot,'privmsg','#test','x'x12000);
 is(scalar @{$bot->{_flood_outq}{'#test'}{items}},30,'queue accepts exactly thirty physical lines');
 ok(!Mediabot::IRC::DeferredOutput::_defer_flooded_send($bot,'privmsg','#test','tail'),'full queue rejects another reply');
 is(scalar @{$bot->{_flood_outq}{'#test'}{items}},30,'overflow preserves existing queued lines');
}
{
 my $bot=bot_1171(20);
 Mediabot::IRC::Sender::botPrivmsg($bot,'#test','x'x2400);
 is_deeply([scalar @{$bot->{irc}{wire}},scalar @{$bot->{_flood_outq}{'#test'}{items}},scalar @{$bot->{_global_af}{hits}},$bot->{_global_af}{silenced_until}],
     [0,6,0,0],'batch exceeding global capacity queues without a cross-channel silence or charge');
 $bot=bot_1171(2);
 $bot->{_flood_outq}{'#test'}={items=>[['privmsg','x'x900],['privmsg','tail']],armed=>0};
 drain_1171($bot);
 is_deeply([map {length($_->[1])} @{$bot->{_flood_outq}{'#test'}{items}}],[400,400,100,4],
     'legacy unsplit queue entry expands at the head without reversing lines');
}

# MB1172: computed retries are read-only and preserve admission policy.
{
 my $now=1800000000;
 my $delay=\&Mediabot::IRC::DeferredOutput::_flood_retry_delay;
 my $bot={};
 is($delay->($bot,'#test',$now),2,'unknown policy retains two-second retry');
 is_deeply($bot,{},'reading deadlines does not autovivify state');
 $bot={_global_af=>{silenced_until=>$now+6,hits=>[$now]},
       _af=>{'#test'=>{silenced_until=>$now+8,nbmsg=>4,first=>$now}}};
 is($delay->($bot,'#test',$now),8,'wait for the later of channel and global silence');
 is($delay->($bot,'#other',$now),6,'another channel only waits for global silence');
 is($delay->($bot,'#test',$now+7),2,'retain minimum pacing near deadline');
 is($delay->($bot,'#test',$now+8),2,'exact expiry resumes normal retries');
 is($delay->($bot,'#test',$now+20),2,'expired deadlines never yield negative delay');
 is_deeply($bot,{_global_af=>{silenced_until=>$now+6,hits=>[$now]},
       _af=>{'#test'=>{silenced_until=>$now+8,nbmsg=>4,first=>$now}}},
       'planning does not charge, prune, reset or extend either budget');
 $bot->{_af}{'#test'}{silenced_until}=$now+300;
 is($delay->($bot,'#test',$now),10,'long channel silence uses ten-second checkpoints');
 $bot->{_global_af}{silenced_until}=$now+120;
 is($delay->($bot,'#other',$now),10,'long global silence uses ten-second checkpoints');
 is($delay->($bot,'#test',$now-3600),10,'backward wall-clock jump cannot create an unbounded timer');
 $bot->{_global_af}{silenced_until}=0;
 $bot->{_af}{'#test'}{silenced_until}=0;
 is($delay->($bot,'#test',$now),2,'removing silences restores ordinary pacing');
 $bot->{_af}{'#test'}{nbmsg}=999;
 is($delay->($bot,'#test',$now),2,'a full window still enters the existing admission and silence policy');
}
{
 no warnings 'redefine';
 my @timers; my @drains;
 local *Mediabot::IRC::Timer::countdown=sub {push @timers,{@_};1};
 local *Mediabot::Helpers::_drain_flood_queue=sub {push @drains,$_[1];1};
 my $q={items=>[['privmsg','queued']],armed=>0};
 my $bot={loop=>bless({},'MB1172::Loop'),_flood_outq=>{'#test'=>$q},
          _af=>{'#test'=>{silenced_until=>time()+300}}};
 Mediabot::IRC::DeferredOutput::_arm_flood_drain($bot,'#test');
 is($timers[0]{delay},10,'real arming uses computed checkpoint');
 Mediabot::IRC::DeferredOutput::_arm_flood_drain($bot,'#test');
 is(scalar @timers,1,'already armed queue never gets a duplicate timer');
 $bot->{_af}{'#test'}{silenced_until}=0;
 $timers[0]{on_expire}->();
 is_deeply(\@drains,['#test'],'checkpoint re-enters normal drain after policy changes');
 $q->{armed}=0;
 Mediabot::IRC::DeferredOutput::_arm_flood_drain($bot,'#test');
 is($timers[1]{delay},2,'rearming reads the changed state');
 $bot->{_flood_outq}{'#test'}={items=>[],armed=>0};
 $timers[1]{on_expire}->();
 is(scalar @drains,1,'retired queue callback cannot drain a replacement queue');
 local *Mediabot::IRC::Timer::countdown=sub {die "MB1172 setup failure\n"};
 eval {Mediabot::IRC::DeferredOutput::_arm_flood_drain($bot,'#test')};
 like($@,qr/MB1172 setup failure/,'timer setup errors still propagate');
 is($bot->{_flood_outq}{'#test'}{armed},0,'failed setup leaves queue rearmable');
}

# MB1173: use the real sender/drain/guard chain with the controlled guard clock.
for my $kind ('privmsg','action') {
 my $send=$kind eq 'action'?\&Mediabot::IRC::Sender::botAction:\&Mediabot::IRC::Sender::botPrivmsg;
 my $bot=bot_1171(1);
 $send->($bot,'#test','x'x500);
 drain_1171($bot);
 my $first=$MB1171::Guard::now;
 drain_1171($bot) for 1..3;
 is_deeply([scalar @{$bot->{irc}{wire}},$bot->{_af}{'#test'}{nbmsg},
   $bot->{_af}{'#test'}{silenced_until},scalar @{$bot->{_global_af}{hits}},
   scalar @{$bot->{_flood_outq}{'#test'}{items}}],[1,1,0,1,1],
   "$kind: blocked retries preserve counters, silence and pending line");
 $MB1171::Guard::now=$first+29;drain_1171($bot);
 is(scalar @{$bot->{irc}{wire}},1,"$kind: no early admission before channel window expires");
 $MB1171::Guard::now=$first+30;drain_1171($bot);
 is_deeply([scalar @{$bot->{irc}{wire}},$bot->{_af}{'#test'}{nbmsg},
   scalar @{$bot->{_global_af}{hits}},scalar @{$bot->{_flood_outq}{'#test'}{items}}],
   [2,1,1,0],"$kind: exact window expiry resumes and charges the last line once");
 $bot=bot_1171(20);
 $send->($bot,'#test','x'x2200);drain_1171($bot) for 1..8;
 is_deeply([scalar @{$bot->{irc}{wire}},scalar @{$bot->{_global_af}{hits}},
   $bot->{_global_af}{silenced_until},scalar @{$bot->{_flood_outq}{'#test'}{items}}],
   [5,5,0,1],"$kind: full global budget queues without a new global silence");
 $MB1171::Guard::now+=10;drain_1171($bot);
 is_deeply([scalar @{$bot->{irc}{wire}},scalar @{$bot->{_global_af}{hits}}],
   [6,1],"$kind: exact global window expiry admits and charges the remaining line");
 $bot=bot_1171(1);
 $send->($bot,'#test','one');$send->($bot,'#test','two');
 my $until=$MB1171::Guard::now+300;
 is($bot->{_af}{'#test'}{silenced_until},$until,"$kind: a new single-line excess still starts channel silence");
 drain_1171($bot);
 is_deeply([scalar @{$bot->{irc}{wire}},$bot->{_af}{'#test'}{silenced_until}],
   [1,$until],"$kind: retry respects the existing channel silence");
 $bot=bot_1171(20);
 $send->($bot,'#test',"line $_") for 1..6;
 $until=$MB1171::Guard::now+15;
 is($bot->{_global_af}{silenced_until},$until,"$kind: fresh excess still starts global silence");
 drain_1171($bot);
 is_deeply([scalar @{$bot->{irc}{wire}},$bot->{_global_af}{silenced_until}],
   [5,$until],"$kind: retry respects the existing global silence");
}
for my $foreign (0,1) {
 my $bot=bot_1171(1);
 Mediabot::IRC::Sender::botPrivmsg($bot,'#test','first');
 my $old={items=>[],armed=>0};
 $bot->{_flood_outq}{$foreign?'#other':'#test'}=$old;
 $bot->{_flood_outq}{'#test'}={items=>[],armed=>0} unless $foreign;
 local $bot->{_flood_draining}=$old;
 Mediabot::IRC::Sender::botPrivmsg($bot,'#test','excess');
 is($bot->{_af}{'#test'}{silenced_until},$MB1171::Guard::now+300,
    $foreign?'another channel drain cannot waive a new penalty':'a retired queue cannot waive a new penalty');
}
done_testing;
