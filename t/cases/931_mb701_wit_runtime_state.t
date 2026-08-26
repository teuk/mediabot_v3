# t/cases/931_mb701_wit_runtime_state.t
# =============================================================================
# MB701-B — real IRC lifecycle state/generation contract for future Wit emission.
# Still no provider call and no IRC emission.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use Mediabot::AI::ConversationRuntimeState;

return sub {
    my ($assert) = @_;

    my $state = Mediabot::AI::ConversationRuntimeState->new();
    my $snap = $state->snapshot('#test');

    $assert->is($snap->{runtime_active}, 1,
        'mb701-931: runtime starts active');
    $assert->is($snap->{irc_connected}, 0,
        'mb701-931: runtime starts IRC-disconnected');
    $assert->is($snap->{channel_joined}, 0,
        'mb701-931: unknown channel starts not joined');
    $assert->is($snap->{current_generation}, 0,
        'mb701-931: unknown channel has no live generation');
    $assert->ok(!defined($state->capture_generation('#test')),
        'mb701-931: disconnected runtime cannot capture an emission generation');

    $assert->is($state->mark_connected(), 1,
        'mb701-931: first connect transition is recorded');
    $assert->is($state->mark_connected(), 0,
        'mb701-931: duplicate connect is idempotent');

    my $gen1 = $state->mark_joined('#Test');
    $assert->ok(defined($gen1) && $gen1 > 0,
        'mb701-931: self JOIN creates a positive generation');
    $assert->is($state->capture_generation('#test'), $gen1,
        'mb701-931: joined channel exposes its live generation');

    my $same_gen = $state->mark_joined('#test');
    $assert->is($same_gen, $gen1,
        'mb701-931: duplicate JOIN is idempotent and does not churn generation');

    my $other_gen = $state->mark_joined('#other');
    $assert->ok($other_gen > $gen1,
        'mb701-931: another joined channel receives a newer independent token');
    $assert->is($state->capture_generation('#test'), $gen1,
        'mb701-931: unrelated channel lifecycle does not invalidate test generation');

    my $left_gen = $state->mark_left('#test');
    $assert->ok($left_gen > $gen1,
        'mb701-931: PART/KICK transition advances the affected channel generation');
    $snap = $state->snapshot('#test');
    $assert->is($snap->{channel_joined}, 0,
        'mb701-931: departed channel is no longer joined');
    $assert->is($snap->{current_generation}, $left_gen,
        'mb701-931: departed channel retains the invalidating generation');
    $assert->ok(!defined($state->capture_generation('#test')),
        'mb701-931: departed channel cannot capture a live generation');

    my $left_again = $state->mark_left('#test');
    $assert->is($left_again, $left_gen,
        'mb701-931: duplicate PART/KICK is idempotent');

    my $gen2 = $state->mark_joined('#test');
    $assert->ok($gen2 > $left_gen,
        'mb701-931: rejoin creates a fresh generation');
    $assert->ok($gen2 != $gen1,
        'mb701-931: pre-PART async results cannot match the rejoined channel');

    $assert->is($state->mark_disconnected(), 1,
        'mb701-931: disconnect transition invalidates joined channels');
    my $test_disc = $state->snapshot('#test');
    my $other_disc = $state->snapshot('#other');
    $assert->is($test_disc->{irc_connected}, 0,
        'mb701-931: disconnect clears IRC connectivity');
    $assert->is($test_disc->{channel_joined}, 0,
        'mb701-931: disconnect clears test membership');
    $assert->ok($test_disc->{current_generation} > $gen2,
        'mb701-931: disconnect invalidates test generation');
    $assert->is($other_disc->{channel_joined}, 0,
        'mb701-931: disconnect clears every joined channel');
    $assert->ok($other_disc->{current_generation} > $other_gen,
        'mb701-931: disconnect invalidates every joined channel generation');
    $assert->is($state->mark_disconnected(), 0,
        'mb701-931: duplicate disconnect is idempotent');

    $assert->ok(!defined($state->mark_joined('#test')),
        'mb701-931: disconnected runtime cannot manufacture joined state');

    $assert->is($state->mark_connected(), 1,
        'mb701-931: reconnect transition is accepted');
    my $gen3 = $state->mark_joined('#test');
    $assert->ok($gen3 > $test_disc->{current_generation},
        'mb701-931: post-reconnect JOIN receives a new generation');

    $assert->is($state->mark_shutdown(), 1,
        'mb701-931: shutdown transition is recorded');
    $snap = $state->snapshot('#test');
    $assert->is($snap->{runtime_active}, 0,
        'mb701-931: shutdown permanently marks runtime inactive');
    $assert->is($snap->{irc_connected}, 0,
        'mb701-931: shutdown clears IRC connectivity');
    $assert->is($snap->{channel_joined}, 0,
        'mb701-931: shutdown clears channel membership');
    $assert->ok($snap->{current_generation} > $gen3,
        'mb701-931: shutdown invalidates the final joined generation');
    $assert->is($state->mark_shutdown(), 0,
        'mb701-931: duplicate shutdown is idempotent');
    $assert->is($state->mark_connected(), 0,
        'mb701-931: inactive runtime cannot reconnect itself');
    $assert->ok(!defined($state->mark_joined('#test')),
        'mb701-931: inactive runtime cannot become joined');

    my $bad_channel = 0;
    eval { $state->snapshot('Alice') };
    $bad_channel = $@ ? 1 : 0;
    $assert->ok($bad_channel,
        'mb701-931: private/non-channel targets are rejected');

    my $module_path = "$Bin/../../Mediabot/AI/ConversationRuntimeState.pm";
    open my $sf, '<:encoding(UTF-8)', $module_path or die "open $module_path: $!";
    local $/;
    my $src = <$sf>;
    close $sf;

    $assert->unlike($src, qr/\b(?:DBI|CHANNEL_SET|CHANSET_LIST|botPrivmsg|botNotice|send_message|do_PRIVMSG)\b/,
        'mb701-931: runtime state owns no DB/chanset/IRC delivery primitive');
    $assert->unlike($src, qr/Mediabot::Helpers|Net::Async::IRC|ConversationExecutor|ConversationEmission/,
        'mb701-931: runtime state remains independent from policy/provider/emission layers');

    my $main = do {
        open my $mf, '<:encoding(UTF-8)', "$Bin/../../mediabot.pl"
            or die "open mediabot.pl: $!";
        local $/;
        <$mf>;
    };

    $assert->like($main, qr/on_login[\s\S]{0,1800}wit_runtime_state.*mark_connected/,
        'mb701-931: successful IRC login marks runtime connected');
    $assert->like($main, qr/on_message_JOIN[\s\S]{0,1600}is_nick_me|on_message_JOIN[\s\S]{0,1600}\$sNick eq \$self->nick/,
        'mb701-931: JOIN handler distinguishes self membership');
    $assert->like($main, qr/on_message_JOIN[\s\S]{0,1800}wit_runtime_state.*mark_joined/,
        'mb701-931: self JOIN records real channel membership');
    $assert->like($main, qr/on_message_PART[\s\S]{0,4000}wit_runtime_state.*mark_left/,
        'mb701-931: self PART invalidates channel generation');
    $assert->like($main, qr/on_message_KICK[\s\S]{0,2200}wit_runtime_state.*mark_left/,
        'mb701-931: self KICK invalidates channel generation before rejoin');
    $assert->like($main, qr/on_message_ERROR[\s\S]{0,1500}wit_runtime_state.*mark_disconnected/,
        'mb701-931: IRC ERROR invalidates runtime connectivity');
    $assert->like($main, qr/on_message_KILL[\s\S]{0,1500}wit_runtime_state.*mark_disconnected/,
        'mb701-931: IRC KILL invalidates runtime connectivity');
    $assert->like($main, qr/on_timer_tick[\s\S]{0,3500}!\$irc_connected[\s\S]{0,500}wit_runtime_state.*mark_disconnected/,
        'mb701-931: silent transport loss also invalidates runtime state');

    my $core = do {
        open my $cf, '<:encoding(UTF-8)', "$Bin/../../Mediabot/Mediabot.pm"
            or die "open Mediabot.pm: $!";
        local $/;
        <$cf>;
    };
    $assert->like($core, qr/wit_runtime_state\s*=>\s*Mediabot::AI::ConversationRuntimeState->new/,
        'mb701-931: Mediabot owns one process-lifetime Wit runtime state object');
    $assert->like($core, qr/sub restart_irc[\s\S]{0,1800}wit_runtime_state.*mark_disconnected/,
        'mb701-931: explicit IRC restart invalidates state before reconnect');
    $assert->like($core, qr/sub clean_and_exit[\s\S]{0,1200}wit_runtime_state.*mark_shutdown/,
        'mb701-931: every clean shutdown invalidates runtime authorization');

    $assert->like($main, qr/ConversationEmission::evaluate_emission\s*\(/,
        'mb701-931: later MB701 runtime revalidates state through final emission gate');
    my ($wit_block) = $main =~ /(\# mb700-G: \+Wit.*?)(?=
\s*my \(\$sCommand,\@tArgs\))/s;
    $assert->ok(defined($wit_block),
        'mb701-931: proactive Wit runtime block remains identifiable');
    $assert->unlike($wit_block // '', qr/(?:botPrivmsg|botNotice|send_message|do_PRIVMSG)/,
        'mb701-931: runtime generation integration still performs no IRC delivery');
};
