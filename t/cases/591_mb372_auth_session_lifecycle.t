# t/cases/591_mb372_auth_session_lifecycle.t
#
# mb372 — Authentication must be tracked by the live IRC nickname, and a
# genuine disconnect must clear USER.auth once the account has no other live
# session.  Before this round several Auth methods expected by LoginCommands
# did not exist, explicit login used the DB handle as session key, and logout
# only removed memory state.

use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);

BEGIN {
    unshift @INC, "$Bin/../..";
}

use Mediabot::Auth;

{
    package MB372::Metrics;
    sub new { bless { sets => [] }, shift }
    sub set {
        my ($self, $name, $value) = @_;
        push @{ $self->{sets} }, [$name, $value];
        return 1;
    }
    sub last {
        my ($self) = @_;
        return undef unless @{ $self->{sets} };
        return $self->{sets}[-1][1];
    }
}

{
    package MB372::STH;
    sub new {
        my ($class, $dbh, $sql) = @_;
        return bless { dbh => $dbh, sql => $sql }, $class;
    }
    sub execute {
        my ($self, @bind) = @_;
        push @{ $self->{dbh}{executions} }, [$self->{sql}, @bind];
        return 1;
    }
    sub finish { 1 }
}

{
    package MB372::DBH;
    sub new { bless { prepared => [], executions => [] }, shift }
    sub prepare {
        my ($self, $sql) = @_;
        push @{ $self->{prepared} }, $sql;
        return MB372::STH->new($self, $sql);
    }
}

{
    package MB372::Bot;
    sub new {
        return bless {
            cache_clears       => [],
            logged_in          => {},
            logged_in_by_nick  => {},
            sessions           => {},
            users_by_id        => {},
            users_by_nick      => {},
        }, shift;
    }
    sub clear_user_cache {
        my ($self, $mask) = @_;
        push @{ $self->{cache_clears} }, defined($mask) ? $mask : '<all>';
        return 1;
    }
}

