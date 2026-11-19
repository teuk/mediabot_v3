# MB770 — channel-activity-v3 renders only detached aggregate values.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..",
        "$Bin/../../plugins/channel-activity-v3/lib";
}

sub _slurp_1142 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;
    require Mediabot::Plugin::ActivityComparisonV3;
    require Mediabot::Plugin::ActivityHeatmapV3;
    require Mediabot::Plugin::InvocationV3;
    require Mediabot::Plugin::ManifestV3;
    require Mediabot::Plugin::PrincipalV3;
    require Mediabot::PluginContext;
    require ChannelActivity;

    my $manifest = Mediabot::Plugin::ManifestV3->load_file(
        'plugins/channel-activity-v3/plugin.json',
        expected_name => 'channel-activity-v3');
    $assert->is($manifest->{activation}{default}, 'off',
        'channel activity package is inert by default');
    $assert->is(join(',', @{ $manifest->{capabilities} }),
        'data.channel_activity.read,irc.reply,irc.notice',
        'package requests one read authority and bounded IRC output');
    $assert->is(join(',', sort keys %{ $manifest->{commands} }),
        'compare,heatmap', 'package adopts only compare and heatmap');

    my (@reads, @replies, @notices);
    my $heatmap_hours = [((1) x 6), ((0) x 18)];
    my $heatmap_unavailable = 0;
    my $authority = Mediabot::PluginContext->new(
        plugin => 'channel-activity-v3',
        requested => [qw(data.channel_activity.read irc.reply irc.notice)],
        granted => [qw(data.channel_activity.read irc.reply irc.notice)],
        channel_activity_read_sink => sub {
            my ($invocation, $operation, $args) = @_;
            push @reads, [$operation, { %$args }];
            return { ok => 1, comparison =>
                Mediabot::Plugin::ActivityComparisonV3->new(
                    left => $args->{left}, right => $args->{right},
                    left_count => 30, right_count => 10,
                    period => $args->{period}, period_label => 'last 7d') }
                if $operation eq 'compare';
            return { ok => 0 } if $operation eq 'heatmap' && $heatmap_unavailable;
            return { ok => 1, heatmap =>
                Mediabot::Plugin::ActivityHeatmapV3->new(
                    nick => $args->{nick},
                    hours => $heatmap_hours) }
                if $operation eq 'heatmap';
            die "unexpected activity read $operation";
        },
    );
    my $principal = Mediabot::Plugin::PrincipalV3->anonymous;
    my $invoke = sub {
        my ($command, $args, $channel) = @_;
        return Mediabot::Plugin::InvocationV3->new(
            nick => 'Luna', channel => ($channel // '#test'),
            command => $command, args => $args, source => 'public',
            is_private => 0, authority => $authority, activation => 'on',
            config => {}, principal => $principal,
            reply_sink => sub { push @replies, $_[0]; 1 },
            notice_sink => sub { push @notices, $_[0]; 1 },
        );
    };
    my $plugin = Mediabot::Plugin::ChannelActivity->new(
        context => $authority);

    $plugin->command_compare($authority,
        $invoke->('compare', [qw(Luna Neville 7d)]));
    $assert->is($reads[-1][0], 'compare',
        'compare crosses only the approved aggregate operation');
    $assert->is($reads[-1][1]{period}, '7d',
        'compare passes one normalized bounded period');
    $assert->is($replies[-1],
        '[last 7d] luna: 30 msg(s) (75%) | neville: 10 msg(s) (25%) | luna leads by 20 msg(s)',
        'compare preserves the historical one-line rendering');

    my $before = scalar @replies;
    $plugin->command_heatmap($authority,
        $invoke->('heatmap', ['Luna']));
    $assert->is($reads[-1][0], 'heatmap',
        'heatmap crosses only the approved 24-bucket operation');
    $assert->is($reads[-1][1]{nick}, 'luna',
        'heatmap normalizes its bounded nickname');
    my @heatmap = @replies[$before .. $#replies];
    $assert->is(scalar @heatmap, 6,
        'non-empty heatmap emits one header, four blocks and one peak');
    $assert->is($heatmap[0],
        'luna activity by hour on #test (6 msgs total):',
        'heatmap header preserves the historical format');
    $assert->like($heatmap[1], qr/^00-05  .*  6 msgs$/,
        'heatmap renders the first six-hour block');
    $assert->is($heatmap[-1], 'Peak activity: 00-05 (6 msgs)',
        'heatmap preserves the historical peak line');

    # MB1375: six-hour colors must use the bar's six-hour reference scale.
    # Exercise both native renderers with explicit expected bins and lengths.
    require Mediabot::Stats::Activity;
    require Mediabot::Context;
    {
        no warnings qw(redefine once);
        my (@legacy, @legacy_notices, @gathers);
        local *Mediabot::Stats::Activity::botPrivmsg = sub {
            push @legacy, [@_[1, 2]]; 1;
        };
        local *Mediabot::Stats::Activity::botNotice = sub {
            push @legacy_notices, [@_[1, 2]]; 1;
        };
        local *Mediabot::Helpers::channel_log_gather = sub {
            my ($bot, $dbh, $sql, $bind, $consume, $scope) = @_;
            push @gathers, [@$bind, $scope];
            # Split source buckets to retain live/archive accumulation coverage.
            for my $hour (0 .. 23) {
                my $first = int($heatmap_hours->[$hour] / 2);
                $consume->({h => $hour, cnt => $first});
                $consume->({h => $hour, cnt => $heatmap_hours->[$hour] - $first});
            }
            return {live_ok => !$heatmap_unavailable};
        };
        my @labels = qw(00-05 06-11 12-17 18-23);
        my %colors = (green => "\x0303", yellow => "\x0308", red => "\x0304", none => '');
        for my $case (
            ['empty', '#test', [(0) x 24], 0,
                [[0, 'none', 0], [0, 'none', 0], [0, 'none', 0], [0, 'none', 0]], undef],
            ['one-hour burst', '&test', [100, (0) x 23], 100,
                [[100, 'green', 1], [0, 'none', 0], [0, 'none', 0], [0, 'none', 0]], 0],
            ['threshold edges', '!test', [100,100,39,0,0,0, 100,100,40,0,0,0,
                100,100,100,100,49,0, 100,100,100,100,50,0], 1378,
                [[239, 'green', 3], [240, 'yellow', 4], [449, 'yellow', 7], [450, 'red', 7]], 3],
            ['full and sparse', '+test', [(100) x 6, 1, (0) x 17], 601,
                [[600, 'red', 10], [1, 'green', 1], [0, 'none', 0], [0, 'none', 0]], 0],
            ['equal blocks', '#test', [(2) x 24], 48,
                [[12, 'red', 10], [12, 'red', 10], [12, 'red', 10], [12, 'red', 10]], 0],
        ) {
            my ($label, $channel, $hours, $total, $blocks, $peak) = @$case;
            $heatmap_hours = $hours;
            @replies = @notices = @legacy = @legacy_notices = @gathers = ();
            my @args = $label eq 'empty' ? () : ('LuNa');
            $plugin->command_heatmap($authority, $invoke->('heatmap', \@args, $channel));
            Mediabot::Stats::Activity::mbHeatmap_ctx(Mediabot::Context->new(
                bot => {}, nick => 'Luna', channel => $channel, args => \@args));
            my @expected = ("luna activity by hour on $channel ($total msgs total):");
            for my $b (0 .. 3) {
                my ($count, $color_name, $length) = @{$blocks->[$b]};
                my $color = $colors{$color_name};
                my $bar = $color . chr(0x2588) x $length . ($color ? "\x0f" : '')
                    . chr(0x2591) x (10 - $length);
                push @expected, "$labels[$b]  $bar  $count msgs";
            }
            push @expected, "Peak activity: $labels[$peak] ($blocks->[$peak][0] msgs)"
                if defined $peak;
            $assert->is(join("\n", @replies), join("\n", @expected),
                "mb1375: $label plugin colors, widths, counts and peak");
            my @normalized = map { my $s = $_->[1]; $s =~ s/^\s+//; $s } @legacy;
            $assert->is(join("\n", @normalized), join("\n", @expected),
                "mb1375: $label legacy colors, widths, counts and peak");
            $assert->is(join('|', map {$_->[0]} @legacy), join('|', ($channel) x @expected),
                "mb1375: $label legacy reply targets are preserved");
            $assert->is(join('|', @{$gathers[0]}), "luna|$channel|content",
                "mb1375: $label legacy nickname, channel and archive scope are preserved");
            $assert->is(scalar(@notices) + scalar(@legacy_notices), 0,
                "mb1375: $label emits no error notice");
        }
        $heatmap_unavailable = 1;
        @replies = @notices = @legacy = @legacy_notices = ();
        $plugin->command_heatmap($authority, $invoke->('heatmap', []));
        Mediabot::Stats::Activity::mbHeatmap_ctx(Mediabot::Context->new(
            bot => {}, nick => 'Luna', channel => '#test', args => []));
        $assert->is(scalar(@replies) + scalar(@legacy), 0,
            'mb1375: unavailable reads never publish a partial chart');
        $assert->is(join('|', @notices, @{$legacy_notices[0]}),
            'Database error.|Luna|Database error.', 'mb1375: both paths retain private read errors');
    }

    $plugin->command_compare($authority,
        $invoke->('compare', [qw(Luna Neville never)]));
    $assert->is($notices[-1],
        "Unknown period 'never'. Use: 7d, 4w, 3m, 1y, all",
        'invalid periods stop before the core read facade');

    my $source = _slurp_1142(
        'plugins/channel-activity-v3/lib/ChannelActivity.pm');
    $assert->ok($source !~ /\b(?:DBI|prepare|execute|SELECT|INSERT|UPDATE|DELETE)\b/,
        'package contains no database primitive or SQL');
};
