package Mediabot::Plugin::ChannelActivityServiceV3;

use strict;
use warnings;
use utf8;

use Mediabot::Plugin::ActivityComparisonV3;
use Mediabot::Plugin::ActivityHeatmapV3;

sub new {
    my ($class, %args) = @_;
    my $gatherer = $args{gatherer};
    if (!defined $gatherer) {
        my $dbh_provider = $args{dbh_provider};
        my $bot_provider = $args{bot_provider};
        die "ChannelActivityServiceV3: database provider is required\n"
            unless ref($dbh_provider) eq 'CODE';
        die "ChannelActivityServiceV3: bot provider is required\n"
            unless ref($bot_provider) eq 'CODE';
        $gatherer = sub {
            my ($sql, $bind, $consumer, $scope) = @_;
            my $dbh = eval { $dbh_provider->() };
            my $bot = eval { $bot_provider->() };
            die "ChannelActivityServiceV3: data service unavailable\n"
                unless $dbh && eval { $dbh->can('prepare') } && $bot;
            require Mediabot::Helpers;
            return Mediabot::Helpers::channel_log_gather(
                $bot, $dbh, $sql, $bind, $consumer, $scope);
        };
    }
    die "ChannelActivityServiceV3: gatherer is required\n"
        unless ref($gatherer) eq 'CODE';
    return bless { gatherer => $gatherer }, $class;
}

sub _channel {
    my ($channel) = @_;
    die "ChannelActivityServiceV3: invalid channel\n"
        unless defined($channel) && !ref($channel)
            && length($channel) >= 2 && length($channel) <= 128
            && $channel =~ /\A[#&+!][^\x00\x07\r\n ,:]+\z/;
    return "$channel";
}

sub _nick {
    my ($nick) = @_;
    die "ChannelActivityServiceV3: invalid nickname\n"
        unless defined($nick) && !ref($nick)
            && length($nick) >= 1 && length($nick) <= 64
            && $nick =~ /\A[^\x00-\x20\x7f,:]+\z/;
    return lc "$nick";
}

sub _period {
    my ($value) = @_;
    $value = 'all' unless defined $value && !ref($value) && length($value);
    $value = lc "$value";
    return ('all', '', 'all time') if $value eq 'all';
    my ($count, $unit) = $value =~ /\A([1-9][0-9]*)([dwmy])\z/
        or die "ChannelActivityServiceV3: invalid period\n";
    my %maximum = (d => 365, w => 52, m => 24, y => 10);
    die "ChannelActivityServiceV3: period exceeds bound\n"
        if $count > $maximum{$unit};
    my %sql_unit = (d => 'DAY', w => 'WEEK', m => 'MONTH', y => 'YEAR');
    return (
        "$count$unit",
        "AND cl.ts >= NOW() - INTERVAL $count $sql_unit{$unit}",
        "last $count$unit",
    );
}

sub _gather {
    my ($self, $sql, $bind, $consumer) = @_;
    my $result = eval {
        $self->{gatherer}->($sql, [ @$bind ], $consumer, 'content');
    };
    die "ChannelActivityServiceV3: data service unavailable\n"
        unless $result && ref($result) eq 'HASH' && $result->{live_ok};
    return $result;
}

sub compare {
    my ($self, %args) = @_;
    my $channel = _channel($args{channel});
    my $left = _nick($args{left});
    my $right = _nick($args{right});
    die "ChannelActivityServiceV3: nicknames must differ\n"
        if $left eq $right;
    my ($period, $period_sql, $period_label) = _period($args{period});
    my %counts = ($left => 0, $right => 0);
    $self->_gather(qq{
        SELECT cl.nick AS nick, COUNT(*) AS count
          FROM __CLSRC__ cl
          JOIN CHANNEL c ON c.id_channel = cl.id_channel
         WHERE c.name = ? AND LOWER(cl.nick) IN (?, ?)
           AND cl.event_type IN ('public','action')
           $period_sql
         GROUP BY cl.nick
    }, [ $channel, $left, $right ], sub {
        my ($row) = @_;
        return unless ref($row) eq 'HASH';
        my $nick = lc($row->{nick} // '');
        return unless exists $counts{$nick};
        my $count = $row->{count};
        die "ChannelActivityServiceV3: invalid aggregate\n"
            unless defined($count) && !ref($count)
                && "$count" =~ /\A[0-9]+\z/;
        $counts{$nick} += 0 + $count;
    });
    return {
        ok => 1,
        comparison => Mediabot::Plugin::ActivityComparisonV3->new(
            left => $left, right => $right,
            left_count => $counts{$left}, right_count => $counts{$right},
            period => $period, period_label => $period_label,
        ),
    };
}

sub heatmap {
    my ($self, %args) = @_;
    my $channel = _channel($args{channel});
    my $nick = _nick($args{nick});
    my @hours = (0) x 24;
    $self->_gather(q{
        SELECT HOUR(cl.ts) AS hour, COUNT(*) AS count
          FROM __CLSRC__ cl
          JOIN CHANNEL c ON c.id_channel = cl.id_channel
         WHERE c.name = ? AND LOWER(cl.nick) = ?
           AND cl.event_type IN ('public','action')
         GROUP BY HOUR(cl.ts)
         ORDER BY hour
    }, [ $channel, $nick ], sub {
        my ($row) = @_;
        return unless ref($row) eq 'HASH';
        my $hour = $row->{hour};
        my $count = $row->{count};
        die "ChannelActivityServiceV3: invalid hour aggregate\n"
            unless defined($hour) && !ref($hour)
                && "$hour" =~ /\A(?:[0-9]|1[0-9]|2[0-3])\z/
                && defined($count) && !ref($count)
                && "$count" =~ /\A[0-9]+\z/;
        $hours[$hour] += 0 + $count;
    });
    return {
        ok => 1,
        heatmap => Mediabot::Plugin::ActivityHeatmapV3->new(
            nick => $nick, hours => \@hours),
    };
}

1;
