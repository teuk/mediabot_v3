use strict;
use warnings;
use utf8;
use Test::More;
use JSON::PP ();
use Mediabot::AI::ConversationRequest qw(build_wit_request);
use Mediabot::AI::QuipRequest qw(build_quip_request);
use Mediabot::AI::ConversationDecision qw(parse_model_decision decision_summary);
use Mediabot::IRC::Presentation qw(_markdown_to_irc);

my @cases = (
    ["\x03١٢ apples", '١٢ apples'],
    ["\x03１２ apples", '１２ apples'],
    ["\x03۲۳ apples", '۲۳ apples'],
    ["\x0304١٢ apples", '١٢ apples'],
    ["\x0304,١٢ apples", ',١٢ apples'],
    ["\x0304,12١٢ apples", '١٢ apples'],
    ["\x031١ apples", '١ apples'],
    ["\x0304,1١ apples", '١ apples'],
    ["\x0304red\x0f apples", 'red apples'],
    ["\x0304,12red apples", 'red apples'],
    ["\x03plain apples", 'plain apples'],
    ["\x0304123 apples", '123 apples'],
    ['١٢ apples', '١٢ apples'],
);
for my $case (@cases) {
    my ($raw, $want) = @$case;
    my $original = $raw;
    is(build_wit_request(message => $raw)->{messages}[0]{content}, $want, 'Wit preserves text after ASCII colour codes');
    my $request = build_quip_request(message => $raw, previous_reply => $raw, context => [
        {speaker => 'speaker1', text => $raw},
        {speaker => 'speaker2', text => 'Some context'},
        {speaker => 'speaker1', text => 'More context'},
    ]);
    my $data = JSON::PP->new->decode($request->{messages}[0]{content});
    is($data->{latest_message}, $want, 'Quip message preserves digits');
    is($data->{conversation}[0]{text}, $want, 'Quip context preserves digits');
    is($data->{last_bot_reply}, $want, 'Quip previous reply preserves digits');
    my $decision = parse_model_decision("REPLY: $raw");
    is($decision->{text}, $want, 'model decision preserves digits');
    is(decision_summary({action => 'reply', reason => 'model_reply', text => $raw})->{text}, $want, 'decision summary agrees');
    is(_markdown_to_irc($raw), $want, 'IRC presentation preserves digits');
    is($raw, $original, 'caller input unchanged');
}
# Numeric-only content must not disappear after a colour reset.
is(parse_model_decision("REPLY: \x03١٢")->{action}, 'reply', 'numeric-only reply remains valid');
is(eval { build_wit_request(message => "\x03١٢")->{messages}[0]{content} }, '١٢', 'numeric-only request remains valid');
done_testing;
