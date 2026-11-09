use strict;
use warnings;
use utf8;

use Mediabot::DTC::Source qw(extract_first_quote parse_random_quotes parse_search_ids strip_trailing_numeric_debris);

return sub {
    my ($assert) = @_;

    my $html = <<'HTML';
<article><a href="/quote/12345.html">quote</a>
<div class="entry-content"><p>&lt;Alice&gt; Salut<br>&lt;Bob&gt; Bonjour &amp; bienvenue</p></div></div></article>
<article><a href="https://danstonchat.com/quote/67890.html">quote</a>
<div class="foo entry-content bar"><p>Line one</p><p>Line two</p></div></div></article>
HTML

    $assert->is(extract_first_quote($html), "<Alice> Salut\n<Bob> Bonjour & bienvenue",
        'mb707-987: entry-content HTML is normalized to IRC quote lines');

    my $quotes = parse_random_quotes($html);
    $assert->is(scalar(@$quotes), 2, 'mb707-987: random page yields bounded quote blocks');
    $assert->is($quotes->[0]{id}, '12345', 'mb707-987: first nearby numeric quote id extracted');
    $assert->is($quotes->[1]{id}, '67890', 'mb707-987: second nearby numeric quote id extracted');

    my $search = q{<a href="/quote/111.html">x</a> <a href="https://danstonchat.com/quote/222.html">y</a>
      <a href="/?uddg=https%3A%2F%2Fdanstonchat.com%2Fquote%2F333.html&x=1">z</a>};
    my $ids = parse_search_ids($search);
    $assert->is(join('|', @$ids), '111|222|333', 'mb707-987: direct and DDG redirect quote IDs are deduplicated');

    $assert->is(strip_trailing_numeric_debris("hello\nworld\n42"), "hello\nworld",
        'mb707-987: trailing numeric debris is removed like the Tcl reference');

    # Mixed card formats must not prefer a farther permalink over data-id.
    for my $pair (
        ['<a href="/quote/111.html">first</a>', '<article data-id="222">'],
        ['<article data-id="111">', '<a href="/quote/222.html">second</a>'],
        ['<article data-id="111">', '<article data-id="222">'],
    ) {
        my $cards=$pair->[0].'<div class="entry-content">First quote</div></div></article>'
            .$pair->[1].'<div class="entry-content">Second quote</div></div></article>';
        my $parsed=parse_random_quotes($cards);
        $assert->is(join('|',map {$_->{id}} @$parsed),'111|222',
            'mb1181: mixed random cards retain their own nearest identifiers');
        $assert->is(join('|',map {$_->{text}} @$parsed),'First quote|Second quote',
            'mb1181: identity selection leaves quote text and order unchanged');
    }
    for my $tail ('<span data-id="333"></span><a href="/quote/444.html">later</a>',
                  '<a href="/quote/333.html">first</a><span data-id="444"></span>') {
        my $card='<div class="entry-content">A quote</div></div>'.$tail;
        $assert->is(parse_random_quotes($card)->[0]{id},'333',
            'mb1181: missing preceding identity uses the first following identifier');
    }
};
