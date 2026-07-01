#!/usr/bin/env perl
use strict;
use warnings;

use lib '.';
use Test::More;

use Mediabot::Auth;

{
    package MB377::Statement;
    sub new { bless { db => $_[1] }, $_[0] }
    sub execute {
        my ($self, @bind) = @_;
        push @{ $self->{db}{updates} }, \@bind;
        return 1;
    }
    sub finish { 1 }
}

{
    package MB377::DB;
    sub new { bless { updates => [] }, $_[0] }
    sub prepare { MB377::Statement->new($_[0]) }
    sub updates { $_[0]{updates} }
}

{
    package MB377::Metrics;
    sub new { bless { values => {} }, $_[0] }
    sub set {
        my ($self, $name, $value) = @_;
        $self->{values}{$name} = $value;
        return 1;
    }
    sub value { $_[0]{values}{$_[1]} }
}

{
    package MB377::Bot;
    sub new {
        bless {
            logged_in_by_nick => {},
            sessions          => {},
            users_by_nick     => {},
            logged_in         => {},
            users_by_id       => {},
            cleared_masks     => [],
        }, $_[0];
    }
    sub clear_user_cache {
        my ($self, $mask) = @_;
        push @{ $self->{cleared_masks} }, defined($mask) ? $mask : '<all>';
        return 1;
    }
}

my $db      = MB377::DB->new;
my $metrics = MB377::Metrics->new;
my $bot     = MB377::Bot->new;
my $auth    = Mediabot::Auth->new(
    dbh     => $db,
    metrics => $metrics,
    bot     => $bot,
);

ok($auth->can('rename_session'), 'Auth exposes rename_session');

ok(
    $auth->set_session_user('OldNick', {
        id_user  => 42,
        nickname => 'RegisteredHandle',
        hostmask => 'OldNick!ident@example.test',
    }),
    'old live nickname session is registered',
);

is($auth->session_count, 1, 'one session exists before NICK');
ok($auth->is_logged_in_id(42), 'account is logged in before NICK');

ok(
    $auth->rename_session(
        'OldNick',
        'NewNick',
        hostmask => 'NewNick!ident@example.test',
    ),
    'NICK rekeys the authenticated session',
);

ok(!exists $auth->{sessions}{oldnick}, 'old live nickname key is removed');
ok(exists $auth->{sessions}{newnick}, 'new live nickname key is present');
is($auth->{sessions}{newnick}{irc_nick}, 'NewNick', 'session records the new live nickname');
is(
    $auth->{sessions}{newnick}{hostmask},
    'NewNick!ident@example.test',
    'session records the new full hostmask',
);
is($auth->session_count, 1, 'NICK keeps the session count stable');
ok($auth->is_logged_in_id(42), 'NICK preserves account authentication');
is(scalar @{ $db->updates }, 0, 'NICK does not write auth=0 to the database');
is($metrics->value('mediabot_auth_sessions_total'), 1, 'session metric stays at one');

ok($auth->logout('NewNick'), 'QUIT under the new nickname finds the migrated session');
is($auth->session_count, 0, 'new-nick logout removes the session');
ok(!$auth->is_logged_in_id(42), 'new-nick logout clears logged-in state');
is(scalar @{ $db->updates }, 1, 'last-session logout performs one DB auth reset');
is_deeply($db->updates->[0], [0, 42], 'DB auth reset targets the correct UID');
is($metrics->value('mediabot_auth_sessions_total'), 0, 'session metric returns to zero');

ok(
    !$auth->rename_session('MissingNick', 'OtherNick'),
    'missing source nickname is a harmless no-op',
);

ok(
    $auth->set_session_user('CaseNick', {
        id_user  => 77,
        nickname => 'CaseAccount',
        hostmask => 'CaseNick!u@h',
    }),
    'case-change fixture session registered',
);
ok(
    $auth->rename_session('CaseNick', 'casenick', hostmask => 'casenick!u@h'),
    'case-only NICK change succeeds',
);
is($auth->{sessions}{casenick}{irc_nick}, 'casenick', 'case-only change refreshes irc_nick');
is($auth->{sessions}{casenick}{hostmask}, 'casenick!u@h', 'case-only change refreshes hostmask');

my $auth_src = do {
    local $/;
    open my $fh, '<:encoding(UTF-8)', 'Mediabot/Auth.pm' or die $!;
    <$fh>;
};
my $main_src = do {
    local $/;
    open my $fh, '<:encoding(UTF-8)', 'mediabot.pl' or die $!;
    <$fh>;
};

like($auth_src, qr/mb377-B1/, 'Auth contains the MB377 marker');
like(
    $main_src,
    qr/on_message_NICK.*?rename_session\s*\(/s,
    'NICK handler migrates the Auth session',
);
like(
    $main_src,
    qr/hostmask\s*=>\s*\$new_fullmask/,
    'NICK handler supplies the new full hostmask',
);

done_testing();
