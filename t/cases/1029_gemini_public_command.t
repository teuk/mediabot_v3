# Public !gemini caller contract: strict opt-in, bounds and explicit provider.

use strict;
use warnings;
use utf8;
use JSON::PP ();
use Encode ();
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

# MB917: a separate interpreter retains real IO::Async pacing and runtime
# generations. Only the provider, configuration lookup and terminal sends are
# substituted; no API, SQL server or IRC connection is contacted.
my $native_probe = <<'MB917_NATIVE';
use strict;
use warnings;
use utf8;
use JSON::PP;
use IO::Async::Loop;
use Time::HiRes qw(time);
use Mediabot::External::Gemini ();
use Mediabot::IRC::PacedOutput qw(queue_privmsg_chunks);
use Mediabot::AI::ConversationRuntimeState;
{
    package MB917::Conf;
    sub get { $_[0]{$_[1]} }
    package MB917::Logger;
    sub log { push @{$_[0]{entries}}, [$_[1], $_[2]]; 1 }
    package MB917::IRC;
    sub is_connected { $_[0]{connected} }
    package MB917::Bot;
    sub getLoop { $_[0]{loop} }
    sub getQuit { $_[0]{quit} }
    package MB917::Client;
    sub submit { my ($self, $request, %opts) = @_; $self->{done} = $opts{on_done}; 1 }
}
sub runtime {
    my $r = Mediabot::AI::ConversationRuntimeState->new;
    $r->mark_connected; $r->mark_joined('#test'); return $r;
}
sub bot {
    return bless {
        conf => bless({'gemini.API_KEY' => 'fixture-only', 'gemini.SLEEP_US' => 20_000, 'gemini.WRAP_BYTES' => 120}, 'MB917::Conf'),
        logger => bless({entries => []}, 'MB917::Logger'),
        client => bless({}, 'MB917::Client'),
        loop => IO::Async::Loop->really_new,
        irc => bless({connected => 1}, 'MB917::IRC'),
        wit_runtime_state => runtime(), enabled => 1, wire => [],
    }, 'MB917::Bot';
}
sub timers { scalar grep { $_->isa('IO::Async::Timer::Countdown') } $_[0]{loop}->notifiers }
sub drain {
    my ($b) = @_;
    my $until = time() + 1;
    while (timers($b) && time() < $until) { $b->{loop}->loop_once(0.01) }
}
sub change {
    my ($b, $kind) = @_;
    if ($kind eq 'replace') { $b->{irc} = bless({connected => 1}, 'MB917::IRC') }
    elsif ($kind eq 'disconnect') { $b->{irc}{connected} = 0 }
    elsif ($kind eq 'quit') { $b->{quit} = 1 }
    elsif ($kind eq 'left') { $b->{wit_runtime_state}->mark_left('#test') }
    elsif ($kind eq 'rejoin') { $b->{wit_runtime_state}->mark_left('#test'); $b->{wit_runtime_state}->mark_joined('#test') }
    elsif ($kind eq 'reconnect') { $b->{wit_runtime_state}->mark_disconnected; $b->{wit_runtime_state}->mark_connected; $b->{wit_runtime_state}->mark_joined('#test') }
    elsif ($kind eq 'shutdown') { $b->{wit_runtime_state}->mark_shutdown }
    elsif ($kind eq 'state_replaced') { $b->{wit_runtime_state} = runtime() }
    elsif ($kind eq 'casemapping') { $b->{wit_runtime_state}->update_isupport('CASEMAPPING=rfc1459') }
    elsif ($kind eq 'disabled') { $b->{enabled} = 0 }
    elsif ($kind eq 'lookup_error') { $b->{lookup_error} = 1 }
}
sub launch { Mediabot::External::Gemini::geminiAI($_[0], undef, $_[1] // 'Alice', '#test', 'hello') }
sub result {
    my ($kind) = @_;
    return {ok => 0, provider => 'gemini', status => 503} if $kind eq 'error';
    return {ok => 1, provider => 'gemini', answer => $kind eq 'empty' ? '' : 'Björk 🙂 ' . ('alpha ' x 24)};
}
sub finish {
    my ($b) = @_;
    drain($b);
    return {wire => $b->{wire}, free => !keys(%{$b->{_gemini_inflight} // {}}) ? 1 : 0,
        clean => !keys(%{$b->{_external_ai_output_queues} // {}}) && !timers($b) ? 1 : 0};
}
no warnings qw(redefine once);
local *Mediabot::External::getIdChansetList = sub { 31 };
local *Mediabot::External::getIdChannelSet = sub { die 'lookup failed' if $_[0]{lookup_error}; $_[0]{enabled} ? 999 : undef };
local *Mediabot::External::Gemini::_client = sub { $_[0]{client} };
local *Mediabot::IRC::Output::privmsg = sub {
    my ($b, $target, $text) = @_;
    push @{$b->{wire}}, [$target, $text];
    $b->{after_send}->($b) if $b->{after_send}; return 1;
};
local *Mediabot::Helpers::botPrivmsg = sub { push @{$_[0]{wire}}, [$_[1], $_[2]]; 1 };
local *Mediabot::Helpers::botNotice = sub { push @{$_[0]{wire}}, [$_[1], $_[2]]; 1 };
my %out;
for my $kind (qw(success error empty)) {
    my $b = bot(); launch($b); $b->{client}{done}->(result($kind));
    $b->{client}{done}->(result($kind)); # retained duplicate completion is inert
    $out{healthy}{$kind} = finish($b);
    for my $change (qw(replace disconnect quit left rejoin reconnect shutdown state_replaced casemapping disabled lookup_error)) {
        my $b = bot(); launch($b); change($b, $change); $b->{client}{done}->(result($kind));
        $out{pending}{$kind}{$change} = finish($b);
    }
}
for my $change (qw(replace disconnect quit left rejoin reconnect shutdown state_replaced casemapping disabled lookup_error)) {
    my $b = bot(); launch($b); $b->{client}{done}->(result('success'));
    change($b, $change);
    queue_privmsg_chunks($b, '#test', ['unrelated'], 0, 'other');
    $out{paced}{$change} = finish($b);
}
{
    my $b = bot(); launch($b); $b->{client}{done}->(result('success'));
    change($b, 'rejoin'); launch($b, 'Bob');
    $b->{client}{done}->({ok => 1, provider => 'gemini', answer => 'fresh answer'});
    $out{successor} = finish($b);
}
for my $mode (qw(noloop zerodelay)) {
    my $b = bot(); $b->{conf}{'gemini.SLEEP_US'} = 0;
    # Drop the loop only after async submission to exercise the immediate queue fallback.
    launch($b); delete $b->{loop} if $mode eq 'noloop';
    $b->{after_send} = sub { $_[0]{enabled} = 0 };
    $b->{client}{done}->(result('success'));
    $b->{loop} ||= IO::Async::Loop->really_new;
    $out{immediate}{$mode} = finish($b);
}
for my $mode (qw(false throws)) {
    my $b = bot(); my $calls = 0;
    queue_privmsg_chunks($b, '#test', [qw(guarded1 guarded2)], 20_000, 'guarded', {can_send => sub { ++$calls == 1 ? 1 : $mode eq 'throws' ? die('guard failed') : 0 }});
    queue_privmsg_chunks($b, '#test', ['successor'], 0, 'other');
    $out{guard}{$mode} = finish($b);
}
print JSON::PP->new->utf8->canonical->encode(\%out);
MB917_NATIVE
open my $native, '-|', $^X, '-I.', '-It/lib', '-e', Encode::encode('UTF-8', $native_probe)
    or die "start Gemini lifecycle probe: $!";
my $native_json = do { local $/; <$native> };
close $native;
is($? >> 8, 0, 'Gemini native lifecycle probe completes');
my $observed = JSON::PP::decode_json($native_json);
my $first = 'Björk 🙂 ' . join(' ', ('alpha') x 17);
my $second = join(' ', ('alpha') x 7);
is_deeply($observed->{healthy}, {
    success => {wire => [['#test', $first], ['#test', $second]], free => 1, clean => 1},
    error => {wire => [['#test', '(Alice) Gemini service error; retry shortly.']], free => 1, clean => 1},
    empty => {wire => [['#test', '(Alice) Could not read Gemini response.']], free => 1, clean => 1},
}, 'current requests retain Unicode, pacing, error messages and single completion');
for my $kind (qw(success error empty)) {
    is_deeply($observed->{pending}{$kind}, {
        map { $_ => {wire => [], free => 1, clean => 1} }
            qw(replace disconnect quit left rejoin reconnect shutdown state_replaced casemapping disabled lookup_error)
    }, "pending $kind: stale or revoked results stay silent and release their slot");
}
is_deeply($observed->{paced}, {
    map { $_ => {wire => [['#test', $first], ['#test', 'unrelated']], free => 1, clean => 1} }
        qw(replace disconnect quit left rejoin reconnect shutdown state_replaced casemapping disabled lookup_error)
}, 'revocation between native expiries drops only the old Gemini tail');
is_deeply($observed->{successor}, {
    wire => [['#test', $first], ['#test', 'fresh answer']], free => 1, clean => 1,
}, 'a newly authorized Gemini reply survives behind an obsolete paced batch');
is_deeply($observed->{immediate}, {
    map { $_ => {wire => [['#test', $first]], free => 1, clean => 1} } qw(noloop zerodelay)
}, 'immediate fallbacks also check authorization between chunks');
is_deeply($observed->{guard}, {
    map { $_ => {wire => [['#test', 'guarded1'], ['#test', 'successor']], free => 1, clean => 1} } qw(false throws)
}, 'false or throwing batch guards preserve an unguarded successor and release timers');

done_testing();
