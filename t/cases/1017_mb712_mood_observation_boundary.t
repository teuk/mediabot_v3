# t/cases/1017_mb712_mood_observation_boundary.t
# =============================================================================
# mb712 — !mood freezes one insertion/time boundary before it observes the
# channel. Sentiment, talkers and peak-hour queries reuse that exact boundary,
# and every query completes before the first IRC response is emitted.
# =============================================================================

use strict;
use warnings;
use utf8;

BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }

use Mediabot::SocialHistory ();

{
    package Ctx1017;
    sub new     { bless { bot => $_[1], nick => $_[2], channel => $_[3] }, $_[0] }
    sub bot     { $_[0]->{bot} }
    sub nick    { $_[0]->{nick} }
    sub channel { $_[0]->{channel} }

    package Metrics1017;
    sub new { bless {}, $_[0] }
    sub inc { 1 }

    package STH1017;
    sub new { bless { owner => $_[1], sql => $_[2], rows => [], i => 0 }, $_[0] }
    sub execute {
        my ($self, @bind) = @_;
        my $sql = $self->{sql};
        my $kind = $sql =~ /MAX\(cl\.id_channel_log\)/ ? 'boundary'
                 : $sql =~ /SELECT cl\.publictext/       ? 'sentiment'
                 : $sql =~ /GROUP BY cl\.nick/          ? 'talkers'
                 : $sql =~ /GROUP BY HOUR\(cl\.ts\)/    ? 'peak'
                 :                                         'unknown';
        push @{$self->{owner}{events}}, [execute => $kind, [@bind], $sql];
        $self->{rows} = $kind eq 'boundary'
            ? [[41, '2026-09-01 09:43:00', '2026-09-01']]
            : $kind eq 'sentiment'
                ? [['salut'], ['message de alice'], ['⚡']]
                : $kind eq 'talkers'
                    ? [{nick => 'mediabotv3', c => 1}, {nick => 'alice', c => 2}]
                    : $kind eq 'peak'
                        ? [{h => 9, c => 3}]
                        : [];
        $self->{i} = 0;
        return 1;
    }
    sub fetchrow_arrayref {
        my ($self) = @_;
        return if $self->{i} >= @{$self->{rows}};
        return $self->{rows}[$self->{i}++];
    }
    sub fetchrow_hashref {
        my ($self) = @_;
        return if $self->{i} >= @{$self->{rows}};
        return $self->{rows}[$self->{i}++];
    }
    sub finish { 1 }

    package DBH1017;
    sub new { bless { events => [] }, $_[0] }
    sub prepare { STH1017->new($_[0], $_[1]) }
}

return sub {
    my ($assert) = @_;

    no warnings qw(redefine once);
    my $dbh = DBH1017->new;
    my @sent;
    local *Mediabot::SocialHistory::botPrivmsg = sub {
        push @{$dbh->{events}}, [send => $_[2]];
        push @sent, $_[2];
        return 1;
    };
    local *Mediabot::SocialHistory::botNotice = sub {
        push @{$dbh->{events}}, [notice => $_[2]];
        return 1;
    };

    my $bot = bless {
        dbh            => $dbh,
        metrics        => Metrics1017->new,
        _mood_cooldown => {},
        _mood_count    => {},
        achievements   => undef,
    }, 'Bot1017';
    my $ctx = Ctx1017->new($bot, 'tester', '#radiocapsule');
    my $ok = eval { Mediabot::SocialHistory::mbMood_ctx($ctx); 1 };
    $assert->ok($ok, 'handler completes');
    $assert->is($@, '', 'handler does not throw');

    my @exec = grep { $_->[0] eq 'execute' } @{$dbh->{events}};
    $assert->is(scalar(@exec), 4, 'one boundary plus three observation queries');
    $assert->is(join(',', map { $_->[1] } @exec),
        'boundary,sentiment,talkers,peak', 'query order is stable');

    my ($first_send) = grep { $dbh->{events}[$_][0] eq 'send' }
                       0 .. $#{$dbh->{events}};
    $assert->is($first_send, 4, 'all observation queries precede first IRC output');

    $assert->is(join('|', @{$exec[0][2]}), '',
        'global primary-key ceiling needs no channel scan');
    $assert->is(join('|', @{$exec[1][2]}),
        '#radiocapsule|41|2026-09-01 09:43:00|2026-09-01 09:43:00',
        'sentiment reuses id and time boundary');
    $assert->is(join('|', @{$exec[2][2]}),
        '#radiocapsule|41|2026-09-01 09:43:00|2026-09-01 09:43:00',
        'talkers reuse exact sentiment boundary');
    $assert->is(join('|', @{$exec[3][2]}),
        '#radiocapsule|41|2026-09-01|2026-09-01 09:43:00',
        'peak reuses id, day and time boundary');

    for my $i (1 .. 3) {
        $assert->like($exec[$i][3], qr/cl\.id_channel_log <= \?/,
            "query $i carries insertion ceiling");
        $assert->like($exec[$i][3], qr/cl\.ts <= \?/,
            "query $i carries time ceiling");
    }

    my $output = join("\n", @sent);
    $assert->like($output, qr/energy: very low .* \(3 msgs\)/,
        'sentiment count stays at boundary total');
    $assert->like($output,
        qr/driven by: mediabotv3 \(1\), alice \(2\)/,
        'talker totals match the same three-row observation');
    $assert->like($output, qr/peak today: 09h-10h \(3 msgs\)/,
        'peak total uses the same observation');
};
