package MB840AsyncFixture;
use strict;
use warnings;
use Exporter 'import';
use Time::HiRes qw(time);
use IO::Async::Loop;
use Mediabot::AI::ConversationRuntimeState;
our @EXPORT_OK = qw(fixture pump record_output);

{ package MB840AsyncFixture::IRC; sub is_connected { $_[0]{connected} } }
{ package MB840AsyncFixture::Handle; sub do {1} sub disconnect {1} }
{ package MB840AsyncFixture::DB;
  sub connect_isolated_handle { return (bless({},'MB840AsyncFixture::Handle'),undef) } }
{ package MB840AsyncFixture::Logger; sub log { push @{$_[0]{lines}},$_[2];1 } }
{ package MB840AsyncFixture::Context; sub nick {'Caller'} sub channel {$_[0]{channel}} }
{ package MB840AsyncFixture::Bot;
  sub getLoop {$_[0]{loop}} sub getQuit {$_[0]{quit} || 0} }

sub fixture {
    my (%args)=@_;
    my $loop=IO::Async::Loop->really_new;
    my $state=Mediabot::AI::ConversationRuntimeState->new;
    $state->mark_connected;$state->mark_joined('#test');
    my $bot=bless {loop=>$loop,irc=>bless({connected=>1},'MB840AsyncFixture::IRC'),
        db=>bless({},'MB840AsyncFixture::DB'),dbh=>bless({},'MB840AsyncFixture::Handle'),
        logger=>bless({lines=>[]},'MB840AsyncFixture::Logger'),wit_runtime_state=>$state,
        out=>[]},'MB840AsyncFixture::Bot';
    my $ctx=bless {channel=>exists($args{channel})?$args{channel}:'#test'},'MB840AsyncFixture::Context';
    return ($bot,$ctx,$loop);
}
sub pump {
    my ($loop,$until,$seconds)=@_;$seconds=2 unless defined $seconds;
    my $deadline=time()+$seconds;
    $loop->loop_once(.005) while !$until->() && time()<$deadline;
    return $until->()?1:0;
}
sub record_output {
    my ($bot,$target,$text)=@_;
    push @{$bot->{out}},[$target,$text];
    $bot->{after_line}->() if $bot->{after_line};
    return 1;
}
1;
