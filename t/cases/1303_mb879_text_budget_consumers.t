use strict;
use warnings;
use utf8;
use Test::More;
use Encode qw(encode);
use Scalar::Util qw(refaddr);
use Mediabot::IRC::TextBudget ();
use Mediabot::AI::IRCOutput ();
use Mediabot::AI::MetaReply ();
use Mediabot::AI::MetaRuntime ();
use Mediabot::External::Claude ();
use Mediabot::External::Horoscope ();
use Mediabot::External::News ();
use Mediabot::External::NewsBulletin ();
use Mediabot::PluginContext ();
use Mediabot::RSS ();
use Mediabot::RSS::Runtime ();
use Mediabot::RandomQuote::Runtime ();
use Mediabot::UserCommands ();
use Mediabot::VDM ();

for my $consumer (qw(AI::MetaReply AI::MetaRuntime External::Horoscope External::News
    External::NewsBulletin PluginContext RSS RSS::Runtime RandomQuote::Runtime UserCommands VDM)) {
    no strict 'refs';
    is(refaddr(\&{"Mediabot::${consumer}::_utf8_text_bytes"}),
        refaddr(\&Mediabot::IRC::TextBudget::_utf8_text_bytes),
        "$consumer uses the shared character counter");
}
my $latin = chr(0xe9);
utf8::downgrade($latin);
is(Mediabot::UserCommands::_irc_bytes($latin), 2,
    'leaderboard keeps its character policy even for downgraded Latin-1');
is(Mediabot::External::News::_utf8_bytes($latin), 2,
    'news keeps character semantics rather than treating Latin-1 as raw wire bytes');
is(Mediabot::AI::IRCOutput::_wire_bytes(encode('UTF-8', 'é🙂')), 6,
    'AI renderer still treats already encoded output as wire bytes');

my $family = '👩‍👩‍👧‍👦';
is(Mediabot::External::Horoscope::cap_text($family x 3, 30), "$family…",
    'horoscope retains whole graphemes and its ellipsis');
is(Mediabot::External::Horoscope::cap_text('Hello world', 10), 'Hello…',
    'horoscope retains its word-boundary preference');
is(Mediabot::External::Horoscope::cap_text('abcd', 3), '',
    'horoscope retains its tiny-budget policy');
is(Mediabot::External::News::_cap_bytes('Hello world', 10), 'Hello w…',
    'news retains its distinct codepoint truncation policy');
is(Mediabot::External::News::_cap_bytes('abcd', 2), '…',
    'news retains its historical tiny-budget fallback');

for my $text ('short', 'é' x 200, '🙂' x 100, $latin x 200) {
    is(Mediabot::PluginContext::_text($text), $text,
        'plugin accepts exactly its existing 400 encoded-byte boundary');
    my $error = eval {Mediabot::PluginContext::_text($text . ('x' x 400)); ''} || $@;
    like($error, qr/exceeds 400 bytes/, 'plugin still rejects oversized output instead of truncating it');
}
for my $answer ('**A styled answer** and a short continuation.', ('Été 🙂 with words. ' x 100)) {
    my $lines = Mediabot::AI::IRCOutput::format_ai_reply($answer);
    cmp_ok(scalar @$lines, '<=', 2, 'AI rendering retains the two-line policy');
    ok(!grep({length(encode('UTF-8', $_)) > 400} @$lines), 'AI styles and suffix stay within the payload budget');
    unlike(join('', @$lines), qr/\*\*/, 'AI rendering still consumes Markdown emphasis');
    my $meta = Mediabot::AI::MetaReply::format_meta_reply($answer);
    cmp_ok(scalar @$meta, '<=', 2, 'meta reply retains its two-line policy');
    ok(!grep({length(encode('UTF-8', $_)) > 400} @$meta), 'meta reply balancing preserves byte bounds');
}

my $url = 'https://example.org/article';
for my $limit (120, 200, 400) {
    my $line = Mediabot::RSS::format_rss_announcement(
        label => 'Résumé', title => 'Une nouvelle été 🙂 ' x 30, url => $url, max_bytes => $limit);
    ok(defined $line, 'RSS still fits by reducing title/label');
    cmp_ok(length(encode('UTF-8', $line)), '<=', $limit, 'RSS retains the caller byte budget');
    like($line, qr/\Q$url\E/, 'RSS never clips the article URL');
    like($line, qr/\A\001ACTION .*\001\z/, 'RSS retains its ACTION formatting');
}
ok(!defined Mediabot::RSS::format_rss_announcement(
    label => 'RSS', title => 'Title', url => $url, max_bytes => 10),
    'RSS still refuses a line whose URL cannot fit');
ok(defined Mediabot::VDM::format_vdm_line(id => 12, story => 'Une journée normale. VDM'),
    'VDM still accepts a complete short story');
ok(!defined Mediabot::VDM::format_vdm_line(id => 12, story => ('🙂' x 100) . ' VDM'),
    'VDM still refuses oversized stories instead of truncating them');
done_testing;
