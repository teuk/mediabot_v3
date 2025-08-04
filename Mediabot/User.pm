package Mediabot::User;

use strict;
use warnings;
use Carp;

=head1 NAME

Mediabot::User - Represents a user in the Mediabot system.

=head1 SYNOPSIS

  use Mediabot::User;

  my $user = Mediabot::User->new($user_row);
  $user->set_dbh($dbh);
  $user->load_level();
  $user->maybe_autologin($bot, $hostmask);

=head1 DESCRIPTION

This module encapsulates a user known to the bot. It provides accessors,
privilege-level management, and optional auto-login logic.

=cut

# Constructor
sub new {
    my ($class, $args) = @_;

    croak "Mediabot::User->new expects a hashref" unless ref($args) eq 'HASH';

    my $self = {
        id           => $args->{id_user},
        nickname     => $args->{nickname},
        password     => $args->{password},
        username     => $args->{username},
        hostmasks    => $args->{hostmasks},
        info1        => $args->{info1},
        info2        => $args->{info2},
        level_id     => $args->{id_user_level},
        auth         => $args->{auth},
        level        => undef,
        level_desc   => undef,
        dbh          => $args->{dbh},  # optional
    };

    bless $self, $class;
    return $self;
}

=head2 Accessors

=cut

sub id                { $_[0]->{id} }
sub nickname          { $_[0]->{nickname} }
sub username          { $_[0]->{username} }
sub password          { $_[0]->{password} }
sub info1             { $_[0]->{info1} }
sub info2             { $_[0]->{info2} }
sub level             { $_[0]->{level} }
sub level_description { $_[0]->{level_desc} }
sub is_authenticated  { $_[0]->{auth} ? 1 : 0 }
sub hostmasks         { $_[0]->{hostmasks} }

=head2 set_dbh($dbh)

Set or override the database handle for this user object.

=cut

sub set_dbh {
    my ($self, $dbh) = @_;
    $self->{dbh} = $dbh;
}

=head2 load_level([$dbh])

Loads the user's privilege level and description from the USER_LEVEL table.
Will use stored DBH if available.

=cut

sub load_level {
    my ($self, $dbh) = @_;
    $dbh //= $self->{dbh};
    return unless $dbh && defined $self->{level_id};

    my $sth = $dbh->prepare("SELECT * FROM USER_LEVEL WHERE id_user_level=?");
    if ($sth->execute($self->{level_id})) {
        if (my $ref = $sth->fetchrow_hashref) {
            $self->{level}      = $ref->{level};
            $self->{level_desc} = $ref->{description};
        }
    }
    $sth->finish;
}

=head2 maybe_autologin($bot, $matched_hostmask)

Try to log in the user automatically using config-based or DB-based flags.

=cut

sub maybe_autologin {
    my ($self, $bot, $matched_hostmask) = @_;
    return if $self->{auth};  # already logged in

    my $conf = $bot->{conf};
    my $dbh  = $bot->{dbh};
    $self->set_dbh($dbh);

    # Undernet hostmask-based auto-login
    if (
        defined($conf->get('connection.CONN_NETWORK_TYPE')) &&
        $conf->get('connection.CONN_NETWORK_TYPE') eq "1" &&
        defined($conf->get('undernet.UNET_CSERVICE_HOSTMASK')) &&
        $conf->get('undernet.UNET_CSERVICE_HOSTMASK') ne ""
    ) {
        my $unet_mask = $conf->get('undernet.UNET_CSERVICE_HOSTMASK');
        if ($matched_hostmask =~ /$unet_mask$/) {
            my $sth = $dbh->prepare("UPDATE USER SET auth=1 WHERE id_user=?");
            if ($sth->execute($self->{id})) {
                $self->{auth} = 1;
                $self->load_level($dbh);
                $bot->{logger}->log(0, "Auto login (Undernet mask) for $self->{nickname} [$matched_hostmask]");
                $bot->noticeConsoleChan("Auto login (Undernet mask) for $self->{nickname} [$matched_hostmask]");
            }
            $sth->finish;
        }
    }

    # #AUTOLOGIN# fallback
    if (defined $self->{username} && $self->{username} eq '#AUTOLOGIN#') {
        my $sth = $dbh->prepare("UPDATE USER SET auth=1 WHERE id_user=?");
        if ($sth->execute($self->{id})) {
            $self->{auth} = 1;
            $self->load_level($dbh);
            $bot->{logger}->log(0, "Auto login (DB flag #AUTOLOGIN#) for $self->{nickname} [$matched_hostmask]");
            $bot->noticeConsoleChan("Auto login (DB flag #AUTOLOGIN#) for $self->{nickname} [$matched_hostmask]");
        }
        $sth->finish;
    }
}

=head2 has_level($required_level [, $dbh])

Check if the user has at least the required level.
If a string is passed (e.g. "Administrator"), $dbh must be available or passed.

=cut

sub has_level {
    my ($self, $required_level, $dbh) = @_;
    $dbh //= $self->{dbh};
    return 0 unless defined $required_level && $dbh;

    $self->load_level($dbh) unless defined $self->{level};

    # Numeric level
    if ($required_level =~ /^\d+$/) {
        return ($self->{level} <= $required_level);
    }

    # Named level
    my $sth = $dbh->prepare("SELECT level FROM USER_LEVEL WHERE description = ?");
    if ($sth->execute($required_level)) {
        if (my $ref = $sth->fetchrow_hashref) {
            my $required_value = $ref->{level};
            return ($self->{level} <= $required_value);
        }
    }

    return 0;
}

# Handle method for compatibility with other parts of the bot
sub handle {
    my ($self) = @_;
    return $self->{nickname};  # or put a field like 'handle' if needed
}


=head1 AUTHOR

Christophe <teuk@teuk.org>

=cut

1;