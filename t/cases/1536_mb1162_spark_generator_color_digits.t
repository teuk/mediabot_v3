use strict;
use warnings;
use utf8;
use Test::More;
use Mediabot::Spark::Generator qw(build_spark_request parse_spark_generation);

for my $case (
    ["\x03١٢ étoiles", '١٢ étoiles'],
    ["\x03１２ étoiles", '１２ étoiles'],
    ["\x03𝟙𝟚 étoiles", '𝟙𝟚 étoiles'],
    ["\x0304١٢ étoiles", '١٢ étoiles'],
    ["\x0304,١٢ étoiles", ',١٢ étoiles'],
    ["\x0304,12١٢ étoiles", '١٢ étoiles'],
    ["\x0304,12 étoiles", 'étoiles'],
    ["\x030412 étoiles", '12 étoiles'],
    ['١٢ étoiles', '١٢ étoiles'],
) {
    my ($raw, $clean) = @$case;
    my $request = build_spark_request(kind => 'portal', context => [$raw],
        contributions => [$raw, 'autre contribution']);
    is($request->{messages}[0]{content},
        "RECENT CHANNEL CONTEXT:\n- $clean\nEVENT CONTRIBUTIONS:\n- $clean\n- autre contribution",
        'context and contributions preserve visible digits');
    my $line = parse_spark_generation('aside', "LINE: $raw");
    is($line->{action}, 'ready', 'line accepted');
    is($line->{content}{line}, $clean, 'generated line preserves visible digits');
    my $fork = parse_spark_generation('fork', "QUESTION: $raw\nA: $raw\nB: $raw");
    is_deeply($fork->{content}, {question => $clean, a => $clean, b => $clean},
        'all fork fields preserve visible digits');
}
done_testing;
