use strict;
use warnings;
use Test::More;
use Mediabot::DTC::Source qw(parse_search_ids dtc_quote_url);

for my $href (
    '/quote/123.html',
    'https://danstonchat.com/quote/123.html',
    'HTTP://WWW.DANSTONCHAT.COM/quote/123.html',
    '//danstonchat.com/quote/123.html',
    '/quote/123.html?from=search#dialogue',
    '/?uddg=https%3A%2F%2Fdanstonchat.com%2Fquote%2F123.html&x=1',
    '/l/?uddg=https%3A%2F%2Fwww.danstonchat.com%2Fquote%2F123.html&amp;rut=fixture',
    '//duckduckgo.com/l/?uddg=https%3A%2F%2Fdanstonchat.com%2Fquote%2F123.html',
    'https://duckduckgo.com/l/?uddg=https%3A%2F%2Fdanstonchat.com%2Fquote%2F123.html',
    'https://lite.duckduckgo.com/l/?uddg=https%3A%2F%2Fdanstonchat.com%2Fquote%2F123.html',
    'https://html.duckduckgo.com/l/?uddg=https%3A%2F%2Fdanstonchat.com%2Fquote%2F123.html',
) {
    is_deeply(parse_search_ids(qq{<a href="$href">result</a>}), ['123'], "supported quote target: $href");
}
is_deeply(parse_search_ids('<a HREF=/quote/321.html>unquoted</a>'), ['321'], 'HTML parser accepts unquoted href attributes');
is_deeply(parse_search_ids('<a href="&#x2f;quote&#x2f;321.html">entities</a>'), ['321'], 'HTML entities are decoded before target admission');
is_deeply(parse_search_ids('<a href="/quote/999999999999.html">max</a>'), ['999999999999'], 'largest supported twelve-digit identity is retained');

for my $href (
    'https://example.test/quote/999.html',
    'https://danstonchat.com.evil.test/quote/999.html',
    'https://danstonchat.com@evil.test/quote/999.html',
    'https://evil.test/danstonchat.com/quote/999.html',
    'https://danstonchat.com/go?next=/quote/999.html',
    '/go?next=https://danstonchat.com/quote/999.html',
    '/other/quote/999.html',
    '../quote/999.html',
    'javascript:go("/quote/999.html")',
    '/quote/0.html', '/quote/0123.html', '/quote/1234567890123.html',
    '/quote/123.html.bak', '/quote/123.html/extra',
    '/?uddg=https%3A%2F%2Fevil.test%2Fquote%2F999.html',
    '/?uddg=https%3A%2F%2Fdanstonchat.com.evil.test%2Fquote%2F999.html',
    '/?uddg=https%3A%2F%2Fdanstonchat.com%2Fgo%3Fnext%3D%2Fquote%2F999.html',
    '/?uddg=https%3A%2F%2Fdanstonchat.com%2Fquote%2F0.html',
    '/?uddg=https%3A%2F%2Fdanstonchat.com%2Fquote%2F1234567890123.html',
    '/?uddg=https%253A%252F%252Fdanstonchat.com%252Fquote%252F999.html',
    'https://evil.test/?uddg=https%3A%2F%2Fdanstonchat.com%2Fquote%2F999.html',
    'https://duckduckgo.com.evil.test/l/?uddg=https%3A%2F%2Fdanstonchat.com%2Fquote%2F999.html',
    '/?uddg=https%3A%2F%2Fdanstonchat.com%2Fquote%2F111.html&uddg=https%3A%2F%2Fdanstonchat.com%2Fquote%2F222.html',
) {
    # Single quotes around href keep the JavaScript double quotes inside it.
    is_deeply(parse_search_ids(qq{<a href='$href'>noise</a>}), [], "unusable/foreign identity is ignored: $href");
}
for my $html (
    'Text https://danstonchat.com/quote/777.html',
    '<script>var url="/quote/777.html";</script>',
    '<!-- <a href="/quote/777.html">comment</a> -->',
    '<img src="/quote/777.html">',
    '<a data-href="/quote/777.html">no hyperlink</a>',
) {
    is_deeply(parse_search_ids($html), [], 'text, scripts, comments and non-href attributes cannot create search results');
}

my $mixed = join '',
    '<a href="/?uddg=https%3A%2F%2Fdanstonchat.com%2Fquote%2F101.html">first</a>',
    '<a href="/quote/202.html">second</a>',
    '<a href="https://duckduckgo.com/l/?uddg=https%3A%2F%2Fdanstonchat.com%2Fquote%2F303.html">third</a>',
    '<a href="https://danstonchat.com/quote/404.html">fourth</a>',
    '<a href="/quote/101.html">duplicate first</a>',
    '<a href="/?uddg=https%3A%2F%2Fdanstonchat.com%2Fquote%2F202.html">duplicate second</a>';
is_deeply(parse_search_ids($mixed), [qw(101 202 303 404)], 'direct and wrapped targets retain document order and first occurrence');

my $bad = join '', map {qq{<a href="/quote/${_}.html">invalid</a>}} ('0', '01', map {'123456789012'.$_} 1 .. 25);
my $good = join '', map {qq{<a href="/quote/${_}.html">valid</a><a href="/quote/${_}.html">duplicate</a>}} 1 .. 25;
is_deeply(parse_search_ids($bad.$good), [map {"$_"} 1 .. 20], 'invalid IDs and duplicates do not consume the twenty-result parser budget');
ok(!grep({!defined dtc_quote_url($_)} @{parse_search_ids($bad.$good)}), 'every parser result is accepted by the existing canonical fetch URL builder');
is_deeply(parse_search_ids('x' x (2 * 1024 * 1024 + 1)), [], 'existing HTML byte/character limit remains enforced');
is_deeply(parse_search_ids(undef), [], 'missing HTML has no result');
is_deeply(parse_search_ids([]), [], 'reference-valued HTML has no result');
done_testing;
