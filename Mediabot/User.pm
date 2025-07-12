package Mediabot::User;

use strict;
use warnings;
use Carp;

=head1 NAME

Mediabot::User - Represents a user in the Mediabot system.

=head1 SYNOPSIS

  use Mediabot::User;

  my $user = Mediabot::User->new($user_row);
  $user->load_level($dbh);
  $user->maybe_autologin($bot, $matched_hostmask);

=head1 DESCRIPTION

This module encapsulates a user known to the bot. It provides accessors
and utility methods such as privilege lookup and auto-login behavior.

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
    };

    bless $self, $class;
    return $self;
}

=head2 Accessors

Basic attribute accessors.

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

=head2 load_level($dbh)

Load the user's privilege level and description from the USER_LEVEL table.

=cut

sub load_level {
    my ($self, $dbh) = @_;
    return unless defined $self->{level_id};

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

Attempt to automatically log in the user based on config or DB flags.

=cut

sub maybe_autologin {
    my ($self, $bot, $matched_hostmask) = @_;

    my $conf = $bot->{conf};
    return if $self->{auth};  # Already logged in

    # Check Undernet-style auto-login based on hostmask suffix
    if (
        defined($conf->get('connection.CONN_NETWORK_TYPE')) &&
        $conf->get('connection.CONN_NETWORK_TYPE') eq "1" &&
        defined($conf->get('undernet.UNET_CSERVICE_HOSTMASK')) &&
        $conf->get('undernet.UNET_CSERVICE_HOSTMASK') ne ""
    ) {
        my $unet_mask = $conf->get('undernet.UNET_CSERVICE_HOSTMASK');
        if ($matched_hostmask =~ /$unet_mask$/) {
            my $sth = $bot->{dbh}->prepare("UPDATE USER SET auth=1 WHERE id_user=?");
            if ($sth->execute($self->{id})) {
                $self->{auth} = 1;
                $bot->{logger}->log(0, "Auto login (Undernet mask) for $self->{nickname} [$matched_hostmask]");
                $bot->noticeConsoleChan("Auto login (Undernet mask) for $self->{nickname} [$matched_hostmask]");
            }
            $sth->finish;
        }
    }

    # Check if the username field is '#AUTOLOGIN#'
    if (defined $self->{username} && $self->{username} eq '#AUTOLOGIN#') {
        my $sth = $bot->{dbh}->prepare("UPDATE USER SET auth=1 WHERE id_user=?");
        if ($sth->execute($self->{id})) {
            $self->{auth} = 1;
            $bot->{logger}->log(0, "Auto login (DB flag #AUTOLOGIN#) for $self->{nickname} [$matched_hostmask]");
            $bot->noticeConsoleChan("Auto login (DB flag #AUTOLOGIN#) for $self->{nickname} [$matched_hostmask]");
        }
        $sth->finish;
    }
}

=head1 AUTHOR

Christophe <teuk@teuk.org>

=cut

1;