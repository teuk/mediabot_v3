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
            return { ok => 1, heatmap =>
                Mediabot::Plugin::ActivityHeatmapV3->new(
                    nick => $args->{nick},
                    hours => [((1) x 6), ((0) x 18)]) }
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
