package Mediabot::DTC::Source;

use strict;
use warnings;
use utf8;

use Exporter qw(import);
use HTML::Entities qw(decode_entities);
use URI::Escape qw(uri_escape_utf8 uri_unescape);

use Mediabot::RSS::Fetcher ();

our @EXPORT_OK = qw(
    dtc_random_url dtc_quote_url
    extract_first_quote parse_random_quotes parse_search_ids
    strip_trailing_numeric_debris
    fetch_random fetch_by_id search_ids
);

use constant MAX_HTML_BYTES     => 2 * 1024 * 1024;
use constant MAX_QUOTE_CHARS    => 12000;
use constant MAX_RANDOM_QUOTES  => 100;
use constant MAX_SEARCH_RESULTS => 20;

sub dtc_random_url { return 'https://danstonchat.com/random' }
sub dtc_quote_url {
    my ($id) = @_;
    return undef unless defined($id) && !ref($id) && $id =~ /\A[0-9]+\z/;
    return "https://danstonchat.com/quote/$id.html";
}

sub _clean_html_text {
    my ($text) = @_;
    return '' unless defined($text) && !ref($text);
    $text =~ s/\r\n?/\n/g;
    $text =~ s{<br\s*/?>}{\n}gi;
    $text =~ s{</(?:p|li)\s*>}{\n}gi;
    $text =~ s{<li\b[^>]*>}{\x{2022} }gi;
    $text =~ s{<p\b[^>]*>}{}gi;
    $text =~ s{<[^>]+>}{}g;
    $text = decode_entities($text);
    $text =~ s/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]//g;

    my @lines;
    for my $line (split /\n/, $text) {
        $line =~ s/[\t ]+/ /g;
        $line =~ s/^\s+|\s+$//g;
        next unless length($line);
        next if $line eq "\x{2022}";
        push @lines, $line;
    }
    my $out = join("\n", @lines);
    $out = substr($out, 0, MAX_QUOTE_CHARS) if length($out) > MAX_QUOTE_CHARS;
    return $out;
}

