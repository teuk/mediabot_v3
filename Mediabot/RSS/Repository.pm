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
               COUNT(ri.id_rss_item) AS item_count,
               SUM(CASE WHEN ri.id_rss_item IS NOT NULL AND ri.announced_at IS NULL
                        THEN 1 ELSE 0 END) AS pending_count,
               MAX(CASE WHEN rf.last_poll_at IS NULL THEN 0
                        ELSE GREATEST(0, TIMESTAMPDIFF(SECOND, NOW(),
                             TIMESTAMPADD(SECOND, rf.poll_interval, rf.last_poll_at)))
                   END) AS next_poll_in
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
               COUNT(ri.id_rss_item) AS item_count,
               SUM(CASE WHEN ri.id_rss_item IS NOT NULL AND ri.announced_at IS NULL
                        THEN 1 ELSE 0 END) AS pending_count,
               MAX(CASE WHEN rf.last_poll_at IS NULL THEN 0
                        ELSE GREATEST(0, TIMESTAMPDIFF(SECOND, NOW(),
                             TIMESTAMPADD(SECOND, rf.poll_interval, rf.last_poll_at)))
                   END) AS next_poll_in
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


sub list_due_feeds {
    my ($self, $limit) = @_;
    $limit = 20 unless defined($limit) && $limit =~ /^\d+$/;
    $limit = 1 if $limit < 1;
    $limit = 100 if $limit > 100;

    my $sth = $self->dbh->prepare(q{
        SELECT rf.id_rss_feed, rf.id_channel, c.name AS channel, rf.label, rf.url,
               rf.enabled, rf.poll_interval, rf.announce_limit, rf.etag,
               rf.last_modified, rf.last_poll_at, rf.last_success_at,
               rf.last_error_at, rf.last_error
          FROM RSS_FEED rf
          JOIN CHANNEL c ON c.id_channel = rf.id_channel
         WHERE rf.enabled = 1
           AND (rf.last_poll_at IS NULL
                OR TIMESTAMPADD(SECOND, rf.poll_interval, rf.last_poll_at) <= NOW())
         ORDER BY COALESCE(rf.last_poll_at, '1970-01-01 00:00:00'), rf.id_rss_feed
         LIMIT ?
    }) or die "RSS due-feed prepare failed";
    $sth->execute($limit) or die "RSS due-feed execute failed";
    my @rows;
    while (my $row = $sth->fetchrow_hashref) { push @rows, { %$row } }
    $sth->finish;
    return \@rows;
}

sub is_feed_enabled {
    my ($self, $id_feed) = @_;
    die "invalid RSS feed id" unless defined($id_feed) && $id_feed =~ /^\d+$/;
    my $sth = $self->dbh->prepare(
        'SELECT enabled FROM RSS_FEED WHERE id_rss_feed = ? LIMIT 1'
    ) or die "RSS enabled lookup prepare failed";
    $sth->execute($id_feed) or die "RSS enabled lookup execute failed";
    my ($enabled) = $sth->fetchrow_array;
    $sth->finish;
    return defined($enabled) && $enabled ? 1 : 0;
}

sub insert_item {
    my ($self, $id_feed, $item, %opts) = @_;
    die "invalid RSS feed id" unless defined($id_feed) && $id_feed =~ /^\d+$/;
    return 0 unless ref($item) eq 'HASH';

    my $key = $item->{item_key};
    my $title = $item->{title};
    return 0 unless defined($key) && $key =~ /^[0-9a-f]{64}$/i;
    return 0 unless defined($title) && !ref($title) && length($title);

    my $url = defined($item->{url}) && !ref($item->{url}) && length($item->{url})
        ? substr($item->{url}, 0, 2048) : undef;
    my $published = defined($item->{published}) && !ref($item->{published})
        ? substr($item->{published}, 0, 160) : undef;
    $title = substr($title, 0, 600);
    my $announced = $opts{announced} ? 1 : 0;

    my $sth = $self->dbh->prepare(q{
        INSERT IGNORE INTO RSS_ITEM
            (id_rss_feed, item_key, title, url, published_raw, announced_at)
        VALUES (?, ?, ?, ?, ?, IF(? = 1, NOW(), NULL))
    }) or die "RSS item insert prepare failed";
    $sth->execute($id_feed, lc($key), $title, $url, $published, $announced)
        or die "RSS item insert execute failed";
    my $rows = $sth->rows;
    $sth->finish;
    return $rows > 0 ? 1 : 0;
}

