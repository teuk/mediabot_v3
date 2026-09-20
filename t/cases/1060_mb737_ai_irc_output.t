# MB737: OpenAI, Claude and Gemini share one compact Markdown-to-IRC charter.

use strict;
use warnings;
use utf8;
use Test::More;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";

    # Keep this test PURE. The production helper already has its own byte-split
    # regression suite; this faithful stub isolates the new presentation layer.
    package Mediabot::Helpers;
    use Encode qw(encode);

    sub _wire_bytes_1060 {
        return utf8::is_utf8($_[0])
            ? length(encode('UTF-8', $_[0]))
            : length($_[0]);
    }

    sub _split_text_for_irc {
        my ($text, $max) = @_;
        return () unless defined($text) && length($text);
        return ($text) if _wire_bytes_1060($text) <= $max;

        my @chunks;
        my $buffer = $text;
        while (_wire_bytes_1060($buffer) > $max) {
            my ($bytes, $chars) = (0, 0);
            for my $char (split //, $buffer) {
                my $cost = _wire_bytes_1060($char);
                last if $bytes + $cost > $max;
                $bytes += $cost;
                $chars++;
            }
            $chars = 1 if $chars < 1;
            my $prefix = substr($buffer, 0, $chars);
            if ($prefix =~ /^(.*\s)\S+\z/s) {
                my $word = $1;
                $prefix = $word
                    if length($word) >= int($chars / 2) && length($word);
            }
            my $cut = length($prefix) || $chars;
            push @chunks, substr($buffer, 0, $cut);
            $buffer = substr($buffer, $cut);
            $buffer =~ s/^\s+//;
        }
        push @chunks, $buffer if length($buffer);
        return @chunks;
    }

    $INC{'Mediabot/Helpers.pm'} = __FILE__;
}

use Encode qw(encode);
use Mediabot::AI::IRCOutput qw(
    format_ai_reply
    with_irc_output_instruction
);

sub _bytes_1060 {
    return length(encode('UTF-8', $_[0]));
}

sub _slurp_1060 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

my $markdown = <<'MARKDOWN';
# Résultat

**Important**, *rapide* et <u>souligné</u>.
- Premier point
- [Documentation](https://example.org/doc)
MARKDOWN

my $styled = format_ai_reply($markdown, max_lines => 8, wrap_bytes => 450);
ok(ref($styled) eq 'ARRAY', 'renderer returns an array reference');
is(scalar(@$styled), 1, 'short multiline Markdown is compacted onto one IRC line');
like($styled->[0], qr/\x02\x1fRésultat\x1f\x02/,
    'heading becomes bold underlined IRC text');
like($styled->[0], qr/\x02Important\x02/,
    'Markdown bold becomes IRC bold');
like($styled->[0], qr/\x1drapide\x1d/,
    'Markdown italic becomes IRC italic');
like($styled->[0], qr/\x1fsouligné\x1f/,
    'HTML underline becomes IRC underline');
like($styled->[0], qr/Documentation <https:\/\/example[.]org\/doc>/,
    'Markdown link keeps readable label and destination');
unlike($styled->[0], qr/(?:\*\*|<u>|<\/u>|```|^#|\]\()/,
    'Markdown scaffolding does not leak to IRC');

my $long = format_ai_reply(
    '**' . join(' ', ('éclair 😀') x 180) . '**',
    max_lines => 9,
    wrap_bytes => 999,
);
is(scalar(@$long), 2, 'legacy high limits are hard-clamped to two IRC lines');
ok(!grep({ _bytes_1060($_) > 400 } @$long),
    'every UTF-8 line respects the real 400-byte botPrivmsg budget');
like($long->[-1], qr/ …\z/, 'truncated answer ends with a compact plain ellipsis');
like($long->[0], qr/^\x02/, 'first continued bold line opens IRC bold');
like($long->[0], qr/\x0f\z/, 'first continued bold line closes formatting');
like($long->[1], qr/^\x02/, 'second continued bold line reopens formatting');
like($long->[1], qr/\x0f …\z/, 'last line resets style before truncation suffix');

my $unsafe = format_ai_reply("\x0304,02red\x16 reverse \x11mono", max_lines => 2);
is(scalar(@$unsafe), 1, 'unsafe provider controls still produce one reply');
unlike($unsafe->[0], qr/[\x03\x11\x16]/,
    'colour, monospace and reverse controls are stripped');
unlike($unsafe->[0], qr/04,02red/, 'colour arguments are stripped with colour code');

my $instruction = with_irc_output_instruction('Custom persona.');
like($instruction, qr/^Custom persona[.]/, 'custom system prompt is preserved');
like($instruction, qr/at most two compact IRC lines/,
    'immutable compact IRC instruction is appended');
is(() = $instruction =~ /at most two compact IRC lines/g, 1,
    'IRC instruction is appended exactly once');
is(with_irc_output_instruction($instruction), $instruction,
    'adding the IRC instruction twice is idempotent');

my $legacy_instruction = with_irc_output_instruction(
    'Be useful. Always respond using a maximum of 10 lines of text and line-based. Be kind.',
);
unlike($legacy_instruction, qr/maximum of 10 lines/i,
    'legacy ten-line instruction is removed from configured prompts');
like($legacy_instruction, qr/Be useful[.] Be kind[.]/,
    'surrounding configured prompt text survives legacy cleanup');

my $main = _slurp_1060('Mediabot/Mediabot.pm');
like($main, qr/tellme\s*=>\s*sub\s*\{\s*my \(\$ctx\) = \@_;\s*chatGPT_ctx\(\$ctx\)/,
    'canonical tellme command remains wired');
like($main, qr/chatgpt\s*=>\s*sub\s*\{\s*my \(\$ctx\) = \@_;\s*chatGPT_ctx\(\$ctx\)/,
    '!chatgpt is an alias of tellme');
like($main, qr/ai\s*=>\s*sub\s*\{\s*my \(\$ctx\) = \@_;\s*claude_ctx\(\$ctx\)/,
    'canonical ai command remains wired');
like($main, qr/claude\s*=>\s*sub\s*\{\s*my \(\$ctx\) = \@_;\s*claude_ctx\(\$ctx\)/,
    '!claude is an alias of ai');
like($main, qr/gemini\s*=>\s*sub\s*\{\s*my \(\$ctx\) = \@_;\s*gemini_ctx\(\$ctx\)/,
    'canonical gemini command remains wired');

my $claude = _slurp_1060('Mediabot/External/Claude.pm');
my $gemini = _slurp_1060('Mediabot/External/Gemini.pm');
like($claude, qr/format_ai_reply\(/,
    'OpenAI and Claude delivery use the shared IRC renderer');
like($claude, qr/_claude_output_chunks\(\$p, \$pcache->\{answer\}\)/,
    'Claude cache hits use the same rendering path as fresh answers');
like($gemini, qr/format_ai_reply\(/,
    'Gemini delivery uses the shared IRC renderer');
like($claude . $gemini, qr/with_irc_output_instruction\(/,
    'provider prompts receive the compact IRC instruction');

done_testing();
