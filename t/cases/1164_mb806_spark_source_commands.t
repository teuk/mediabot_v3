use strict;
use warnings;
use utf8;

BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use Mediabot::Spark::Selector qw(select_spark_event);
use Mediabot::Spark::Sender;
use Mediabot::DTC::AsyncFetcher;

{
    package MB806Worker;
    our $pending;
    sub start {
        my ($class, %args) = @_;
        $pending = \%args;
        return bless {}, $class;
    }
    sub finish {
        my ($result) = @_;
        my $cb = $pending->{on_done};
        undef $pending;
        $cb->($result);
    }
}

return sub {
    my ($assert) = @_;
    my %selected;
    for my $cursor (0 .. 40) {
        my $choice = select_spark_event(
            recent_humans => 3, context_lines => 0, ai_available => 1,
            audience_regime => 'social', vdm_enabled => 1, dtc_enabled => 1,
            cursor => $cursor,
        );
        $selected{$choice->{kind}}++;
    }
    $assert->ok($selected{vdm} >= 2 && $selected{dtc} >= 2,
        'mb806: both source commands recur in an eligible social room');
    for my $flag (qw(vdm_enabled dtc_enabled)) {
        my %off;
        for my $cursor (0 .. 20) {
            my $choice = select_spark_event(
                recent_humans => 3, context_lines => 0, ai_available => 0,
                audience_regime => 'social', vdm_enabled => 1, dtc_enabled => 1,
                $flag => 0, cursor => $cursor,
            );
            $off{$choice->{kind}}++;
        }
        my $kind = $flag eq 'vdm_enabled' ? 'vdm' : 'dtc';
        $assert->ok(!$off{$kind}, "mb806: disabled $kind never selected");
    }
    my $solo = select_spark_event(
        recent_humans => 1, audience_regime => 'solo', ai_available => 0,
        vdm_enabled => 1, dtc_enabled => 1,
    );
    $assert->is($solo->{action}, 'skip',
        'mb806: source commands do not target a solo room');

    my @sent;
    my $now = 1000;
    my $prefix = '!';
    my $sender = Mediabot::Spark::Sender->new(
        clock => sub { $now }, command_char_cb => sub { $prefix },
        send_cb => sub { push @sent, [ @_ ]; 1 },
    );
    my $state = {
        enabled => 1, runtime_active => 1, irc_connected => 1,
        channel_joined => 1, current_generation => 7,
    };
    my $quote = {
        action => 'ready', kind => 'dtc',
        content => { id => 42, text => join("\n", map { "<a> quote $_" } 1 .. 9) },
    };
    my %request = (
        channel => '#room', kind => 'dtc', generation => 7,
        generated => $quote, state_cb => sub { return { %$state }; },
    );
    $assert->is($sender->attempt_send(%request)->{reason}, 'kill_switch',
        'mb806: disarmed sender emits neither command nor quote');
    $assert->is(scalar(@sent), 0, 'mb806: disarmed channel stays silent');
    $sender->arm;
    $assert->is($sender->attempt_send(%request)->{action}, 'sent',
        'mb806: guarded DTC sends successfully');
    $assert->is($sent[0][1], '!dtc',
        'mb806: visible command precedes the quote');
    $assert->is(scalar(@sent), 4,
        'mb806: automatic DTC is capped at command plus three quote lines');
    $assert->like($sent[-1][1], qr{https://danstonchat\.com/quote/42\.html},
        'mb806: truncated quote retains its source URL');
    $assert->is($sender->attempt_send(%request)->{reason}, 'rate_limited',
        'mb806: entire command and quote share the channel send limit');
    $now += 120;
    $state->{enabled} = 0;
    $assert->is($sender->attempt_send(%request)->{reason}, 'disabled',
        'mb806: late channel revocation suppresses command and quote');
    $assert->is(scalar(@sent), 4, 'mb806: revocation emits no partial command');
    $state->{enabled} = 1;
    $prefix = '#';
    $assert->is($sender->attempt_send(%request)->{action}, 'sent',
        'mb806: configured prefix still permits delivery');
    $assert->is($sent[4][1], '#dtc',
        'mb806: visible command uses the instance prefix');

    my $fetcher = Mediabot::DTC::AsyncFetcher->new(
        loop => bless({}, 'MB806Loop'), worker_class => 'MB806Worker',
        fetch_cb => sub { die 'only a worker may fetch' },
    );
    my @done;
    $assert->ok($fetcher->fetch(on_done => sub { push @done, $_[0] }),
        'mb806: DTC starts a bounded asynchronous source fetch');
    $assert->ok(!$fetcher->fetch(on_done => sub { push @done, $_[0] }),
        'mb806: concurrent fetches cannot multiply');
    MB806Worker::finish({ ok => 1, value => { ok => 1, id => 7, text => 'quote' } });
    $assert->is($done[0]{id}, 7, 'mb806: worker result reaches parent callback');
    $assert->ok(!$fetcher->inflight, 'mb806: completion clears the worker');

    open my $fh, '<:encoding(UTF-8)', "$Bin/../../mediabot.pl" or die $!;
    local $/;
    my $main = <$fh>;
    $assert->like($main, qr/dtc_enabled\s*=>\s*\$dtc_enabled/,
        'mb806: channel permission reaches Spark selection');
    $assert->like($main, qr/_spark_handle_dtc_candidate\(/,
        'mb806: worker result reaches the guarded delivery adapter');
    $assert->like($main, qr/_spark_dtc_last_id.*?eq "\$id"/s,
        'mb806: immediately repeated DTC IDs are skipped per channel');
    $assert->like($main, qr/\$kind eq 'vdm' \|\| \$kind eq 'dtc'\) \? 2_400/,
        'mb806: both source commands get the bounded forty-minute cooldown');
};
