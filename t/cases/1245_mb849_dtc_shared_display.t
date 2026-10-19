use strict;
use warnings;
use utf8;
use lib '.', 't/lib';
use Test::More;
use Mediabot::DTC::Commands;
use Mediabot::Spark::Sender;
use Mediabot::Context;
use MB840AsyncFixture qw(fixture pump record_output);

sub mb849_dtc_plain {
    my ($text) = @_;
    $text =~ s/\x03\d{0,2}(?:,\d{1,2})?//g;
    $text =~ s/[\x02\x0f\x16\x1d\x1f]//g;
    return $text;
}
sub mb849_dtc_sender {
    my ($text, $transport) = @_;
    my @out;
    my $sender = Mediabot::Spark::Sender->new(clock => sub {1000},
        send_cb => $transport || sub {push @out, $_[1]; 1});
    $sender->arm;
    my $sent = $sender->attempt_send(channel => '#test', kind => 'dtc', generation => 1,
        generated => {action => 'ready', kind => 'dtc', content => {id => 15924, text => $text}},
        state_cb => sub {return {enabled => 1, runtime_active => 1, irc_connected => 1,
            channel_joined => 1, current_generation => 1}});
    return ($sent, \@out);
}

for my $count (1, 3, 9, 10, 11, 20) {
    my $text = join "\n", map {"Speaker: dialogue $_"} 1..$count;
    my ($result, $auto) = mb849_dtc_sender($text);
    is($result->{action}, 'sent', "$count lines: automatic source delivery is accepted");
    is(shift @$auto, '!dtc', "$count lines: visible command still precedes the quote");
    is(scalar @$auto, $count <= 10 ? $count : 10, "$count lines: automatic quote uses the full shared budget");
    my @plain = map {mb849_dtc_plain($_)} @$auto;
    like($plain[0], qr/^\[15924\] Speaker: dialogue 1\z/, "$count lines: ID and first dialogue remain together");
    if ($count <= 10) {
        like($plain[-1], qr/dialogue \Q$count\E\z/, "$count lines: last dialogue appears without premature link");
        ok(!grep({/Consultez|^\.\.\.\z/} @plain), "$count lines: complete quote has no ellipsis or needless link");
    }
    else {
        like($plain[7], qr/dialogue 8\z/, "$count lines: eighth dialogue appears before truncation");
        is($plain[8], '...', "$count lines: ellipsis follows all eight dialogues");
        is($plain[9], 'Consultez la quote ici : https://danstonchat.com/quote/15924.html',
            "$count lines: exact full quote URL stays last");
    }
}

# The actual manual dispatch and CommandAsync fork/pipe/replay path must retain
# the same output for both public aliases, random, ID and search. Only source
# IO and the final transport are replaced; no real DB/API/IRC is contacted.
{
    no warnings qw(redefine once);
    local *Mediabot::Helpers::chanset_enabled = sub {1};
    local *Mediabot::Helpers::botPrivmsg = \&record_output;
    local *Mediabot::Helpers::botNotice = \&record_output;
    my $text = join "\n", map {"Speaker: dialogue $_"} 1..12;
    local *Mediabot::DTC::Commands::fetch_random = sub {return {ok => 1, id => 15924, text => $text}};
    local *Mediabot::DTC::Commands::fetch_by_id = sub {return {ok => 1, id => $_[0], text => $text}};
    local *Mediabot::DTC::Commands::search_ids = sub {return {ok => 1, ids => [15924]}};
    my ($auto_result, $auto) = mb849_dtc_sender($text);
    shift @$auto;
    for my $alias (qw(dtc bashfr)) {
        for my $args ([], [15924], ['fixture']) {
            my $mode = !@$args ? 'random' : $args->[0] eq 'fixture' ? 'search' : 'ID';
            my ($bot, undef, $loop) = fixture();
            my $ctx = Mediabot::Context->new(bot => $bot, channel => '#test', nick => 'Tester',
                command => $alias, args => $args);
            ok(Mediabot::DTC::Commands::dispatch_ctx($ctx), "$alias $mode: actual manual command starts");
            ok(pump($loop, sub {!keys %{$bot->{_cmd_async_jobs}}}, 5), "$alias $mode: real worker finishes");
            is($bot->{_cmd_async_stats}{spawned} // 0, 1, "$alias $mode: command actually crossed the fork worker");
            my @reply = map {$_->[1]} @{$bot->{out}};
            if ($mode eq 'search') {
                like(shift @reply, qr/\[DansTonChat : 15924\]/, "$alias $mode: search heading stays separate");
            }
            is_deeply(\@reply, $auto, "$alias $mode: complete ten-line response matches automatic quote");
            is(scalar @reply, 10, "$alias $mode: no worker cap recuts the quote");
            ok(!grep({$_->[0] ne '#test'} @{$bot->{out}}), "$alias $mode: all reply lines use requesting channel");
        }
    }
}

# Ordinary rejection/cooldown semantics must not change with the larger batch.
my @partial; my $now = 1000;
my $sender = Mediabot::Spark::Sender->new(clock => sub {$now},
    send_cb => sub {push @partial, $_[1]; return @partial < 6});
$sender->arm;
my %request = (channel => '#test', kind => 'dtc', generation => 1,
    generated => {action => 'ready', kind => 'dtc', content => {id => 15924,
        text => join("\n", map {"dialogue $_"} 1..20)}},
    state_cb => sub {return {enabled => 1, runtime_active => 1, irc_connected => 1,
        channel_joined => 1, current_generation => 1}});
is($sender->attempt_send(%request)->{reason}, 'partial_delivery', 'transport refusal stops the longer batch');
is(scalar @partial, 6, 'no later dialogue or URL bypasses refused transport');
is($sender->attempt_send(%request)->{reason}, 'rate_limited', 'partial quote retains channel rate limit');
is(scalar @partial, 6, 'immediate retry cannot repeat the visible command');

done_testing;
