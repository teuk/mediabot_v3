use strict;
use warnings;
use utf8;

BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use Mediabot::Spark::Event qw(spark_event_kinds spark_event_profile);
use Mediabot::Spark::Selector qw(select_spark_event);

return sub {
    my ($assert) = @_;
    my $kinds = spark_event_kinds();
    $assert->is(join(',', @$kinds), 'fork,portal,callback,vdm',
        'mb704-979: VDM is appended as the fourth Spark event family');
    my $p = spark_event_profile('vdm');
    $assert->is($p->{ai_use}, 'never', 'mb704-979: VDM never consumes the AI generator');
    $assert->is($p->{min_recent_humans}, 3, 'mb704-979: auto VDM requires a real recent audience');

    my $off = select_spark_event(recent_humans=>3, context_lines=>5, ai_available=>1,
        vdm_enabled=>0, cursor=>3);
    $assert->ok($off->{kind} ne 'vdm', 'mb704-979: -VDM removes VDM from Spark eligibility');

    my $on = select_spark_event(recent_humans=>3, context_lines=>5, ai_available=>1,
        vdm_enabled=>1, cursor=>3);
    $assert->is($on->{kind}, 'vdm', 'mb704-979: +Spark caller may select VDM only when +VDM is supplied');
};
