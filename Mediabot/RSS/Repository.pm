package Mediabot::RSS::Repository;

use strict;
use warnings;
use utf8;

use Digest::SHA qw(sha256_hex);
use Mediabot::RSS qw(canonical_feed_url normalize_feed_label);

sub new {
    my ($class, %args) = @_;
    die "dbh is required" unless $args{dbh};
    return bless { dbh => $args{dbh} }, $class;
}

sub dbh { $_[0]->{dbh} }

sub channel_id {
    my ($self, $channel) = @_;
    return undef unless defined $channel && $channel =~ /^[#&!+]/;
    my $sth = $self->dbh->prepare('SELECT id_channel FROM CHANNEL WHERE name = ? LIMIT 1')
        or die "RSS channel lookup prepare failed";
    $sth->execute($channel) or die "RSS channel lookup execute failed";
    my ($id) = $sth->fetchrow_array;
    $sth->finish;
    return $id;
}

sub list_feeds {
    my ($self, $channel) = @_;
    my $sth = $self->dbh->prepare(q{
        SELECT rf.id_rss_feed, rf.id_channel, c.name AS channel, rf.label, rf.url,
               rf.enabled, rf.poll_interval, rf.announce_limit, rf.last_poll_at,
               rf.last_success_at, rf.last_error_at, rf.last_error,
               COUNT(ri.id_rss_item) AS item_count
          FROM RSS_FEED rf
          JOIN CHANNEL c ON c.id_channel = rf.id_channel
          LEFT JOIN RSS_ITEM ri ON ri.id_rss_feed = rf.id_rss_feed
         WHERE c.name = ?
         GROUP BY rf.id_rss_feed, rf.id_channel, c.name, rf.label, rf.url,
                  rf.enabled, rf.poll_interval, rf.announce_limit, rf.last_poll_at,
                  rf.last_success_at, rf.last_error_at, rf.last_error
         ORDER BY rf.label
    }) or die "RSS list prepare failed";
    $sth->execute($channel) or die "RSS list execute failed";
    my @rows;
    while (my $row = $sth->fetchrow_hashref) { push @rows, { %$row } }
    $sth->finish;
    return \@rows;
}

sub get_feed {
    my ($self, $channel, $label) = @_;
    $label = normalize_feed_label($label);
    return undef unless defined $label;
    my $sth = $self->dbh->prepare(q{
        SELECT rf.id_rss_feed, rf.id_channel, c.name AS channel, rf.label, rf.url,
               rf.url_hash, rf.enabled, rf.poll_interval, rf.announce_limit,
               rf.etag, rf.last_modified, rf.last_poll_at, rf.last_success_at,
               rf.last_error_at, rf.last_error, rf.created_by, rf.created_by_nick,
               rf.created_at, rf.updated_at,
               COUNT(ri.id_rss_item) AS item_count
          FROM RSS_FEED rf
          JOIN CHANNEL c ON c.id_channel = rf.id_channel
          LEFT JOIN RSS_ITEM ri ON ri.id_rss_feed = rf.id_rss_feed
         WHERE c.name = ? AND rf.label = ?
         GROUP BY rf.id_rss_feed, rf.id_channel, c.name, rf.label, rf.url,
                  rf.url_hash, rf.enabled, rf.poll_interval, rf.announce_limit,
                  rf.etag, rf.last_modified, rf.last_poll_at, rf.last_success_at,
                  rf.last_error_at, rf.last_error, rf.created_by, rf.created_by_nick,
                  rf.created_at, rf.updated_at
         LIMIT 1
    }) or die "RSS get prepare failed";
    $sth->execute($channel, $label) or die "RSS get execute failed";
    my $row = $sth->fetchrow_hashref;
    $sth->finish;
    return $row ? { %$row } : undef;
}

sub add_feed {
    my ($self, %args) = @_;
    my $label = normalize_feed_label($args{label});
    my $url   = canonical_feed_url($args{url});
    die "invalid RSS label" unless defined $label;
    die "invalid RSS URL"   unless defined $url;
    die "invalid channel id" unless defined($args{id_channel}) && $args{id_channel} =~ /^\d+$/;

    my $poll = defined($args{poll_interval}) ? int($args{poll_interval}) : 1800;
    my $max  = defined($args{announce_limit}) ? int($args{announce_limit}) : 5;
    die "invalid poll interval" unless $poll >= 300 && $poll <= 86400;
    die "invalid announce limit" unless $max >= 1 && $max <= 10;

    my $uid = defined($args{created_by}) && $args{created_by} =~ /^\d+$/
        ? 0 + $args{created_by} : undef;
    my $nick = defined($args{created_by_nick}) ? substr($args{created_by_nick}, 0, 64) : undef;
    my $hash = sha256_hex($url);

    my $sth = $self->dbh->prepare(q{
        INSERT INTO RSS_FEED
            (id_channel, label, url, url_hash, poll_interval, announce_limit,
             created_by, created_by_nick)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    }) or die "RSS add prepare failed";
    my $ok = $sth->execute(
        $args{id_channel}, $label, $url, $hash, $poll, $max, $uid, $nick
    );
    my $err = $sth->errstr;
    $sth->finish;
    die "RSS add execute failed: " . ($err // 'unknown') unless $ok;
    return 1;
}

sub delete_feed {
    my ($self, $channel, $label) = @_;
    my $feed = $self->get_feed($channel, $label) or return 0;
    my $sth = $self->dbh->prepare('DELETE FROM RSS_FEED WHERE id_rss_feed = ?')
        or die "RSS delete prepare failed";
    $sth->execute($feed->{id_rss_feed}) or die "RSS delete execute failed";
    my $rows = $sth->rows;
    $sth->finish;
    return $rows > 0 ? 1 : 0;
}

sub update_feed_setting {
    my ($self, $channel, $label, $setting, $value) = @_;
    my $feed = $self->get_feed($channel, $label) or return 0;
    my ($column, $normalized);

    if ($setting eq 'interval') {
        return -1 unless defined($value) && $value =~ /^\d+$/ && $value >= 5 && $value <= 1440;
        ($column, $normalized) = ('poll_interval', int($value) * 60);
    }
    elsif ($setting eq 'max') {
        return -1 unless defined($value) && $value =~ /^\d+$/ && $value >= 1 && $value <= 10;
        ($column, $normalized) = ('announce_limit', int($value));
    }
    elsif ($setting eq 'enabled') {
        return -1 unless defined $value;
        my $v = lc $value;
        return -1 unless $v =~ /^(?:1|0|on|off|yes|no)$/;
        ($column, $normalized) = ('enabled', $v =~ /^(?:1|on|yes)$/ ? 1 : 0);
    }
    else {
        return -1;
    }

    my %allowed = map { $_ => 1 } qw(poll_interval announce_limit enabled);
    die "unsafe RSS setting column" unless $allowed{$column};
    my $sth = $self->dbh->prepare("UPDATE RSS_FEED SET $column = ? WHERE id_rss_feed = ?")
        or die "RSS update prepare failed";
    $sth->execute($normalized, $feed->{id_rss_feed}) or die "RSS update execute failed";
    $sth->finish;
    return 1;
}

1;
