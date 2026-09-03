#!/usr/bin/perl

use strict;
use warnings;
use Test::More;
use lib '.';

BEGIN {
    package Mediabot::Helpers;
    sub chanset_enabled { return $_[0]{fullop_enabled} ? 1 : 0 }
    sub checkUserChannelLevel { return $_[0]{channel_75} ? 1 : 0 }
    $INC{'Mediabot/Helpers.pm'} = __FILE__;
}

use Mediabot::Fullop;

{
    package Local::Boundary::User;
    sub new { my ($class, %args) = @_; bless \%args, $class }
    sub is_authenticated { $_[0]{authenticated} ? 1 : 0 }
    sub has_level {
        my ($self, $level) = @_;
        return $self->{administrator} && $level eq 'Administrator' ? 1 : 0;
    }
    sub id { $_[0]{id} // 7 }

    package Local::Boundary::IRC;
    sub new { bless { nick => $_[1] // 'mediabot' }, $_[0] }
    sub is_nick_me { lc($_[1] // '') eq lc($_[0]{nick}) ? 1 : 0 }

    package Local::Boundary::Conf;
    sub new { bless { trusted => $_[1] // '' }, $_[0] }
    sub get {
        my ($self, $key) = @_;
        return 'EpiKnet' if $key eq 'connection.CONN_SERVER_NETWORK';
        return $self->{trusted} if $key eq 'fullop.TRUSTED_SERVICE_MASKS';
        return '';
    }
    sub get_int { return 600 }

    package Local::Boundary::Channel;
    sub get_id { 12 }

    package Local::Boundary::Bot;
    sub get_user_from_message { $_[0]{user} }
    sub gethChannelsNicksOnChan { return () }

    package Local::Boundary::Ban;
    sub new { bless { rows => [] }, $_[0] }
    sub mask_from_hostmask {
        my ($self, $prefix) = @_;
        my (undef, $ident, $host) = $prefix =~ /^([^!]+)!([^@]+)\@(.+)$/;
        return "*!*$ident\@$host";
    }
    sub add_ban {
        my ($self, %args) = @_;
        push @{ $self->{rows} }, \%args;
        return (scalar(@{ $self->{rows} }), undef);
    }
}

sub exercise {
    my (%args) = @_;
    my (@sent, @said);
    my $ban = Local::Boundary::Ban->new;
    my $bot = bless {
        fullop_enabled => 1,
        channel_75     => ($args{channel_75} // 0),
        user           => $args{user},
        irc            => Local::Boundary::IRC->new('mediabot'),
        conf           => Local::Boundary::Conf->new($args{trusted}),
        channels       => { '#open' => bless({}, 'Local::Boundary::Channel') },
    }, 'Local::Boundary::Bot';
    my $guard = Mediabot::Fullop->new(
        bot         => $bot,
        channel_ban => $ban,
        send_cb     => sub { push @sent, [@_]; 1 },
        announce_cb => sub { push @said, [@_]; 1 },
    );
    $guard->update_isupport('PREFIX=(qaohv)~&@%+', 'CHANMODES=beI,k,l,imnpst');
    my $result = $guard->handle_mode(
        channel     => '#open',
        prefix      => ($args{prefix} // 'Actor!ident@users.example'),
        message     => bless({}, 'Local::Boundary::Message'),
        mode_string => '+b',
        mode_args   => [ '*!*@blocked.example' ],
    );
    return ($result, \@sent, \@said, $ban);
}

my ($admin) = exercise(
    user => Local::Boundary::User->new(authenticated => 1, administrator => 1),
);
is($admin->{privileged}, 1, 'authenticated global Administrator is exempt');

my ($admin_unauth, $admin_unauth_sent, undef, $admin_unauth_ban) = exercise(
    user => Local::Boundary::User->new(authenticated => 0, administrator => 1),
);
is($admin_unauth->{sanctioned}, 1, 'Administrator label without authentication is denied');
is(scalar(@{ $admin_unauth_ban->{rows} }), 1, 'unauthenticated Administrator is kickbanned');

my ($channel_access) = exercise(
    user       => Local::Boundary::User->new(authenticated => 1),
    channel_75 => 1,
);
is($channel_access->{privileged}, 1, 'authenticated channel access 75 is exempt');

my ($no_channel_access, undef, undef, $no_channel_ban) = exercise(
    user       => Local::Boundary::User->new(authenticated => 1),
    channel_75 => 0,
);
is($no_channel_access->{sanctioned}, 1, 'authenticated user below channel 75 is denied');
is(scalar(@{ $no_channel_ban->{rows} }), 1, 'below-threshold actor receives the sanction');

my ($unknown, undef, undef, $unknown_ban) = exercise(user => undef);
is($unknown->{sanctioned}, 1, 'unknown IRC identity is denied');
is(scalar(@{ $unknown_ban->{rows} }), 1, 'unknown actor cannot gain privilege from nickname text');

my ($server, $server_sent, $server_said, $server_ban) = exercise(
    prefix => 'irc.epiknet.example',
    user   => undef,
);
is($server->{privileged}, 1, 'server-origin MODE is trusted');
is_deeply($server_sent, [], 'server-origin MODE is untouched');
is(scalar(@{ $server_ban->{rows} }), 0, 'server is never sanctioned');

my ($self, $self_sent, undef, $self_ban) = exercise(
    prefix => 'mediabot!bot@services.example',
    user   => undef,
);
is($self->{privileged}, 1, 'Mediabot own MODE correction is trusted');
is_deeply($self_sent, [], 'self MODE causes no loop');
is(scalar(@{ $self_ban->{rows} }), 0, 'self is never sanctioned');

my ($service, $service_sent, undef, $service_ban) = exercise(
    prefix  => 'ChanServ!service@services.epik.example',
    trusted => 'ChanServ!service@services.epik.example',
    user    => undef,
);
is($service->{privileged}, 1, 'configured complete service mask is trusted');
is_deeply($service_sent, [], 'trusted service MODE is untouched');
is(scalar(@{ $service_ban->{rows} }), 0, 'trusted service is never sanctioned');

done_testing();
