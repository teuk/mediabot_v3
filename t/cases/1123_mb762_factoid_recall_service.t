# MB762 — factoid recall counting is exact, bounded and channel-scoped.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

{
    package T1123::DBH;
    sub new { bless { plans => [], sql => [], binds => [] }, shift }
    sub plan { push @{ $_[0]{plans} }, $_[1]; $_[0] }
    sub prepare {
        my ($self, $sql) = @_;
        push @{ $self->{sql} }, $sql;
        my $plan = shift @{ $self->{plans} } || {};
        return undef if $plan->{prepare_fail};
        return T1123::STH->new($self, $plan);
    }
}

{
    package T1123::STH;
    sub new {
        my ($class, $dbh, $plan) = @_;
        bless { dbh => $dbh, plan => $plan }, $class;
    }
    sub execute {
        my ($self, @bind) = @_;
        push @{ $self->{dbh}{binds} }, \@bind;
        return $self->{plan}{execute_fail} ? 0 : 1;
    }
    sub finish { 1 }
}

return sub {
    my ($assert) = @_;
    require Mediabot::Plugin::FactoidWriteServiceV3;

    my $dbh = T1123::DBH->new;
    my $service = Mediabot::Plugin::FactoidWriteServiceV3->new(dbh => $dbh);

    $dbh->plan({});
    my $result = $service->recall(
        channel => '#Test', keyword => '  Spell  ');
    $assert->ok($result->{ok},
        'bounded recall returns a detached success result');
    $assert->is($result->{status}, 'recalled',
        'recall result names the exact mutation');
    $assert->is($result->{keyword}, 'spell',
        'keyword normalization remains core-owned');
    $assert->like($dbh->{sql}[0],
        qr/UPDATE FACTOID f\s+JOIN CHANNEL c/s,
        'recall resolves channel scope inside one prepared update');
    $assert->like($dbh->{sql}[0],
        qr/SET f\.hits = COALESCE\(f\.hits, 0\) \+ 1/,
        'recall performs one null-safe counter increment');
    $assert->like($dbh->{sql}[0],
        qr/WHERE c\.name = \? AND f\.keyword = \?/,
        'recall cannot escape channel and keyword scope');
    $assert->is($dbh->{binds}[0][0], '#Test',
        'policy channel is the first bound selector');
    $assert->is($dbh->{binds}[0][1], 'spell',
        'normalized keyword is the second bound selector');

    my $before = scalar @{ $dbh->{sql} };
    eval { $service->recall(channel => '#Test', keyword => 'bad key') };
    $assert->like($@ // '', qr/invalid keyword/,
        'invalid recall keyword fails closed');
    $assert->is(scalar @{ $dbh->{sql} }, $before,
        'invalid keyword reaches no SQL');

    $dbh->plan({ execute_fail => 1 });
    eval { $service->recall(channel => '#Test', keyword => 'spell') };
    $assert->like($@ // '', qr/data service unavailable/,
        'database failure becomes a bounded service error');
};
