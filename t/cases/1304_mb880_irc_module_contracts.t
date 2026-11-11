use strict;
use warnings;
use utf8;
use Test::More;
use Encode qw(encode);
use Scalar::Util qw(refaddr);
use IPC::Open3;
use Symbol qw(gensym);
use Mediabot::IRC::Target qw(is_channel);
use Mediabot::IRC::Text qw(decode_irc_text redact_service_secret sanitize_line);
use Mediabot::IRC::CaseMapping qw(fold_irc);
use Mediabot::IRC::Presentation qw(format_reply);
use Mediabot::Helpers ();
use Mediabot::Context ();
use Mediabot::AI::IRCOutput ();
use Mediabot::AI::ConversationExclusion ();
use Mediabot::AI::ConversationRoom ();
use Mediabot::AI::ConversationRuntimeState ();
use Mediabot::Hailo::Normalizer ();
use Mediabot::AI::MetaPolicy ();
use Mediabot::Radio::Public ();
use Mediabot::XAuth ();
use Mediabot::Fullop ();

for my $module (qw(IRC::Target IRC::Text IRC::CaseMapping IRC::Presentation
    IRC::PacedOutput IRC::OutputPolicy Channel::FloodRules)) {
    my $err = gensym;
    my $code = "require Mediabot::$module;" . q{
        die 'runtime dependency' if $INC{'Mediabot/Helpers.pm'} || $INC{'Mediabot/External/Claude.pm'}
            || $INC{'Mediabot/AI/Client.pm'} || $INC{'Mediabot/AI/IRCOutput.pm'};
        print 'loaded';};
    my $pid = open3(undef, my $out, $err, $^X, '-I.', '-It/lib', '-we', $code);
    my $stdout = do {local $/; <$out>} // '';
    my $stderr = do {local $/; <$err>} // '';
    waitpid($pid, 0);
    is($?, 0, "$module loads independently in a fresh interpreter");
    is($stdout, 'loaded', "$module has no bot or provider dependency at load time");
    is($stderr, '', "$module loads without diagnostics");
}
for my $order (
    [qw(Helpers External::Claude AI::IRCOutput IRC::PacedOutput IRC::Presentation)],
    [qw(IRC::Presentation IRC::Text IRC::Target IRC::CaseMapping IRC::PacedOutput Helpers External::Claude)],
    [qw(External::Claude AI::IRCOutput Helpers IRC::PacedOutput)],
) {
    my $code = join('', map {"require Mediabot::$_;\n"} @$order) . q{
        die 'missing facade' unless defined &Mediabot::Helpers::queueBotNotices
            && defined &Mediabot::External::Claude::_queue_irc_chunks
            && defined &Mediabot::AI::IRCOutput::format_ai_reply;
        print 'loaded';};
    my $err = gensym;
    my $pid = open3(undef, my $out, $err, $^X, '-I.', '-It/lib', '-we', $code);
    my $stdout = do {local $/; <$out>} // '';
    my $stderr = do {local $/; <$err>} // '';
    waitpid($pid, 0);
    is($?, 0, 'legacy and new modules load in either order');
    is($stdout, 'loaded', 'all compatibility entry points are present');
    is($stderr, '', 'loading order produces no circular-load or redefinition diagnostics');
}
for my $target (undef, '', '0', 'Te[u]K', '#test', '&local', '!safe', '+modeless', '#') {
    my $expected = defined($target) && $target =~ /^[#&!+]/ ? 1 : 0;
    is(is_channel($target), $expected, 'classification retains the prefix-only contract');
    is(Mediabot::Helpers::isIrcChannelTarget($target), $expected, 'Helpers preserves channel classification');
    is(Mediabot::Context->new(channel => $target)->is_private ? 1 : 0, !$expected ? 1 : 0,
        'Context retains channel/private routing');
}
for my $row (
    ['ascii', '[a]\\^'], ['strict-rfc1459', '{a}|^'], ['rfc1459', '{a}|~'],
    ['unknown', '[a]\\^'], ['RFC1459', '[a]\\^'],
) {
    is(fold_irc('[A]\\^', $row->[0]), $row->[1], 'network mapping preserves distinct ASCII/strict/RFC equivalences');
    is(Mediabot::Fullop::_fold({casemapping => $row->[0]}, '[A]\\^'), $row->[1], 'Fullop retains its selected mapping');
}
is(fold_irc('[A]\\^'), '{a}|~', 'explicit default is historical RFC1459 folding');
is(fold_irc('0'), '0', 'folding preserves a valid scalar zero');
for my $fn (\&Mediabot::AI::ConversationExclusion::_irc_fold,
    \&Mediabot::AI::ConversationRoom::_fold, \&Mediabot::Hailo::Normalizer::_irc_fold,
    \&Mediabot::AI::MetaPolicy::fold, \&Mediabot::Radio::Public::fold, \&Mediabot::XAuth::_fold) {
    is($fn->('[A]\\^'), '{a}|~', 'existing RFC1459 consumer uses the same equivalence classes');
}
ok(!defined Mediabot::AI::ConversationExclusion::_irc_fold(undef), 'exclusion keeps its undef policy');
is(Mediabot::Hailo::Normalizer::_irc_fold(undef), '', 'Hailo keeps its empty-string policy');
is(Mediabot::XAuth::_fold([]), '', 'XAuth keeps its reference guard');
my $runtime = Mediabot::AI::ConversationRuntimeState->new;
is($runtime->_channel_key('#[A]^'), '#[a]^', 'conversation runtime starts conservatively in ASCII mode');
$runtime->{casemapping} = 'strict-rfc1459';
is($runtime->_channel_key('#[A]^'), '#{a}^', 'strict mode keeps caret distinct');
$runtime->{casemapping} = 'rfc1459';
is($runtime->_channel_key('#[A]^'), '#{a}~', 'RFC mode folds caret as before');

for my $text (undef, '', '0', 'é🙂', encode('UTF-8', 'é🙂'), "legacy:\xff", "one\r\ntwo\0tail") {
    my $original = $text;
    is_deeply(Mediabot::Helpers::decode_irc_text($text), decode_irc_text($text), 'legacy and owner inbound decoding agree');
    is($text, $original, 'decoding does not consume the input scalar');
    is(Mediabot::Helpers::_sanitize_irc_text($text), sanitize_line($text), 'line sanitation remains shared');
}
my $raw = "legacy:\xff";
is(decode_irc_text($raw), $raw, 'invalid legacy bytes remain unchanged');
ok(!utf8::is_utf8(decode_irc_text($raw)), 'invalid bytes keep their representation');
ok(utf8::is_utf8(decode_irc_text('ASCII')), 'ASCII inbound decoding retains its character-string flag');
my $ref = [];
is(refaddr(decode_irc_text($ref)), refaddr($ref), 'defensive reference pass-through is preserved');
for my $row (
    ['identify secret', 'identify ****'], ['identify account secret', 'identify account ****'],
    ['login account secret', 'login account ****'], ['SET password secret', 'SET password ****'],
    ['ordinary text', 'ordinary text'], ['0', '0'],
) {
    is(redact_service_secret($row->[0]), $row->[1], 'private service diagnostics retain their masking rules');
    is(Mediabot::Helpers::_redact_irc_service_secret_for_log($row->[0]), $row->[1], 'legacy redaction reaches the shared owner');
}

for my $name (qw(format_ai_reply _wire_bytes _decode_entity _markdown_to_irc _style_after
    _balanced_line _plain_suffix)) {
    no strict 'refs';
    is(refaddr(\&{"Mediabot::AI::IRCOutput::$name"}), refaddr(\&{"Mediabot::IRC::Presentation::$name"}),
        "$name retains one implementation behind the AI compatibility facade");
}
for my $name (qw(IRC_BOLD IRC_RESET IRC_ITALIC IRC_UNDERLINE MAX_IRC_LINES MAX_IRC_BYTES)) {
    no strict 'refs';
    is(&{"Mediabot::AI::IRCOutput::$name"}(), &{"Mediabot::IRC::Presentation::$name"}(),
        "$name retains its value through the compatibility facade");
}
for my $answer ('**Bold** and *italic*.', '# Heading' . "\n- item", 'Été 🙂 ' x 150,
    "hello\r\nworld\0tail", '[source](https://example.org/news)', '') {
    for my $limit (120, 400) {
        my $lines = format_reply($answer, wrap_bytes => $limit);
        is_deeply($lines, Mediabot::AI::IRCOutput::format_ai_reply($answer, wrap_bytes => $limit),
            'generic Markdown rendering preserves the AI facade output');
        cmp_ok(scalar @$lines, '<=', 2, 'compact renderer keeps its two-line maximum');
        ok(!grep({length(encode('UTF-8', $_)) > $limit} @$lines), 'style and suffix bytes remain within the limit');
    }
}
# MB1209: native facade keeps optional cost and callback arguments intact.
{
    require Mediabot::IRC::OutputPolicy;
    no warnings 'redefine';
    my @calls;
    local *Mediabot::Helpers::_af_conf_int = sub {push @calls, ['config', @_]; 17};
    local *Mediabot::Helpers::botPrivmsg = sub {push @calls, ['reply', @_]; 'sent'};
    local *Mediabot::Helpers::noticeConsoleChan = sub {push @calls, ['console', @_]; 'logged'};
    local *Mediabot::IRC::OutputPolicy::checkAntiFlood = sub {
        my ($bot,$channel,$cost,$hooks) = @_;
        is($channel,'#policy','native facade forwards channel');
        is($cost,$bot->{cost},'native facade forwards optional line cost');
        cmp_ok(abs($hooks->{clock}->()-time()),'<=',1,'native facade supplies wall clock');
        is($hooks->{config_int}->($bot,'key',60,5,100),17,'configuration result is preserved');
        is($hooks->{reply}->($bot,$channel,'text'),'sent','reply result is preserved');
        is($hooks->{console}->($bot,'notice'),'logged','console result is preserved');
        return 1;
    };
    for my $args ([],[3]) {
        my $bot={cost=>$args->[0]}; @calls=();
        is(Mediabot::Helpers::checkAntiFlood($bot,'#policy',@$args),1,'admission result is preserved');
        is_deeply(\@calls,[['config',$bot,'key',60,5,100],['reply',$bot,'#policy','text'],
                           ['console',$bot,'notice']], 'native callbacks preserve arguments and order');
    }
    local *Mediabot::IRC::OutputPolicy::checkAntiFlood = sub {die "policy exception\n"};
    eval {Mediabot::Helpers::checkAntiFlood({},'#policy')};
    is($@,"policy exception\n",'facade does not swallow policy exceptions');
}
done_testing;
