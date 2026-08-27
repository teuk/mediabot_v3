use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use Mediabot::VDM qw(evaluate_vdm_gate vdm_chanset_name);

return sub {
    my ($assert) = @_;

    $assert->is(vdm_chanset_name(), 'VDM',
        'mb704-968: canonical chanset name is VDM');

    my $manual = evaluate_vdm_gate(
        mode => 'manual', channel => '#test', vdm_enabled => 1, spark_enabled => 0,
    );
    $assert->is($manual->{action}, 'allow',
        'mb704-968: manual !vdm needs +VDM but not +Spark');

    my $manual_off = evaluate_vdm_gate(
        mode => 'manual', channel => '#test', vdm_enabled => 0,
    );
    $assert->is($manual_off->{reason}, 'vdm_disabled',
        'mb704-968: manual !vdm is blocked by -VDM');

    my $spark_ok = evaluate_vdm_gate(
        mode => 'spark', channel => '#test', vdm_enabled => 1, spark_enabled => 1,
    );
    $assert->is($spark_ok->{action}, 'allow',
        'mb704-968: Spark-assisted VDM requires +Spark +VDM');

    my $spark_off = evaluate_vdm_gate(
        mode => 'spark', channel => '#test', vdm_enabled => 1, spark_enabled => 0,
    );
    $assert->is($spark_off->{reason}, 'spark_disabled',
        'mb704-968: +VDM alone never authorizes automatic Spark VDM');

    my $vdm_off = evaluate_vdm_gate(
        mode => 'spark', channel => '#test', vdm_enabled => 0, spark_enabled => 1,
    );
    $assert->is($vdm_off->{reason}, 'vdm_disabled',
        'mb704-968: +Spark alone never authorizes VDM');

    for my $case (
        [ { mode => 'manual', channel => 'Alice', vdm_enabled => 1 }, 'private_target' ],
        [ { mode => 'manual', channel => '#test', vdm_enabled => 1, runtime_active => 0 }, 'runtime_inactive' ],
        [ { mode => 'manual', channel => '#test', vdm_enabled => 1, irc_connected => 0 }, 'irc_disconnected' ],
        [ { mode => 'manual', channel => '#test', vdm_enabled => 1, channel_joined => 0 }, 'not_joined' ],
        [ { mode => 'future', channel => '#test', vdm_enabled => 1 }, 'invalid_mode' ],
    ) {
        my ($args, $reason) = @$case;
        my $d = evaluate_vdm_gate(%$args);
        $assert->is($d->{action}, 'skip',
            "mb704-968: $reason gate fails closed");
        $assert->is($d->{reason}, $reason,
            "mb704-968: $reason reason is explicit");
    }
};
