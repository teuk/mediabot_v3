use strict;
use warnings;
use utf8;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use Mediabot::Spark::Sender;
return sub {
 my($assert)=@_; my @sent; my $now=1000;
 my $s=Mediabot::Spark::Sender->new(clock=>sub{$now},send_cb=>sub{push @sent,[@_];1});
 my $gen={action=>'ready',kind=>'vdm',content=>{id=>'513869',story=>'Aujourd’hui, Spark a choisi mon histoire. VDM'}};
 my $state={enabled=>1,runtime_active=>1,irc_connected=>1,channel_joined=>1,game_active=>0,wit_pending=>0,current_generation=>9};
 my $off=$s->attempt_send(channel=>'#x',kind=>'vdm',generation=>9,generated=>$gen,state_cb=>sub { return { %$state } });
 $assert->is($off->{reason},'kill_switch','mb704-982: VDM auto delivery obeys Spark master arm');
 $s->arm;
 my $ok=$s->attempt_send(channel=>'#x',kind=>'vdm',generation=>9,generated=>$gen,state_cb=>sub { return { %$state } });
 $assert->is($ok->{action},'sent','mb704-982: authorized VDM uses guarded Spark sender');
 $assert->like($sent[0][1],qr/^\x02\x0301,15\[513869\]\x0f /,'mb704-982: Spark sender preserves canonical VDM id formatting');
 $assert->like($sent[0][1],qr/VDM\x0f\z/,'mb704-982: Spark sender preserves canonical VDM closing/reset');
 my $log=Mediabot::Spark::Sender::format_sender_log('#x',$ok);
 $assert->like($log,qr/kind=vdm/,'mb704-982: Spark delivery metadata identifies VDM kind');
 $assert->unlike($log,qr/Spark a choisi/,'mb704-982: VDM source content is absent from Spark sender log');
};
