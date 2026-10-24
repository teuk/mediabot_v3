use strict;
use warnings;
use Test::More;
use Mediabot::Helpers;
use Mediabot::Spark::Observer;
use Mediabot::Spark::State;
use Mediabot::Spark::Orchestrator;

{
    package MB943::Logger;
    sub new { bless {}, shift }
    sub log { 1 }
    package MB943::IRC;
    sub new { bless { wire => [], fail => 0 }, shift }
    sub nick_folded { 'mediabot' }
    sub do_PRIVMSG {
        my ($self, %args) = @_;
        die "transport unavailable\n" if $self->{fail};
        push @{ $self->{wire} }, \%args;
        return 1;
    }
    package MB943::Wit;
    sub new { bless { channels => [], fail => 0 }, shift }
    sub note_bot_pressure {
        my ($self, $channel) = @_;
        die "observer unavailable\n" if $self->{fail};
        push @{ $self->{channels} }, $channel;
        return 1;
    }
    package MB943::BrokenObserver;
    sub note_bot_pressure { die "observer unavailable\n" }
}

my $now = 1000;
my $make = sub {
    $now = 1000;
    my $observer = Mediabot::Spark::Observer->new(clock => sub { $now });
    my $state = Mediabot::Spark::State->new(clock => sub { $now });
    my $orchestrator = Mediabot::Spark::Orchestrator->new(
        clock => sub { $now }, observer => $observer, state => $state,
    );
    for my $i (0 .. 5) {
        $now = 1000 + $i;
        $orchestrator->observe_public_line(channel => '#test', enabled => 1,
            nick => ('Alice', 'Bob', 'Cara')[$i % 3], bot_nick => 'mediabot',
            message => "human context $i", command_char => '!');
    }
    $now = 1090;
    my $bot = { logger => MB943::Logger->new, irc => MB943::IRC->new,
        spark_observer => $observer, wit_dryrun => MB943::Wit->new,
        _badword_cache => { '#test' => { ts => time(), words => [] } },
    };
    return ($bot, $observer, $orchestrator);
};
my $evaluate = sub {
    $_[0]->evaluate_action_channel(channel => '#test', spark_enabled => 1,
        action_enabled => 1, ai_available => 1, runtime_active => 1,
        irc_connected => 1, channel_joined => 1);
};

