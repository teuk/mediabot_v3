use strict;
use warnings;
use Test::More;
use lib '.', 't/lib';
use Mediabot::AI::ConversationRuntimeState;
use Mediabot::CommandAsync;
use MB840AsyncFixture qw(fixture pump record_output);

for my $pair (['#Room[one]','#room{ONE}'],['#Room\\one','#room|ONE'],['#Room^one','#room~ONE']) {
    my($joined,$alias)=@$pair;
    my $s=Mediabot::AI::ConversationRuntimeState->new;
    $s->mark_connected;$s->update_isupport('CASEMAPPING=rfc1459');my $gen=$s->mark_joined($joined);
    is($s->capture_generation($alias),$gen,'equivalent IRC spelling finds the joined room');
    is($s->mark_joined($alias),$gen,'duplicate JOIN under an equivalent spelling preserves the current ticket');
    is(scalar keys %{$s->{channels}},1,'equivalent spellings do not create parallel room incarnations');
    $s->mark_left($alias);
    ok(!defined $s->capture_generation($joined),'PART/KICK under an equivalent spelling revokes the old room');
    my $next=$s->mark_joined($alias);
    isnt($next,$gen,'rejoining an equivalent room creates a fresh generation');
    is($s->capture_generation($joined),$next,'original spelling sees only the replacement generation');
    $s->mark_disconnected;
    ok(!defined $s->capture_generation($alias),'disconnect invalidates the shared room');
    $s->mark_connected;$s->mark_joined($joined);$s->mark_shutdown;
    ok(!defined $s->capture_generation($alias),'shutdown invalidates every equivalent spelling');
}

{
    my $s=Mediabot::AI::ConversationRuntimeState->new;$s->mark_connected;
    $s->update_isupport('CASEMAPPING=rfc1459');
    my $a=$s->mark_joined('#room[one]');my $b=$s->mark_joined('#room[two]');
    $s->mark_left('#room{ONE}');
    is($s->capture_generation('#room[two]'),$b,'revocation stays confined to the actual room');
    ok(!defined $s->capture_generation('#room[one]'),'revoked room remains unavailable');
    for my $invalid ('Caller','&private','#bad name',"#bad\nline") {
        ok(!eval {$s->snapshot($invalid);1},'public-channel validation remains strict');
    }
}

{
    my $s=Mediabot::AI::ConversationRuntimeState->new;
    $s->mark_connected;
    my $bracket=$s->mark_joined('#room[one]');
    my $brace=$s->mark_joined('#room{one}');
    isnt($bracket,$brace,'unnegotiated and ASCII channel identities stay distinct');
    $s->mark_left('#ROOM{ONE}');
    is($s->capture_generation('#room[one]'),$bracket,'ASCII departure cannot revoke a different bracket channel');
    is($s->update_isupport('CASEMAPPING=invalid','CASEMAPPING=ascii trailing',undef,{}),0,'malformed capabilities leave identity unchanged');
    is($s->update_isupport('CASEMAPPING=ascii'),0,'repeated mapping does not churn live tickets');
    is($s->update_isupport('CASEMAPPING=strict-rfc1459'),1,'strict mapping is accepted');
    my $strict=$s->capture_generation('#room{one}');
    ok(defined($strict) && $strict != $bracket,'mapping change revokes old ticket but preserves joined membership');
    my $caret=$s->mark_joined('#room^one');
    ok(!defined $s->capture_generation('#room~one'),'strict RFC1459 keeps caret and tilde distinct');
    $s->mark_left('#room~one');
    is($s->capture_generation('#room^one'),$caret,'strict caret room survives a different tilde departure');
    $s->update_isupport('CASEMAPPING=RFC1459');
    my $rfc=$s->capture_generation('#room~one');
    ok(defined($rfc) && $rfc != $caret,'full RFC1459 folds caret with a fresh authorization ticket');
    $s->update_isupport('-CASEMAPPING');
    ok(!defined $s->capture_generation('#room~one'),'removing mapping narrows identities without inventing a joined alias');
    ok(defined $s->capture_generation('#room^one'),'original joined spelling survives mapping removal');
    $s->update_isupport('CASEMAPPING=rfc1459');$s->mark_disconnected;$s->mark_connected;
    my $new=$s->mark_joined('#room[one]');
    ok(!defined $s->capture_generation('#room{one}'),'previous server mapping never leaks across reconnection');
    ok($new > $strict,'reconnect preserves monotonic incarnation tokens');
    $s->mark_left('#room[one]');$s->mark_joined('#room{one}');
    $s->update_isupport('CASEMAPPING=rfc1459');$s->update_isupport('CASEMAPPING=ascii');
    ok(defined $s->capture_generation('#room{one}'),'mapping merge retains the actual joined spelling');
    ok(!defined $s->capture_generation('#room[one]'),'mapping narrowing never revives a departed spelling');
}

