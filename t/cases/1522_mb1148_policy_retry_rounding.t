use strict;
use warnings;
use Test::More;
use Mediabot::AI::ConversationPolicy qw(evaluate_candidate);
use Mediabot::Spark::Policy qw(evaluate_spark_start);
use Mediabot::Spark::ActionPolicy qw(evaluate_spark_action_start);
my %base=(enabled=>1,spark_enabled=>1,action_enabled=>1,channel=>'#test',
    runtime_active=>1,irc_connected=>1,channel_joined=>1,recent_humans=>10,
    recent_lines=>50,message=>'Hello there',last_human_at=>0);
my @policies=(
    ['Wit cooldown','cooldown',sub {my ($remaining,$now)=@_;evaluate_candidate(%base,now=>$now,last_reply_at=>910+$remaining,min_interval_seconds=>90)}],
    ['Spark cooldown','cooldown',sub {my ($remaining,$now)=@_;evaluate_spark_start(%base,now=>$now,cooldown_until=>1000+$remaining)}],
    ['Spark silence','not_quiet',sub {my ($remaining,$now)=@_;evaluate_spark_start(%base,now=>$now,last_human_at=>910+$remaining,min_silence_seconds=>90)}],
    ['SparkAction cooldown','cooldown',sub {my ($remaining,$now)=@_;evaluate_spark_action_start(%base,now=>$now,cooldown_until=>1000+$remaining)}],
);
for my $policy (@policies) {
    my ($name,$reason,$evaluate)=@$policy;
    for my $remaining (0.25,0.75,1,1.25,2.75,30,89.75,90) {
        my $decision=$evaluate->($remaining,1000);
        is($decision->{reason},$reason,"$name: gate remains closed before deadline");
        my $expected=int($remaining);++$expected if $expected<$remaining;
        is($decision->{retry_after_seconds},$expected,"$name: retry rounds up to a complete second");
        my $next=$evaluate->($remaining,1000+($decision->{retry_after_seconds}//0));
        isnt($next->{reason},$reason,"$name: advertised retry does not wake before deadline");
    }
    isnt($evaluate->(0,1000)->{reason},$reason,"$name: exact deadline is not delayed");
}
done_testing;