{
    no warnings 'redefine';
    my $flood = 0;
    my @queued;
    local *Mediabot::Helpers::getIdChansetList = sub { $_[1] eq 'AntiFlood' ? 1 : undef };
    local *Mediabot::Helpers::getIdChannelSet = sub { 1 };
    local *Mediabot::Helpers::checkAntiFlood = sub { $flood };
    local *Mediabot::Helpers::logBotAction = sub { 1 };
    local *Mediabot::Helpers::noticeConsoleChan = sub { 1 };
    local *Mediabot::Helpers::_defer_flooded_send = sub { push @queued, [@_]; 1 };

    my (undef, undef, $control) = $make->();
    is($evaluate->($control)->{action}, 'action_candidate',
        'three humans and six recent lines can qualify a paused conversation');

    for my $delivery (qw(privmsg action)) {
        my ($bot, $observer, $orchestrator) = $make->();
        my $context = $observer->context_lines('#test');
        if ($delivery eq 'privmsg') {
            ok(Mediabot::Helpers::botPrivmsg($bot, '#test', 'PRIVATE_PROVIDER_TEXT'),
                'ordinary public output is accepted by the real output facade');
        } else {
            Mediabot::Helpers::botAction($bot, '#test', 'PRIVATE_PROVIDER_TEXT');
            is(scalar @{ $bot->{irc}{wire} }, 1, 'public action reaches the real output transport');
        }
        my $activity = $observer->activity_summary('#test', window_seconds => 600);
        is($activity->{bot_pressure_lines}, 1, "$delivery: own output creates breathing space without a server echo");
        is($activity->{distinct_humans}, 3, "$delivery: bot output cannot manufacture another human");
        is($activity->{line_count}, 6, "$delivery: human volume remains unchanged");
        is_deeply($observer->context_lines('#test'), $context, "$delivery: outgoing provider text never enters human context");
        is($evaluate->($orchestrator)->{reason}, 'bot_pressure', "$delivery: native Spark policy yields after the actual output");
        is_deeply($bot->{wit_dryrun}{channels}, ['#test'], "$delivery: existing Wit/Quip notification still happens once");
    }

    my ($bot, $observer) = $make->();
    Mediabot::Helpers::botPrivmsg($bot, '#test', 'x' x 900);
    ok(scalar(@{ $bot->{irc}{wire} }) > 1, 'a long output is split by the native sender');
    is($observer->activity_summary('#test')->{bot_pressure_lines}, 1,
        'one logical multi-chunk message records one pressure event');

    ($bot, $observer) = $make->();
    Mediabot::Helpers::botPrivmsg($bot, 'Alice', 'private message');
    Mediabot::Helpers::botAction($bot, 'Alice', 'private action');
    is($observer->activity_summary('#test')->{bot_pressure_lines}, 0, 'private output does not quiet a public room');

    ($bot, $observer) = $make->();
    $bot->{_badword_cache}{'#test'}{words} = ['blocked'];
    Mediabot::Helpers::botPrivmsg($bot, '#test', 'blocked output');
    Mediabot::Helpers::botAction($bot, '#test', 'blocked action');
    is(scalar @{ $bot->{irc}{wire} }, 0, 'rejected text and action never reach the wire');
    is($observer->activity_summary('#test')->{bot_pressure_lines}, 0, 'rejected outputs do not consume breathing space');

    ($bot, $observer) = $make->();
    $flood = 1;
    is(Mediabot::Helpers::botPrivmsg($bot, '#test', 'deferred output'), 1, 'ordinary deferred output retains its acknowledgement');
    is($observer->activity_summary('#test')->{bot_pressure_lines}, 0, 'enqueueing alone is not represented as output');
    is(Mediabot::Helpers::botPrivmsg($bot, '#test', 'expired contextual reply', { no_defer => 1 }), 0,
        'contextual output rejected by antiflood is still refused');
    is($observer->activity_summary('#test')->{bot_pressure_lines}, 0, 'rejected contextual output adds no pressure');
    $flood = 0;
    my (undef, undef, $target, $text) = @{ shift @queued };
    Mediabot::Helpers::botPrivmsg($bot, $target, $text);
    is($observer->activity_summary('#test')->{bot_pressure_lines}, 1, 'delivery through the deferred queue boundary records the pressure later');

    ($bot, $observer) = $make->();
    $bot->{irc}{fail} = 1;
    eval { Mediabot::Helpers::botPrivmsg($bot, '#test', 'failed transport') };
    is($observer->activity_summary('#test')->{bot_pressure_lines}, 0, 'transport exception does not invent successful output');

    ($bot, $observer) = $make->();
    $bot->{wit_dryrun}{fail} = 1;
    ok(Mediabot::Helpers::botPrivmsg($bot, '#test', 'accepted output'), 'a Wit observation failure cannot reject an accepted send');
    is($observer->activity_summary('#test')->{bot_pressure_lines}, 1, 'Spark observation remains independent of a failing peer observer');

    ($bot, $observer) = $make->();
    $bot->{spark_observer} = bless {}, 'MB943::BrokenObserver';
    ok(Mediabot::Helpers::botPrivmsg($bot, '#test', 'accepted output'), 'Spark observation failure does not change transport acknowledgement');
    is_deeply($bot->{wit_dryrun}{channels}, ['#test'], 'Wit is still notified when Spark observation fails');

    ($bot, $observer) = $make->();
    delete $bot->{spark_observer};
    Mediabot::Helpers::botPrivmsg($bot, '#test', 'no Spark runtime');
    ok(!exists $bot->{spark_observer}, 'sending alone never creates or enables Spark');
    is(Mediabot::Helpers::botAction($bot, '#test', 'no Spark runtime'), 1,
        'the ACTION facade retains its existing return when Spark is absent');

    ($bot, $observer) = $make->();
    $bot->{_badword_cache}{'#unobserved'} = { ts => time(), words => [] };
    my $channels = $observer->channels;
    Mediabot::Helpers::botPrivmsg($bot, '#unobserved', 'unrelated output');
    is_deeply($observer->channels, $channels, 'unobserved channels never allocate or evict Spark context');

    ($bot, $observer) = $make->();
    $bot->{_badword_cache}{'#TEST'} = { ts => time(), words => [] };
    Mediabot::Helpers::botPrivmsg($bot, '#TEST', 'same room');
    is($observer->activity_summary('#test')->{bot_pressure_lines}, 1, 'outgoing observation follows the native Spark channel key');
    $now += 601;
    is($observer->activity_summary('#test', window_seconds => 600)->{bot_pressure_lines}, 0, 'pressure expires through the existing bounded activity window');
}
done_testing;
