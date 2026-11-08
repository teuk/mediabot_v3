use strict;
use warnings;
use utf8;
use Test::More;
use Encode qw(encode);
use Mediabot::IRC::Presentation qw(format_reply _markdown_to_irc);
use Mediabot::AI::IRCOutput qw(format_ai_reply);
my @cases = (
    ['`**literal**`', '**literal**'],
    ['`*literal*`', '*literal*'],
    ['`__literal__`', '__literal__'],
    ['`++literal++`', '++literal++'],
    ['`~~literal~~`', '~~literal~~'],
    ['`<b>literal</b>`', '<b>literal</b>'],
    ['`&amp;`', '&amp;'],
    ['`[label](https://example.org)`', '[label](https://example.org)'],
    [q{`\*literal\*`}, q{\*literal\*}],
    ['`# heading`', '# heading'],
    ['`- item`', '- item'],
    ['``a `tick` b``', 'a `tick` b'],
    ['```**é**```', '**é**'],
    ['Before `**code**` and **bold**', "Before **code** and \x02bold\x02"],
    ['`one` and `two`', 'one and two'],
    ["```perl\nplain text\n```", 'plain text'],
    ['`&#2;literal`', '&#2;literal'],
    ['**bold** `*code*` *italic*', "\x02bold\x02 *code* \x1ditalic\x1d"],
    [q{\`escaped\` **bold**}, "`escaped` \x02bold\x02"],
);
for my $case (@cases) {
    my ($raw,$want)=@$case;
    is(_markdown_to_irc($raw),$want,'inline code keeps its literal content');
    is_deeply(format_reply($raw),[$want],'shared renderer retains literal code');
    is_deeply(format_ai_reply($raw),[$want],'AI facade agrees');
}
my $raw = '`**é** 🔥` ' x 150;
for my $limit (120,400) {
    my $lines = format_reply($raw,wrap_bytes=>$limit);
    is(scalar @$lines,2,'long literal code respects line cap');
    ok(!grep(length(encode('UTF-8',$_))>$limit,@$lines),'literal code respects byte budget');
    ok(!grep(/[\x02\x1d\x1f]/,@$lines),'code markers never become IRC styles');
    like($lines->[-1],qr/ …\z/,'truncation suffix retained');
}
is(_markdown_to_irc("`\x0304red\x00`"),'red','code does not bypass input control stripping');
done_testing;
