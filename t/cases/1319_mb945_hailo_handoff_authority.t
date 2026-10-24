use strict;
use warnings;
use Test::More;
use Mediabot::Hailo ();
use Mediabot::Helpers;
use Mediabot::Hailo::PostEditRuntime;
use Mediabot::Hailo::ReplyQueue;
use Mediabot::AI::ConversationRuntimeState;

{
    package MB945::Editor;
    sub new { bless { requests => [], pending => [] }, shift }
    sub submit {
        my ($self, %args) = @_;
        push @{ $self->{requests} }, { %args };
        push @{ $self->{pending} }, [$args{on_done}, $args{candidate}];
        return 1;
    }
    sub complete {
        my ($self) = @_;
        my $entry = shift @{ $self->{pending} } or die 'missing provider request';
        $entry->[0]->({ok => 1, line => $entry->[1], edited => 0, reason => 'unchanged'});
    }
    package MB945::Conf;
    sub get { $_[0]{$_[1]} }
    package MB945::Logger;
    sub log { 1 }
    package MB945::IRC;
    sub nick_folded { 'mediabot' }
    sub do_PRIVMSG { my ($self, %args) = @_; push @{ $self->{wire} }, \%args; 1 }
}

my $now = 100;
my $make = sub {
    my (%extra) = @_;
    $now = 100;
    my $editor = MB945::Editor->new;
    my @outcomes;
    my $runtime = Mediabot::Hailo::PostEditRuntime->new(
        post_editor => $editor, max_inflight => 1, typing_enabled => 0,
        clock => sub { $now },
        queue => Mediabot::Hailo::ReplyQueue->new(now_cb => sub { $now }),
        log_cb => sub { push @outcomes, $_[0] }, %extra);
    my $state = Mediabot::AI::ConversationRuntimeState->new;
    $state->mark_connected;
    my $bot = { hailo_post_edit_runtime => $runtime, wit_runtime_state => $state,
        conf => bless({'main.MAIN_PROG_CMD_CHAR' => '!'}, 'MB945::Conf'),
        logger => bless({}, 'MB945::Logger'),
        irc => bless({wire => []}, 'MB945::IRC'), flags => {}, _badword_cache => {} };
    for my $channel ('#test', '#other', '#later') {
        $state->mark_joined($channel);
        $bot->{flags}{$channel} = {Hailo => 1, HailoRespond => 1, HailoLearn => 1, HailoChatter => 1};
        $bot->{_badword_cache}{$channel} = {ts => time(), words => []};
    }
    return ($bot, $editor, $runtime, \@outcomes);
};
my $submit = sub {
    my ($bot, $channel, $candidate, $mode) = @_;
    return Mediabot::Hailo::hailo_submit_candidate($bot,
        channel => $channel, trigger => 'do you like this music?',
        candidate => $candidate, mode => $mode || 'mention');
};

