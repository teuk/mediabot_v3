# MB746 — namespaced repository snapshot and optimistic atomic commit.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

return sub {
    my ($assert) = @_;
    require Mediabot::Plugin::RepositoryV3;

    my $stored;
    my $writes = 0;
    my $repository = Mediabot::Plugin::RepositoryV3->new(
        plugin => 'v3-short-content-v3',
        reader => sub { $stored },
        writer => sub {
            my ($name, $document) = @_;
            $writes++;
            $stored = {
                revision => $document->{revision},
                values => { %{ $document->{values} } },
            };
            return (1, undef);
        },
    );

    my $empty = $repository->snapshot;
    $assert->is($empty->{revision}, 0,
        'missing repository starts at revision zero');
    $assert->is(scalar keys %{ $empty->{values} }, 0,
        'missing repository starts with no values');

    my $first = $repository->commit(
        expected_revision => 0,
        changes => { last => 'hello', served => '1' },
    );
    $assert->ok($first->{ok} && $first->{revision} == 1,
        'matching revision commits one atomic document');
    $assert->is($writes, 1, 'successful transaction performs one write');

    my $conflict = $repository->commit(
        expected_revision => 0,
        changes => { served => '2' },
    );
    $assert->is($conflict->{error}, 'conflict',
        'stale revision fails with an explicit conflict');
    $assert->is($writes, 1, 'conflict performs no write');

    my $second = $repository->commit(
        expected_revision => 1,
        changes => { served => '2' },
        delete => ['last'],
    );
    $assert->ok($second->{ok} && $second->{revision} == 2,
        'commit can update and delete in one revision');
    $assert->is($second->{values}{served}, '2',
        'updated scalar is returned in detached snapshot');
    $assert->ok(!exists $second->{values}{last},
        'deleted key is absent');

    my $ok = eval {
        $repository->commit(
            expected_revision => 2,
            changes => { bad => { nested => 1 } },
        );
        1;
    };
    $assert->like($@ // '', qr/plain scalars/,
        'repository rejects nested plugin-controlled values');
    # MB1189: revisions must remain exactly representable, as in channel storage.
    for my $revision ('1000000000000000', '18446744073709551616', '18446744073709551617', '9' x 400) {
        $stored = { revision => $revision, values => { served => 'kept' } };
        my $before = $writes;
        my $read_ok = eval { $repository->snapshot; 1 };
        $assert->ok(!$read_ok, 'oversized stored revision is rejected');
        $assert->like($@, qr/stored revision is invalid/, 'stored revision has a bounded diagnostic');
        $stored = { revision => 2, values => { served => 'kept' } };
        my $commit_ok = eval { $repository->commit(expected_revision => $revision); 1 };
        $assert->ok(!$commit_ok, 'oversized expected revision is rejected');
        $assert->is($writes, $before, 'invalid revision cannot invoke the writer');
    }
    $stored = { revision => '999999999999998', values => { served => 'kept' } };
    my $last = $repository->commit(expected_revision => '999999999999998');
    $assert->is($last->{revision}, '999999999999999', 'last supported revision is exact');
    my $before = $writes;
    my $stale = $repository->commit(expected_revision => '999999999999998');
    $assert->is($stale->{error}, 'conflict', 'stale revision still conflicts at the limit');
    my $overflow_ok = eval { $repository->commit(expected_revision => '999999999999999', changes => { served => 'lost' }); 1 };
    $assert->ok(!$overflow_ok, 'revision exhaustion stops before writing');
    $assert->like($@, qr/revision limit reached/, 'revision exhaustion is explicit');
    $assert->is($writes, $before, 'neither conflict nor exhaustion writes state');
    $assert->is($repository->snapshot->{values}{served}, 'kept', 'exhaustion preserves stored values');

};
