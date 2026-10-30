use strict;
use warnings;
use utf8;
use Test::More;
use Encode qw(encode);
use Mediabot::IRC::Presentation qw(format_reply);
use Mediabot::AI::IRCOutput qw(format_ai_reply);

binmode Test::More->builder->output, ':encoding(UTF-8)';
binmode Test::More->builder->failure_output, ':encoding(UTF-8)';

sub render_1401 {
    return [map { [format_reply($_),format_ai_reply($_)] } @_];
}
sub expected_1401 { return [map { [[$_],[$_]] } @_] }

is_deeply(render_1401('**A**','__C__','**é**','__é__'),
    expected_1401("\x02A\x02","\x02C\x02","\x02é\x02","\x02é\x02"),
    'single ASCII and accented characters use bold through both shared facades');
is_deeply(render_1401('*B*','_D_','*é*','_é_'),
    expected_1401("\x1dB\x1d","\x1dD\x1d","\x1dé\x1d","\x1dé\x1d"),
    'both italic spellings retain a single visible character');
is_deeply(render_1401('++E++','++🔥++'),
    expected_1401("\x1fE\x1f","\x1f🔥\x1f"),
    'single-character underline works for ASCII and emoji');
is_deeply(render_1401('A **B** C *D* E ++F++.','**A** **B**','_C_ _D_'),
    expected_1401("A \x02B\x02 C \x1dD\x1d E \x1fF\x1f.",
        "\x02A\x02 \x02B\x02","\x1dC\x1d \x1dD\x1d"),
    'short spans keep their exact style and neighboring text in a mixed sentence');

is_deeply(render_1401(q{\*\*A\*\*},q{\_\_C\_\_},q{\`x\`},q{\~\~F\~\~}),
    expected_1401('**A**','__C__','`x`','~~F~~'),
    'escaped double markers and backticks remain literal instead of being removed by cleanup');
is_deeply(render_1401(q{\*\*A\*\* **B** \`x\` *C*}),
    expected_1401("**A** \x02B\x02 `x` \x1dC\x1d"),
    'literal markers and actual short emphasis remain independent in the same reply');
is_deeply(render_1401(q{alpha_beta_gamma **LONG** *word* ++under++ ~~gone~~ \*literal\*},
        '** LONG ** and __ WORD __','***nested emphasis***'),
    expected_1401("alpha_beta_gamma \x02LONG\x02 \x1dword\x1d \x1funder\x1f gone *literal*",
        "\x02LONG\x02 and \x02WORD\x02","\x02\x1dnested emphasis\x02\x1d"),
    'long spans, strong whitespace, intraword underscores, single escapes and nested emphasis retain their semantics');

my @bounds;
for my $limit (120,400) {
    my $text="\x0304red\0 **A** ++🔥++ ".q{\`x\`}.' ';
    my $lines=format_reply($text x 150,wrap_bytes=>$limit,max_lines=>9);
    push @bounds,[scalar(@$lines),
        scalar(grep {length(encode('UTF-8',$_))>$limit} @$lines),
        scalar(grep {/[\x00-\x01\x03-\x0e\x10-\x1c\x1e\x7f]/} @$lines),
        $lines->[-1]=~/ …\z/?1:0,
        format_ai_reply($text x 150,wrap_bytes=>$limit,max_lines=>9)];
    is_deeply($bounds[-1],[2,0,0,1,$lines],
        "short styles and restored literal markers preserve the $limit-byte budget, two-line cap, control filtering and plain suffix");
}
done_testing;
