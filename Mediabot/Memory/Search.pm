package Mediabot::Memory::Search;

use strict;
use warnings;
use utf8;
use Encode qw(encode decode FB_CROAK LEAVE_SRC);
use Mediabot::Helpers ();

# A small read-only index into deliberately saved channel references. This
# does not query CHANNEL_LOG, expose account ids, or increment recall counters.
sub query {
    my ($args) = @_;
    return unless ref($args) eq 'ARRAY' && @$args && @$args <= 6;
    return if grep { !defined($_) || ref($_) || /[\x00-\x1f\x7f]/ } @$args;
    my $text = join ' ', @$args;
    $text =~ s/^\s+|\s+$//g;
    my @words = grep { length } split /\s+/, $text;
    return unless @words && @words <= 6 && length($text) >= 2;
    my $bytes = eval { encode('UTF-8', $text, FB_CROAK | LEAVE_SRC) };
    return unless defined($bytes) && length($bytes) <= 160;
    return join ' ', @words;
}

sub _like {
    my ($word) = @_;
    $word =~ s/!/!!/g;
    $word =~ s/%/!%/g;
    $word =~ s/_/!_/g;
    return "%$word%";
}

sub _rows {
    my ($dbh, $sql, @bind) = @_;
    my $sth;
    my @rows;
    my $ok = eval {
        $sth = $dbh->prepare($sql) or die 'prepare';
        $sth->execute(@bind) or die 'execute';
        while (my $row = $sth->fetchrow_hashref) {
            die 'row' unless ref($row) eq 'HASH';
            push @rows, { %$row };
            die 'bound' if @rows > 4;
        }
        die 'fetch' if $sth->err;
        1;
    };
    eval { $sth->finish } if $sth;
    return $ok ? \@rows : undef;
}

sub search {
    my ($dbh, $cid, $text, %opts) = @_;
    return unless $dbh && defined($cid) && !ref($cid)
        && $cid =~ /\A[1-9][0-9]{0,9}\z/;
    $text = query([$text]);
    return unless defined $text;
    my @patterns = map { _like($_) } split /\s+/, $text;
    my $quote_where = join ' AND ', map { q{q.quotetext LIKE ? ESCAPE '!'} } @patterns;
    my $quotes = _rows($dbh, qq{
        SELECT q.id_quotes AS id, LEFT(q.quotetext, 512) AS text,
               LEFT(COALESCE(u.nickname, 'Unknown'), 64) AS author,
               DATE_FORMAT(q.ts, '%Y-%m-%d') AS date
        FROM QUOTES q
        LEFT JOIN USER u ON u.id_user = q.id_user
        WHERE q.id_channel = ? AND $quote_where
        ORDER BY q.id_quotes DESC LIMIT 4
    }, $cid, @patterns);
    my $result = { quotes => $quotes, factoids => undef,
        factoids_enabled => $opts{factoids} ? 1 : 0 };
    if ($opts{factoids}) {
        my $fact_where = join ' AND ', map {
            q{(f.keyword LIKE ? ESCAPE '!' OR f.value LIKE ? ESCAPE '!')}
        } @patterns;
        $result->{factoids} = _rows($dbh, qq{
            SELECT f.keyword, LEFT(f.value, 512) AS text,
                   LEFT(COALESCE(NULLIF(f.created_by_nick, ''), 'Unknown'), 64) AS author,
                   DATE_FORMAT(f.created_at, '%Y-%m-%d') AS date
            FROM FACTOID f
            WHERE f.id_channel = ? AND $fact_where
            ORDER BY f.id_factoid DESC LIMIT 4
        }, $cid, map { ($_, $_) } @patterns);
    }
    return $result;
}

sub _text {
    my ($value, $budget) = @_;
    return '' unless defined($value) && !ref($value);
    my $text = "$value";
    if (!utf8::is_utf8($text) && $text =~ /[^\x00-\x7f]/) {
        my $decoded = eval { decode('UTF-8', $text, FB_CROAK | LEAVE_SRC) };
        return '' unless defined $decoded;
        $text = $decoded;
    }
    $text =~ s/[\x00-\x1f\x7f]/ /g;
    $text =~ s/\s+/ /g;
    $text =~ s/^\s+|\s+$//g;
    # Keep downgraded non-ASCII character strings on the Unicode wire path.
    utf8::upgrade($text);
    return Mediabot::Helpers::truncate_utf8($text, $budget, '...');
}

sub lines {
    my ($result, $prefix) = @_;
    return () unless ref($result) eq 'HASH';
    $prefix = '!' unless defined($prefix) && !ref($prefix)
        && $prefix =~ /\A[^\s\x00-\x1f\x7f]\z/;
    my @lines;
    for my $kind (qw(quotes factoids)) {
        if ($kind eq 'factoids' && !$result->{factoids_enabled}) {
            push @lines, 'Factoids: not searched (-Factoids or policy unavailable).';
            next;
        }
        my $rows = $result->{$kind};
        my $label = $kind eq 'quotes' ? 'Quotes' : 'Factoids';
        unless (defined $rows) {
            push @lines, "$label: lookup unavailable.";
            next;
        }
        unless (@$rows) {
            push @lines, "$label: no matches.";
            next;
        }
        # Validate references before suggesting executable command text.
        my $valid = !grep {
            $kind eq 'quotes'
                ? !defined($_->{id}) || ref($_->{id}) || $_->{id} !~ /\A[1-9][0-9]{0,19}\z/
                : !defined($_->{keyword}) || ref($_->{keyword}) || $_->{keyword} !~ /\A[a-z0-9_.-]{1,64}\z/
        } @$rows;
        unless ($valid) {
            push @lines, "$label: lookup unavailable.";
            next;
        }
        for my $i (0 .. (@$rows > 3 ? 2 : $#$rows)) {
            my $row = $rows->[$i];
            my $link = $kind eq 'quotes' ? "${prefix}q view $row->{id}"
                : "${prefix}factoid $row->{keyword}";
            my $author = _text($row->{author}, 32) || 'Unknown';
            my $date = defined($row->{date}) && !ref($row->{date})
                && $row->{date} =~ /\A[0-9]{4}-[0-9]{2}-[0-9]{2}\z/ ? $row->{date} : '?';
            my $excerpt = _text($row->{text}, 130) || '[text unavailable]';
            push @lines, "$link | $date | by $author | $excerpt";
        }
        push @lines, "$label: more matches; refine your search." if @$rows > 3;
    }
    return @lines;
}

1;
