package Mediabot::Plugin::FactoidWriteServiceV3;

use strict;
use warnings;
use utf8;

use Encode qw(encode);
use Scalar::Util qw(blessed);

use constant MAX_KEYWORD_CHARS => 64;
use constant MAX_VALUE_CHARS   => 400;
use constant MAX_VALUE_BYTES   => 400;
use constant MAX_NICK_BYTES    => 64;

sub new {
    my ($class, %args) = @_;
    my $provider = $args{dbh_provider};
    if (!defined $provider) {
        my $dbh = $args{dbh};
        $provider = sub { $dbh };
    }
    die "FactoidWriteServiceV3: database provider is required\n"
        unless ref($provider) eq 'CODE';
    die "FactoidWriteServiceV3: on_stored must be CODE\n"
        if exists($args{on_stored}) && ref($args{on_stored}) ne 'CODE';
    return bless {
        dbh_provider => $provider,
        on_stored    => $args{on_stored},
    }, $class;
}

sub _dbh {
    my ($self) = @_;
    my $dbh = eval { $self->{dbh_provider}->() };
    die "FactoidWriteServiceV3: data service unavailable\n"
        unless $dbh && eval { $dbh->can('prepare') };
    return $dbh;
}

sub _channel {
    my ($channel) = @_;
    die "FactoidWriteServiceV3: invalid channel\n"
        unless defined($channel) && !ref($channel)
            && length($channel) >= 2 && length($channel) <= 128
            && $channel =~ /\A[#&+!][^\x00\x07\r\n ,:]+\z/;
    return "$channel";
}

sub _principal {
    my ($principal) = @_;
    die "FactoidWriteServiceV3: invalid principal\n"
        unless blessed($principal)
            && $principal->isa('Mediabot::Plugin::PrincipalV3');
    return $principal;
}

sub _actor_nick {
    my ($value) = @_;
    die "FactoidWriteServiceV3: invalid actor nickname\n"
        unless defined($value) && !ref($value);
    my $nick = "$value";
    die "FactoidWriteServiceV3: invalid actor nickname\n"
        if $nick =~ /[\r\n\0]/;
    $nick =~ s/^\s+|\s+$//g;
    die "FactoidWriteServiceV3: invalid actor nickname\n"
        unless length($nick)
            && length(encode('UTF-8', $nick)) <= MAX_NICK_BYTES;
    return $nick;
}

sub _keyword {
    my ($value) = @_;
    die "FactoidWriteServiceV3: invalid keyword\n"
        unless defined($value) && !ref($value);
    my $keyword = lc "$value";
    die "FactoidWriteServiceV3: invalid keyword\n"
        if $keyword =~ /[\r\n\0]/;
    $keyword =~ s/^\s+|\s+$//g;
    die "FactoidWriteServiceV3: invalid keyword\n"
        unless length($keyword) <= MAX_KEYWORD_CHARS
            && $keyword =~ /\A[a-z0-9_.-]{1,64}\z/;
    return $keyword;
}

sub _value {
    my ($value) = @_;
    die "FactoidWriteServiceV3: invalid value\n"
        unless defined($value) && !ref($value);
    my $text = "$value";
    die "FactoidWriteServiceV3: invalid value\n"
        if $text =~ /[\r\n\0]/;
    $text =~ s/^\s+|\s+$//g;
    die "FactoidWriteServiceV3: invalid value\n"
        unless length($text)
            && length($text) <= MAX_VALUE_CHARS
            && length(encode('UTF-8', $text)) <= MAX_VALUE_BYTES;
    return $text;
}

sub _delete_level {
    my ($value) = @_;
    $value = 400 unless defined $value;
    die "FactoidWriteServiceV3: invalid delete level\n"
        unless !ref($value) && "$value" =~ /\A[0-9]+\z/
            && $value >= 0 && $value <= 500;
    return 0 + $value;
}

sub _statement {
    my ($self, $dbh, $sql, @bind) = @_;
    die "FactoidWriteServiceV3: data service unavailable\n"
        unless $dbh && eval { $dbh->can('prepare') };
    my $sth = eval { $dbh->prepare($sql) };
    die "FactoidWriteServiceV3: data service unavailable\n" unless $sth;
    my $ok = eval { $sth->execute(@bind) };
    unless ($ok) {
        eval { $sth->finish };
        die "FactoidWriteServiceV3: data service unavailable\n";
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

sub upsert {
    my ($self, %args) = @_;
    my $channel = _channel($args{channel});
    my $principal = _principal($args{principal});
    my $actor_nick = _actor_nick($args{actor_nick});
    my $keyword = _keyword($args{keyword});
    my $value = _value($args{value});
    my $dbh = $self->_dbh;

    my $channel_row = $self->_one($dbh, q{
        SELECT id_channel AS id
          FROM CHANNEL
         WHERE name = ?
         LIMIT 1}, $channel);
    return { ok => 0, error => 'channel_unavailable' }
        unless $channel_row && defined($channel_row->{id})
            && "$channel_row->{id}" =~ /\A[1-9][0-9]*\z/;

    my $channel_id = 0 + $channel_row->{id};
    my $author_id = $principal->authenticated ? $principal->user_id : undef;
    my $sth = $self->_statement($dbh, q{
        INSERT INTO FACTOID
            (id_channel, keyword, value, created_by, created_by_nick)
        VALUES (?, ?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE
            value = VALUES(value), updated_at = CURRENT_TIMESTAMP},
        $channel_id, $keyword, $value, $author_id, $actor_nick);
    eval { $sth->finish };

    if (ref($self->{on_stored}) eq 'CODE') {
        eval { $self->{on_stored}->(
            channel => $channel,
            keyword => $keyword,
            actor_nick => $actor_nick,
            actor_id => $author_id,
            account => $principal->account,
        ) };
    }
    return { ok => 1, status => 'stored', keyword => $keyword };
}

sub delete {
    my ($self, %args) = @_;
    my $channel = _channel($args{channel});
    my $principal = _principal($args{principal});
    my $keyword = _keyword($args{keyword});
    my $required = _delete_level($args{delete_level});

    return { ok => 0, error => 'unauthorized' }
        unless $principal->authenticated;
    my $dbh = $self->_dbh;

    my $factoid = $self->_one($dbh, q{
        SELECT f.id_factoid AS id, f.created_by AS author_id,
               f.id_channel AS channel_id
          FROM FACTOID f
          JOIN CHANNEL c ON c.id_channel = f.id_channel
         WHERE c.name = ? AND f.keyword = ?
         LIMIT 1}, $channel, $keyword);
    return { ok => 1, status => 'not_found', keyword => $keyword }
        unless $factoid;

    my $is_author = defined($factoid->{author_id})
        && "$factoid->{author_id}" =~ /\A[1-9][0-9]*\z/
        && $principal->user_id == $factoid->{author_id};
    my $authorized = $is_author
        || $principal->has_global_level('administrator')
        || $principal->has_channel_level($required);
    return {
        ok => 0, error => 'forbidden', required_channel_level => $required,
    } unless $authorized;

    die "FactoidWriteServiceV3: data service unavailable\n"
        unless defined($factoid->{id})
            && "$factoid->{id}" =~ /\A[1-9][0-9]*\z/
            && defined($factoid->{channel_id})
            && "$factoid->{channel_id}" =~ /\A[1-9][0-9]*\z/;
    my $sth = $self->_statement($dbh, q{
        DELETE FROM FACTOID
         WHERE id_factoid = ? AND id_channel = ?},
        0 + $factoid->{id}, 0 + $factoid->{channel_id});
    eval { $sth->finish };
    return {
        ok => 1, status => 'deleted', keyword => $keyword,
        id => 0 + $factoid->{id},
    };
}

1;
