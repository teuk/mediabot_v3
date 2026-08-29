use strict;
use warnings;
use utf8;

BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use Mediabot::Spark::Event qw(spark_event_kinds spark_event_profile);
use Mediabot::Spark::Selector qw(select_spark_event);

return sub {
    my ($assert) = @_;
    my $kinds = spark_event_kinds();
    $assert->is(join(',', @$kinds), 'fork,portal,callback,reaction,mosaic,stage_cue,vdm',
        'mb709: Stage Cue joins the catalog while VDM remains a distinct source-backed family');
    my $p = spark_event_profile('vdm');
    $assert->is($p->{ai_use}, 'never', 'mb704-979: VDM never consumes the AI generator');
    $assert->is($p->{min_recent_humans}, 3, 'mb704-979: auto VDM requires a real recent audience');

    my %off_seen;
    my %on_seen;
    for my $cursor (0 .. 15) {
        my $off = select_spark_event(recent_humans=>3, context_lines=>5, ai_available=>1,
            vdm_enabled=>0, cursor=>$cursor);
        $off_seen{$off->{kind}}++ if ($off->{action} // '') eq 'select';

        my $on = select_spark_event(recent_humans=>3, context_lines=>5, ai_available=>1,
            vdm_enabled=>1, cursor=>$cursor);
        $on_seen{$on->{kind}}++ if ($on->{action} // '') eq 'select';
    }
    $assert->ok(!$off_seen{vdm}, 'mb704-979: -VDM removes VDM from Spark eligibility');
    $assert->ok($on_seen{vdm}, 'mb708: contextual schedule still reaches VDM when +VDM authorizes it');
    $assert->ok($on_seen{reaction} && $on_seen{callback} && $on_seen{fork},
        'mb708: contextual schedule provides multiple social families instead of a Fork-only loop');
    $assert->ok(!$on_seen{stage_cue},
        'mb709: Stage Cue cannot leak into the long-silence selector');
};
