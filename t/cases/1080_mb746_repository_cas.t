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
};
