use strict;
use warnings;
use Test::More;
use Mediabot::Helpers;
use Mediabot::AI::ConversationRuntimeState;
use Mediabot::Spark::Observer;
use Mediabot::Spark::State;
use Mediabot::Spark::Orchestrator;
use Mediabot::Spark::Sender;
use Mediabot::Spark::DryRun;

{
    package MB944::Conf;
    sub get { $_[1] eq 'main.MAIN_PROG_CMD_CHAR' ? '!' : undef }
    sub get_int { 1 }
    package MB944::Logger;
    sub log { push @{ $_[0]{lines} }, $_[2] }
    package MB944::IRC;
    sub nick_folded { 'mediabot' }
    sub do_PRIVMSG { my ($self, %args) = @_; push @{ $self->{wire} }, \%args; 1 }
    package MB944::Generator;
    sub submit { my ($self, %args) = @_; $self->{pending} = $args{on_done}; 1 }
    sub complete {
        my ($self, $kind) = @_;
        my $done = delete $self->{pending} or die 'no pending request';
        $done->({ action => 'ready', kind => $kind,
            content => { line => 'A spontaneous thought.' } });
    }
    package MB944::BrokenObserver;
    sub activity_summary { die 'observation unavailable' }
}

my $main = do {
    open my $fh, '<:encoding(UTF-8)', 'mediabot.pl' or die $!;
    local $/; <$fh>;
};
my $helpers = '';
for my $name (qw(_spark_game_active _spark_action_arm_enabled
    _spark_delivery_state _spark_sender _spark_sync_sender_arm
    _spark_finish_ambient_delivery _spark_handle_candidate)) {
    my ($body) = $main =~ /(sub \Q$name\E \{.*?\n\})/s;
    die "Missing runtime helper $name" unless defined $body;
    $helpers .= "$body\n";
}
eval 'package MB944::Runtime; use strict; use warnings;
    use Mediabot::Spark::Event qw(spark_event_is_momentum spark_event_requires_response);
    '.$helpers.' 1;' or die $@;

my $now;
my $make = sub {
    my %options = @_;
    $now = 1000;
    my $observer = Mediabot::Spark::Observer->new(clock => sub { $now });
    my $state = Mediabot::Spark::State->new(clock => sub { $now });
    my $runtime = Mediabot::Spark::Orchestrator->new(
        observer => $observer, state => $state, clock => sub { $now }, %options);
    for my $i (0 .. 5) {
        $now = 1000 + $i;
        $runtime->observe_public_line(channel => '#test', enabled => 1,
            nick => ('Alice', 'Bob', 'Cara')[$i % 3], bot_nick => 'mediabot',
            message => "human context $i", command_char => '!');
    }
    $now = 1090;
    my $irc_state = Mediabot::AI::ConversationRuntimeState->new;
    $irc_state->mark_connected;
    $irc_state->mark_joined('#test');
    return { spark_state => $state, spark_observer => $observer,
        spark_orchestrator => $runtime, wit_runtime_state => $irc_state,
        conf => bless({}, 'MB944::Conf'),
        logger => bless({ lines => [] }, 'MB944::Logger'),
        irc => bless({ wire => [] }, 'MB944::IRC'),
        flags => { Spark => 1, SparkAction => 1 },
        _badword_cache => { '#test' => { ts => time(), words => [] },
            '#other' => { ts => time(), words => [] } },
    };
};
my $request = sub {
    my ($bot, $kind) = @_;
    my $generator = bless {}, 'MB944::Generator';
    my $dryrun = Mediabot::Spark::DryRun->new(generator => $generator);
    $dryrun->submit_candidate(channel => '#test', kind => $kind,
        context => [], on_result => sub {}, on_candidate => sub {
            MB944::Runtime::_spark_handle_candidate($bot, '#test', 45, $_[0]);
        });
    return ($generator, $dryrun);
};

