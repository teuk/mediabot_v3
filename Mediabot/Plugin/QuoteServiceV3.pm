package Mediabot::Plugin::QuoteServiceV3;

use strict;
use warnings;
use utf8;

use Encode qw(encode);
use Mediabot::Plugin::QuoteRecordV3;

use constant MAX_RESULTS => 20;
use constant MAX_QUERY_BYTES => 256;

sub new {
    my ($class, %args) = @_;
    my $provider = $args{dbh_provider};
    if (!defined $provider) {
        my $dbh = $args{dbh};
        $provider = sub { $dbh };
    }
    die "QuoteServiceV3: database provider is required\n"
        unless ref($provider) eq 'CODE';
    return bless {
        dbh_provider => $provider,
        random_index => ref($args{random_index}) eq 'CODE'
            ? $args{random_index} : sub { int(rand($_[0])) },
    }, $class;
}

sub _dbh {
    my ($self) = @_;
    my $dbh = eval { $self->{dbh_provider}->() };
    die "QuoteServiceV3: data service unavailable\n"
        unless $dbh && eval { $dbh->can('prepare') };
    return $dbh;
}

sub _channel {
    my ($channel) = @_;
    die "QuoteServiceV3: invalid channel\n"
        unless defined($channel) && !ref($channel)
            && length($channel) >= 2 && length($channel) <= 128
            && $channel =~ /\A[#&+!][^\x00\x07\r\n ,:]+\z/;
    return "$channel";
}

sub _limit {
    my ($value) = @_;
    $value = 10 unless defined $value;
    die "QuoteServiceV3: invalid result limit\n"
        unless !ref($value) && "$value" =~ /\A[0-9]+\z/
            && $value >= 1 && $value <= MAX_RESULTS;
    return 0 + $value;
}

sub _query_text {
    my ($value, $field) = @_;
    die "QuoteServiceV3: invalid $field\n"
        unless defined($value) && !ref($value);
    my $text = "$value";
    $text =~ s/[\r\n\0]+/ /g;
    $text =~ s/^\s+|\s+$//g;
    die "QuoteServiceV3: invalid $field\n"
        unless length($text)
            && length(encode('UTF-8', $text)) <= MAX_QUERY_BYTES;
    return $text;
}

sub _id {
    my ($value) = @_;
    die "QuoteServiceV3: invalid quote id\n"
        unless defined($value) && !ref($value)
            && "$value" =~ /\A[1-9][0-9]*\z/;
    return 0 + $value;
}

sub _escape_like {
    my ($value) = @_;
    $value =~ s/!/!!/g;
    $value =~ s/%/!%/g;
    $value =~ s/_/!_/g;
    return $value;
}

sub _select {
    my ($self, $sql, @bind) = @_;
    my $dbh = $self->_dbh;
    my $sth = eval { $dbh->prepare($sql) };
    die "QuoteServiceV3: data service unavailable\n" unless $sth;
    my $executed = eval { $sth->execute(@bind) };
    unless ($executed) {
        eval { $sth->finish };
        die "QuoteServiceV3: data service unavailable\n";
    }
    my @rows;
    my $ok = eval {
        while (my $row = $sth->fetchrow_hashref) {
            push @rows, { %$row };
            die "QuoteServiceV3: result bound exceeded\n"
                if @rows > MAX_RESULTS;
        }
        1;
    };
    eval { $sth->finish };
    die "QuoteServiceV3: data service unavailable\n" unless $ok;
    return \@rows;
}

sub _records {
    my ($rows) = @_;
    return [ map {
        Mediabot::Plugin::QuoteRecordV3->new(
            id         => $_->{id},
            text       => $_->{text} // '',
            author     => $_->{author} // 'Unknown',
            author_id  => $_->{author_id} // 0,
            created_at => $_->{created_at} // '',
            hits       => $_->{hits} // 0,
        )
    } @$rows ];
}

sub _columns {
    return q{q.id_quotes AS id, q.quotetext AS text, q.id_user AS author_id,
             q.ts AS created_at, COALESCE(u.nickname, 'Unknown') AS author,
             COALESCE(q.hits, 0) AS hits};
}

sub by_id {
    my ($self, %args) = @_;
    my $channel = _channel($args{channel});
    my $id = _id($args{id});
    my $rows = $self->_select(
        'SELECT ' . _columns() . q{
           FROM QUOTES q
           JOIN CHANNEL c ON c.id_channel = q.id_channel
           LEFT JOIN USER u ON u.id_user = q.id_user
          WHERE c.name = ? AND q.id_quotes = ?
          LIMIT 1},
        $channel, $id,
    );
    my $records = _records($rows);
    return { ok => 1, record => $records->[0] };
}

sub count {
    my ($self, %args) = @_;
    my $channel = _channel($args{channel});
    my ($sql, @bind) = (q{
        SELECT COUNT(*) AS count
          FROM QUOTES q
          JOIN CHANNEL c ON c.id_channel = q.id_channel
         WHERE c.name = ?}, $channel);
    if (defined($args{author}) && length("$args{author}")) {
        my $author = _query_text($args{author}, 'author');
        $sql = q{
            SELECT COUNT(*) AS count
              FROM QUOTES q
              JOIN CHANNEL c ON c.id_channel = q.id_channel
              JOIN USER u ON u.id_user = q.id_user
             WHERE c.name = ? AND u.nickname = ?};
        push @bind, $author;
    }
    my $rows = $self->_select($sql, @bind);
    my $count = $rows->[0] && defined($rows->[0]{count})
        && "$rows->[0]{count}" =~ /\A[0-9]+\z/ ? 0 + $rows->[0]{count} : 0;
    return { ok => 1, count => $count };
}

sub random {
    my ($self, %args) = @_;
    my $channel = _channel($args{channel});
    my $total = $self->count(channel => $channel)->{count};
    return { ok => 1, record => undef } unless $total;
    my $offset = $self->{random_index}->($total);
    die "QuoteServiceV3: invalid random index\n"
        unless defined($offset) && !ref($offset)
            && "$offset" =~ /\A[0-9]+\z/ && $offset < $total;
    my $rows = $self->_select(
        'SELECT ' . _columns() . q{
           FROM QUOTES q
           JOIN CHANNEL c ON c.id_channel = q.id_channel
           LEFT JOIN USER u ON u.id_user = q.id_user
          WHERE c.name = ?
          ORDER BY q.id_quotes
          LIMIT 1 OFFSET ?},
        $channel, 0 + $offset,
    );
    my $records = _records($rows);
    return { ok => 1, record => $records->[0] };
}

sub search {
    my ($self, %args) = @_;
    my $channel = _channel($args{channel});
    my $query = _query_text($args{query}, 'query');
    my $limit = _limit($args{limit});
    my @words = grep { length } split /\s+/, $query, 9;
    die "QuoteServiceV3: too many search words\n" if @words > 8;
    my $where = join ' AND ', map { q{q.quotetext LIKE ? ESCAPE '!'} } @words;
    my @patterns = map { '%' . _escape_like($_) . '%' } @words;
    my $rows = $self->_select(
        'SELECT ' . _columns() . qq{
           FROM QUOTES q
           JOIN CHANNEL c ON c.id_channel = q.id_channel
           LEFT JOIN USER u ON u.id_user = q.id_user
          WHERE c.name = ? AND $where
          ORDER BY q.id_quotes DESC
          LIMIT ?},
        $channel, @patterns, $limit,
    );
    return { ok => 1, records => _records($rows) };
}

sub by_author {
    my ($self, %args) = @_;
    my $channel = _channel($args{channel});
    my $author = _query_text($args{author}, 'author');
    my $limit = _limit($args{limit});
    my $rows = $self->_select(
        'SELECT ' . _columns() . q{
           FROM QUOTES q
           JOIN CHANNEL c ON c.id_channel = q.id_channel
           JOIN USER u ON u.id_user = q.id_user
          WHERE c.name = ? AND u.nickname = ?
          ORDER BY q.id_quotes DESC
          LIMIT ?},
        $channel, $author, $limit,
    );
    return { ok => 1, records => _records($rows) };
}

sub top {
    my ($self, %args) = @_;
    my $channel = _channel($args{channel});
    my $limit = _limit($args{limit});
    my $rows = $self->_select(
        'SELECT ' . _columns() . q{
           FROM QUOTES q
           JOIN CHANNEL c ON c.id_channel = q.id_channel
           LEFT JOIN USER u ON u.id_user = q.id_user
          WHERE c.name = ?
          ORDER BY q.hits DESC, q.id_quotes DESC
          LIMIT ?},
        $channel, $limit,
    );
    return { ok => 1, records => _records($rows) };
}

1;
