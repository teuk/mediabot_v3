package Mediabot::RSS;

# =============================================================================
# Mediabot::RSS — pure RSS/Atom foundation (mb692)
#
# No network access or Scheduler registration lives here. The later polling
# layer must revalidate DNS addresses and every redirect immediately before
# connect.
# =============================================================================

use strict;
use warnings;
use utf8;

use Exporter 'import';
use Digest::SHA qw(sha256_hex);
use HTML::Entities qw(decode_entities);
use Socket qw(AF_INET6 inet_pton);

our @EXPORT_OK = qw(
    normalize_feed_label
    canonical_feed_url
    validate_feed_url
    is_public_ip_literal
    parse_feed_document
    rss_item_key
    format_rss_announcement
    format_rss_feed_list
    rss_feed_state
    format_rss_feed_overview
    format_rss_feed_info_lines
);

use constant MAX_FEED_BYTES => 2 * 1024 * 1024;
use constant MAX_ITEMS      => 100;
use constant DEFAULT_LIMIT  => 5;
use constant DEFAULT_POLL   => 1800;

sub _clean_scalar {
    my ($value, $max) = @_;
    $value = '' unless defined $value && !ref $value;
    $value =~ s/[\x00-\x1f\x7f]//g;
    $value =~ s/\s+/ /g;
    $value =~ s/^\s+|\s+\z//g;
    $value = substr($value, 0, $max)
        if defined($max) && length($value) > $max;
    return $value;
}

sub normalize_feed_label {
    my ($label) = @_;
    $label = _clean_scalar($label, 80);
    return length($label) ? $label : undef;
}

sub _parse_url_authority {
    my ($url) = @_;
    return unless defined $url && !ref($url) && length($url) <= 2048;
    return unless $url =~ m{\A(https?)://([^/?#]+)(.*)\z}i;

    my ($scheme, $authority) = (lc($1), $2);
    return if $authority =~ /\@/; # no credentials/userinfo

    my ($host, $port);
    if ($authority =~ /\A\[([0-9A-Fa-f:.]+)\](?::(\d+))?\z/) {
        ($host, $port) = (lc($1), $2);
    }
    elsif ($authority =~ /\A([^:]+)(?::(\d+))?\z/) {
        ($host, $port) = (lc($1), $2);
    }
    else {
        return;
    }

    $host =~ s/\.\z//;
    return unless length($host) && $host =~ /\A[A-Za-z0-9_.:-]+\z/;

    if (defined $port) {
        return unless $port =~ /\A\d+\z/ && $port >= 1 && $port <= 65535;
        # IRC-controlled URLs must not become a general-purpose port scanner.
        return unless ($scheme eq 'http'  && $port == 80)
                   || ($scheme eq 'https' && $port == 443);
    }
    else {
        $port = $scheme eq 'https' ? 443 : 80;
    }

    return ($scheme, $host, 0 + $port);
}

sub _public_ipv4 {
    my ($ip) = @_;
    return 0 unless defined $ip
        && $ip =~ /\A(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})\z/;

    my @o = ($1, $2, $3, $4);
    return 0 if grep { $_ > 255 } @o;

    return 0 if $o[0] == 0;
    return 0 if $o[0] == 10;
    return 0 if $o[0] == 100 && $o[1] >= 64 && $o[1] <= 127;
    return 0 if $o[0] == 127;
    return 0 if $o[0] == 169 && $o[1] == 254;
    return 0 if $o[0] == 172 && $o[1] >= 16 && $o[1] <= 31;
    return 0 if $o[0] == 192 && $o[1] == 0 && ($o[2] == 0 || $o[2] == 2);
    return 0 if $o[0] == 192 && $o[1] == 168;
    return 0 if $o[0] == 198 && ($o[1] == 18 || $o[1] == 19);
    return 0 if $o[0] == 198 && $o[1] == 51 && $o[2] == 100;
    return 0 if $o[0] == 203 && $o[1] == 0 && $o[2] == 113;
    return 0 if $o[0] >= 224;

    return 1;
}