{
    no warnings 'redefine';
    my ($flood, @deferred);
    $flood = 0;
    local *Mediabot::Helpers::chanset_enabled = sub { $_[0]{flags}{$_[1]}{$_[2]} || 0 };
    local *Mediabot::Hailo::getIdChansetList = sub { $_[1] };
    local *Mediabot::Hailo::getIdChannelSet = sub { $_[0]{flags}{$_[1]}{$_[2]} || 0 };
    local *Mediabot::Helpers::channel_lang = sub { 'en' };
    local *Mediabot::Helpers::getIdChansetList = sub { $_[1] eq 'AntiFlood' ? 1 : undef };
    local *Mediabot::Helpers::getIdChannelSet = sub { 1 };
    local *Mediabot::Helpers::checkAntiFlood = sub { $flood };
    local *Mediabot::Helpers::logBotAction = sub { 1 };
    local *Mediabot::Helpers::_defer_flooded_send = sub { push @deferred, [@_]; 1 };

    for my $case (
        ['mention', 'respond', 'disabled'],
        ['chatter', 'chatter', 'disabled'],
        ['mention', 'master', 'disabled'],
        ['mention', 'rejoin', 'stale_generation'],
    ) {
        my ($mode, $change, $reason) = @$case;
        my ($bot, $editor, $runtime, $outcomes) = $make->();
        ok($submit->($bot, '#other', 'An earlier reply.'), "$change: a request occupies the provider slot");
        ok($submit->($bot, '#test', 'The stale reply.', $mode), "$change: the target request waits in the real queue");
        $submit->($bot, '#later', 'A later reply.');
        is(scalar @{ $editor->{requests} }, 1, "$change: queued requests have not reached the provider");
        $bot->{flags}{'#test'}{HailoRespond} = 0 if $change eq 'respond';
        $bot->{flags}{'#test'}{HailoChatter} = 0 if $change eq 'chatter';
        $bot->{flags}{'#test'}{Hailo} = 0 if $change eq 'master';
        if ($change eq 'rejoin') {
            $bot->{wit_runtime_state}->mark_left('#test');
            $bot->{wit_runtime_state}->mark_joined('#test');
        }
        $editor->complete;
        is_deeply([map { $_->{candidate} } @{ $editor->{requests} }],
            ['An earlier reply.', 'A later reply.'],
            "$change: provider handoff skips the revoked request and starts the next valid one");
        my ($dropped) = grep { $_->{channel} eq '#test' } @$outcomes;
        is($dropped ? $dropped->{reason} : undef, $reason,
            "$change: the queued refusal has its existing bounded reason");
        is($dropped ? $dropped->{edit_reason} : undef, 'not_requested',
            "$change: diagnostics cannot invent a provider failure before submission");
        is($runtime->stats->{queue}{queued}, 0, "$change: invalid work cannot hold the later channel in the queue");
        $editor->complete;
        is($runtime->stats->{inflight}, 0, "$change: terminal jobs release their provider slots");
        is(scalar @{ $bot->{irc}{wire} }, 2, "$change: only the two valid channels publish replies");
    }

    for my $mode (qw(mention chatter)) {
        my ($bot, $editor, $runtime, $outcomes) = $make->();
        @deferred = ();
        $submit->($bot, '#test', 'A contextual reply.', $mode);
        $flood = 1;
        $editor->complete;
        is(scalar @deferred, 0, "$mode: refused Hailo output cannot enter the deferred transport queue");
        is($runtime->stats->{sent}, 0, "$mode: queue acknowledgement is never a delivered reply");
        is($outcomes->[-1]{reason}, 'send_failed', "$mode: transport refusal is reported as a terminal failure");
        is_deeply($runtime->recent_context(channel => '#test'), [],
            "$mode: undelivered output never becomes observed conversation context");
        $bot->{flags}{'#test'}{Hailo} = 0;
        $flood = 0;
        for my $entry (splice @deferred) {
            Mediabot::Helpers::botPrivmsg($entry->[0], $entry->[2], $entry->[3]);
        }
        is(scalar @{ $bot->{irc}{wire} }, 0,
            "$mode: lifting antiflood after disabling Hailo cannot resurrect a queued reply");
        is($runtime->stats->{inflight}, 0, "$mode: a rejected send still releases the channel slot");
        $flood = 1;
        Mediabot::Helpers::botPrivmsg($bot, '#test', 'An ordinary command reply.');
        is(scalar @deferred, 1, "$mode: ordinary callers retain their deferred-output behavior");
        @deferred = ();
        $flood = 0;
    }

    my @timers;
    my ($bot, $editor, $runtime, $outcomes) = $make->(
        typing_enabled => 1,
        schedule_cb => sub { push @timers, $_[1]; 1 });
    $submit->($bot, '#test', 'A typing-delayed reply.');
    $editor->complete;
    is(scalar @timers, 1, 'a valid completed edit retains its nonblocking typing delay');
    $bot->{flags}{'#test'}{HailoRespond} = 0;
    $_->() for @timers;
    is(scalar @{ $bot->{irc}{wire} }, 0, 'authorization is still rechecked after the typing delay');
    is($outcomes->[-1]{reason}, 'disabled', 'late revocation keeps the established refusal reason');
    $_->() for @timers;
    is(scalar @$outcomes, 1, 'a repeated timer cannot duplicate terminal accounting');
}
done_testing;
