use strict;
use warnings;
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC SOL_SOCKET SO_SNDBUF);
use IO::Handle;
use IO::Async::Loop;
use IO::Async::Stream;
use Mediabot::IRC::Transport;
use Mediabot::IRC::Recovery ();
{
 package MB1277::Bot; sub getQuit {$_[0]{quit}//0}
 package MB1277::Logger; sub log {push @{$_[0]{lines}},$_[2]; die 'logger failure' if $_[0]{fail}}
 package MB1277::Transport;
 sub close_now {$_[0]{closes}++;$_[0]{callback}->() if $_[0]{callback};die 'close failure' if $_[0]{fail}}
}
return sub {
 my ($a)=@_;
 local $SIG{ALRM}=sub {die "keepalive probe exceeded 15 seconds\n"};alarm 15;
 for my $mode (qw(baseline silent stalled responsive)) {
  socketpair(my $client,my $peer,AF_UNIX,SOCK_STREAM,PF_UNSPEC) or die $!;
  setsockopt($client,SOL_SOCKET,SO_SNDBUF,pack('i',4096)) or die $!;
  $peer->blocking(0);
  my $loop=IO::Async::Loop->really_new;
  my $bot=bless {logger=>bless({lines=>[]},'MB1277::Logger')},'MB1277::Bot';
  my $done=$loop->new_future;
  my $irc=Mediabot::IRC::Transport->new(handle=>$client,pingtime=>0.01,
   pongtime=>$mode eq 'responsive'?2:0.03,
   on_ping_timeout=>sub {
    Mediabot::IRC::Recovery::ping_timeout($bot,$_[0]) unless $mode eq 'baseline';
    $done->done('timeout') unless $done->is_ready;
   },
   on_pong_reply=>sub {$done->done('pong') unless $done->is_ready});
  $bot->{irc}=$irc;$loop->add($irc);
  # Socket-pair construction skips connect(). Seed its completed receipt only;
  # parser, timers, writes, close and is_connected remain native methods.
  $irc->{connect_f}=$loop->new_future->done;
  my $tail;
  if ($mode eq 'stalled') {
   for (1..256) {$tail=$irc->do_PRIVMSG(target=>'#local',text=>'x'x380)}
   $a->is($tail->is_ready?1:0,0,'stalled: backlog is genuinely pending before timeout');
  }
  my $reader;
  if ($mode eq 'responsive') {
   $reader=IO::Async::Stream->new(handle=>$peer,on_read=>sub {
    my ($s,$buf)=@_;
    while ($$buf =~ s/^(.*?)\r\n//) {
     my $line=$1; $s->write(":peer PONG bot $1\r\n") if $line =~ /^PING (.+)$/;
    }
    0;
   });$loop->add($reader);
  }
  my $empty='';$irc->on_read(\$empty,0);
  $loop->await($done);
  my $retired=$mode eq 'silent'||$mode eq 'stalled';
  $a->is($done->get,$mode eq 'responsive'?'pong':'timeout',"$mode: native keepalive outcome");
  $a->is($irc->is_connected?1:0,$retired?0:1,"$mode: transport connection state");
  $a->is($bot->{irc_reconnect_requested}//0,$retired?1:0,"$mode: existing reconnect request flag");
  $a->is(scalar @{$bot->{logger}{lines}},$retired?1:0,"$mode: one bounded diagnostic only for recovery");
  if ($tail) {
   $a->is($tail->is_failed?1:0,1,'stalled: unsent tail receipt fails explicitly');
   $tail->failure;
  }
  if ($retired) {
   $a->is(Mediabot::IRC::Recovery::ping_timeout($bot,$irc),0,"$mode: duplicate timeout is inert");
   $a->is(scalar @{$bot->{logger}{lines}},1,"$mode: duplicate does not repeat diagnostic");
  }
  $irc->close_now;$reader ? $reader->close_now : close($peer);
 }
 for my $mode (qw(stale quitting close_failure logger_failure replacement)) {
  my $t=bless {},'MB1277::Transport';
  my $other=bless {},'MB1277::Transport';
  my $bot=bless {irc=>$t,logger=>bless({lines=>[],fail=>$mode eq 'logger_failure'},'MB1277::Logger')},'MB1277::Bot';
  $bot->{irc}=$other if $mode eq 'stale';$bot->{quit}=1 if $mode eq 'quitting';
  $t->{fail}=1 if $mode eq 'close_failure';
  $t->{callback}=sub {$bot->{irc}=$other;$bot->{irc_reconnect_requested}=0} if $mode eq 'replacement';
  my $result=Mediabot::IRC::Recovery::ping_timeout($bot,$t);
  my $acted=$mode ne 'stale' && $mode ne 'quitting';
  $a->is($result,$acted?1:0,"$mode: recovery decision");
  $a->is($t->{closes}//0,$acted?1:0,"$mode: only selected old transport closes");
  $a->is($other->{closes}//0,0,"$mode: successor is untouched");
  $a->is($bot->{irc_reconnect_requested}//0,$acted && $mode ne 'replacement'?1:0,"$mode: recovery state survives failure but not overwritten after replacement");
 }
 alarm 0;
};
