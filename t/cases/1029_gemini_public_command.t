# Public !gemini caller contract: strict opt-in, bounds and explicit provider.

use strict;
use warnings;
use Test::More;
BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";

    # This contract is PURE and exercises only Gemini caller policy. Avoid
    # loading the complete IRC helper dependency graph in minimal test images.
    package Mediabot::Helpers;
    sub botNotice { 1 }
    sub botPrivmsg { 1 }
    sub _split_text_for_irc { return ($_[0]) }
    $INC{'Mediabot/Helpers.pm'} = __FILE__;

    package Mediabot::External::Claude;
    sub _queue_irc_chunks { return scalar @{ $_[2] || [] } }
    $INC{'Mediabot/External/Claude.pm'} = __FILE__;
}

use Mediabot::External::Gemini ();

{
    package Gemini1029::Conf;
    sub new { my ($class, %kv) = @_; bless \%kv, $class }
    sub get { $_[0]{ $_[1] } }
}

{
    package Gemini1029::Logger;
    sub new { bless { entries => [] }, shift }
    sub log { push @{ $_[0]{entries} }, [ $_[1], $_[2] ]; 1 }
}

{
    package Gemini1029::Metrics;
    sub new { bless { values => {} }, shift }
    sub inc { $_[0]{values}{$_[1]}++; 1 }
}

{
    package Gemini1029::Client;
    sub new { bless { seen => $_[1] }, $_[0] }
    sub execute {
        my ($self, $request) = @_;
        ${ $self->{seen} } = $request;
        return { ok => 1, provider => 'gemini', model => 'gemini-test', answer => 'Bonjour le canal' };
    }
}

sub _bot_1029 {
    my (%extra) = @_;
    return bless {
        conf => Gemini1029::Conf->new(
            'gemini.API_KEY' => 'configured-not-returned',
            %extra,
        ),
        logger  => Gemini1029::Logger->new,
        metrics => Gemini1029::Metrics->new,
    }, 'Gemini1029::Bot';
}

my $src = do {
        open my $fh, '<:encoding(UTF-8)', 'Mediabot/External/Gemini.pm' or die $!;
        local $/; <$fh>;
};
like($src, qr/build_request\(.*?provider\s*=>\s*'gemini'/s,
        '!gemini builds an explicitly Gemini request');
unlike($src, qr/(?:API_KEY|api_key)\s*=>/,
        'public caller never places credentials in request/client overrides');
like($src, qr/Mediabot::AI::Transport::usable_loop/,
        'production command detects the asynchronous boundary');
like($src, qr/\$client->submit\(/,
        'production command submits provider work asynchronously');
like($src, qr/_strict_chanset_enabled/,
        'public command uses a strict Gemini chanset gate');

    my (@notice, @privmsg, $request, $client_calls);
    no warnings 'redefine';
    local *Mediabot::Helpers::botNotice = sub {
        push @notice, $_[2]; return 1;
    };
    local *Mediabot::Helpers::botPrivmsg = sub {
        push @privmsg, $_[2]; return 1;
    };
    local *Mediabot::External::Claude::_queue_irc_chunks = sub {
        my ($self, $target, $chunks) = @_;
        push @privmsg, @$chunks;
        return scalar @$chunks;
    };
    local *Mediabot::External::getIdChansetList = sub {
        $client_calls->{list}++ if ref($client_calls) eq 'HASH';
        return 31;
    };
    local *Mediabot::External::getIdChannelSet = sub { return 999 };
    local *Mediabot::External::Gemini::_client = sub {
        $client_calls->{client}++;
        return Gemini1029::Client->new(\$request);
    };

    $client_calls = {};
    my $bot = _bot_1029();
    my $answer = Mediabot::External::Gemini::geminiAI(
        $bot, undef, 'Alice', '#test', 'bonjour', 'Gemini'
    );
is($answer, 'Bonjour le canal',
        'successful Gemini answer reaches IRC delivery');
is($request->{provider}, 'gemini',
        'runtime request stays explicitly Gemini');
is($request->{messages}[0]{content}, 'bonjour Gemini',
        'prompt words are preserved');
is($request->{max_output_tokens}, 1024,
        'default IRC budget leaves room for Gemini thinking and visible text');
is($bot->{metrics}{values}{mediabot_gemini_requests_total}, 1,
        'successful launch increments aggregate request metric');
is(join('|', @privmsg), 'Bonjour le canal',
        'answer is delivered without exposing request metadata');

    @privmsg = (); $request = undef; $client_calls = {};
    local *Mediabot::External::getIdChansetList = sub { return undef };
    my $closed = Mediabot::External::Gemini::geminiAI(
        _bot_1029(), undef, 'Alice', '#closed', 'do', 'not', 'send'
    );
ok(!defined($closed), 'missing Gemini chanset fails closed');
is($client_calls->{client} // 0, 0,
        'closed channel performs no provider call');
is(scalar(@notice), 0,
        'closed channel emits no command or configuration notice');

    @notice = (); $client_calls = {};
    my $closed_unconfigured = Mediabot::External::Gemini::geminiAI(
        _bot_1029('gemini.API_KEY' => ''), undef, 'Alice', '#closed'
    );
ok(!defined($closed_unconfigured),
        'closed channel stays silent before configuration and syntax checks');
is(scalar(@notice), 0,
        'closed channel does not disclose missing Gemini configuration');

    @notice = ();
    local *Mediabot::External::getIdChansetList = sub { return 31 };
    my $missing = _bot_1029('gemini.API_KEY' => '');
    Mediabot::External::Gemini::geminiAI(
        $missing, undef, 'Alice', '#test', 'ping'
    );
like(join(' ', @notice), qr/not configured.*gemini\.API_KEY/i,
        'missing key produces a useful private notice without key value');

    @notice = (); $request = undef; $client_calls = {};
    local *Mediabot::External::getIdChansetList = sub { return 31 };
    my $bounded = _bot_1029('gemini.MAX_PROMPT_CHARS' => 256);
    Mediabot::External::Gemini::geminiAI(
        $bounded, undef, 'Alice', '#test', ('x' x 257)
    );
like(join(' ', @notice), qr/prompt too long/i,
        'oversized prompt is rejected before provider work');
is($client_calls->{client} // 0, 0,
        'oversized prompt performs no provider call');

done_testing();