{
    no warnings 'redefine';
    my ($flood, $queued) = (0, 0);
    local *Mediabot::Helpers::chanset_enabled = sub { $_[0]{flags}{$_[2]} || 0 };
    local *Mediabot::Helpers::getIdChansetList = sub { $_[1] eq 'AntiFlood' ? 1 : undef };
    local *Mediabot::Helpers::getIdChannelSet = sub { 1 };
    local *Mediabot::Helpers::checkAntiFlood = sub { $flood };
    local *Mediabot::Helpers::logBotAction = sub { 1 };
    local *Mediabot::Helpers::_defer_flooded_send = sub { $queued++; 1 };

    for my $kind (qw(stage_cue reaction)) {
        for my $intervening (qw(none same_channel other_channel private)) {
            my $bot = $make->();
            my ($generator, $dryrun) = $request->($bot, $kind);
            ok($dryrun->channel_inflight('#test'), "$kind: native request is pending");
            $now++;
            Mediabot::Helpers::botPrivmsg($bot,
                $intervening eq 'same_channel' ? '#test'
                    : $intervening eq 'other_channel' ? '#other' : 'Alice',
                'Another bot reply.') unless $intervening eq 'none';
            my $before = @{ $bot->{irc}{wire} };
            $generator->complete($kind);
            is(scalar @{ $bot->{irc}{wire} }, $before + ($intervening eq 'same_channel' ? 0 : 1),
                "$kind: live cadence respects $intervening output during generation");
            ok(!$dryrun->channel_inflight('#test'), "$kind: provider completion releases inflight state");
            if ($intervening eq 'same_channel') {
                like(join(' ', @{ $bot->{logger}{lines} }), qr/reason=bot_pressure/,
                    "$kind: refusal explains current automation pressure");
                ok(!$bot->{spark_state}->snapshot('#test')->{event_active},
                    "$kind: refused output creates no phantom participation window");
            }
        }
    }

    my $bot = $make->();
    Mediabot::Helpers::botPrivmsg($bot, '#test', 'Another bot reply.');
    $now += 44;
    my $gates = MB944::Runtime::_spark_delivery_state($bot, '#TEST');
    ok($gates->{action_bot_pressure}, 'momentum delivery uses the existing 45-second pause');
    ok($gates->{bot_pressure}, 'revival delivery retains its longer existing silence');
    $now++;
    $gates = MB944::Runtime::_spark_delivery_state($bot, '#test');
    ok(!$gates->{action_bot_pressure}, 'momentum may resume at the existing pause boundary');
    ok($gates->{bot_pressure}, 'momentum release cannot release the revival lane early');
    $now = 1090 + 1200;
    $gates = MB944::Runtime::_spark_delivery_state($bot, '#test');
    ok(!$gates->{bot_pressure}, 'revival may resume at its existing silence boundary');

    $bot = $make->();
    $bot->{spark_orchestrator}{observer} = bless {}, 'MB944::BrokenObserver';
    $gates = MB944::Runtime::_spark_delivery_state($bot, '#test');
    ok($gates->{bot_pressure} && $gates->{action_bot_pressure},
        'an unavailable activity observation cannot authorize spontaneous output');

    for my $kind (qw(reaction stage_cue)) {
        $bot = $make->();
        my $sender = MB944::Runtime::_spark_sender($bot);
        $sender->arm;
        my $generation = $bot->{spark_state}->begin_event(channel => '#test', kind => $kind);
        Mediabot::Helpers::botPrivmsg($bot, '#test', 'A reply before the final send.');
        my $send = $sender->attempt_send(channel => '#test', kind => $kind,
            generation => $generation,
            generated => { action => 'ready', kind => $kind, content => { line => 'A late thought.' } },
            state_cb => sub { MB944::Runtime::_spark_delivery_state($bot, '#test') });
        is($send->{reason}, 'bot_pressure', "$kind: the final sender rechecks pressure independently of candidate admission");
        is(scalar @{ $bot->{irc}{wire} }, 1, "$kind: only the intervening reply reaches the wire");
    }

    $bot = $make->(action_min_pause_seconds => 90);
    Mediabot::Helpers::botPrivmsg($bot, '#test', 'A reply with a configured pause.');
    $now += 89;
    ok(MB944::Runtime::_spark_delivery_state($bot, '#test')->{action_bot_pressure},
        'a configured pause is honored instead of an extra hardcoded threshold');
    $now++;
    ok(!MB944::Runtime::_spark_delivery_state($bot, '#test')->{action_bot_pressure},
        'the configured pause releases at its exact boundary');

    $bot = $make->();
    my $sender = MB944::Runtime::_spark_sender($bot);
    $sender->arm;
    my $generation = $bot->{spark_state}->begin_event(channel => '#test', kind => 'portal');
    my %args = (channel => '#test', kind => 'portal', generation => $generation,
        generated => { action => 'ready', kind => 'portal', content => { line => 'The promised story.' } },
        state_cb => sub { MB944::Runtime::_spark_delivery_state($bot, '#test') });
    is($sender->attempt_send(%args)->{action}, 'sent', 'interactive opening can be delivered');
    is($sender->attempt_send(%args, continuation => 1)->{action}, 'sent',
        'the opening pressure does not suppress its one promised interactive conclusion');

    $bot = $make->();
    $sender = MB944::Runtime::_spark_sender($bot);
    $sender->arm;
    $generation = $bot->{spark_state}->begin_event(channel => '#test', kind => 'vdm');
    is($sender->attempt_send(channel => '#test', kind => 'vdm', generation => $generation,
        generated => { action => 'ready', kind => 'vdm',
            content => { id => 304759, story => 'A short story. VDM' } },
        state_cb => sub { MB944::Runtime::_spark_delivery_state($bot, '#test') })->{action},
        'sent', 'one permitted story batch is not interrupted by its own first line');
    is(scalar @{ $bot->{irc}{wire} }, 2, 'the story preserves its visible !vdm command and content');

    $bot = $make->();
    my ($generator, $dryrun) = $request->($bot, 'reaction');
    $flood = 1;
    $generator->complete('reaction');
    is(scalar @{ $bot->{irc}{wire} }, 0, 'late antiflood blocks the actual transport');
    is($queued, 0, 'a contextual Spark response is never accepted into the deferred output queue');
    ok(!$bot->{spark_state}->snapshot('#test')->{event_active},
        'a transport refusal releases its provisional Spark event');
    $flood = 0;
    ok(Mediabot::Helpers::botPrivmsg($bot, '#test', 'An explicit command reply.'),
        'ordinary requested replies remain deliverable through the common facade');
}
done_testing;
