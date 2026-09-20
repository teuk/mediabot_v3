# MB753 — command invocations carry one detached, non-sensitive principal.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

return sub {
    my ($assert) = @_;
    require Mediabot::Plugin::PrincipalV3;
    require Mediabot::Plugin::InvocationV3;
    require Mediabot::PluginContext;

    my $principal = Mediabot::Plugin::PrincipalV3->new(
        authenticated => 1,
        user_id => 42,
        account => 'Minerva',
        global_level => 'master',
        channel_level => 150,
    );
    $assert->ok($principal->authenticated,
        'principal records authenticated state');
    $assert->is($principal->user_id, 42,
        'principal exposes only the numeric account identity');
    $assert->is($principal->account, 'Minerva',
        'principal exposes the bounded registered account');
    $assert->ok($principal->has_global_level('Administrator'),
        'global hierarchy is evaluated inside the detached principal');
    $assert->ok(!$principal->has_global_level('Owner'),
        'principal fails closed above the captured global level');
    $assert->ok($principal->has_channel_level(100),
        'channel threshold is evaluated from the captured scalar level');
    $assert->ok(!$principal->has_channel_level(200),
        'channel threshold cannot be inflated by the caller');

    my $snapshot = $principal->snapshot;
    $snapshot->{channel_level} = 500;
    $assert->is($principal->channel_level, 150,
        'snapshot mutation cannot rewrite the principal');
    $assert->ok(!$principal->can('password') && !$principal->can('hostmasks')
        && !$principal->can('message'),
        'passwords, hostmasks and raw messages are outside the API');

    my $authority = Mediabot::PluginContext->new(
        plugin => 'principal-probe', requested => [], granted => []);
    my $invocation = Mediabot::Plugin::InvocationV3->new(
        nick => 'McGonagall', channel => '#test', command => 'probe',
        args => [], source => 'public', authority => $authority,
        activation => 'on', principal => $principal,
        reply_sink => sub { 1 }, notice_sink => sub { 1 },
    );
    $assert->is($invocation->principal->account, 'Minerva',
        'invocation carries the core-created principal');

    my $anonymous = Mediabot::Plugin::InvocationV3->new(
        nick => 'Guest', channel => '#test', command => 'probe',
        args => [], source => 'public', authority => $authority,
        activation => 'on', reply_sink => sub { 1 },
        notice_sink => sub { 1 },
    )->principal;
    $assert->ok(!$anonymous->authenticated
        && $anonymous->global_level eq 'anonymous'
        && $anonymous->channel_level == 0,
        'missing identity becomes an explicit anonymous principal');

    eval {
        Mediabot::Plugin::PrincipalV3->new(
            authenticated => 1, user_id => 1, account => "bad\nname",
            global_level => 'user', channel_level => 0);
    };
    $assert->like($@ // '', qr/invalid account/,
        'control-bearing account names fail closed');
    eval {
        Mediabot::Plugin::PrincipalV3->new(
            authenticated => 1, user_id => 1, account => 'User',
            global_level => 'user', channel_level => 501);
    };
    $assert->like($@ // '', qr/invalid channel level/,
        'out-of-range channel levels fail closed');
};