sub read_file {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

my $dbh     = MB372::DBH->new;
my $metrics = MB372::Metrics->new;
my $bot     = MB372::Bot->new;
my $auth    = Mediabot::Auth->new(dbh => $dbh, metrics => $metrics, bot => $bot);

ok($auth->can('is_logged_in_id'), 'Auth exposes is_logged_in_id');
ok($auth->can('set_logged_in'),   'Auth exposes set_logged_in');
ok($auth->can('set_session_user'),'Auth exposes set_session_user');

ok($auth->set_session_user('LiveNick', {
    id_user  => 42,
    nickname => 'DatabaseHandle',
    hostmask => 'LiveNick!ident@example.test',
}), 'live IRC session is registered through the public API');
ok(exists $auth->{sessions}{livenick}, 'session key is the live IRC nickname');
ok(!exists $auth->{sessions}{databasehandle}, 'DB handle is not used as session key');
ok($auth->is_logged_in_id(42), 'account is marked logged in');
is($metrics->last, 1, 'session gauge is updated on registration');

# Fill mirrored bot caches to prove logout invalidates all related state.
$bot->{logged_in}{42} = 1;
$bot->{logged_in_by_nick}{livenick} = 1;
$bot->{sessions}{livenick} = { id_user => 42 };
$bot->{users_by_id}{42} = { auth => 1 };
$bot->{users_by_nick}{livenick} = { auth => 1 };

ok($auth->logout('LiveNick'), 'logout by live IRC nickname succeeds');
is(scalar @{ $dbh->{executions} }, 1, 'last live session triggers one DB auth reset');
is_deeply($dbh->{executions}[0],
    ['UPDATE USER SET auth=? WHERE id_user=?', 0, 42],
    'DB auth is cleared for the disconnected account');
ok(!$auth->is_logged_in_id(42), 'logged_in state is cleared');
ok(!exists $auth->{sessions}{livenick}, 'Auth session is removed');
is($metrics->last, 0, 'session gauge returns to zero');
is_deeply($bot->{cache_clears}, ['LiveNick!ident@example.test'],
    'hostmask cache is invalidated');
ok(!exists $bot->{logged_in}{42}, 'bot logged_in cache is cleared');
ok(!exists $bot->{sessions}{livenick}, 'bot live-nick session cache is cleared');
ok(!exists $bot->{users_by_id}{42}, 'bot user-by-id cache is cleared');

# Two live IRC nicks may represent the same account.  Closing one must not
# clear USER.auth while the second session is still alive.
$dbh->{executions} = [];
$auth->set_session_user('FirstNick', {
    id_user => 77, nickname => 'Shared', hostmask => 'FirstNick!a@host',
});
$auth->set_session_user('SecondNick', {
    id_user => 77, nickname => 'Shared', hostmask => 'SecondNick!b@host',
});
is($metrics->last, 2, 'two live nicknames produce two sessions');
ok($auth->logout('FirstNick'), 'first concurrent session closes');
is(scalar @{ $dbh->{executions} }, 0,
    'DB auth remains set while another session for the UID survives');
ok($auth->is_logged_in_id(77), 'shared account remains logged in');
is($metrics->last, 1, 'gauge keeps the surviving session');
ok($auth->logout('SecondNick'), 'last concurrent session closes');
is(scalar @{ $dbh->{executions} }, 1,
    'last concurrent session clears DB auth once');
is_deeply($dbh->{executions}[0],
    ['UPDATE USER SET auth=? WHERE id_user=?', 0, 77],
    'correct UID is deauthenticated after its last session');

# Explicit logout already performs its SQL update in LoginCommands and uses
# skip_db only for the in-memory cleanup.
$dbh->{executions} = [];
$auth->set_session_user('ManualNick', {
    id_user => 88, nickname => 'Manual', hostmask => 'ManualNick!x@host',
});
ok($auth->logout('ManualNick', skip_db => 1), 'skip_db logout clears memory');
is(scalar @{ $dbh->{executions} }, 0, 'skip_db avoids a duplicate UPDATE');

# Reusing the same live nickname for another account must retire the previous
# account instead of overwriting its only session silently.
$dbh->{executions} = [];
$auth->set_session_user('SwitchNick', {
    id_user => 100, nickname => 'OldAccount', hostmask => 'SwitchNick!x@old',
});
$auth->set_session_user('SwitchNick', {
    id_user => 101, nickname => 'NewAccount', hostmask => 'SwitchNick!x@new',
});
is_deeply($dbh->{executions}[0],
    ['UPDATE USER SET auth=? WHERE id_user=?', 0, 100],
    'replacing a live nick deauthenticates the displaced account');
ok(!$auth->is_logged_in_id(100), 'displaced UID is no longer logged in');
ok($auth->is_logged_in_id(101), 'replacement UID is logged in');
is($auth->{sessions}{switchnick}{id_user}, 101,
    'live nick now points only to the replacement account');
$auth->logout('SwitchNick');

# Stale cleanup must persist logout only for accounts with no fresh session.
$dbh->{executions} = [];
$auth->set_session_user('OldOnly', {
    id_user => 90, nickname => 'OldOnly', hostmask => 'OldOnly!x@host',
    logged_in_at => time() - 500,
});
$auth->set_session_user('OldShared', {
    id_user => 91, nickname => 'Shared', hostmask => 'OldShared!x@host',
    logged_in_at => time() - 500,
});
$auth->set_session_user('FreshShared', {
    id_user => 91, nickname => 'Shared', hostmask => 'FreshShared!x@host',
    logged_in_at => time(),
});
is($auth->cleanup_stale_sessions(100), 2, 'two stale sessions are purged');
my @cleanup_uids = map { $_->[2] } @{ $dbh->{executions} };
is_deeply(\@cleanup_uids, [90],
    'cleanup clears DB auth only for UID without another fresh session');
ok($auth->is_logged_in_id(91), 'fresh sibling session keeps shared UID authenticated');

my $auth_src  = read_file("$Bin/../../Mediabot/Auth.pm");
my $login_src = read_file("$Bin/../../Mediabot/LoginCommands.pm");
my $help_src  = read_file("$Bin/../../Mediabot/Helpers.pm");

like($auth_src, qr/mb372-B1/, 'MB372 marker is present in Auth');
like($auth_src, qr/sub logout\s*\{.*?_set_db_auth\(\$uid, 0\)/s,
    'logout persists auth=0 when the last session disappears');
like($auth_src, qr/sub set_session_user\s*\{.*?irc_nick/s,
    'Auth public API records the live IRC nickname');
like($auth_src, qr/sub cleanup_stale_sessions\s*\{.*?_set_db_auth\(\$uid, 0\)/s,
    'stale cleanup also clears persistent auth');
like($login_src, qr/set_session_user\(\$sNick,\s*\{/s,
    'explicit login registers the caller live IRC nickname');
unlike($login_src, qr/\{sessions\}\{lc \$db_nick\}/,
    'explicit login no longer writes a session under the DB handle');
like($login_src, qr/logout\(\$nick, skip_db => 1\)/,
    'explicit logout reuses Auth cleanup without duplicate SQL');
like($login_src, qr/auth session unavailable/,
    'explicit login rolls back instead of leaving DB auth without a live session');
unlike($login_src, qr/->update_last_login\(\$uid\)/,
    'memory synchronisation no longer rewrites last_login on ordinary messages');

my $constructors = () = $help_src =~ /Mediabot::Auth->new\s*\(/g;
my $bot_links    = () = $help_src =~ /bot\s*=>\s*\$self/g;
is($constructors, 4, 'four lazy Auth constructors remain in Helpers');
is($bot_links, $constructors, 'every lazy Auth constructor now receives the bot');

done_testing();
