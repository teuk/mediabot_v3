package Mediabot::Users::Levels;

use strict;
use warnings;
use utf8;
use Exporter 'import';

our @EXPORT_OK = qw(
    getIdUserLevel
    getLevelUser
    getUserLevelDesc
    getUserChannelLevel
);

# Read exact existing level rows; authorization stays with each caller.
sub getIdUserLevel {
    my ($self, $sLevel) = @_;

    return undef unless defined($sLevel) && $sLevel ne '';

    my $sQuery = "SELECT id_user_level FROM USER_LEVEL WHERE description = ?";
    my $sth = $self->{dbh}->prepare($sQuery);

    unless ($sth) {
        $self->{logger}->log(1, "getIdUserLevel() SQL prepare error : " . $DBI::errstr . " Query : " . $sQuery)
            if $self->{logger};
        return undef;
    }

    unless ($sth->execute($sLevel)) {
        $self->{logger}->log(1, "getIdUserLevel() SQL execute error : " . $DBI::errstr . " Query : " . $sQuery)
            if $self->{logger};
        $sth->finish;
        return undef;
    }

    my $id_user_level;
    if (my $ref = $sth->fetchrow_hashref()) {
        $id_user_level = $ref->{id_user_level};
    }

    $sth->finish;
    return $id_user_level;
}

sub getLevelUser {
    my ($self, $sUserHandle) = @_;

    return undef unless defined($sUserHandle) && $sUserHandle ne '';

    my $sQuery = "SELECT USER_LEVEL.level FROM USER JOIN USER_LEVEL ON USER_LEVEL.id_user_level = USER.id_user_level WHERE USER.nickname = ?";
    my $sth = $self->{dbh}->prepare($sQuery);

    unless ($sth) {
        $self->{logger}->log(1, "getLevelUser() SQL prepare error : " . $DBI::errstr . " Query : " . $sQuery)
            if $self->{logger};
        return undef;
    }

    unless ($sth->execute($sUserHandle)) {
        $self->{logger}->log(1, "getLevelUser() SQL execute error : " . $DBI::errstr . " Query : " . $sQuery)
            if $self->{logger};
        $sth->finish;
        return undef;
    }

    my $level;
    if (my $ref = $sth->fetchrow_hashref()) {
        $level = $ref->{level};
    }

    $sth->finish;
    return $level;
}

sub getUserLevelDesc {
    my ($self, $level) = @_;

    return undef unless defined($level) && $level ne '';

    my $sQuery = "SELECT description FROM USER_LEVEL WHERE level = ?";
    my $sth = $self->{dbh}->prepare($sQuery);

    unless ($sth) {
        $self->{logger}->log(1, "getUserLevelDesc() SQL prepare error : " . $DBI::errstr . " Query : " . $sQuery)
            if $self->{logger};
        return undef;
    }

    unless ($sth->execute($level)) {
        $self->{logger}->log(1, "getUserLevelDesc() SQL execute error : " . $DBI::errstr . " Query : " . $sQuery)
            if $self->{logger};
        $sth->finish;
        return undef;
    }

    my $sDescription;
    if (my $ref = $sth->fetchrow_hashref()) {
        $sDescription = $ref->{description};
    }

    $sth->finish;
    return $sDescription;
}

sub getUserChannelLevel {
    my ($self, $message, $sChannel, $id_user) = @_;

    return 0 unless defined($sChannel) && $sChannel ne '';
    return 0 unless defined($id_user)  && $id_user  ne '';

    my $sQuery = "SELECT USER_CHANNEL.level FROM CHANNEL JOIN USER_CHANNEL ON USER_CHANNEL.id_channel = CHANNEL.id_channel WHERE CHANNEL.name = ? AND USER_CHANNEL.id_user = ?";
    my $sth = $self->{dbh}->prepare($sQuery);

    unless ($sth) {
        $self->{logger}->log(1, "getUserChannelLevel() SQL prepare error : " . $DBI::errstr . " Query : " . $sQuery)
            if $self->{logger};
        return 0;
    }

    unless ($sth->execute($sChannel, $id_user)) {
        $self->{logger}->log(1, "getUserChannelLevel() SQL execute error : " . $DBI::errstr . " Query : " . $sQuery)
            if $self->{logger};
        $sth->finish;
        return 0;
    }

    my $iLevel = 0;
    if (my $ref = $sth->fetchrow_hashref()) {
        $iLevel = $ref->{level} // 0;
    }

    $sth->finish;
    return $iLevel;
}

1;
