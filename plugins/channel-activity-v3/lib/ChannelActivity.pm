package Mediabot::Plugin::ChannelActivity;

use strict;
use warnings;
use utf8;

sub new {
    my ($class, %args) = @_;
    return bless { context => $args{context} }, $class;
}

sub start { $_[0]{started} = 1; 1 }
sub stop  { $_[0]{started} = 0; 1 }

sub _channel_ok {
    my ($invocation) = @_;
    my $channel = $invocation->channel;
    return defined($channel) && !ref($channel)
        && $channel =~ /\A[#&+!][^\x00\x07\r\n ,:]+\z/ ? 1 : 0;
}

sub _period {
    my ($value) = @_;
    return ('all', 'all time')
        unless defined($value) && !ref($value) && length($value);
    my $period = lc "$value";
    return ('all', 'all time') if $period eq 'all';
    my ($count, $unit) = $period =~ /\A([1-9][0-9]*)([dwmy])\z/
        or return;
    my %maximum = (d => 365, w => 52, m => 24, y => 10);
    return if $count > $maximum{$unit};
    return ("$count$unit", "last $count$unit");
}

sub command_compare {
    my ($self, $context, $invocation) = @_;
    my @args = @{ $invocation->args };
    return $context->notice($invocation,
        'Syntax: compare <nick1> <nick2> [Nd|Nw|Nm|all]  (ex: 7d 4w 3m)')
        unless _channel_ok($invocation) && @args >= 2;

    my ($left, $right) = (lc($args[0]), lc($args[1]));
    my @period = _period($args[2]);
    return $context->notice($invocation,
        "Unknown period '$args[2]'. Use: 7d, 4w, 3m, 1y, all")
        unless @period;

    my $result = $context->activity_compare(
        $invocation, $left, $right, period => $period[0]);
    return $context->notice($invocation, 'Database error.')
        unless $result && $result->{ok} && $result->{comparison};

    my $comparison = $result->{comparison};
    my $left_count = $comparison->left_count;
    my $right_count = $comparison->right_count;
    my $difference = abs($left_count - $right_count);
    my $leader = $left_count > $right_count ? $comparison->left
        : $left_count < $right_count ? $comparison->right : undef;
    my $verdict = $leader
        ? "$leader leads by $difference msg(s)" : 'tied!';
    my $total = $left_count + $right_count;
    my $left_percent = $total > 0 ? int(100 * $left_count / $total) : 0;
    my $right_percent = $total > 0 ? 100 - $left_percent : 0;

    return $context->reply($invocation, sprintf(
        '[%s] %s: %d msg(s) (%d%%) | %s: %d msg(s) (%d%%) | %s',
        $comparison->period_label,
        $comparison->left, $left_count, $left_percent,
        $comparison->right, $right_count, $right_percent,
        $verdict,
    ));
}

sub command_heatmap {
    my ($self, $context, $invocation) = @_;
    return $context->notice($invocation,
        'Syntax: heatmap [nick]  (use it in a channel)')
        unless _channel_ok($invocation);

    my @args = @{ $invocation->args };
    my $target = @args ? lc($args[0]) : lc($invocation->nick);
    my $result = $context->activity_heatmap($invocation, $target);
    return $context->notice($invocation, 'Database error.')
        unless $result && $result->{ok} && $result->{heatmap};

    my $heatmap = $result->{heatmap};
    my @hours = @{ $heatmap->hours };
    my $channel = $invocation->channel;
    $context->reply($invocation,
        $heatmap->nick . " activity by hour on $channel ("
        . $heatmap->total . ' msgs total):');

    my $maximum = (sort { $b <=> $a } @hours)[0] || 1;
    my @labels = ('00-05', '06-11', '12-17', '18-23');
    my @totals;
    for my $block (0 .. 3) {
        my $total = 0;
        $total += $hours[$block * 6 + $_] for 0 .. 5;
        push @totals, $total;
        my $bar_length = int(10 * $total / ($maximum * 6 || 1));
        $bar_length = 1 if $total > 0 && $bar_length == 0;
        my $ratio = $maximum > 0 ? $total / $maximum : 0;
        my $color = $ratio >= 0.75 ? "\x0304"
            : $ratio >= 0.40 ? "\x0308"
            : $ratio > 0 ? "\x0303" : '';
        my $reset = length($color) ? "\x0f" : '';
        my $bar = $color . chr(0x2588) x $bar_length . $reset
            . chr(0x2591) x (10 - $bar_length);
        $context->reply($invocation,
            sprintf('  %s  %s  %d msgs', $labels[$block], $bar, $total));
    }

    my ($peak) = sort { $totals[$b] <=> $totals[$a] } 0 .. 3;
    if ($totals[$peak] > 0) {
        $context->reply($invocation,
            "  Peak activity: $labels[$peak] ($totals[$peak] msgs)");
    }
    return 1;
}

1;
