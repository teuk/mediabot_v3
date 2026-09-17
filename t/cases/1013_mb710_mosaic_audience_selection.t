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
    $assert->is($profile->{lane}, 'retired',
        'mb739-1013: Mosaic is retained only for rolling-state compatibility');
    $assert->ok(!$profile->{selectable},
        'mb739-1013: no new Mosaic can be selected');

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

    $assert->ok(!$solo{mosaic} && !$small{mosaic} && !$social{mosaic}
            && !$crowded{mosaic} && !$offline{mosaic},
        'mb739-1013: Mosaic is unreachable in every audience regime');
    $assert->ok($solo{aside} && $solo{micro_scene},
        'mb739-1013: solo rooms receive autonomous variety');
    $assert->ok($crowded{portal} && $crowded{micro_scene} && $crowded{reaction},
        'mb739-1013: crowded rooms retain collaborative, autonomous and contextual variety');
};
