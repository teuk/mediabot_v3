# Exercise the IRC command, actual worker and Wiktionary response adapter
# with a local HTTP fixture, so no test depends on a live wiki.
use strict;
use warnings;
use utf8;
use Encode qw(encode);
use IO::Async::Loop;
use JSON::PP qw(encode_json);
use Time::HiRes qw(time);
use Test::More;
use Mediabot::Context;
use Mediabot::External ();
use Mediabot::IRC::TextBudget qw(_irc_wire_bytes);
use Mediabot::UserCommands ();

{
    package MB436::DefineBot;
    sub getLoop { $_[0]{loop} }
    sub botPrivmsg { push @{shift->{messages}}, ['channel', @_] }
    sub botNotice { push @{shift->{messages}}, ['notice', @_] }

    package MB436::DefineConf;
    sub get { $_[1] eq 'main.DEFINE_LANG' ? 'fr' : undef }

    package MB436::DefineHTTP;
    sub get {
        my ($self, $url) = @_;
        return {success => 0} unless $url eq $self->{url};
        return {success => 1, content => $self->{body}};
    }
}

my $loop = IO::Async::Loop->new;
my $bot = bless {loop => $loop, conf => bless({}, 'MB436::DefineConf')}, 'MB436::DefineBot';
my $invoke = sub {
    my ($channel, @args) = @_;
    $bot->{messages} = [];
    my $ctx = Mediabot::Context->new(
        bot => $bot, nick => 'Alice', channel => $channel, command => 'define', args => \@args,
    );
    Mediabot::UserCommands::mbDefine_ctx($ctx);
    return $bot->{messages};
};

my ($url, $body);
no warnings 'redefine';
local *Mediabot::External::_make_http = sub {
    return bless {url => $url, body => $body}, 'MB436::DefineHTTP';
};

$url = 'https://fr.wiktionary.org/api/rest_v1/page/definition/caf%C3%A9';
$body = encode_json({fr => [{partOfSpeech => 'nom', definitions => [
    {definition => '<b>Boisson</b> préparée avec du café.'},
]}]});
my $messages = $invoke->('#salon', encode('UTF-8', 'café'));
my $deadline = time + 3;
$loop->loop_once(0.02) while !@$messages && time < $deadline;
is_deeply($messages, [['channel', '#salon', 'café [fr] (nom): Boisson préparée avec du café.']],
    'accented wire input survives the HTTP URL and worker round trip');

$url = 'https://fr.wiktionary.org/api/rest_v1/page/definition/caf%C3%A9_cr%C3%A8me';
$body = encode_json({
    en => [{definitions => [{definition => 'Fallback'}]}],
    fr => [{partOfSpeech => 'nom', definitions => [
        {definition => '<span>&nbsp;</span>'},
        {definition => 'Café au lait&#13;&#10;ou à la crème.'},
    ]}],
});
# Mix an already-decoded argument with a raw UTF-8 argument.
$messages = $invoke->(undef, 'café', encode('UTF-8', 'crème'));
$deadline = time + 3;
$loop->loop_once(0.02) while !@$messages && time < $deadline;
is_deeply($messages, [['notice', 'Alice', 'café_crème [fr] (nom): Café au lait ou à la crème.']],
    'private lookup handles mixed inputs and skips a visually empty definition');

$url = 'https://fr.wiktionary.org/api/rest_v1/page/definition/restaurant';
$body = encode_json({
    fr => [{definitions => [{definition => '<i>&nbsp;</i>'}]}],
    en => [{definitions => [{definition => 'A caf&eacute; or restaurant.'}]}],
});
my $fallback = Mediabot::External::Wiktionary::_define_lookup_sync($bot, 'restaurant', 'fr');
my $expected = 'restaurant: A café or restaurant.';
is_deeply([$fallback, _irc_wire_bytes($fallback)], [$expected, length(encode('UTF-8', $expected))],
    'fallback uses visible text from the next edition and encodes entities for IRC');

for my $word ("caf\xc3", "foo!bar", "é" x 33, "one\ttwo") {
    $messages = $invoke->('#salon', $word);
    is_deeply($messages, [['notice', 'Alice', 'Invalid word.']],
        'invalid input is rejected before the asynchronous lookup');
}
done_testing;
