# MB760 — factoid mutations stay bounded, channel-scoped and core-authorized.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

{
    package T1117::DBH;
    sub new { bless { plans => [], sql => [], binds => [] }, shift }
    sub plan { push @{ $_[0]{plans} }, $_[1]; $_[0] }
    sub prepare {
        my ($self, $sql) = @_;
        push @{ $self->{sql} }, $sql;
        my $plan = shift @{ $self->{plans} } || { rows => [] };
        return undef if $plan->{prepare_fail};
        return T1117::STH->new($self, $plan);
    }
}

{
    package T1117::STH;
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
    require Mediabot::Plugin::FactoidWriteServiceV3;

    my $user = Mediabot::Plugin::PrincipalV3->new(
        authenticated => 1, user_id => 5, account => 'Luna',
        global_level => 'user', channel_level => 25);
    my $admin = Mediabot::Plugin::PrincipalV3->new(
        authenticated => 1, user_id => 9, account => 'Kingsley',
        global_level => 'administrator', channel_level => 0);
    my $anonymous = Mediabot::Plugin::PrincipalV3->anonymous;
    my $dbh = T1117::DBH->new;
    my @stored;
    my $service = Mediabot::Plugin::FactoidWriteServiceV3->new(
        dbh => $dbh, on_stored => sub { push @stored, { @_ } });

    $dbh->plan({ rows => [ { id => 4 } ] });
    $dbh->plan({ rows => [] });
    my $learned = $service->upsert(
        channel => '#test', principal => $user, actor_nick => 'Luna_',
        keyword => 'Spell', value => 'Lumos');
    $assert->is($learned->{status}, 'stored',
        'bounded upsert returns a detached stored outcome');
    $assert->is($learned->{keyword}, 'spell',
        'keyword normalization is core-owned');
    $assert->is($dbh->{binds}[0][0], '#test',
        'channel lookup uses the policy channel');
    $assert->is($dbh->{binds}[1][0], 4,
        'upsert receives only the resolved channel id');
    $assert->is($dbh->{binds}[1][1], 'spell',
        'upsert binds the normalized keyword');
    $assert->is($dbh->{binds}[1][2], 'Lumos',
        'upsert binds the bounded value');
    $assert->is($dbh->{binds}[1][3], 5,
        'authenticated attribution uses the principal user id');
    $assert->is($dbh->{binds}[1][4], 'Luna_',
        'display attribution uses the core invocation nickname');
    $assert->is($stored[0]{actor_id}, 5,
        'post-store hook receives bounded identity, not a user object');

    $dbh->plan({ rows => [ { id => 4 } ] });
    $dbh->plan({ rows => [] });
    my $anonymous_learn = $service->upsert(
        channel => '#test', principal => $anonymous, actor_nick => 'Guest',
        keyword => 'guest', value => 'Alohomora');
    $assert->is($anonymous_learn->{status}, 'stored',
        'anonymous learn remains available through the bounded service');
    $assert->ok(!defined($dbh->{binds}[-1][3]),
        'anonymous attribution binds SQL NULL instead of a fake USER id');
    $assert->is($dbh->{binds}[-1][4], 'Guest',
        'anonymous display attribution remains bounded and core-sourced');

    $dbh->plan({ rows => [
        { id => 71, author_id => 5, channel_id => 4 } ] });
    $dbh->plan({ rows => [] });
    my $deleted = $service->delete(
        channel => '#test', principal => $user,
        keyword => 'spell', delete_level => 400);
    $assert->is($deleted->{status}, 'deleted',
        'numeric factoid author may delete inside the policy channel');
    $assert->is($dbh->{binds}[-1][0], 71,
        'delete binds the resolved factoid id');
    $assert->is($dbh->{binds}[-1][1], 4,
        'delete also binds the resolved channel id');

    $dbh->plan({ rows => [
        { id => 72, author_id => 6, channel_id => 4 } ] });
    my $forbidden = $service->delete(
        channel => '#test', principal => $user,
        keyword => 'other', delete_level => 400);
    $assert->is($forbidden->{error}, 'forbidden',
        'authenticated non-author without channel authority fails closed');

    $dbh->plan({ rows => [
        { id => 72, author_id => 6, channel_id => 4 } ] });
    $dbh->plan({ rows => [] });
    $assert->is($service->delete(
        channel => '#test', principal => $admin,
        keyword => 'other', delete_level => 400)->{status}, 'deleted',
        'Administrator may delete through the same core policy');

    my $channel_operator = Mediabot::Plugin::PrincipalV3->new(
        authenticated => 1, user_id => 10, account => 'Pomona',
        global_level => 'user', channel_level => 400);
    $dbh->plan({ rows => [
        { id => 73, author_id => 6, channel_id => 4 } ] });
    $dbh->plan({ rows => [] });
    $assert->is($service->delete(
        channel => '#test', principal => $channel_operator,
        keyword => 'herbology', delete_level => 400)->{status}, 'deleted',
        'historical channel operator threshold authorizes deletion');

    my $sql_before = scalar @{ $dbh->{sql} };
    $assert->is($service->delete(
        channel => '#test', principal => $anonymous,
        keyword => 'spell', delete_level => 400)->{error}, 'unauthorized',
        'anonymous nickname text cannot authorize deletion');
    $assert->is(scalar @{ $dbh->{sql} }, $sql_before,
        'anonymous deletion is rejected before database access');

    $dbh->plan({ rows => [] });
    $assert->is($service->delete(
        channel => '#test', principal => $user,
        keyword => 'missing', delete_level => 400)->{status}, 'not_found',
        'missing delete is an idempotent detached outcome');

    eval { $service->upsert(
        channel => '#test', principal => $user, actor_nick => 'Luna_',
        keyword => 'bad key', value => 'value') };
    $assert->like($@ // '', qr/invalid keyword/,
        'invalid keywords fail before SQL');
    eval { $service->upsert(
        channel => '#test', principal => $user, actor_nick => 'Luna_',
        keyword => 'spell', value => "bad\nvalue") };
    $assert->like($@ // '', qr/invalid value/,
        'control-bearing values fail before SQL');
    eval { $service->delete(
        channel => '#test', principal => $user,
        keyword => 'spell', delete_level => 501) };
    $assert->like($@ // '', qr/invalid delete level/,
        'out-of-range authorization thresholds fail closed');
};
