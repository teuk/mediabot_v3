use strict;
use warnings;
use utf8;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use Mediabot::VDM::Runtime;
{
 package MB704D980::Fetcher;
 sub new { bless { c=>[] }, shift }
 sub fetch { my($s,%a)=@_; push @{$s->{c}},$a{on_done}; 1 }
 sub complete { my($s,$i,$r)=@_; $s->{c}[$i]->($r) }
}
return sub {
 my($assert)=@_; my $now=1000; my @delivered;
 my $bot={vdm=>1,connected=>1,channels=>{'#x'=>{}}};
 my $f=MB704D980::Fetcher->new;
 my $rt=Mediabot::VDM::Runtime->new(bot=>$bot,fetcher=>$f,now_cb=>sub{$now},
   chanset_cb=>sub{$_[0]{vdm}}, connected_cb=>sub{$_[0]{connected}},
   joined_cb=>sub{exists $_[0]{channels}{lc $_[1]}}, notice_cb=>sub{1}, send_cb=>sub{die 'manual send path forbidden'});
 my $spark=1;
 my $tok=$rt->request_spark(channel=>'#x',activity_current_cb=>sub{1},spark_enabled_cb=>sub{$spark},
   deliver_cb=>sub{my($item)=@_; push @delivered,$item; return {action=>'sent',reason=>'delivered'};});
 $assert->ok($tok,'mb704-980: +Spark +VDM starts async VDM source path');
 $f->complete(0,{ok=>1,items=>[{id=>'1',story=>'Aujourd’hui, test Spark. VDM'}]});
 $assert->is(scalar(@delivered),1,'mb704-980: ready VDM crosses only injected Spark delivery callback');
 $assert->is($delivered[0]{id},'1','mb704-980: raw normalized item reaches guarded Spark sender boundary');
 $now++;
 my $tok2=$rt->request_spark(channel=>'#x',activity_current_cb=>sub{1},spark_enabled_cb=>sub{$spark},
   deliver_cb=>sub{my($item)=@_; push @delivered,$item; return {action=>'sent',reason=>'delivered'};});
 $f->complete(1,{ok=>1,items=>[{id=>'1',story=>'Aujourd’hui, test Spark. VDM'},{id=>'2',story=>'Aujourd’hui, autre test. VDM'}]});
 $assert->is($delivered[-1]{id},'2','mb704-980: auto mode shares per-channel anti-repeat state');
};
