package Mediabot::Plugin::PrincipalV3;

use strict;
use warnings;
use utf8;

use Encode qw(encode);
use Scalar::Util qw(refaddr);

my %STATE;

my %LEVEL_RANK = (
    anonymous     => 4,
    user          => 3,
    administrator => 2,
    master        => 1,
    owner         => 0,
);

sub _state {
    my ($self) = @_;
    return $STATE{ refaddr($self) };
}

sub _account {
    my ($value) = @_;
    die "PrincipalV3: account is required\n"
        unless defined($value) && !ref($value);
    my $account = "$value";
    die "PrincipalV3: invalid account\n"
        unless length($account)
            && length(encode('UTF-8', $account)) <= 64
            && $account !~ /[\r\n\0]/;
    return $account;
}

sub _channel_level {
    my ($value) = @_;
    $value = 0 unless defined $value;
    die "PrincipalV3: invalid channel level\n"
        unless !ref($value) && "$value" =~ /\A[0-9]+\z/
            && $value >= 0 && $value <= 500;
    return 0 + $value;
}

sub new {
    my ($class, %args) = @_;
    my $authenticated = $args{authenticated} ? 1 : 0;
    my ($user_id, $account, $global_level, $channel_level);

    if ($authenticated) {
        die "PrincipalV3: invalid user id\n"
            unless defined($args{user_id}) && !ref($args{user_id})
                && "$args{user_id}" =~ /\A[1-9][0-9]*\z/;
        $user_id = 0 + $args{user_id};
        $account = _account($args{account});
        $global_level = lc($args{global_level} // '');
        die "PrincipalV3: invalid global level\n"
            unless exists($LEVEL_RANK{$global_level})
                && $global_level ne 'anonymous';
        $channel_level = _channel_level($args{channel_level});
    }
    else {
        ($user_id, $account, $global_level, $channel_level) =
            (undef, '', 'anonymous', 0);
    }

    my $opaque = 0;
    my $self = bless \$opaque, $class;
    $STATE{ refaddr($self) } = {
        authenticated => $authenticated,
        user_id       => $user_id,
        account       => $account,
        global_level  => $global_level,
        channel_level => $channel_level,
    };
    return $self;
}

sub anonymous {
    my ($class) = @_;
    return $class->new(authenticated => 0);
}

sub authenticated { _state($_[0])->{authenticated} ? 1 : 0 }
sub user_id       { _state($_[0])->{user_id} }
sub account       { _state($_[0])->{account} }
sub global_level  { _state($_[0])->{global_level} }
sub channel_level { _state($_[0])->{channel_level} }

sub has_global_level {
    my ($self, $required) = @_;
    return 0 unless defined($required) && !ref($required);
    $required = lc "$required";
    return 0 unless exists($LEVEL_RANK{$required});
    my $current = _state($self)->{global_level};
    return $LEVEL_RANK{$current} <= $LEVEL_RANK{$required} ? 1 : 0;
}

sub has_channel_level {
    my ($self, $required) = @_;
    return 0 unless defined($required) && !ref($required)
        && "$required" =~ /\A[0-9]+\z/
        && $required >= 0 && $required <= 500;
    return _state($self)->{channel_level} >= $required ? 1 : 0;
}

sub snapshot {
    my ($self) = @_;
    my $state = _state($self);
    return {
        authenticated => $state->{authenticated} ? 1 : 0,
        user_id       => $state->{user_id},
        account       => $state->{account},
        global_level  => $state->{global_level},
        channel_level => $state->{channel_level},
    };
}

sub DESTROY {
    my ($self) = @_;
    delete $STATE{ refaddr($self) };
}

1;