{
    # Execute the real numeric hook with offline adapters, including an
    # unrelated Fullop failure. No network connection or IRC send is made.
    open my $fh,'<','mediabot.pl' or die $!;local $/;my $main=<$fh>;
    my ($hook)=$main =~ /(sub on_message_005 \{.*?^\})/ms;
    ok(defined($hook),'real numeric 005 handler is available');
    my $loaded=eval 'package MB844Hook;our $mediabot;sub log_debug_args {} sub _irc_message_args { @{$_[0]} } '.$hook.';1;';
    ok($loaded,'real ISUPPORT handler loads in offline fixture') or diag $@;
    my $s=Mediabot::AI::ConversationRuntimeState->new;$s->mark_connected;
    no warnings 'once'; # Intentional package variable used by the extracted hook.
    local $MB844Hook::mediabot={wit_runtime_state=>$s,logger=>bless({},'MB844Logger'),fullop=>bless({},'MB844FailingFullop')};
    MB844Hook::on_message_005(undef,['bot','CASEMAPPING=rfc1459','are supported'],{});
    my $gen=$s->mark_joined('#hook[room]');
    is($s->capture_generation('#hook{room}'),$gen,'real 005 hook delivers mapping even if Fullop parsing fails');
    $s->mark_left('#hook{room}');
    ok(!defined $s->capture_generation('#hook[room]'),'negotiated mapping controls real departure authorization');
}

no warnings qw(redefine once);
local *Mediabot::Helpers::botPrivmsg=\&record_output;
for my $mode (qw(healthy left rejoined mapping_changed)) {
    my($bot,$ctx,$loop)=fixture(channel=>'#Room[one]');
    $bot->{wit_runtime_state}->update_isupport('CASEMAPPING=rfc1459');
    $bot->{wit_runtime_state}->mark_joined('#Room[one]');
    ok(Mediabot::CommandAsync::run_ctx_async($bot,$ctx,'stats',sub {
        Mediabot::Helpers::botPrivmsg($bot,'#Room[one]','delayed result');
    }),"$mode: real deferred command starts");
    if ($mode eq 'left' || $mode eq 'rejoined') {$bot->{wit_runtime_state}->mark_left('#room{ONE}')}
    if ($mode eq 'rejoined') {$bot->{wit_runtime_state}->mark_joined('#room{ONE}')}
    if ($mode eq 'mapping_changed') {$bot->{wit_runtime_state}->update_isupport('CASEMAPPING=ascii')}
    ok(pump($loop,sub {!keys %{$bot->{_cmd_async_jobs}}}),"$mode: real worker and channel slot finish");
    is(scalar @{$bot->{out}},$mode eq 'healthy'?1:0,"$mode: delayed output obeys the equivalent channel lifecycle");
}
done_testing;

package MB844Logger;sub log {}
package MB844FailingFullop;sub update_isupport {die qq{fixture failure\n}}
