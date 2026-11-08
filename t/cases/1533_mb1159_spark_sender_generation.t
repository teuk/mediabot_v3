use strict;
use warnings;
use utf8;
use Test::More;
use Mediabot::Spark::Sender;
for my $bad ('1١', '1１', '1𝟙', '01', "1\n", undef, []) {
    for my $side ('request', 'current') {
        my @sent;
        my $sender=Mediabot::Spark::Sender->new(clock=>sub {1000},send_cb=>sub {push @sent, [@_];1});
        $sender->arm;
        my $current=$side eq 'current' ? $bad : 1;
        my %args=(channel=>'#test',kind=>'fork',generation=>$side eq 'request' ? $bad : 1,
            generated=>{action=>'ready',kind=>'fork',content=>{question=>'Tea or coffee?',a=>'Tea',b=>'Coffee'}},
            state_cb=>sub {return {enabled=>1,runtime_active=>1,irc_connected=>1,channel_joined=>1,current_generation=>$current}});
        my @warnings;
        my $out;
        {local $SIG{__WARN__}=sub {push @warnings,@_}; $out=$sender->attempt_send(%args);}
        is($out->{action},'no_send','malformed identity blocks delivery');
        is(scalar @sent,0,'transport not called');
        is_deeply(\@warnings,[],'no numeric conversion warning');
        $current=1;
        $out=$sender->attempt_send(%args,generation=>1);
        is($out->{action},'sent','valid generation remains deliverable after rejection');
        is(scalar @sent,1,'valid delivery reaches transport once');
    }
}
done_testing;
