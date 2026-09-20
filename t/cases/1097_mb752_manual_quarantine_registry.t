# MB752 — bounded, explicit and instance-local API v3 quarantine registry.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

return sub {
    my ($assert) = @_;
    require Mediabot::Plugin::QuarantineV3;

    my $now = 200;
    my $registry = Mediabot::Plugin::QuarantineV3->new(
        max_entries => 2, clock => sub { ++$now });

    my $first = $registry->quarantine(
        kind => 'command', resource => 'v3hello', channel => '#Test');
    $assert->is($first->{created}, 1,
        'first explicit quarantine creates one entry');
    $assert->is($first->{quarantined_at}, 201,
        'quarantine records a bounded integer timestamp');
    $assert->ok($registry->is_quarantined(
        kind => 'command', resource => 'v3hello', channel => '#TEST'),
        'quarantine lookup follows RFC1459 channel casemapping');
    $assert->ok(!$registry->is_quarantined(
        kind => 'command', resource => 'v3hello', channel => '#other'),
        'same resource remains available on another channel');
    $assert->ok(!$registry->is_quarantined(
        kind => 'command', resource => 'other', channel => '#test'),
        'same channel keeps unrelated resources available');

    my $again = $registry->quarantine(
        kind => 'command', resource => 'v3hello', channel => '#test');
    $assert->is($again->{created}, 0,
        'repeating the same operator action is idempotent');
    $assert->is($again->{quarantined_at}, 201,
        'idempotent set preserves the original timestamp');

    $registry->quarantine(
        kind => 'job', resource => 'heartbeat', channel => '#test');
    my $report = $registry->report;
    $assert->is($report->{total}, 2,
        'report counts the two exact quarantines');
    $assert->is($report->{max_entries}, 2,
        'report publishes the hard registry bound');

    my $ok = eval {
        $registry->quarantine(
            kind => 'event', resource => 'scheduler.minute',
            channel => '#test');
        1;
    };
    $assert->like($@ // '', qr/quarantine limit reached/,
        'new entries fail closed at the hard bound');

    $report->{entries}[0]{resource} = 'mutated';
    $assert->is($registry->report->{entries}[0]{resource}, 'v3hello',
        'detached report mutation cannot alter quarantine state');
    $assert->ok(!$registry->can('clear'),
        'registry exposes no bulk clear shortcut');

    $assert->is($registry->release(
        kind => 'command', resource => 'v3hello', channel => '#tESt'), 1,
        'explicit release removes the casemapped target');
    $assert->is($registry->release(
        kind => 'command', resource => 'v3hello', channel => '#test'), 0,
        'repeating release is safely idempotent');
};
