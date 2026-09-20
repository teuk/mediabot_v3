# MB747 — bounded, channel-scoped approved quote queries.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

{
    package T1084::DBH;
    sub new { bless { plans => [], sql => [], binds => [] }, shift }
    sub plan { push @{ $_[0]{plans} }, $_[1]; $_[0] }
    sub prepare {
        my ($self, $sql) = @_;
        push @{ $self->{sql} }, $sql;
        my $plan = shift @{ $self->{plans} };
        return undef if $plan && $plan->{prepare_fail};
        return T1084::STH->new($self, $plan || { rows => [] });
    }
}

{
    package T1084::STH;
    sub new { my ($class, $dbh, $plan) = @_; bless { dbh => $dbh, plan => $plan, at => 0 }, $class }
    sub execute {
        my ($self, @bind) = @_;
        push @{ $self->{dbh}{binds} }, \@bind;
        return $self->{plan}{execute_fail} ? 0 : 1;
    }
    sub fetchrow_hashref {
        my ($self) = @_;
        my $row = $self->{plan}{rows}[ $self->{at}++ ];
        return defined($row) ? { %$row } : undef;
    }
    sub finish { 1 }
}

sub quote_row {
    my ($id, $text, $author, $hits) = @_;
    return {
        id => $id, text => $text, author => $author, author_id => $id + 100,
        created_at => '2026-09-19 20:00:00', hits => $hits,
    };
}

return sub {
    my ($assert) = @_;
    require Mediabot::Plugin::QuoteServiceV3;

    my $dbh = T1084::DBH->new;
    $dbh->plan({ rows => [ quote_row(7, 'seven', 'Alice', 4) ] });
    $dbh->plan({ rows => [ { count => 2 } ] });
    $dbh->plan({ rows => [ { count => 2 } ] });
    $dbh->plan({ rows => [ quote_row(9, 'random', 'Bob', 1) ] });
    $dbh->plan({ rows => [ quote_row(10, '100% real_name', 'Carol', 2) ] });
    $dbh->plan({ rows => [ quote_row(11, 'author', 'Tangy', 0) ] });
    $dbh->plan({ rows => [ { count => 1 } ] });
    $dbh->plan({ rows => [ { count => 3 } ] });
    $dbh->plan({ rows => [ quote_row(12, 'top', 'Dana', 99) ] });
    my $service = Mediabot::Plugin::QuoteServiceV3->new(
        dbh => $dbh, random_index => sub { 1 });

    my $by_id = $service->by_id(channel => '#test', id => 7);
    $assert->is($by_id->{record}->text, 'seven',
        'by_id returns one detached record');
    $assert->is(join(',', @{ $dbh->{binds}[0] }), '#test,7',
        'by_id always binds the invocation channel');

    $assert->is($service->count(channel => '#test')->{count}, 2,
        'count is channel-scoped');
    my $random = $service->random(channel => '#test');
    $assert->is($random->{record}->id, 9,
        'random uses a bounded offset after a scoped count');
    $assert->is(join(',', @{ $dbh->{binds}[3] }), '#test,1',
        'random cannot replace the selected channel');

    my $search = $service->search(
        channel => '#test', query => '100% real_name', limit => 5);
    $assert->is($search->{records}[0]->id, 10,
        'search returns detached records');
    $assert->is(join(',', @{ $dbh->{binds}[4] }), '#test,%100!%%,%real!_name%,5',
        'search treats SQL wildcard characters as literal data');

    my $author = $service->by_author(
        channel => '#test', author => 'Tangy', limit => 3);
    $assert->is($author->{records}[0]->author, 'Tangy',
        'by_author is explicit and bounded');
    $assert->is($service->count(channel => '#test', author => 'Tangy')->{count}, 1,
        'author count remains inside the selected channel');
    $assert->is($service->count(
        channel => '#test', author => 'Ta%_', author_match => 'prefix')->{count},
        3, 'prefix author count supports historical command parity');
    $assert->is(join(',', @{ $dbh->{binds}[7] }), '#test,ta!%!_%',
        'prefix author count lowercases and escapes wildcard characters');
    $assert->is($service->top(channel => '#test', limit => 2)
        ->{records}[0]->hits, 99, 'top returns the bounded recall ranking');

    my $ok = eval {
        $service->search(channel => '#other', query => 'x', limit => 21);
        1;
    };
    $assert->like($@ // '', qr/invalid result limit/,
        'result limits above the core maximum fail closed');
    $ok = eval { $service->by_id(channel => 'not-a-channel', id => 7); 1 };
    $assert->like($@ // '', qr/invalid channel/,
        'non-channel scope fails before database access');
    $ok = eval {
        $service->count(channel => '#test', author => 'Tangy',
            author_match => 'contains');
        1;
    };
    $assert->like($@ // '', qr/invalid author match mode/,
        'unknown author match modes fail closed');
    $assert->ok(!grep(/UPDATE|INSERT|DELETE/i, @{ $dbh->{sql} }),
        'the approved service emits no mutating statement');

    my $current = $dbh;
    my $provided = Mediabot::Plugin::QuoteServiceV3->new(
        dbh_provider => sub { $current });
    my $replacement = T1084::DBH->new->plan({ rows => [ { count => 4 } ] });
    $current = $replacement;
    $assert->is($provided->count(channel => '#test')->{count}, 4,
        'each operation resolves the current core database handle');
};