sub _public_ipv6 {
    my ($ip) = @_;
    my $packed = eval { inet_pton(AF_INET6, $ip) };
    return 0 unless defined($packed) && length($packed) == 16;

    my @b = unpack('C16', $packed);

    return 0 if !grep { $_ != 0 } @b; # ::
    return 0 if (grep { $_ != 0 } @b[0..14]) == 0 && $b[15] == 1; # ::1
    return 0 if ($b[0] & 0xfe) == 0xfc; # fc00::/7
    return 0 if $b[0] == 0xfe && ($b[1] & 0xc0) == 0x80; # fe80::/10
    return 0 if $b[0] == 0xff; # multicast
    return 0 if $b[0] == 0x20 && $b[1] == 0x01
             && $b[2] == 0x0d && $b[3] == 0xb8; # documentation

    # IPv4-mapped ::ffff:a.b.c.d
    if ((grep { $_ != 0 } @b[0..9]) == 0
            && $b[10] == 0xff && $b[11] == 0xff) {
        return _public_ipv4(join('.', @b[12..15]));
    }

    return 1;
}

sub is_public_ip_literal {
    my ($host) = @_;
    return 0 unless defined $host && !ref $host;
    $host =~ s/^\[|\]$//g;

    return _public_ipv4($host) if $host =~ /\A\d+(?:\.\d+){3}\z/;
    return _public_ipv6($host) if index($host, ':') >= 0;
    return undef; # DNS name: connect-time resolution is mandatory later.
}

