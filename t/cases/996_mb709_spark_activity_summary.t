# t/cases/996_mb709_spark_activity_summary.t
use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use Mediabot::Spark::Observer;

return sub {
    my ($assert) = @_;

    my $now = 20_000;
    my $observer = Mediabot::Spark::Observer->new(clock => sub { $now });
    for my $row (
        [ Alice => 'premiere ligne confidentielle' ],
        [ Bob   => 'deuxieme ligne confidentielle' ],
        [ Carol => 'troisieme ligne confidentielle' ],
        [ Alice => 'quatrieme ligne confidentielle' ],
        [ Bob   => 'cinquieme ligne confidentielle' ],
        [ Carol => 'sixieme ligne confidentielle' ],
    ) {
        $observer->observe_public_line(
            channel => '#Spark', nick => $row->[0], bot_nick => 'Mediabot',
            message => $row->[1], command_char => '!',
        );
        $now++;
    }
    $now += 54;

    my $summary = $observer->activity_summary(
        '#spark', window_seconds => 600,
    );
    $assert->is($summary->{line_count}, 6,
        'mb709-996: momentum summary counts recent eligible lines');
    $assert->is($summary->{distinct_humans}, 3,
        'mb709-996: momentum summary counts case-canonical distinct humans');
    $assert->is($summary->{quiet_for_seconds}, 55,
        'mb709-996: momentum summary measures the current breathing pause');
    $assert->is($summary->{window_seconds}, 600,
        'mb709-996: momentum summary exposes the bounded activity window');

    my $serialized = join(' ', map {
        defined($summary->{$_}) ? "$summary->{$_}" : ''
    } sort keys %$summary);
    $assert->unlike($serialized, qr/confidentielle|Alice|Bob|Carol/i,
        'mb709-996: activity summary exports neither text nor nicknames');
    $assert->unlike(join(',', sort keys %$summary), qr/(?:message|text|nick)/,
        'mb709-996: activity summary schema is metadata-only');

    $now += 601;
    my $aged = $observer->activity_summary('#SPARK', window_seconds => 600);
    $assert->is($aged->{line_count}, 0,
        'mb709-996: activity outside the momentum window is not counted');
    $assert->is($aged->{distinct_humans}, 0,
        'mb709-996: expired participant identities are not projected');
};
