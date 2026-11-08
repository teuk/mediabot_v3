use strict;
use warnings;
use utf8;
use Test::More;
use Mediabot::Spark::DryRun;
{
    package MB1161::Generator;
    sub new {bless {},shift}
    sub submit {my ($self,%args)=@_;$self->{done}=$args{on_done};return 1}
}
for my $bad ('1١','1１','1𝟙','01',"1\n",undef,[]) {
    my $generator=MB1161::Generator->new;
    my $runtime=Mediabot::Spark::DryRun->new(generator=>$generator);
    my @results;
    my $generation=$runtime->submit_candidate(channel=>'#test',kind=>'fork',on_result=>sub {push @results,$_[0]});
    is($generation,1,'first request has valid generation');
    my (@warnings,$current,$log);
    {local $SIG{__WARN__}=sub {push @warnings,@_};
     $current=$runtime->generation_is_current('#test',$bad);
     $log=Mediabot::Spark::DryRun::format_ai_dryrun_log('#test',{action=>'ready',reason=>'generated',kind=>'fork',generation=>$bad});}
    ok(!$current,'malformed generation cannot match inflight work');
    unlike($log,qr/ generation=/,'malformed generation omitted from log metadata');
    is_deeply(\@warnings,[],'malformed generation never coerced numerically');
    ok($runtime->generation_is_current('#test',$generation),'real generation still current');
    $generator->{done}->({action=>'no_content',reason=>'test_finished'});
    is(scalar @results,1,'real completion still reported once');
    ok(!$runtime->channel_inflight('#test'),'completion releases channel');
}
for my $value (1,12,999999999999999) {
    my $log=Mediabot::Spark::DryRun::format_ai_dryrun_log('#test',{action=>'ready',reason=>'generated',kind=>'fork',generation=>$value});
    like($log,qr/ generation=\Q$value\E(?: |$)/,'valid generation retained in logs');
}


# MB1163: consolidated from 1534_mb1160_spark_log_channel.t
{
package MB1163::Case1534;
use strict;
use warnings;
use utf8;
use Test::More;
use Mediabot::Spark::DryRun;
my $summary={action=>'ready',reason=>'generated',kind=>'fork',generation=>1};
for my $bad ('#', '#two words', "#test\nforged", "#test\rforged", "#test\tforged",
             "#test\0forged", "#test\x7f", '#a,b', '#a:b', '#'.('a'x80), undef, [], 'test') {
    ok(!defined Mediabot::Spark::DryRun::format_ai_dryrun_log($bad,$summary), 'invalid channel rejected before log construction');
}
for my $valid ('#test','#A[B]','##room','#café','#'.('a'x79)) {
    my $line=Mediabot::Spark::DryRun::format_ai_dryrun_log($valid,$summary);
    is($line,"[SPARK_AI_DRYRUN] channel=$valid action=ready reason=generated kind=fork generation=1",'valid channel retains exact log format');
    unlike($line,qr/[\r\n\x00-\x1f\x7f]/,'log stays on one safe line');
}


}

done_testing;
