# MB751 — bounded, detached and non-sensitive API v3 failure history.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

use JSON::PP ();

return sub {
    my ($assert) = @_;
    require Mediabot::Plugin::FailureLedgerV3;

    my $now = 100;
    my $ledger = Mediabot::Plugin::FailureLedgerV3->new(
        max_recent => 2, max_resources => 4,
        clock => sub { ++$now },
    );
    $ledger->record_failure(
        kind => 'command', resource => 'roll', channel => '#test',
        error => "secret-token=first\nprivate path");
    $ledger->record_failure(
        kind => 'command', resource => 'roll', channel => '#test',
        error => 'secret-token=second');

    my $report = $ledger->report;
    $assert->is($report->{total_failures}, 2,
        'ledger counts failures without exposing their text');
    $assert->is($report->{active_streaks}[0]{consecutive_failures}, 2,
        'same resource accumulates one active failure streak');
    $assert->like($report->{recent}[0]{fingerprint}, qr/\A[0-9a-f]{16}\z/,
        'failure identity is a short deterministic SHA-256 fingerprint');
    $assert->unlike(JSON::PP->new->encode($report), qr/secret-token|private path/,
        'detached report contains no raw exception text');

    my $recorded_resource = $report->{recent}[0]{resource};
    $report->{recent}[0]{resource} = 'mutated';
    $assert->is($ledger->report->{recent}[0]{resource}, $recorded_resource,
        'caller mutation cannot alter ledger state');

    $ledger->record_success(
        kind => 'command', resource => 'roll', channel => '#test');
    $report = $ledger->report;
    $assert->is(scalar(@{ $report->{active_streaks} }), 0,
        'success clears only the current streak');
    $assert->is($report->{recent_count}, 2,
        'success preserves recent forensic history');

    for my $kind (qw(event http_callback job)) {
        $ledger->record_failure(
            kind => $kind, resource => 'new-resource',
            channel => '#test', error => "failure-$kind");
    }
    $report = $ledger->report;
    $assert->is($report->{recent_count}, 2,
        'recent history never exceeds its declared ring bound');
    $assert->is(join(',', map { $_->{kind} } @{ $report->{recent} }),
        'http_callback,job',
        'bounded history retains the newest records in order');
    $assert->is(scalar(keys %{ $ledger->{resources} }), 4,
        'resource cardinality remains within the hard global bound');

    # MB1202: match the channel identity used by the quarantine registry.
    for my $pair (['#Salon', '#sALON'], ['#[Ops]', '#{ops}'],
                  ['#A\\B^', '#a|b~']) {
        my ($first, $alias) = @$pair;
        my $scoped = Mediabot::Plugin::FailureLedgerV3->new(clock => sub { 200 });
        for my $channel ($first, $alias) {
            $scoped->record_failure(kind => 'command', resource => 'roll',
                channel => $channel, error => 'failure');
        }
        my $r = $scoped->report;
        $assert->is($r->{affected_resources}, 1,
            'mb1202: IRC aliases share one affected resource');
        $assert->is($r->{active_streaks}[0]{consecutive_failures}, 2,
            'mb1202: IRC aliases accumulate one failure streak');
        $assert->is($r->{recent}[1]{channel}, $first,
            'mb1202: report preserves the first channel spelling');
        $scoped->record_failure(kind => 'command', resource => 'roll',
            channel => '#other', error => 'failure');
        $scoped->record_failure(kind => 'job', resource => 'roll',
            channel => $alias, error => 'failure');
        $scoped->record_failure(kind => 'command', resource => 'other',
            channel => $alias, error => 'failure');
        $scoped->record_success(kind => 'command', resource => 'roll', channel => $alias);
        $r = $scoped->report;
        $assert->is(scalar @{$r->{active_streaks}}, 3,
            'mb1202: alias success clears only its channel/resource/kind streak');
        $assert->is($r->{total_failures}, 5,
            'mb1202: recovery preserves all historical failures');
        $assert->is($r->{total_successes}, 1,
            'mb1202: alias recovery counts once');
        $assert->is($r->{recent_count}, 5,
            'mb1202: channel normalization preserves recent history');
        $assert->is(scalar keys %{$scoped->{resources}}, 4,
            'mb1202: alias recovery does not allocate another resource slot');
    }

    my $ok = eval {
        $ledger->record_failure(
            kind => 'unknown', resource => 'bad', error => 'bad');
        1;
    };
    $assert->like($@ // '', qr/unsupported runtime kind/,
        'unknown runtime kinds fail closed');
};