sub pending_items {
    my ($self, $id_feed, $limit) = @_;
    die "invalid RSS feed id" unless defined($id_feed) && $id_feed =~ /^\d+$/;
    $limit = 5 unless defined($limit) && $limit =~ /^\d+$/;
    $limit = 1 if $limit < 1;
    $limit = 10 if $limit > 10;

    my $sth = $self->dbh->prepare(q{
        SELECT id_rss_item, item_key, title, url, published_raw, seen_at
          FROM RSS_ITEM
         WHERE id_rss_feed = ? AND announced_at IS NULL
         ORDER BY id_rss_item ASC
         LIMIT ?
    }) or die "RSS pending prepare failed";
    $sth->execute($id_feed, $limit) or die "RSS pending execute failed";
    my @rows;
    while (my $row = $sth->fetchrow_hashref) { push @rows, { %$row } }
    $sth->finish;
    return \@rows;
}

sub mark_announced {
    my ($self, $id_feed, $keys) = @_;
    die "invalid RSS feed id" unless defined($id_feed) && $id_feed =~ /^\d+$/;
    return 0 unless ref($keys) eq 'ARRAY' && @$keys;
    my @keys = grep { defined($_) && !ref($_) && /^[0-9a-f]{64}$/i } @$keys;
    return 0 unless @keys;
    splice @keys, 10 if @keys > 10;

    my $marks = join(',', ('?') x @keys);
    my $sql = "UPDATE RSS_ITEM SET announced_at = NOW() "
            . "WHERE id_rss_feed = ? AND item_key IN ($marks) AND announced_at IS NULL";
    my $sth = $self->dbh->prepare($sql) or die "RSS announce prepare failed";
    $sth->execute($id_feed, map { lc($_) } @keys) or die "RSS announce execute failed";
    my $rows = $sth->rows;
    $sth->finish;
    return $rows > 0 ? $rows : 0;
}

sub record_poll_success {
    my ($self, $id_feed, %meta) = @_;
    die "invalid RSS feed id" unless defined($id_feed) && $id_feed =~ /^\d+$/;
    my $etag = defined($meta{etag}) && !ref($meta{etag}) ? substr($meta{etag}, 0, 255) : undef;
    my $modified = defined($meta{last_modified}) && !ref($meta{last_modified})
        ? substr($meta{last_modified}, 0, 255) : undef;
    my $sth = $self->dbh->prepare(q{
        UPDATE RSS_FEED
           SET last_poll_at = NOW(), last_success_at = NOW(),
               last_error_at = NULL, last_error = NULL,
               etag = COALESCE(?, etag),
               last_modified = COALESCE(?, last_modified)
         WHERE id_rss_feed = ?
    }) or die "RSS poll-success prepare failed";
    $sth->execute($etag, $modified, $id_feed) or die "RSS poll-success execute failed";
    $sth->finish;
    return 1;
}

sub record_not_modified {
    my ($self, $id_feed, %meta) = @_;
    return $self->record_poll_success($id_feed, %meta);
}

sub record_poll_error {
    my ($self, $id_feed, $error) = @_;
    die "invalid RSS feed id" unless defined($id_feed) && $id_feed =~ /^\d+$/;
    $error = 'unknown RSS poll error' unless defined($error) && !ref($error) && length($error);
    $error =~ s/[\r\n\0]+/ /g;
    $error = substr($error, 0, 255);
    my $sth = $self->dbh->prepare(q{
        UPDATE RSS_FEED
           SET last_poll_at = NOW(), last_error_at = NOW(), last_error = ?
         WHERE id_rss_feed = ?
    }) or die "RSS poll-error prepare failed";
    $sth->execute($error, $id_feed) or die "RSS poll-error execute failed";
    $sth->finish;
    return 1;
}

1;
