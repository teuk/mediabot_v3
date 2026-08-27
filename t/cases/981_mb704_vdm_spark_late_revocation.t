use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use Mediabot::VDM::Runtime;
{
 package MB704D981::Fetcher;
 sub new { bless {c=>[]},shift } sub fetch{my($s,%a)=@_;push @{$s->{c}},$a{on_done};1}
 sub complete{my($s,$i,$r)=@_;$s->{c}[$i]->($r)}
}
return sub {
 my($assert)=@_; my $bot={vdm=>1,connected=>1,channels=>{'#x'=>{}}}; my $f=MB704D981::Fetcher->new; my $sent=0; my $spark=1;
 my $rt=Mediabot::VDM::Runtime->new(bot=>$bot,fetcher=>$f,chanset_cb=>sub{$_[0]{vdm}},connected_cb=>sub{$_[0]{connected}},joined_cb=>sub{exists $_[0]{channels}{lc $_[1]}},notice_cb=>sub{1},send_cb=>sub{0});
 $rt->request_spark(channel=>'#x',activity_current_cb=>sub{1},spark_enabled_cb=>sub{$spark},deliver_cb=>sub{$sent++;{action=>'sent'}});
 $spark=0;
 $f->complete(0,{ok=>1,items=>[{id=>1,story=>'A VDM'}]});
 $assert->is($sent,0,'mb704-981: removing +Spark while fetch is in flight revokes delivery');
 $spark=1;
 $rt->request_spark(channel=>'#x',activity_current_cb=>sub{1},spark_enabled_cb=>sub{$spark},deliver_cb=>sub{$sent++;{action=>'sent'}});
 $bot->{vdm}=0;
 $f->complete(1,{ok=>1,items=>[{id=>2,story=>'B VDM'}]});
 $assert->is($sent,0,'mb704-981: removing +VDM while fetch is in flight revokes delivery');
 $bot->{vdm}=1; my $activity=1;
 $rt->request_spark(channel=>'#x',activity_current_cb=>sub{$activity},spark_enabled_cb=>sub{$spark},deliver_cb=>sub{$sent++;{action=>'sent'}});
 $activity=0;
 $f->complete(2,{ok=>1,items=>[{id=>3,story=>'C VDM'}]});
 $assert->is($sent,0,'mb704-981: renewed human activity revokes an automatic VDM fetch before delivery');
};
