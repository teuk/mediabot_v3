# MB753 — quote mutations stay bounded, channel-scoped and core-authorized.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

{
    package T1101::DBH;
    sub new {
        bless { plans => [], sql => [], binds => [], last_id => 77 }, shift;
    }
    sub plan { push @{ $_[0]{plans} }, $_[1]; $_[0] }
    sub prepare {
        my ($self, $sql) = @_;
        push @{ $self->{sql} }, $sql;
        my $plan = shift @{ $self->{plans} } || { rows => [] };
        return undef if $plan->{prepare_fail};
        return T1101::STH->new($self, $plan);
    }
    sub last_insert_id { $_[0]{last_id} }
}

{
    package T1101::STH;
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

return sub {
    my ($assert) = @_;
    require Mediabot::Plugin::PrincipalV3;
    require Mediabot::Plugin::QuoteWriteServiceV3;

    my $user = Mediabot::Plugin::PrincipalV3->new(
        authenticated => 1, user_id => 5, account => 'Hermione',
        global_level => 'user', channel_level => 25);
    my $admin = Mediabot::Plugin::PrincipalV3->new(
        authenticated => 1, user_id => 9, account => 'Kingsley',
        global_level => 'administrator', channel_level => 0);
    my $anonymous = Mediabot::Plugin::PrincipalV3->anonymous;

    my $dbh = T1101::DBH->new;
    $dbh->plan({ rows => [] });
    $dbh->plan({ rows => [ { id => 4 } ] });
    $dbh->plan({ rows => [] });
    my @created;
    my $service = Mediabot::Plugin::QuoteWriteServiceV3->new(
        dbh => $dbh, on_created => sub { push @created, { @_ } });

    my $added = $service->add(
        channel => '#test', principal => $user, text => 'Alohomora');
    $assert->is($added->{status}, 'created',
        'bounded add returns a detached created outcome');
    $assert->is($added->{id}, 77, 'inserted identifier is copied');
    $assert->is(join(',', @{ $dbh->{binds}[0] }), '#test,Alohomora',
        'duplicate lookup binds channel and literal text');
    $assert->is(join(',', @{ $dbh->{binds}[2] }), '4,5,Alohomora',
        'insert receives only core channel and principal author ids');
    $assert->is($created[0]{account}, 'Hermione',
        'post-create hook receives bounded attribution, not a user object');

    $dbh->plan({ rows => [ { id => 77 } ] });
    my $duplicate = $service->add(
        channel => '#test', principal => $anonymous, text => 'Alohomora');
    $assert->is($duplicate->{status}, 'duplicate',
        'duplicate add is idempotent and performs no insert');

    $dbh->plan({ rows => [
        { id => 77, author_id => 5, channel_id => 4 } ] });
    $dbh->plan({ rows => [] });
    my $deleted = $service->delete(
        channel => '#test', principal => $user, id => 77,
        delete_level => 100);
    $assert->is($deleted->{status}, 'deleted',
        'quote author may delete the exact channel-scoped quote');
    $assert->is(join(',', @{ $dbh->{binds}[-1] }), '77,4',
        'delete binds both quote and channel identifiers');

    $dbh->plan({ rows => [
        { id => 88, author_id => 6, channel_id => 4 } ] });
    my $forbidden = $service->delete(
        channel => '#test', principal => $user, id => 88,
        delete_level => 100);
    $assert->is($forbidden->{error}, 'forbidden',
        'unprivileged non-author deletion fails closed');

    $dbh->plan({ rows => [
        { id => 88, author_id => 6, channel_id => 4 } ] });
    $dbh->plan({ rows => [] });
    $assert->is($service->delete(
        channel => '#test', principal => $admin, id => 88,
        delete_level => 100)->{status}, 'deleted',
        'Administrator may delete through the same core policy');

    my $sql_before = scalar @{ $dbh->{sql} };
    $assert->is($service->delete(
        channel => '#test', principal => $anonymous, id => 88,
        delete_level => 100)->{error}, 'unauthorized',
        'anonymous deletion is rejected');
    $assert->is(scalar @{ $dbh->{sql} }, $sql_before,
        'anonymous deletion does not touch the database');

    my $channel_operator = Mediabot::Plugin::PrincipalV3->new(
        authenticated => 1, user_id => 10, account => 'Pomona',
        global_level => 'user', channel_level => 150);
    $dbh->plan({ rows => [
        { id => 90, author_id => 6, channel_id => 4 } ] });
    $dbh->plan({ rows => [] });
    $assert->is($service->delete(
        channel => '#test', principal => $channel_operator, id => 90,
        delete_level => 100)->{status}, 'deleted',
        'configured channel privilege authorizes deletion');

    $dbh->plan({ rows => [] });
    my $recalled = $service->recall(channel => '#test', id => 77);
    $assert->is($recalled->{status}, 'recalled',
        'recall counter mutation is an explicit bounded operation');
    $assert->is(join(',', @{ $dbh->{binds}[-1] }), '#test,77',
        'recall binds both the policy channel and returned quote id');

    eval { $service->add(
        channel => '#test', principal => $user, text => "bad\nquote") };
    $assert->like($@ // '', qr/invalid quote text/,
        'control-bearing quote text fails before SQL');
    eval { $service->delete(
        channel => '#test', principal => $user, id => 1,
        delete_level => 501) };
    $assert->like($@ // '', qr/invalid delete level/,
        'out-of-range authorization thresholds fail closed');
};
