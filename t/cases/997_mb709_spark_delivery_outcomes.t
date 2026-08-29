# t/cases/997_mb709_spark_delivery_outcomes.t
use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use Mediabot::Spark::Event qw(
    spark_event_kinds spark_event_requires_response
);
use Mediabot::Spark::State;

return sub {
    my ($assert) = @_;

    my %expected = (
        fork => 1, portal => 1, mosaic => 1,
        callback => 0, reaction => 0, stage_cue => 0, vdm => 0,
    );
    for my $kind (@{ spark_event_kinds() }) {
        $assert->is(
            spark_event_requires_response($kind),
            $expected{$kind},
            "mb709-997: $kind response contract is explicit",
        );
    }

    my $now = 30_000;
    my $state = Mediabot::Spark::State->new(clock => sub { $now });
    $state->begin_event(channel => '#spark', kind => 'fork');
    my $miss = $state->finish_event(channel => '#spark', outcome => 'miss');
    $assert->is($miss->{miss_streak}, 1,
        'mb709-997: setup establishes one genuine missed interactive event');

    $now = $miss->{cooldown_until};
    $state->begin_event(channel => '#spark', kind => 'reaction');
    my $delivered = $state->finish_event(
        channel => '#spark', outcome => 'delivered',
    );
    $assert->is($delivered->{outcome}, 'delivered',
        'mb709-997: ambient delivery has a first-class terminal outcome');
    $assert->is($delivered->{miss_streak}, 1,
        'mb709-997: ambient delivery neither invents engagement nor resets misses');
    $assert->is($delivered->{cooldown_seconds}, 3600,
        'mb709-997: successful ambient delivery still receives bounded pacing');

    open my $fh, '<:encoding(UTF-8)', "$Bin/../../mediabot.pl" or die $!;
    local $/;
    my $main = <$fh>;
    my ($finish) = $main =~
        /(sub _spark_finish_human_event \{.*?\n\})\n\nsub _spark_observe_public_line/s;
    $assert->ok(defined $finish,
        'mb709-997: human participation handler remains structurally auditable');
    $assert->like($finish // '', qr/if \(\$kind eq 'portal'\)/,
        'mb709-997: Portal owns its explicit contribution path');
    $assert->like($finish // '', qr/if \(\$kind eq 'fork'\)/,
        'mb709-997: only the explicit Fork branch can consume a human choice');
    $assert->unlike($finish // '', qr/outcome\s*=>\s*'superseded'/,
        'mb709-997: ambient content cannot be closed by unrelated human speech');
    $assert->like(
        $main,
        qr/_spark_finish_ambient_delivery.*?outcome\s*=>\s*'delivered'/s,
        'mb709-997: successful ambient transport closes immediately as delivered');
};
