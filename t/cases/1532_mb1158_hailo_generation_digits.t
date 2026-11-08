use strict;
use warnings;
use utf8;
use Test::More;
use Mediabot::Hailo::PostEditRuntime;
{
    package MB1158::Editor;
    sub new { bless {calls=>0}, shift }
    sub submit {
        my ($self,%args)=@_;
        ++$self->{calls};
        $args{on_done}->({ok=>1,line=>$args{candidate},edited=>0,reason=>'unchanged'});
        return 1;
    }
}
for my $bad ('1١', '1１', '1𝟙', '01', "1\n", '0', '-1', undef, []) {
    my $editor=MB1158::Editor->new;
    my $runtime=Mediabot::Hailo::PostEditRuntime->new(post_editor=>$editor,clock=>sub {1000},typing_enabled=>0);
    my ($sent,$state_calls)=(0,0);
    my %args=(channel=>'#test',candidate=>'The garden is quiet',trigger=>'Tell me about the garden',channel_language=>'en',
        send_cb=>sub {++$sent;1}, state_cb=>sub {++$state_calls;return {enabled=>1,runtime_active=>1,irc_connected=>1,channel_joined=>1,current_generation=>1}});
    my @warnings;
    my $result;
    { local $SIG{__WARN__}=sub {push @warnings,@_};
      $result=$runtime->submit(%args,request_generation=>$bad); }
    is($result->{accepted},0,'invalid generation rejected at submission');
    is($result->{reason},'invalid_generation','specific validation reason');
    is($editor->{calls},0,'invalid input never reaches editor');
    is($sent,0,'invalid input never emits');
    is($state_calls,0,'invalid input does not start authorization callbacks');
    is_deeply(\@warnings,[],'no numeric conversion warnings');
    $result=$runtime->submit(%args,request_generation=>1);
    ok($result->{accepted},'valid generation still accepted after rejection');
    is($editor->{calls},1,'valid input reaches editor once');
    is($sent,1,'valid input emits once');
}
done_testing;