sub canonical_feed_url {
    my ($url) = @_;
    my ($scheme, $host, $port) = _parse_url_authority($url);
    return undef unless defined $scheme;

    my ($rest) = $url =~ m{\Ahttps?://[^/?#]+(.*)\z}i;
    $rest = '' unless defined $rest;
    $rest =~ s/#.*\z//s;
    $rest = '/' if $rest eq '';

    my $authority = index($host, ':') >= 0 ? "[$host]" : $host;
    my $default = ($scheme eq 'http' && $port == 80)
               || ($scheme eq 'https' && $port == 443);
    $authority .= ":$port" unless $default;

    return "$scheme://$authority$rest";
}

sub validate_feed_url {
    my ($url) = @_;
    my ($scheme, $host, $port) = _parse_url_authority($url);

    return { ok => 0, error => 'invalid_url' }
        unless defined $scheme;

    return { ok => 0, error => 'blocked_host' }
        if $host eq 'localhost'
        || $host =~ /\.localhost\z/
        || $host =~ /\.local\z/
        || $host =~ /\.internal\z/
        || $host eq 'home.arpa'
        || $host =~ /\.home\.arpa\z/;

    my $literal = is_public_ip_literal($host);
    return { ok => 0, error => 'blocked_ip' }
        if defined($literal) && !$literal;

    return {
        ok                   => 1,
        scheme               => $scheme,
        host                 => $host,
        port                 => $port,
        url                  => $url,
        needs_dns_validation => defined($literal) ? 0 : 1,
    };
}

sub _xml_unescape {
    my ($s) = @_;
    return '' unless defined $s;

    $s =~ s/\A\s*<!\[CDATA\[(.*?)\]\]>\s*\z/$1/si;
    $s =~ s/<[^>]+>/ /g;
    $s = decode_entities($s);

    return _clean_scalar($s, 600);
}

sub _xml_tag_text {
    my ($block, $tag) = @_;
    my ($value) = ($block // '') =~
        m{<(?:[A-Za-z_][\w.-]*:)?\Q$tag\E\b[^>]*>
          (.*?)
          </(?:[A-Za-z_][\w.-]*:)?\Q$tag\E>}six;

    return _xml_unescape($value);
}

sub _xml_tag_attr {
    my ($block, $tag, $attr, $prefer_rel) = @_;

    my @nodes = ($block // '') =~
        m{(<(?:[A-Za-z_][\w.-]*:)?\Q$tag\E\b[^>]*>)}sig;

    for my $node (@nodes) {
        if (defined $prefer_rel) {
            my ($rel) = $node =~ /\brel\s*=\s*["']([^"']+)["']/i;
            next if defined($rel) && lc($rel) ne lc($prefer_rel);
        }

        my ($value) = $node =~
            /\b\Q$attr\E\s*=\s*["']([^"']+)["']/i;

        return _xml_unescape($value) if defined $value;
    }

    return '';
}

sub _article_url {
    my ($url) = @_;
    $url = _clean_scalar($url, 2048);
    return $url =~ m{\Ahttps?://}i ? $url : '';
}

sub rss_item_key {
    my ($item) = @_;
    return undef unless ref($item) eq 'HASH';

    for my $field (qw(id guid url)) {
        my $value = _clean_scalar($item->{$field}, 2048);
        return sha256_hex(lc($field) . "\0" . $value)
            if length $value;
    }

    my $title = _clean_scalar($item->{title}, 600);
    my $date  = _clean_scalar($item->{published}, 160);

    return undef unless length($title) || length($date);
    return sha256_hex("fallback\0$title\0$date");
}

sub _parse_rss_items {
    my ($xml, $limit) = @_;
    my @items;

    while ($xml =~ m{<item\b[^>]*>(.*?)</item>}sig) {
        my $block = $1;
        my $title = _xml_tag_text($block, 'title');
        next unless length $title;

        my $entry = {
            title     => $title,
            url       => _article_url(_xml_tag_text($block, 'link')),
            guid      => _xml_tag_text($block, 'guid'),
            published => _xml_tag_text($block, 'pubDate')
                         || _xml_tag_text($block, 'date'),
        };

        $entry->{item_key} = rss_item_key($entry);
        push @items, $entry;
        last if @items >= $limit;
    }

    return \@items;
}

sub _parse_atom_items {
    my ($xml, $limit) = @_;
    my @items;

    while ($xml =~ m{<entry\b[^>]*>(.*?)</entry>}sig) {
        my $block = $1;
        my $title = _xml_tag_text($block, 'title');
        next unless length $title;

        my $url = _xml_tag_attr($block, 'link', 'href', 'alternate')
               || _xml_tag_attr($block, 'link', 'href', undef);

        my $entry = {
            title     => $title,
            url       => _article_url($url),
            id        => _xml_tag_text($block, 'id'),
            published => _xml_tag_text($block, 'published')
                         || _xml_tag_text($block, 'updated'),
        };

        $entry->{item_key} = rss_item_key($entry);
        push @items, $entry;
        last if @items >= $limit;
    }

    return \@items;
}

sub parse_feed_document {
    my ($xml, %opts) = @_;

    return { ok => 0, error => 'missing_xml' }
        unless defined $xml && !ref($xml);

    my $bytes = length($xml);

    return { ok => 0, error => 'feed_too_large' }
        if $bytes > MAX_FEED_BYTES;

    return { ok => 0, error => 'nul_byte' }
        if index($xml, "\0") >= 0;

    # No general entity engine is instantiated. Reject these declarations
    # explicitly so a later parser refactor cannot silently open an XXE path.
    return { ok => 0, error => 'forbidden_doctype' }
        if $xml =~ /<!DOCTYPE\b/i || $xml =~ /<!ENTITY\b/i;

    my $limit = $opts{max_items};
    $limit = DEFAULT_LIMIT
        unless defined($limit) && $limit =~ /\A\d+\z/;
    $limit = 1         if $limit < 1;
    $limit = MAX_ITEMS if $limit > MAX_ITEMS;

    my ($format, $title, $items);

    if ($xml =~ /<(?:[A-Za-z_][\w.-]*:)?feed\b/i) {
        $format = 'atom';

        my ($head) = $xml =~ m{\A(.*?)(?=<entry\b)}si;
        $title = _xml_tag_text($head // $xml, 'title');
        $items = _parse_atom_items($xml, $limit);
    }
    elsif ($xml =~ /<(?:rss|(?:[A-Za-z_][\w.-]*:)?RDF)\b/i) {
        $format = 'rss';

        my ($channel) =
            $xml =~ m{<channel\b[^>]*>(.*?)</channel>}si;

        $title = _xml_tag_text($channel // $xml, 'title');
        $items = _parse_rss_items($xml, $limit);
    }
    else {
        return { ok => 0, error => 'unsupported_feed' };
    }

    return {
        ok     => 1,
        format => $format,
        title  => $title,
        items  => $items || [],
        bytes  => $bytes,
    };
}

# Historical rss-synd.tcl display:
# ACTION - news : [Source] Title - URL
# source=13, title=6, separator=13+bold, URL=14.
sub format_rss_announcement {
    my (%args) = @_;

    my $label = normalize_feed_label($args{label}) // 'RSS';
    my $title = _clean_scalar($args{title}, 350);
    my $url   = _article_url($args{url});

    return undef unless length($title) && length($url);

    return "\001ACTION - news \002:\002 "
         . "\00313[$label]"
         . "\0036 $title "
         . "\00313\002-\002"
         . "\00314 $url\001";
}

sub format_rss_feed_list {
    my (@labels) = @_;

    @labels = grep { defined($_) && length($_) }
              map  { normalize_feed_label($_) } @labels;

    return "\037Flux disponibles\037 : "
         . "\00314"
         . join("\00313 | \00314", @labels)
         . "\003";
}

sub rss_feed_state {
    my ($feed) = @_;
    return 'error' unless ref($feed) eq 'HASH';
    return 'off' unless $feed->{enabled};
    return 'error' if defined($feed->{last_error}) && length($feed->{last_error});
    return 'waiting' unless defined($feed->{last_success_at}) && length($feed->{last_success_at});
    return 'pending' if ($feed->{pending_count} || 0) > 0;
    return 'ok';
}

sub _rss_human_interval {
    my ($seconds) = @_;
    $seconds = int($seconds || 0);
    return '0 min' if $seconds <= 0;
    my $minutes = int(($seconds + 59) / 60);
    return '1 d' if $minutes == 1440;
    return int($minutes / 60) . ' h' if $minutes >= 60 && $minutes % 60 == 0;
    return "$minutes min";
}

sub _rss_human_due {
    my ($feed) = @_;
    return 'paused' unless $feed->{enabled};
    my $seconds = $feed->{next_poll_in};
    return 'now' unless defined($seconds) && $seconds =~ /^-?\d+$/ && $seconds > 0;
    return 'in <1 min' if $seconds < 60;
    my $minutes = int(($seconds + 59) / 60);
    return 'in ' . int($minutes / 60) . ' h' if $minutes >= 60 && $minutes % 60 == 0;
    return "in $minutes min";
}

sub _rss_state_text {
    my ($state) = @_;
    return 'PAUSED'             if $state eq 'off';
    return 'ERROR'              if $state eq 'error';
    return 'WAITING FIRST POLL' if $state eq 'waiting';
    return 'PENDING'            if $state eq 'pending';
    return 'OK';
}

sub _rss_state_color {
    my ($state) = @_;
    return '14' if $state eq 'off';
    return '04' if $state eq 'error';
    return '08' if $state eq 'waiting';
    return '07' if $state eq 'pending';
    return '03';
}

sub format_rss_feed_overview {
    my ($channel, @feeds) = @_;
    $channel = _clean_scalar($channel, 80);
    $channel = '?' unless length $channel;

    my $prefix = "\037Flux RSS $channel\037 : ";
    my @lines;
    my $line = $prefix;

    for my $feed (@feeds) {
        next unless ref($feed) eq 'HASH';
        my $label = normalize_feed_label($feed->{label}) // 'RSS';
        my $state = rss_feed_state($feed);
        my $color = _rss_state_color($state);
        my $status = _rss_state_text($state);
        my $poll = _rss_human_interval($feed->{poll_interval});
        my $max = int($feed->{announce_limit} || 0);
        my $items = int($feed->{item_count} || 0);
        my $pending = int($feed->{pending_count} || 0);

        my $entry = "\00314[$label]\003 "
                  . "\00313$poll/max$max · $items item" . ($items == 1 ? '' : 's')
                  . ($pending ? " · $pending pending" : '')
                  . " · \003${color}$status\003";

        my $sep = $line eq $prefix ? '' : " \00313|\003 ";
        if (length($line . $sep . $entry) > 390 && $line ne $prefix) {
            push @lines, $line;
            $line = $prefix . $entry;
        }
        else {
            $line .= $sep . $entry;
        }
    }

    push @lines, $line if $line ne $prefix;
    return \@lines;
}

sub format_rss_feed_info_lines {
    my ($feed) = @_;
    return [] unless ref($feed) eq 'HASH';

    my $label = normalize_feed_label($feed->{label}) // 'RSS';
    my $channel = _clean_scalar($feed->{channel}, 80);
    $channel = '?' unless length $channel;
    my $state = rss_feed_state($feed);
    my $enabled = $feed->{enabled} ? 'ON' : 'OFF';
    my $poll = _rss_human_interval($feed->{poll_interval});
    my $max = int($feed->{announce_limit} || 0);
    my $items = int($feed->{item_count} || 0);
    my $pending = int($feed->{pending_count} || 0);
    my $due = _rss_human_due($feed);
    my $url = _article_url($feed->{url});
    my $last_poll = $feed->{last_poll_at} // 'never';
    my $last_success = $feed->{last_success_at} // 'never';
    my $last_error = $feed->{last_error};

    my @lines = (
        "RSS [$label] on $channel — $enabled · " . _rss_state_text($state),
        "URL: $url",
        "Polling: every $poll | max $max | next: $due",
        "Items: $items stored | $pending pending",
        "Last poll: $last_poll | success: $last_success",
    );

    if (defined($last_error) && length($last_error)) {
        my $when = $feed->{last_error_at} // 'unknown time';
        $last_error = _clean_scalar($last_error, 180);
        push @lines, "Last error: $last_error ($when)";
    }
    else {
        push @lines, 'Last error: none';
    }

    return \@lines;
}

1;
