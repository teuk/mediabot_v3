# MB758 — immutable factoid records and bounded channel-scoped reads.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

{
    package T1111::DBH;
    sub new { bless { plans => [], sql => [], binds => [] }, shift }
    sub plan { push @{ $_[0]{plans} }, $_[1]; $_[0] }
    sub prepare {
        my ($self, $sql) = @_;
        push @{ $self->{sql} }, $sql;
        my $plan = shift @{ $self->{plans} };
        return undef if $plan && $plan->{prepare_fail};
        return T1111::STH->new($self, $plan || { rows => [] });
    }
}

{
    package T1111::STH;
    sub new {
        my ($class, $dbh, $plan) = @_;
        bless { dbh => $dbh, plan => $plan, at => 0 }, $class;
    }
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

sub factoid_row {
    my ($id, $keyword, $value, $hits) = @_;
    return {
        id => $id,
        keyword => $keyword,
        value => $value,
        author => 'Hermione',
        author_id => 7,
        created_at => '2026-09-21 10:00:00',
        updated_at => '2026-09-21 11:00:00',
        hits => $hits,
    };
}

return sub {
    my ($assert) = @_;
    require Mediabot::Plugin::FactoidRecordV3;
    require Mediabot::Plugin::FactoidServiceV3;

    my $detached = Mediabot::Plugin::FactoidRecordV3->new(
        id => 9,
        keyword => 'wand',
        value => "oak\nphoenix",
        author => 'Ollivander',
        author_id => 4,
        created_at => '2026-09-21 10:00:00',
        updated_at => '2026-09-21 10:00:00',
        hits => 3,
    );
    $assert->is($detached->value, 'oak phoenix',
        'record strips line-breaking control data');
    my $copy = $detached->as_hash;
    $copy->{value} = 'elder';
    $assert->is($detached->value, 'oak phoenix',
        'returned hashes cannot mutate the opaque record');
    $assert->ok(!$detached->can('database') && !$detached->can('dbh'),
        'record exposes neither database nor handle');

    my $dbh = T1111::DBH->new;
    $dbh->plan({ rows => [ factoid_row(7, 'spell', 'Lumos', 12) ] });
    $dbh->plan({ rows => [
        { keyword => 'alpha' }, { keyword => 'under_score' },
    ] });
    $dbh->plan({ rows => [ { keyword => 'magic_one' } ] });
    $dbh->plan({ rows => [
        { keyword => 'spell', hits => 12 },
        { keyword => 'wand', hits => 4 },
    ] });

    my $service = Mediabot::Plugin::FactoidServiceV3->new(dbh => $dbh);
    my $exact = $service->by_keyword(channel => '#Test', keyword => ' Spell ');
    $assert->is($exact->{record}->keyword, 'spell',
        'exact lookup returns one normalized immutable record');
    $assert->is($exact->{record}->value, 'Lumos',
        'exact lookup carries only copied factoid data');
    $assert->is(join(',', @{ $dbh->{binds}[0] }), '#Test,spell',
        'exact lookup binds the core-selected channel and keyword');

    my $listed = $service->list(channel => '#Test');
    $assert->is(join(',', @{ $listed->{keywords} }), 'alpha,under_score',
        'listing returns only bounded detached keywords');
    $assert->is(join(',', @{ $dbh->{binds}[1] }), '#Test,60',
        'default list limit is explicit and bounded');

    my $patterned = $service->list(
        channel => '#Test', pattern => 'magic_*', limit => 8);
    $assert->is(join(',', @{ $patterned->{keywords} }), 'magic_one',
        'validated glob listing returns copied keywords');
    $assert->is(join(',', @{ $dbh->{binds}[2] }), '#Test,magic!_%,8',
        'literal underscore is escaped before glob expansion');

    my $top = $service->top(channel => '#Test', limit => 2);
    $assert->is($top->{items}[0]{keyword}, 'spell',
        'top view preserves deterministic ranking order');
    $assert->is($top->{items}[0]{hits}, 12,
        'top view exposes a bounded numeric recall count');
    $assert->is(join(',', @{ $dbh->{binds}[3] }), '#Test,2',
        'top limit and channel are bound by the service');

    my $ok = eval {
        $service->list(channel => '#Test', pattern => '../*');
        1;
    };
    $assert->like($@ // '', qr/invalid pattern/,
        'invalid glob syntax fails before database access');
    $ok = eval { $service->top(channel => '#Test', limit => 11); 1 };
    $assert->like($@ // '', qr/invalid result limit/,
        'top limits above ten fail closed');
    $ok = eval {
        $service->by_keyword(channel => '#other', keyword => 'has space');
        1;
    };
    $assert->like($@ // '', qr/invalid keyword/,
        'invalid keywords fail closed');
    $ok = eval {
        $service->by_keyword(channel => 'not-a-channel', keyword => 'spell');
        1;
    };
    $assert->like($@ // '', qr/invalid channel/,
        'non-channel scope fails before database access');
    $assert->ok(!grep(/\b(?:UPDATE|INSERT|DELETE)\b/i, @{ $dbh->{sql} }),
        'the approved service emits no mutating statement');

    my $current = T1111::DBH->new;
    my $provided = Mediabot::Plugin::FactoidServiceV3->new(
        dbh_provider => sub { $current });
    my $replacement = T1111::DBH->new->plan({
        rows => [ factoid_row(8, 'fresh', 'handle', 0) ],
    });
    $current = $replacement;
    $assert->is($provided->by_keyword(
        channel => '#test', keyword => 'fresh')->{record}->id, 8,
        'each operation resolves the current core database handle');
};
