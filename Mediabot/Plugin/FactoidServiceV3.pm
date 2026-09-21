package Mediabot::Plugin::FactoidServiceV3;

use strict;
use warnings;
use utf8;

use Mediabot::Plugin::FactoidRecordV3;

use constant MAX_LIST_RESULTS => 60;
use constant MAX_TOP_RESULTS => 10;

sub new {
    my ($class, %args) = @_;
    my $provider = $args{dbh_provider};
    if (!defined $provider) {
        my $dbh = $args{dbh};
        $provider = sub { $dbh };
    }
    die "FactoidServiceV3: database provider is required\n"
        unless ref($provider) eq 'CODE';
    return bless { dbh_provider => $provider }, $class;
}

sub _dbh {
    my ($self) = @_;
    my $dbh = eval { $self->{dbh_provider}->() };
    die "FactoidServiceV3: data service unavailable\n"
        unless $dbh && eval { $dbh->can('prepare') };
    return $dbh;
}

sub _channel {
    my ($channel) = @_;
    die "FactoidServiceV3: invalid channel\n"
        unless defined($channel) && !ref($channel)
            && length($channel) >= 2 && length($channel) <= 128
            && $channel =~ /\A[#&+!][^\x00\x07\r\n ,:]+\z/;
    return "$channel";
}

sub _keyword {
    my ($value) = @_;
    die "FactoidServiceV3: invalid keyword\n"
        unless defined($value) && !ref($value);
    my $keyword = lc "$value";
    $keyword =~ s/^\s+|\s+$//g;
    die "FactoidServiceV3: invalid keyword\n"
        unless $keyword =~ /\A[a-z0-9_.-]{1,64}\z/;
    return $keyword;
}

sub _pattern {
    my ($value) = @_;
    return undef unless defined $value;
    die "FactoidServiceV3: invalid pattern\n" if ref($value);
    my $pattern = lc "$value";
    $pattern =~ s/^\s+|\s+$//g;
    return undef unless length $pattern;
    die "FactoidServiceV3: invalid pattern\n"
        unless $pattern =~ /\A[a-z0-9_.?*-]{1,64}\z/;
    return $pattern;
}

sub _limit {
    my ($value, $default, $maximum) = @_;
    $value = $default unless defined $value;
    die "FactoidServiceV3: invalid result limit\n"
        unless !ref($value) && "$value" =~ /\A[0-9]+\z/
            && $value >= 1 && $value <= $maximum;
    return 0 + $value;
}

sub _glob_like {
    my ($pattern) = @_;
    my $like = '';
    for my $char (split //, $pattern) {
        if ($char eq '*') {
            $like .= '%';
        }
        elsif ($char eq '?') {
            $like .= '_';
        }
        elsif ($char eq '_' || $char eq '%' || $char eq '!') {
            $like .= "!$char";
        }
        else {
            $like .= $char;
        }
    }
    return $like;
}

sub _select {
    my ($self, $sql, @bind) = @_;
    my $sth = eval { $self->_dbh->prepare($sql) };
    die "FactoidServiceV3: data service unavailable\n" unless $sth;
    my $executed = eval { $sth->execute(@bind) };
    unless ($executed) {
        eval { $sth->finish };
        die "FactoidServiceV3: data service unavailable\n";
    }
    my @rows;
    my $ok = eval {
        while (my $row = $sth->fetchrow_hashref) {
            push @rows, { %$row };
            die "FactoidServiceV3: result bound exceeded\n"
                if @rows > MAX_LIST_RESULTS;
        }
        1;
    };
    eval { $sth->finish };
    die "FactoidServiceV3: data service unavailable\n" unless $ok;
    return \@rows;
}

sub _record {
    my ($row) = @_;
    return undef unless $row;
    return Mediabot::Plugin::FactoidRecordV3->new(
        id         => $row->{id},
        keyword    => $row->{keyword},
        value      => $row->{value} // '',
        author     => length($row->{author} // '')
            ? $row->{author} : 'Unknown',
        author_id  => $row->{author_id} // 0,
        created_at => $row->{created_at} // '',
        updated_at => $row->{updated_at} // '',
        hits       => $row->{hits} // 0,
    );
}

sub _record_columns {
    return q{f.id_factoid AS id, f.keyword, f.value,
             f.created_by AS author_id,
             COALESCE(NULLIF(f.created_by_nick, ''), 'Unknown') AS author,
             f.created_at, f.updated_at, COALESCE(f.hits, 0) AS hits};
}

sub by_keyword {
    my ($self, %args) = @_;
    my $channel = _channel($args{channel});
    my $keyword = _keyword($args{keyword});
    my $rows = $self->_select(
        'SELECT ' . _record_columns() . q{
           FROM FACTOID f
           JOIN CHANNEL c ON c.id_channel = f.id_channel
          WHERE c.name = ? AND f.keyword = ?
          LIMIT 1},
        $channel, $keyword,
    );
    return { ok => 1, record => _record($rows->[0]) };
}

sub list {
    my ($self, %args) = @_;
    my $channel = _channel($args{channel});
    my $pattern = _pattern($args{pattern});
    my $limit = _limit($args{limit}, MAX_LIST_RESULTS, MAX_LIST_RESULTS);
    my ($sql, @bind);
    if (defined $pattern) {
        $sql = q{
            SELECT f.keyword
              FROM FACTOID f
              JOIN CHANNEL c ON c.id_channel = f.id_channel
             WHERE c.name = ? AND f.keyword LIKE ? ESCAPE '!'
             ORDER BY f.keyword ASC
             LIMIT ?};
        @bind = ($channel, _glob_like($pattern), $limit);
    }
    else {
        $sql = q{
            SELECT f.keyword
              FROM FACTOID f
              JOIN CHANNEL c ON c.id_channel = f.id_channel
             WHERE c.name = ?
             ORDER BY f.keyword ASC
             LIMIT ?};
        @bind = ($channel, $limit);
    }
    my $rows = $self->_select($sql, @bind);
    return { ok => 1, keywords => [ map { _keyword($_->{keyword}) } @$rows ] };
}

sub top {
    my ($self, %args) = @_;
    my $channel = _channel($args{channel});
    my $limit = _limit($args{limit}, MAX_TOP_RESULTS, MAX_TOP_RESULTS);
    my $rows = $self->_select(q{
        SELECT f.keyword, f.hits
          FROM FACTOID f
          JOIN CHANNEL c ON c.id_channel = f.id_channel
         WHERE c.name = ? AND f.hits > 0
         ORDER BY f.hits DESC, f.keyword ASC
         LIMIT ?}, $channel, $limit);
    return {
        ok => 1,
        items => [ map {
            my $hits = defined($_->{hits}) && !ref($_->{hits})
                && "$_->{hits}" =~ /\A[0-9]+\z/ ? 0 + $_->{hits} : 0;
            { keyword => _keyword($_->{keyword}), hits => $hits }
        } @$rows ],
    };
}

1;
