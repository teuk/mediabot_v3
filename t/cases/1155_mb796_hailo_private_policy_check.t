use strict;
use warnings;
use utf8;
use Test::More;
use FindBin qw($Bin);
use Encode qw(encode);

BEGIN { unshift @INC, "$Bin/../.." }
use Mediabot::Hailo::BrainInfo qw(hailo_command);

{
    package MB796::Bot;
    sub new { bless { calls => [], result => {
        ok => 1, learn => 1, reply => 1, rate_pending => 1,
        key_reply_rate => 95, learn_reason => 'allowed',
        reply_reason => 'allowed',
    } }, $_[0] }
    sub hailo_preview_turn {
        my ($self, %args) = @_;
        push @{ $self->{calls} }, \%args;
        return $self->{result};
    }
}
{
    package MB796::Context;
    sub new { bless { bot => MB796::Bot->new, args => [], nick => 'Te[u]K',
        replies => [], master => 1 }, $_[0] }
    sub require_level {
        my ($self, $level) = @_;
        return 1 if $self->{master};
        push @{ $self->{replies} }, 'Access denied';
        return 0;
    }
    sub args { $_[0]{args} }
    sub bot { $_[0]{bot} }
    sub nick { $_[0]{nick} }
    sub reply_private { push @{ $_[0]{replies} }, $_[1] }
}

my $ctx = MB796::Context->new;
$ctx->{args} = ['check', '#radiocapsule', 'mention', 'je', 'viens', 'ce', 'soir'];
$ctx->{master} = 0;
hailo_command($ctx);
is(scalar @{ $ctx->{bot}{calls} }, 0, 'non-Master cannot simulate an Hailo turn');
like($ctx->{replies}[-1], qr/Access denied/, 'access refusal remains private');

$ctx->{master} = 1;
$ctx->{replies} = [];
ok(hailo_command($ctx), 'Master can rehearse a direct reply privately');
is_deeply($ctx->{bot}{calls}[0], {
    channel => '#radiocapsule', speaker => 'Te[u]K', mode => 'mention',
    text => 'je viens ce soir',
}, 'preview uses the explicit channel and the authenticated speaker');
is(scalar @{ $ctx->{replies} }, 2, 'private report is two short notices');
like(join(' ', @{ $ctx->{replies} }), qr/sans apprentissage ni envoi.*tirage 95% restant/s,
    'report distinguishes eligibility from a real rate draw');
unlike(join(' ', @{ $ctx->{replies} }), qr/je viens ce soir|\.brn|provider_key/,
    'preview report never echoes message text, paths or provider internals');
ok(!grep(length(encode('UTF-8', $_)) > 400, @{ $ctx->{replies} }),
    'both styled notices fit the IRC byte budget');

$ctx->{bot}{result} = {
    ok => 1, learn => 0, reply => 0, learn_reason => 'bot_command',
    reply_reason => 'bot_command',
};
$ctx->{args} = ['check', '#i/o', 'ambient', '!bang'];
$ctx->{replies} = [];
ok(hailo_command($ctx), 'excluded traffic can be rehearsed without sending');
like(join(' ', @{ $ctx->{replies} }), qr/bloqué \(bot_command\).*bloquée \(bot_command\)/s,
    'exclusion is visible independently for learning and replies');

$ctx->{args} = ['check', '#i/o', 'nonsense', 'hello'];
$ctx->{replies} = [];
ok(!hailo_command($ctx), 'unknown preview mode is rejected');
is(scalar @{ $ctx->{bot}{calls} }, 2, 'invalid input never reaches preview logic');
$ctx->{args} = ['check', '#i/o', 'mention', "hello\x0aworld"];
ok(!hailo_command($ctx), 'newline input is rejected before any policy work');
is(scalar @{ $ctx->{bot}{calls} }, 2, 'malformed text never reaches preview logic');

$ctx->{args} = ['check', '#' . ('a' x 79), 'chatter', 'salut'];
$ctx->{replies} = [];
ok(hailo_command($ctx), 'longest valid channel can be checked');
ok(!grep(length(encode('UTF-8', $_)) > 400, @{ $ctx->{replies} }),
    'longest valid channel still fits both notice budgets');

done_testing;
