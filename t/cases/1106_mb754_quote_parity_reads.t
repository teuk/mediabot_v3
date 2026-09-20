# MB754 — mixed-command parity reads stay bounded and channel-scoped.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

{
    package T1106::DBH;
    sub new { bless { plans => [], sql => [], binds => [] }, shift }
    sub plan { push @{ $_[0]{plans} }, $_[1]; $_[0] }
    sub prepare {
        my ($self, $sql) = @_;
        push @{ $self->{sql} }, $sql;
        return T1106::STH->new($self,
            shift(@{ $self->{plans} }) || { rows => [] });
    }
}

{
    package T1106::STH;
    sub new { my ($class, $dbh, $plan) = @_; bless { dbh => $dbh, plan => $plan, at => 0 }, $class }
    sub execute {
        my ($self, @bind) = @_;
        push @{ $self->{dbh}{binds} }, \@bind;
        return 1;
    }
    sub fetchrow_hashref {
        my ($self) = @_;
        my $row = $self->{plan}{rows}[ $self->{at}++ ];
        return defined($row) ? { %$row } : undef;
    }
    sub finish { 1 }
}

return sub {
    my ($assert) = @_;
    require Mediabot::Plugin::QuoteServiceV3;

    my $dbh = T1106::DBH->new;
    $dbh->plan({ rows => [ { count => 2 } ] });
    $dbh->plan({ rows => [ {
        id => 14, text => 'Literal author match', author => 'Ta%_ngy',
        author_id => 8, created_at => '2026-09-20 08:00:00', hits => 2,
    } ] });
    $dbh->plan({ rows => [ {
        count => 5, oldest_epoch => 100, newest_epoch => 200,
    } ] });
    $dbh->plan({ rows => [ { author => 'Luna', count => 3 } ] });
    my $service = Mediabot::Plugin::QuoteServiceV3->new(
        dbh => $dbh, random_index => sub { 0 });

    my $random = $service->random_by_author(
        channel => '#test', author => 'Ta%_', author_match => 'prefix',
        exclude_id => 9);
    $assert->is($random->{record}->id, 14,
        'author selection returns one detached random record');
    $assert->is(join(',', @{ $dbh->{binds}[0] }), '#test,ta!%!_%,9',
        'author count escapes wildcards and binds the anti-repeat id');
    $assert->is(join(',', @{ $dbh->{binds}[1] }), '#test,ta!%!_%,9,0',
        'author fetch reuses the exact scoped predicate and bounded offset');

    my $stats = $service->stats(channel => '#test');
    $assert->is($stats->{count}, 5,
        'quote stats return only detached aggregate counts');
    $assert->is($stats->{top_author}, 'Luna',
        'quote stats expose the bounded top contributor label');
    $assert->is($stats->{top_count}, 3,
        'quote stats expose the bounded top contributor count');
    $assert->is(join(',', @{ $dbh->{binds}[2] }), '#test',
        'stats aggregate is bound to the invocation channel');
    $assert->is(join(',', @{ $dbh->{binds}[3] }), '#test',
        'top contributor lookup cannot cross the invocation channel');
    $assert->ok(!grep(/\b(?:INSERT|UPDATE|DELETE)\b/i, @{ $dbh->{sql} }),
        'parity reads remain physically read-only');
};
