#!/usr/bin/perl

use strict;
use warnings;
use utf8;
use Test::More;
use lib '.';

use Mediabot::Fullop;

{
    package Local::Fullop::ChannelBan;

    sub new {
        my ($class, %args) = @_;
        return bless {
            added         => [],
            error         => $args{error},
            existing_mask => $args{existing_mask},
        }, $class;
    }
    sub mask_from_hostmask {
        my ($self, $prefix) = @_;
        my (undef, $ident, $host) = $prefix =~ /^([^!]+)!([^@]+)\@(.+)$/;
        return defined($host) ? "*!*$ident\@$host" : undef;
    }
    sub add_ban {
        my ($self, %args) = @_;
        push @{ $self->{added} }, { %args };
        return (undef, $self->{error}) if defined $self->{error};
        return (scalar(@{ $self->{added} }), undef);
    }
    sub active_ban_for_mask {
        my ($self) = @_;
        return undef unless defined $self->{existing_mask};
        return { id_channel_ban => 9, mask => $self->{existing_mask} };
    }
}

sub build_guard {
    my (%opts) = @_;
    my (@sent, @announced);
    my $bans = Local::Fullop::ChannelBan->new(
        error         => $opts{ban_error},
        existing_mask => $opts{existing_mask},
    );
    my $guard = Mediabot::Fullop->new(
        network       => ($opts{network} // 'UnknownNet'),
        channel_ban   => $bans,
        enabled_cb    => sub { $opts{enabled} // 1 },
        privileged_cb => sub { $opts{privileged} // 0 },
        channel_id_cb => sub { 42 },
        nicklist_cb   => sub { @{ $opts{nicks} || [] } },
        send_cb       => sub { push @sent, [@_]; return 1 },
        announce_cb   => sub { push @announced, [@_]; return 1 },
    );
    return ($guard, \@sent, \@announced, $bans);
}

my ($libera, $libera_sent, $libera_announced, $libera_bans) =
    build_guard(network => 'Libera.Chat');
$libera->update_isupport(
    'NETWORK=Libera.Chat',
    'PREFIX=(qaohv)~&@%+',
    'CHANMODES=beI,k,l,imnpst',
    'MODES=3',
    'CASEMAPPING=rfc1459',
);

is_deeply(
    [ $libera->names_from_blob('~Owner @+Alice Bob') ],
    [ qw(Owner Alice Bob) ],
    'NAMES tokens are normalized with live multi-prefix semantics',
);

my @q = $libera->parse_mode_changes('+q', 'Alice');
is($q[0]{category}, 'status', 'Libera +q is parsed as an owner status, not a quiet list');

my @mixed = $libera->parse_mode_changes('+b-o', '*!*@victim.example', 'Victim');
is_deeply(
    [ map { [ @{$_}{qw(sign mode category arg)} ] } @mixed ],
    [
        [ '+', 'b', 'A',      '*!*@victim.example' ],
        [ '-', 'o', 'status', 'Victim' ],
    ],
    'ISUPPORT drives mixed MODE argument consumption',
);

my $result = $libera->handle_mode(
    channel     => '#open',
    prefix      => 'BadOp!ident@users.example',
    mode_string => '+b-o',
    mode_args   => [ '*!*@victim.example', 'Victim' ],
);
is($result->{protected}, 2, 'ban and deop are both protected');
is($result->{sanctioned}, 1, 'one sanction is issued for the MODE line');
is(scalar(@{ $libera_bans->{added} }), 1, 'one persistent ban is stored');
is($libera_bans->{added}[0]{expires_seconds}, 600, 'sanction lasts ten minutes');
is($libera_bans->{added}[0]{source}, 'fullop', 'sanction source is auditable');
is($libera_bans->{added}[0]{reason}, q{hey ho, c'est pas le genre de la maison},
    'required French reason is preserved exactly');
is_deeply(
    $libera_announced,
    [[ '#open', q{BadOp: hey ho, c'est pas le genre de la maison} ]],
    'the fixed response is visible once on channel',
);
is_deeply(
    $libera_sent,
    [
        [ 'MODE', undef, '#open', '-b', '*!*@victim.example' ],
        [ 'MODE', undef, '#open', '+o', 'Victim' ],
        [ 'MODE', undef, '#open', '+b', '*!*ident@users.example' ],
        [ 'KICK', undef, '#open', 'BadOp', q{hey ho, c'est pas le genre de la maison} ],
    ],
    'restriction is reversed before the ten-minute kickban',
);

my ($trusted, $trusted_sent, $trusted_announced, $trusted_bans) =
    build_guard(network => 'Libera.Chat', privileged => 1);
$trusted->update_isupport('PREFIX=(qaohv)~&@%+', 'CHANMODES=beI,k,l,imnpst');
my $trusted_result = $trusted->handle_mode(
    channel     => '#open',
    prefix      => 'Admin!ident@users.example',
    mode_string => '+b',
    mode_args   => [ '*!*@blocked.example' ],
);
is($trusted_result->{privileged}, 1, 'authenticated privileged actor is exempt');
is_deeply($trusted_sent, [], 'privileged restriction is not reversed');
is_deeply($trusted_announced, [], 'privileged actor is not admonished');
is(scalar(@{ $trusted_bans->{added} }), 0, 'privileged actor is not sanctioned');

my ($quiet, $quiet_sent, $quiet_announced, $quiet_bans) =
    build_guard(network => 'GenericNet');
$quiet->update_isupport('PREFIX=(ohv)@%+', 'CHANMODES=bqeI,k,l,imnpst');
my @quiet_change = $quiet->parse_mode_changes('+q', '*!*@talker.example');
is($quiet_change[0]{category}, 'A', 'generic +q is a quiet list when CHANMODES says so');
$quiet->handle_mode(
    channel     => '#open',
    prefix      => 'BadOp!ident@users.example',
    mode_string => '+q',
    mode_args   => [ '*!*@talker.example' ],
);
is_deeply($quiet_sent->[0], [ 'MODE', undef, '#open', '-q', '*!*@talker.example' ],
    'quiet is immediately removed');

my ($epik, $epik_sent, $epik_announced, $epik_bans) =
    build_guard(network => 'EpiKnet');
$epik->update_isupport('PREFIX=(qaohv)~&@%+', 'CHANMODES=beI,kLM,l,imnpst');
$epik->handle_mode(
    channel     => '#open',
    prefix      => 'BadOp!ident@users.example',
    mode_string => '+M',
    mode_args   => [ 'account-only' ],
);
is_deeply($epik_sent->[0], [ 'MODE', undef, '#open', '-M', 'account-only' ],
    'network profile protects an EpiK/InspIRCd restriction');

my ($stateful, $stateful_sent) = build_guard(network => 'GenericNet');
$stateful->update_isupport('PREFIX=(ov)@+', 'CHANMODES=beI,k,l,imnpst');
$stateful->remember_channel_modes('#open', '+mk', 'old-secret');
$stateful->handle_mode(
    channel     => '#open',
    prefix      => 'BadOp!ident@users.example',
    mode_string => '+k',
    mode_args   => [ 'new-secret' ],
);
is_deeply(
    [ @$stateful_sent[0, 1] ],
    [
        [ 'MODE', undef, '#open', '-k', 'new-secret' ],
        [ 'MODE', undef, '#open', '+k', 'old-secret' ],
    ],
    'a replaced channel key is removed and the prior key is restored',
);

my ($key_remove, $key_remove_sent) = build_guard(network => 'GenericNet');
$key_remove->update_isupport('PREFIX=(ov)@+', 'CHANMODES=beI,k,l,imnpst');
$key_remove->remember_channel_modes('#open', '+k', 'old-secret');
$key_remove->handle_mode(
    channel     => '#open',
    prefix      => 'BadOp!ident@users.example',
    mode_string => '-k',
    mode_args   => [ '*' ],
);
is_deeply($key_remove_sent->[0], [ 'MODE', undef, '#open', '+k', 'old-secret' ],
    'a hidden -k argument is repaired from the numeric 324 state');

my ($duplicate, $duplicate_sent) = build_guard(network => 'GenericNet');
$duplicate->update_isupport('PREFIX=(ov)@+', 'CHANMODES=beI,k,l,imnpst');
$duplicate->remember_channel_modes('#open', '+m');
$duplicate->handle_mode(
    channel     => '#open',
    prefix      => 'BadOp!ident@users.example',
    mode_string => '+m',
    mode_args   => [],
);
is_deeply($duplicate_sent->[0],
    [ 'MODE', undef, '#open', '+b', '*!*ident@users.example' ],
    'a duplicate restrictive mode never removes a pre-existing trusted mode');

my ($persist_fail, $persist_fail_sent, $persist_fail_announced) = build_guard(
    network   => 'GenericNet',
    ban_error => 'database execute error',
);
$persist_fail->update_isupport('PREFIX=(ov)@+', 'CHANMODES=beI,k,l,imnpst');
my $persist_fail_result = $persist_fail->handle_mode(
    channel     => '#open',
    prefix      => 'BadOp!ident@users.example',
    mode_string => '+m',
    mode_args   => [],
);
is($persist_fail_result->{corrected}, 1,
    'restriction is still reversed when persistent sanction storage fails');
is($persist_fail_result->{sanctioned}, 0,
    'failed persistent storage is not reported as a ten-minute sanction');
is_deeply(
    $persist_fail_sent,
    [
        [ 'MODE', undef, '#open', '-m' ],
        [ 'KICK', undef, '#open', 'BadOp', q{hey ho, c'est pas le genre de la maison} ],
    ],
    'storage failure kicks the actor but never creates an unmanaged IRC ban',
);
is_deeply(
    $persist_fail_announced,
    [[ '#open', q{BadOp: hey ho, c'est pas le genre de la maison} ]],
    'storage failure keeps the required visible warning',
);

my ($existing_ban, $existing_ban_sent) = build_guard(
    network       => 'GenericNet',
    ban_error     => 'an active ban already exists for *!*ident@users.example (id 9)',
    existing_mask => '*!*@users.example',
);
$existing_ban->update_isupport('PREFIX=(ov)@+', 'CHANMODES=beI,k,l,imnpst');
my $existing_ban_result = $existing_ban->handle_mode(
    channel     => '#open',
    prefix      => 'BadOp!ident@users.example',
    mode_string => '+m',
    mode_args   => [],
);
is($existing_ban_result->{sanctioned}, 1,
    'an already active durable ban remains safe to enforce');
is_deeply(
    $existing_ban_sent,
    [
        [ 'MODE', undef, '#open', '-m' ],
        [ 'MODE', undef, '#open', '+b', '*!*@users.example' ],
        [ 'KICK', undef, '#open', 'BadOp', q{hey ho, c'est pas le genre de la maison} ],
    ],
    'an existing durable ban reuses the exact mask the expiry worker will remove',
);

my ($topic, $topic_sent, $topic_announced, $topic_bans) =
    build_guard(network => 'GenericNet');
$topic->update_isupport('PREFIX=(ov)@+', 'CHANMODES=beI,k,l,imnpst');
my $topic_result = $topic->handle_mode(
    channel     => '#open',
    prefix      => 'FriendlyOp!ident@users.example',
    mode_string => '+t',
    mode_args   => [],
);
is($topic_result->{sanctioned}, 0, 'non-restrictive topic protection is left alone');
is_deeply($topic_sent, [], 'ordinary harmless MODE is untouched');
is(scalar(@{ $topic_bans->{added} }), 0, 'harmless MODE causes no ban');

my ($joins, $join_sent) = build_guard(
    network => 'GenericNet',
    nicks   => [qw(Alice Bob Carol Dave)],
);
$joins->update_isupport('MODES=3');
is($joins->sweep_channel('#open'), 4, 'current users are swept immediately');
is_deeply(
    $join_sent,
    [
        [ 'MODE', undef, '#open', '+ooo', qw(Alice Bob Carol) ],
        [ 'MODE', undef, '#open', '+o', 'Dave' ],
    ],
    'op sweep respects the server-advertised MODES limit',
);

my ($casemap, $casemap_sent) = build_guard(network => 'GenericNet');
$casemap->update_isupport('MODES=4', 'CASEMAPPING=rfc1459');
is($casemap->sweep_channel('#open', '[Alice', '{Alice'), 1,
    'RFC1459-equivalent nick spellings are deduplicated');
is_deeply($casemap_sent->[0], [ 'MODE', undef, '#open', '+o', '[Alice' ],
    'op sweep keeps the first server spelling after casemap deduplication');

my ($disabled, $disabled_sent) = build_guard(enabled => 0);
is($disabled->handle_join('#closed', 'Alice'), 0, 'feature fails closed without +Fullop');
is_deeply($disabled_sent, [], 'disabled channel receives no IRC mutation');

done_testing();
