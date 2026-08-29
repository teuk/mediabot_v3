use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

use Mediabot::Spark::Event qw(spark_event_profile);
use Mediabot::Spark::Selector qw(select_spark_event);

return sub {
    my ($assert) = @_;

    my $profile = spark_event_profile('mosaic');
    $assert->is($profile->{interaction}, 'word_mosaic',
        'mb710-1013: Mosaic declares its own explicit response contract');
    $assert->is($profile->{min_recent_humans}, 2,
        'mb710-1013: two real voices are the minimum audience');
    $assert->is($profile->{ai_use}, 'required',
        'mb710-1013: selection requires a possible closing synthesis');

    my (%solo, %small, %social, %crowded, %offline);
    for my $cursor (0 .. 31) {
        for my $row (
            [ \%solo, 'solo', 1, 5, 1 ],
            [ \%small, 'small', 2, 5, 1 ],
            [ \%social, 'social', 4, 7, 1 ],
            [ \%crowded, 'crowded', 8, 8, 1 ],
            [ \%offline, 'social', 4, 7, 0 ],
        ) {
            my ($seen, $regime, $humans, $lines, $ai) = @$row;
            my $pick = select_spark_event(
                recent_humans => $humans,
                context_lines => $lines,
                ai_available => $ai,
                audience_regime => $regime,
                cursor => $cursor,
            );
            $seen->{ $pick->{kind} }++
                if ($pick->{action} // '') eq 'select';
        }
    }

    $assert->ok(!$solo{mosaic},
        'mb710-1013: solo schedule never pretends to be collective');
    $assert->ok($small{mosaic} && $social{mosaic} && $crowded{mosaic},
        'mb710-1013: every genuinely collective regime can reach Mosaic');
    $assert->ok(!$offline{mosaic},
        'mb710-1013: Mosaic fails closed without closing AI');
    $assert->ok($crowded{portal} && $crowded{mosaic} && $crowded{reaction},
        'mb710-1013: crowded rooms retain varied behavior instead of one dominant game');
};
