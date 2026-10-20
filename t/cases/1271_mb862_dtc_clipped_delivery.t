use strict;
use warnings;
use utf8;
use lib '.', 't/lib';
use Test::More;
use Encode qw(encode);
use Mediabot::DTC::Commands;
use Mediabot::Spark::Sender;
use Mediabot::Context;
use MB840AsyncFixture qw(fixture pump record_output);

sub automatic862 {
    my ($text, $transport) = @_;
    my @out;
    my $sender = Mediabot::Spark::Sender->new(clock => sub {1000},
        send_cb => $transport || sub {push @out, $_[1]; 1});
    $sender->arm;
    my %request = (channel => '#test', kind => 'dtc', generation => 1,
        generated => {action => 'ready', kind => 'dtc', content => {id => 15924, text => $text}},
        state_cb => sub {{enabled => 1, runtime_active => 1, irc_connected => 1,
            channel_joined => 1, current_generation => 1}});
    return ($sender->attempt_send(%request), \@out, $sender, \%request);
}

# Both actual caller paths use the formatter. Only external source IO and
# final IRC transport are replaced; the manual command uses real fork/pipe IO.
{
    no warnings qw(redefine once);
    local *Mediabot::Helpers::chanset_enabled = sub {1};
    local *Mediabot::Helpers::botPrivmsg = \&record_output;
    local *Mediabot::Helpers::botNotice = \&record_output;
    for my $count (1, 10) {
        my $text = join "\n", 'Zoë: ' . ('réplique 🎶 ' x 80), map {"Dialogue $_"} 2 .. $count;
        local *Mediabot::DTC::Commands::fetch_random = sub {{ok => 1, id => 15924, text => $text}};
        local *Mediabot::DTC::Commands::fetch_by_id = sub {{ok => 1, id => $_[0], text => $text}};
        local *Mediabot::DTC::Commands::search_ids = sub {{ok => 1, ids => [15924]}};
        my ($sent, $automatic) = automatic862($text);
        is($sent->{action}, 'sent', "$count dialogues: automatic quote accepted");
        is(shift @$automatic, '!dtc', "$count dialogues: automatic command marker remains");
        like($automatic->[-1], qr{https://danstonchat[.]com/quote/15924[.]html},
            "$count dialogues: automatic clipping retains full quote destination");
        ok(@$automatic <= 10 && !grep({length(encode('UTF-8', $_)) > 430} @$automatic),
            "$count dialogues: automatic line and byte limits remain");
        for my $alias (qw(dtc bashfr)) {
            for my $args ([], [15924], ['offline-search']) {
                my $mode = !@$args ? 'random' : $args->[0] eq 'offline-search' ? 'search' : 'ID';
                my ($bot, undef, $loop) = fixture();
                my $ctx = Mediabot::Context->new(bot => $bot, channel => '#test', nick => 'Tester',
                    command => $alias, args => $args);
                ok(Mediabot::DTC::Commands::dispatch_ctx($ctx), "$count/$alias/$mode: native dispatch starts");
                ok(pump($loop, sub {!keys %{$bot->{_cmd_async_jobs}}}, 5), "$count/$alias/$mode: worker completes");
                is($bot->{_cmd_async_stats}{spawned} // 0, 1, "$count/$alias/$mode: actual worker was used");
                my @reply = map {$_->[1]} @{$bot->{out}};
                like(shift(@reply), qr/\[DansTonChat : 15924\]/, 'search heading is separate') if $mode eq 'search';
                is_deeply(\@reply, $automatic, "$count/$alias/$mode: manual and automatic quote bytes agree");
                ok(!grep({$_->[0] ne '#test'} @{$bot->{out}}), "$count/$alias/$mode: correct requesting channel");
            }
        }
    }
    my $text = 'Speaker: ' . ('x' x 900);
    my ($bot, undef, $loop) = fixture();
    local *Mediabot::DTC::Commands::fetch_random = sub {{ok => 1, id => 15924, text => $text}};
    my $ctx = Mediabot::Context->new(bot => $bot, channel => '#test', nick => 'Tester', command => 'dtc', args => []);
    $bot->{after_line} = sub {$bot->{wit_runtime_state}->mark_left('#test')};
    Mediabot::DTC::Commands::dispatch_ctx($ctx);
    ok(pump($loop, sub {!keys %{$bot->{_cmd_async_jobs}}}, 5), 'revoked manual batch completes');
    is(scalar @{$bot->{out}}, 1, 'channel loss after dialogue blocks the new final link');
    unlike(join('', map {$_->[1]} @{$bot->{out}}), qr/https:\/\//, 'manual link cannot bypass final channel checks');
}

my @attempts;
my ($result, undef, $sender, $request) = automatic862('Speaker: ' . ('x' x 900), sub {
    push @attempts, $_[1]; return @attempts < 3;
});
is($result->{reason}, 'partial_delivery', 'refused final link is a partial automatic delivery');
is(scalar @attempts, 3, 'sender stops at ordinary transport refusal');
is($sender->attempt_send(%$request)->{reason}, 'rate_limited', 'partial delivery keeps normal cooldown');
is(scalar @attempts, 3, 'cooldown prevents a second quote or link');

done_testing;
