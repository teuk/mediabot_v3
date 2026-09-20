package Mediabot::Plugin::QuoteWriteServiceV3;

use strict;
use warnings;
use utf8;

use Encode qw(encode);
use Scalar::Util qw(blessed);

use constant MAX_QUOTE_CHARS => 512;
use constant MAX_QUOTE_BYTES => 2048;

sub new {
    my ($class, %args) = @_;
    my $provider = $args{dbh_provider};
    if (!defined $provider) {
        my $dbh = $args{dbh};
        $provider = sub { $dbh };
    }
    die "QuoteWriteServiceV3: database provider is required\n"
        unless ref($provider) eq 'CODE';
    die "QuoteWriteServiceV3: on_created must be CODE\n"
        if exists($args{on_created}) && ref($args{on_created}) ne 'CODE';
    return bless {
        dbh_provider => $provider,
        on_created   => $args{on_created},
    }, $class;
}

sub _dbh {
    my ($self) = @_;
    my $dbh = eval { $self->{dbh_provider}->() };
    die "QuoteWriteServiceV3: data service unavailable\n"
        unless $dbh && eval { $dbh->can('prepare') };
    return $dbh;
}

sub _channel {
    my ($channel) = @_;
    die "QuoteWriteServiceV3: invalid channel\n"
        unless defined($channel) && !ref($channel)
            && length($channel) >= 2 && length($channel) <= 128
            && $channel =~ /\A[#&+!][^\x00\x07\r\n ,:]+\z/;
    return "$channel";
}

sub _principal {
    my ($principal) = @_;
    die "QuoteWriteServiceV3: invalid principal\n"
        unless blessed($principal)
            && $principal->isa('Mediabot::Plugin::PrincipalV3');
    return $principal;
}

sub _text {
    my ($value) = @_;
    die "QuoteWriteServiceV3: invalid quote text\n"
        unless defined($value) && !ref($value);
    my $text = "$value";
    die "QuoteWriteServiceV3: invalid quote text\n"
        unless length($text) && $text !~ /[\r\n\0]/
            && length($text) <= MAX_QUOTE_CHARS
            && length(encode('UTF-8', $text)) <= MAX_QUOTE_BYTES;
    return $text;
}

sub _id {
    my ($value) = @_;
    die "QuoteWriteServiceV3: invalid quote id\n"
        unless defined($value) && !ref($value)
            && "$value" =~ /\A[1-9][0-9]*\z/;
    return 0 + $value;
}

sub _delete_level {
    my ($value) = @_;
    $value = 100 unless defined $value;
    die "QuoteWriteServiceV3: invalid delete level\n"
        unless !ref($value) && "$value" =~ /\A[0-9]+\z/
            && $value >= 0 && $value <= 500;
    return 0 + $value;
}

sub _statement {
    my ($self, $dbh, $sql, @bind) = @_;
    die "QuoteWriteServiceV3: data service unavailable\n"
        unless $dbh && eval { $dbh->can('prepare') };
    my $sth = eval { $dbh->prepare($sql) };
    die "QuoteWriteServiceV3: data service unavailable\n" unless $sth;
    my $ok = eval { $sth->execute(@bind) };
    unless ($ok) {
        eval { $sth->finish };
        die "QuoteWriteServiceV3: data service unavailable\n";
    }
    return $sth;
}

sub _one {
    my ($self, $dbh, $sql, @bind) = @_;
    my $sth = $self->_statement($dbh, $sql, @bind);
    my $row = eval { $sth->fetchrow_hashref };
    eval { $sth->finish };
    return ref($row) eq 'HASH' ? { %$row } : undef;
}

sub add {
    my ($self, %args) = @_;
    my $channel = _channel($args{channel});
    my $principal = _principal($args{principal});
    my $text = _text($args{text});
    my $dbh = $self->_dbh;

    my $existing = $self->_one($dbh, q{
        SELECT q.id_quotes AS id
          FROM QUOTES q
          JOIN CHANNEL c ON c.id_channel = q.id_channel
         WHERE c.name = ? AND q.quotetext = ?
         LIMIT 1}, $channel, $text);
    if ($existing && defined($existing->{id})
        && "$existing->{id}" =~ /\A[1-9][0-9]*\z/) {
        return { ok => 1, status => 'duplicate', id => 0 + $existing->{id} };
    }

    my $channel_row = $self->_one($dbh, q{
        SELECT id_channel AS id
          FROM CHANNEL
         WHERE name = ?
         LIMIT 1}, $channel);
    return { ok => 0, error => 'channel_unavailable' }
        unless $channel_row && defined($channel_row->{id})
            && "$channel_row->{id}" =~ /\A[1-9][0-9]*\z/;

    my $channel_id = 0 + $channel_row->{id};
    my $author_id = $principal->authenticated ? $principal->user_id : 0;
    my $sth = $self->_statement($dbh, q{
        INSERT INTO QUOTES (id_channel, id_user, quotetext)
        VALUES (?, ?, ?)}, $channel_id, $author_id, $text);
    eval { $sth->finish };

    my $id = eval { $dbh->last_insert_id(undef, undef, undef, undef) };
    $id = eval { $dbh->{mysql_insertid} } unless defined($id);
    die "QuoteWriteServiceV3: inserted id unavailable\n"
        unless defined($id) && !ref($id) && "$id" =~ /\A[1-9][0-9]*\z/;
    $id = 0 + $id;

    if (ref($self->{on_created}) eq 'CODE') {
        eval { $self->{on_created}->(
            id => $id, channel => $channel, author_id => $author_id,
            account => $principal->account) };
    }
    return { ok => 1, status => 'created', id => $id };
}

sub delete {
    my ($self, %args) = @_;
    my $channel = _channel($args{channel});
    my $principal = _principal($args{principal});
    my $id = _id($args{id});
    my $required = _delete_level($args{delete_level});

    return { ok => 0, error => 'unauthorized' }
        unless $principal->authenticated;
    my $dbh = $self->_dbh;

    my $quote = $self->_one($dbh, q{
        SELECT q.id_quotes AS id, q.id_user AS author_id,
               q.id_channel AS channel_id
          FROM QUOTES q
          JOIN CHANNEL c ON c.id_channel = q.id_channel
         WHERE c.name = ? AND q.id_quotes = ?
         LIMIT 1}, $channel, $id);
    return { ok => 1, status => 'not_found', id => $id } unless $quote;

    my $is_author = defined($quote->{author_id})
        && "$quote->{author_id}" =~ /\A[1-9][0-9]*\z/
        && $principal->user_id == $quote->{author_id};
    my $authorized = $is_author
        || $principal->has_global_level('administrator')
        || $principal->has_channel_level($required);
    return {
        ok => 0, error => 'forbidden', required_channel_level => $required,
    } unless $authorized;

    die "QuoteWriteServiceV3: data service unavailable\n"
        unless defined($quote->{channel_id})
            && "$quote->{channel_id}" =~ /\A[1-9][0-9]*\z/;
    my $sth = $self->_statement($dbh, q{
        DELETE FROM QUOTES
         WHERE id_quotes = ? AND id_channel = ?},
        $id, 0 + $quote->{channel_id});
    eval { $sth->finish };
    return { ok => 1, status => 'deleted', id => $id };
}

sub recall {
    my ($self, %args) = @_;
    my $channel = _channel($args{channel});
    my $id = _id($args{id});
    my $dbh = $self->_dbh;
    my $sth = $self->_statement($dbh, q{
        UPDATE QUOTES q
        JOIN CHANNEL c ON c.id_channel = q.id_channel
           SET q.hits = COALESCE(q.hits, 0) + 1
         WHERE c.name = ? AND q.id_quotes = ?}, $channel, $id);
    eval { $sth->finish };
    return { ok => 1, status => 'recalled', id => $id };
}

1;
