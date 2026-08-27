package Mediabot::VDM::Source;

use strict;
use warnings;
use utf8;

use Exporter qw(import);
use HTML::Entities qw(decode_entities);

use Mediabot::RSS::Fetcher ();
use Mediabot::VDM qw(vdm_feed_url vdm_item_id format_vdm_line);

our @EXPORT_OK = qw(parse_vdm_feed_document fetch_vdm_once);

use constant MAX_FEED_BYTES => 2 * 1024 * 1024;
use constant MAX_ITEMS      => 50;

sub _clean_text {
    my ($value, $max) = @_;
    return '' unless defined($value) && !ref($value);

    $value =~ s/\A\s*<!\[CDATA\[(.*?)\]\]>\s*\z/$1/si;
    $value =~ s/<br\s*\/?>/ /gi;
    $value =~ s/<[^>]+>/ /g;
    $value = decode_entities($value);
    $value =~ s/[\x00-\x1f\x7f]+/ /g;
    $value =~ s/\s+/ /g;
    $value =~ s/^\s+|\s+\z//g;
    $value = substr($value, 0, $max)
        if defined($max) && length($value) > $max;
    return $value;
}

sub _tag_text {
    my ($block, $tag) = @_;
    my ($value) = ($block // '') =~
        m{<(?:[A-Za-z_][\w.-]*:)?\Q$tag\E\b[^>]*>(.*?)</(?:[A-Za-z_][\w.-]*:)?\Q$tag\E>}six;
    return _clean_text($value, 4096);
}

sub _atom_link {
    my ($block) = @_;
    my @links = ($block // '') =~ m{(<(?:[A-Za-z_][\w.-]*:)?link\b[^>]*>)}sig;
    for my $node (@links) {
        my ($rel) = $node =~ /\brel\s*=\s*["']([^"']+)["']/i;
        next if defined($rel) && lc($rel) ne 'alternate';
        my ($href) = $node =~ /\bhref\s*=\s*["']([^"']+)["']/i;
        my $url = _clean_text($href, 2048);
        return $url if $url =~ m{\Ahttps?://}i;
    }
    return '';
}

sub _published_story {
    my ($value) = @_;
    return '' unless defined($value) && !ref($value) && length($value);

    # The official VDM RSS description currently appends a short editorial
    # suffix after the story's published closing marker.  The story contract
    # itself remains "Aujourd'hui ... VDM", so isolate that published portion
    # instead of requiring the whole RSS field to end at the marker.
    return '' unless $value =~ /\A(?:Aujourd['’]hui)\b/i;

    if ($value =~ /\A((?:Aujourd['’]hui)\b.*\bVDM)\b(.*)\z/is) {
        my ($story, $suffix) = ($1, $2);
        return '' if length($suffix) > 128;
        $story =~ s/\s+\z//;
        return $story;
    }

    return '';
}

sub _story_from_block {
    my ($block, $format) = @_;
    my @fields = $format eq 'atom'
        ? qw(summary content title)
        : qw(description encoded title);

    for my $field (@fields) {
        my $value = _tag_text($block, $field);
        next unless length($value);
        my $story = _published_story($value);
        return $story if length($story);
    }
    return '';
}

sub _item_from_block {
    my ($block, $format) = @_;

    my $url = $format eq 'atom'
        ? _atom_link($block)
        : _tag_text($block, 'link');
    $url = '' unless $url =~ m{\Ahttps?://}i;

    my $guid = $format eq 'atom'
        ? _tag_text($block, 'id')
        : _tag_text($block, 'guid');

    my $story = _story_from_block($block, $format);
    return undef unless length($story);

    my $id = vdm_item_id({ url => $url, guid => $guid });
    return undef unless defined $id;

    # Reuse the canonical presentation validator as the final source-quality
    # gate. The parser returns clean content, not IRC formatting.
    return undef unless defined format_vdm_line(id => $id, story => $story);

    return {
        id        => $id,
        story     => $story,
        url       => $url,
        guid      => $guid,
        published => $format eq 'atom'
            ? (_tag_text($block, 'published') || _tag_text($block, 'updated'))
            : (_tag_text($block, 'pubDate') || _tag_text($block, 'date')),
    };
}

sub parse_vdm_feed_document {
    my ($xml, %opts) = @_;

    return { ok => 0, error => 'missing_xml' }
        unless defined($xml) && !ref($xml);
    return { ok => 0, error => 'feed_too_large' }
        if length($xml) > MAX_FEED_BYTES;
    return { ok => 0, error => 'nul_byte' }
        if index($xml, "\0") >= 0;
    return { ok => 0, error => 'forbidden_doctype' }
        if $xml =~ /<!DOCTYPE\b/i || $xml =~ /<!ENTITY\b/i;

    my $limit = $opts{max_items};
    $limit = 10 unless defined($limit) && $limit =~ /\A\d+\z/;
    $limit = 1 if $limit < 1;
    $limit = MAX_ITEMS if $limit > MAX_ITEMS;

    my ($format, $tag);
    if ($xml =~ /<(?:[A-Za-z_][\w.-]*:)?feed\b/i) {
        ($format, $tag) = ('atom', 'entry');
    }
    elsif ($xml =~ /<(?:rss|(?:[A-Za-z_][\w.-]*:)?RDF)\b/i) {
        ($format, $tag) = ('rss', 'item');
    }
    else {
        return { ok => 0, error => 'unsupported_feed' };
    }

    my @items;
    while ($xml =~ m{<(?:[A-Za-z_][\w.-]*:)?\Q$tag\E\b[^>]*>(.*?)</(?:[A-Za-z_][\w.-]*:)?\Q$tag\E>}sig) {
        my $item = _item_from_block($1, $format);
        next unless $item;
        push @items, $item;
        last if @items >= $limit;
    }

    return { ok => 0, error => 'no_valid_items' } unless @items;
    return {
        ok     => 1,
        format => $format,
        items  => \@items,
        bytes  => length($xml),
    };
}

sub fetch_vdm_once {
    my (%opts) = @_;

    my $fetcher = delete($opts{feed_fetcher}) || \&Mediabot::RSS::Fetcher::fetch_feed_once;
    return { ok => 0, error => 'invalid_fetcher' } unless ref($fetcher) eq 'CODE';

    my $limit = delete($opts{max_items});
    $limit = 10 unless defined($limit) && $limit =~ /\A\d+\z/;
    $limit = 1 if $limit < 1;
    $limit = MAX_ITEMS if $limit > MAX_ITEMS;

    my $res = eval {
        $fetcher->(
            vdm_feed_url(),
            %opts,
            max_items => $limit,
            parser    => \&parse_vdm_feed_document,
        );
    };

    unless ($res && ref($res) eq 'HASH') {
        my $err = $@ || 'VDM feed fetcher returned no result';
        $err =~ s/[\r\n\0]+/ /g;
        return { ok => 0, error => 'fetch_exception', detail => substr($err, 0, 240) };
    }

    return { %$res, ok => 0 } unless $res->{ok};
    my $items = ref($res->{feed}) eq 'HASH' ? $res->{feed}{items} : undef;
    return { ok => 0, error => 'invalid_feed_result' }
        unless ref($items) eq 'ARRAY' && @$items;

    return {
        ok     => 1,
        status => $res->{status},
        url    => $res->{url},
        items  => $items,
    };
}

1;