sub _entry_content_blocks {
    my ($html) = @_;
    return [] unless defined($html) && !ref($html) && length($html);
    return [] if length($html) > MAX_HTML_BYTES;

    my @blocks;
    while ($html =~ m{<div\b[^>]*class=["'][^"']*\bentry-content\b[^"']*["'][^>]*>(.*?)</div>\s*</div>}sig) {
        push @blocks, { raw => $1, start => $-[0], end => $+[0] };
        last if @blocks >= MAX_RANDOM_QUOTES;
    }

    # Fallback for markup where the historical double-div close is absent.
    if (!@blocks) {
        while ($html =~ m{<div\b[^>]*class=["'][^"']*\bentry-content\b[^"']*["'][^>]*>(.*?)</div>}sig) {
            push @blocks, { raw => $1, start => $-[0], end => $+[0] };
            last if @blocks >= MAX_RANDOM_QUOTES;
        }
    }
    return \@blocks;
}

sub extract_first_quote {
    my ($html) = @_;
    my $blocks = _entry_content_blocks($html);
    return '' unless @$blocks;
    return _clean_html_text($blocks->[0]{raw});
}

sub strip_trailing_numeric_debris {
    my ($text) = @_;
    return '' unless defined($text) && !ref($text);
    my @lines = grep { length($_) } map {
        my $x = $_; $x =~ s/^\s+|\s+$//g; $x
    } split /\n/, $text;
    pop @lines if @lines && $lines[-1] =~ /\A[0-9]+\z/;
    return join("\n", @lines);
}

sub _id_near_block {
    my ($html, $block) = @_;
    return undef unless ref($block) eq 'HASH';
    my $start = $block->{start} // 0;
    my $end   = $block->{end}   // $start;
    my $from  = $start > 1600 ? $start - 1600 : 0;

    # The quote permalink normally appears before entry-content. Take the
    # nearest preceding ID instead of the first ID in a wide window, otherwise
    # adjacent cards can steal each other's identifier.
    my $before = substr($html, $from, $start - $from);
    my @before_ids = ($before =~ m{/quote/([0-9]+)\.html}ig);
    return $before_ids[-1] if @before_ids;
    my @before_data = ($before =~ /\bdata-id\s*=\s*["']([0-9]+)["']/ig);
    return $before_data[-1] if @before_data;

    my $to = $end + 1600;
    $to = length($html) if $to > length($html);
    my $after = substr($html, $end, $to - $end);
    return $1 if $after =~ m{/quote/([0-9]+)\.html}i;
    return $1 if $after =~ /\bdata-id\s*=\s*["']([0-9]+)["']/i;
    return undef;
}

sub parse_random_quotes {
    my ($html) = @_;
    return [] unless defined($html) && !ref($html) && length($html) <= MAX_HTML_BYTES;
    my $blocks = _entry_content_blocks($html);
    my @quotes;
    my %seen;
    for my $block (@$blocks) {
        my $text = strip_trailing_numeric_debris(_clean_html_text($block->{raw}));
        next unless length($text);
        my $id = _id_near_block($html, $block);
        $id = '??' unless defined $id;
        my $key = "$id\0$text";
        next if $seen{$key}++;
        push @quotes, { id => $id, text => $text };
        last if @quotes >= MAX_RANDOM_QUOTES;
    }
    return \@quotes;
}

sub parse_search_ids {
    my ($html) = @_;
    return [] unless defined($html) && !ref($html) && length($html) <= MAX_HTML_BYTES;
    my (@ids, %seen);

    while ($html =~ m{(?:https?://(?:www\.)?danstonchat\.com)?/quote/([0-9]+)\.html}ig) {
        push @ids, $1 unless $seen{$1}++;
        last if @ids >= MAX_SEARCH_RESULTS;
    }

    while (@ids < MAX_SEARCH_RESULTS && $html =~ /[?&]uddg=([^"'&<>]+)/ig) {
        my $decoded = uri_unescape($1);
        if ($decoded =~ m{/quote/([0-9]+)\.html}i) {
            push @ids, $1 unless $seen{$1}++;
        }
    }
    return \@ids;
}

sub _html_parser {
    my ($html) = @_;
    return { ok => 0, error => 'html_too_large' }
        unless defined($html) && !ref($html) && length($html) <= MAX_HTML_BYTES;
    return { ok => 1, html => $html };
}

sub _fetch_html {
    my ($url, %opts) = @_;
    my $fetcher = delete($opts{fetcher}) || \&Mediabot::RSS::Fetcher::fetch_feed_once;
    return { ok => 0, error => 'invalid_fetcher' } unless ref($fetcher) eq 'CODE';

    my $res = eval {
        $fetcher->(
            $url,
            %opts,
            timeout   => ($opts{timeout} // 8),
            max_items => 1,
            parser    => \&_html_parser,
        );
    };
    unless ($res && ref($res) eq 'HASH') {
        my $err = $@ || 'HTML fetcher returned no result';
        $err =~ s/[\r\n\0]+/ /g;
        return { ok => 0, error => 'fetch_exception', detail => substr($err, 0, 240) };
    }
    return { %$res, ok => 0 } unless $res->{ok};
    my $html = ref($res->{feed}) eq 'HASH' ? $res->{feed}{html} : undef;
    return { ok => 0, error => 'invalid_html_result' } unless defined($html) && !ref($html);
    return { ok => 1, html => $html, status => $res->{status}, url => $res->{url} };
}

sub fetch_by_id {
    my ($id, %opts) = @_;
    my $url = dtc_quote_url($id);
    return { ok => 0, error => 'invalid_id' } unless defined $url;
    my $res = _fetch_html($url, %opts);
    return $res unless $res->{ok};
    my $text = strip_trailing_numeric_debris(extract_first_quote($res->{html}));
    return { ok => 0, error => 'quote_not_found', id => "$id" } unless length($text);
    return { ok => 1, id => "$id", text => $text, url => $url };
}

sub fetch_random {
    my (%opts) = @_;
    my $rand_cb = delete($opts{rand_cb});
    $rand_cb = sub { rand($_[0]) } unless ref($rand_cb) eq 'CODE';
    my $res = _fetch_html(dtc_random_url(), %opts);
    return $res unless $res->{ok};
    my $quotes = parse_random_quotes($res->{html});
    return { ok => 0, error => 'no_random_quote' } unless @$quotes;
    my $idx = int($rand_cb->(scalar @$quotes));
    $idx = 0 if $idx < 0;
    $idx = $#$quotes if $idx > $#$quotes;
    return { ok => 1, %{ $quotes->[$idx] } };
}

sub _search_urls {
    my ($query) = @_;
    my $escaped = uri_escape_utf8($query);
    return (
        'https://duckduckgo.com/html/?q=' . uri_escape_utf8("site:danstonchat.com/quote $query") . '&kl=fr-fr&kp=-2&ia=web',
        'https://lite.duckduckgo.com/lite/?q=' . uri_escape_utf8("site:danstonchat.com $query"),
        'https://danstonchat.com/?s=' . $escaped,
    );
}

sub search_ids {
    my ($query, %opts) = @_;
    return { ok => 0, error => 'invalid_query' }
        unless defined($query) && !ref($query);
    $query =~ s/^\s+|\s+$//g;
    return { ok => 0, error => 'invalid_query' } unless length($query);
    return { ok => 0, error => 'query_too_long' } if length($query) > 160;
    return { ok => 0, error => 'control_char' } if $query =~ /[\x00-\x1f\x7f]/;

    my @urls = _search_urls($query);
    for my $url (@urls) {
        my $res = _fetch_html($url, %opts);
        next unless $res->{ok};
        my $ids = parse_search_ids($res->{html});
        if (@$ids) {
            splice(@$ids, 5) if @$ids > 5;
            return { ok => 1, ids => $ids, source_url => $url };
        }
    }
    return { ok => 1, ids => [] };
}

1;
