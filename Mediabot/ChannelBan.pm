package Mediabot::ChannelBan;

use strict;
use warnings;
use POSIX qw(strftime);

# =============================================================================
# Mediabot::ChannelBan
#
# Persistent channel bans for Mediabot v3.
#
# This module intentionally does not dispatch IRC commands by itself.
# It provides safe helpers used by command handlers:
#   - duration parsing
#   - ban level validation
#   - mask validation
#   - DB insert/list/remove/expire helpers
# =============================================================================

use constant MIN_BAN_LEVEL => 75;

sub new {
    my ($class, %args) = @_;

    my $self = {
        bot    => $args{bot},
        dbh    => $args{dbh},
        logger => $args{logger},
    };

    die "Mediabot::ChannelBan requires dbh" unless $self->{dbh};

    return bless $self, $class;
}

sub min_ban_level {
    return MIN_BAN_LEVEL;
}

# -----------------------------------------------------------------------------
# parse_duration($text)
#
# Accepted examples:
#   10m, 2h, 3d, 1w
#   30     -> minutes
#   0      -> permanent
#   perm, permanent, never -> permanent
#
# Returns:
#   (seconds, normalized_label, error)
# -----------------------------------------------------------------------------
sub parse_duration {
    my ($self, $text) = @_;

    $text = '' unless defined $text;
    $text =~ s/^\s+|\s+$//g;

    return (0, 'permanent', undef) if $text eq '';
    return (0, 'permanent', undef) if $text =~ /^(?:perm|permanent|never)$/i;

    if ($text =~ /^(\d+)$/) {
        my $minutes = int($1);
        # A bare "0" should be written as "perm" — caught above.
        # A plain number of 0 minutes is meaningless as a timed ban.
        return (undef, undef, "duration cannot be zero — use 'perm' for permanent bans")
            if $minutes == 0;
        return ($minutes * 60, "${minutes}m", undef);
    }

    unless ($text =~ /^(\d+)([mhdw])$/i) {
        return (undef, undef, "invalid duration '$text' (use 10m, 2h, 3d, 1w, or permanent)");
    }

    my ($n, $unit) = (int($1), lc($2));
    return (undef, undef, "duration must be positive") if $n <= 0;

    my %mult = (
        m => 60,
        h => 3600,
        d => 86400,
        w => 604800,
    );

    return ($n * $mult{$unit}, "$n$unit", undef);
}

sub expires_sql_from_seconds {
    my ($self, $seconds) = @_;

    return undef unless defined $seconds;
    return undef if $seconds <= 0;

    my $ts = time + $seconds;
    return strftime('%Y-%m-%d %H:%M:%S', localtime($ts));
}

# -----------------------------------------------------------------------------
# parse_ban_level($text, $actor_channel_level)
#
# Default ban level is actor channel level, with minimum 75.
# Explicit level must be:
#   >= 75
#   <= actor channel level
# -----------------------------------------------------------------------------
sub parse_ban_level {
    my ($self, $text, $actor_level) = @_;

    $actor_level = int($actor_level || 0);

    return (undef, "channel level $actor_level is below minimum ban level " . MIN_BAN_LEVEL)
        if $actor_level < MIN_BAN_LEVEL;

    if (!defined($text) || $text eq '') {
        my $level = $actor_level;
        $level = MIN_BAN_LEVEL if $level < MIN_BAN_LEVEL;
        return ($level, undef);
    }

    unless ($text =~ /^\d+$/) {
        return (undef, "invalid ban level '$text'");
    }

    my $level = int($text);

    return (undef, "ban level must be at least " . MIN_BAN_LEVEL)
        if $level < MIN_BAN_LEVEL;

    return (undef, "you cannot set a ban level higher than your channel level ($actor_level)")
        if $level > $actor_level;

    return ($level, undef);
}

# -----------------------------------------------------------------------------
# looks_like_duration($arg)
# looks_like_level($arg)
# -----------------------------------------------------------------------------
sub looks_like_duration {
    my ($self, $arg) = @_;
    return 0 unless defined $arg;
    return $arg =~ /^(?:\d+[mhdw]?|perm|permanent|never)$/i ? 1 : 0;
}

sub looks_like_level {
    my ($self, $arg) = @_;
    return 0 unless defined $arg;
    return $arg =~ /^\d+$/ ? 1 : 0;
}

# -----------------------------------------------------------------------------
# mask_from_hostmask($hostmask)
#
# Input examples:
#   nick!ident@host
#   ident@host
#
# Output:
#   *!ident@host
# -----------------------------------------------------------------------------
sub mask_from_hostmask {
    my ($self, $hostmask) = @_;

    return unless defined $hostmask;

    $hostmask =~ s/^\s+|\s+$//g;
    return if $hostmask eq '';

    if ($hostmask =~ /^([^!]+)!([^@]+)\@(.+)$/) {
        my ($ident, $host) = ($2, $3);
        $ident =~ s/^~//;
        return "*!*$ident\@$host";
    }

    if ($hostmask =~ /^([^@]+)\@(.+)$/) {
        my ($ident, $host) = ($1, $2);
        $ident =~ s/^~//;
        return "*!*$ident\@$host";
    }

    return;
}

# -----------------------------------------------------------------------------
# normalize_mask($target)
#
# If a full mask is given, keep it normalized.
# If a plain nick is given, command handler should resolve it to a hostmask first.
# -----------------------------------------------------------------------------
sub normalize_mask {
    my ($self, $mask) = @_;

    return unless defined $mask;

    $mask =~ s/^\s+|\s+$//g;
    return if $mask eq '';

    # Basic nick-like input: let caller resolve nick -> hostmask.
    return $mask if $mask !~ /[!@*?]/;

    # user@host -> *!user@host
    if ($mask !~ /!/ && $mask =~ /\@/) {
        $mask = "*!$mask";
    }

    return $mask;
}

# -----------------------------------------------------------------------------
# validate_mask($mask)
#
# Refuses dangerous broad masks.
# This is intentionally conservative.
# -----------------------------------------------------------------------------
sub validate_mask {
    my ($self, $mask) = @_;

    return "empty ban mask" unless defined $mask && $mask ne '';

    $mask =~ s/^\s+|\s+$//g;

    return "empty ban mask" unless $mask ne '';
    return "ban mask too long" if length($mask) > 255;

    # Use index() instead of regex for @ to avoid escaping/interpolation traps.
    return 'ban mask must contain a host part' unless index($mask, '@') >= 0;
    return 'ban mask must contain nick!user@host form' unless index($mask, '!') >= 0;

    my ($left, $host) = split(/\@/, $mask, 2);
    return "ban mask has empty host" unless defined $host && $host ne '';

    my ($nick, $user) = split(/!/, $left, 2);
    $nick = '' unless defined $nick;
    $user = '' unless defined $user;

    return "ban mask has empty nick part" unless $nick ne '';
    return "ban mask has empty user part" unless $user ne '';

    my $compact = lc($mask);
    $compact =~ s/\s+//g;

    my %forbidden = map { $_ => 1 } (
        '*!*@*',
        '*!*@*.*',
        '*!*@?',
        '*!*@??',
        '*@*',
        '*!*',
        '*',
    );

    return "ban mask is too broad: $mask" if $forbidden{$compact};

    return "ban mask host is too broad" if $host =~ /^\*+$/;

    # Refuse masks where both user and host are basically wildcard-only.
    return "ban mask user/host is too broad"
        if $user =~ /^[\*\?]+$/ && $host =~ /^[\*\?\.]+$/;

    # Require at least some fixed host material.
    my $host_material = $host;
    $host_material =~ s/[\*\?\.:-]//g;
    return "ban mask host has no useful fixed part" if length($host_material) < 2;

    return undef;
}

sub active_ban_for_mask {
    my ($self, $id_channel, $mask) = @_;

    my $sth = $self->{dbh}->prepare(q{
        SELECT
            id_channel_ban,
            id_channel,
            mask,
            ban_level,
            reason,
            created_by,
            created_by_nick,
            created_at,
            expires_at,
            active,
            source
        FROM CHANNEL_BAN
        WHERE id_channel = ?
          AND mask = ?
          AND active = 1
        ORDER BY id_channel_ban DESC
        LIMIT 1
    });

    $sth->execute($id_channel, $mask);
    my $row = $sth->fetchrow_hashref;
    $sth->finish;

    return $row;
}

# -----------------------------------------------------------------------------
# add_ban(...)
# -----------------------------------------------------------------------------
sub add_ban {
    my ($self, %args) = @_;

    my $id_channel = $args{id_channel};
    my $mask       = $args{mask};
    my $ban_level  = $args{ban_level} || MIN_BAN_LEVEL;

    return (undef, "missing id_channel") unless $id_channel;
    return (undef, "missing mask")       unless $mask;

    if (my $err = $self->validate_mask($mask)) {
        return (undef, $err);
    }

    if (my $existing = $self->active_ban_for_mask($id_channel, $mask)) {
        return (undef, "an active ban already exists for $mask (id $existing->{id_channel_ban})");
    }

    my $sth = $self->{dbh}->prepare(q{
        INSERT INTO CHANNEL_BAN
            (
                id_channel,
                mask,
                ban_level,
                reason,
                created_by,
                created_by_nick,
                expires_at,
                active,
                source
            )
        VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?)
    });

    $sth->execute(
        $id_channel,
        $mask,
        $ban_level,
        $args{reason},
        $args{created_by},
        $args{created_by_nick},
        $args{expires_at},
        $args{source} || 'irc',
    );

    my $id = $self->{dbh}->{mysql_insertid};
    $sth->finish;

    return ($id, undef);
}

# -----------------------------------------------------------------------------
# list_active_bans($id_channel)
# -----------------------------------------------------------------------------
sub list_active_bans {
    my ($self, $id_channel) = @_;

    my $sth = $self->{dbh}->prepare(q{
        SELECT
            id_channel_ban,
            id_channel,
            mask,
            ban_level,
            reason,
            created_by,
            created_by_nick,
            created_at,
            expires_at,
            active,
            source
        FROM CHANNEL_BAN
        WHERE id_channel = ?
          AND active = 1
        ORDER BY id_channel_ban ASC
    });

    $sth->execute($id_channel);

    my @rows;
    while (my $row = $sth->fetchrow_hashref) {
        push @rows, $row;
    }

    $sth->finish;

    return @rows;
}

# -----------------------------------------------------------------------------
# mark_removed(...)
# -----------------------------------------------------------------------------
sub mark_removed {
    my ($self, %args) = @_;

    my $id_channel = $args{id_channel};
    my $selector   = $args{selector};

    return (0, "missing id_channel") unless $id_channel;
    return (0, "missing selector")   unless defined $selector && $selector ne '';

    my ($where, @bind);

    if ($selector =~ /^\d+$/) {
        $where = "id_channel_ban = ?";
        @bind  = ($selector);
    }
    else {
        $where = "mask = ?";
        @bind  = ($selector);
    }

    my $sql = qq{
        UPDATE CHANNEL_BAN
        SET
            active = 0,
            removed_by = ?,
            removed_by_nick = ?,
            removed_at = NOW(),
            remove_reason = ?
        WHERE id_channel = ?
          AND active = 1
          AND $where
    };

    my $sth = $self->{dbh}->prepare($sql);
    $sth->execute(
        $args{removed_by},
        $args{removed_by_nick},
        $args{remove_reason} || 'manual unban',
        $id_channel,
        @bind,
    );

    my $rows = $sth->rows;
    $sth->finish;

    return ($rows, undef);
}

# -----------------------------------------------------------------------------
# expired_bans()
# -----------------------------------------------------------------------------
sub expired_bans {
    my ($self) = @_;

    my $sth = $self->{dbh}->prepare(q{
        SELECT
            id_channel_ban,
            id_channel,
            mask,
            ban_level,
            reason,
            created_by,
            created_by_nick,
            created_at,
            expires_at,
            active,
            source
        FROM CHANNEL_BAN
        WHERE active = 1
          AND expires_at IS NOT NULL
          AND expires_at <= NOW()
        ORDER BY expires_at ASC
    });

    $sth->execute;

    my @rows;
    while (my $row = $sth->fetchrow_hashref) {
        push @rows, $row;
    }

    $sth->finish;

    return @rows;
}

1;

__END__

=head1 NAME

Mediabot::ChannelBan - Persistent channel bans for Mediabot v3

=head1 DESCRIPTION

This module stores and validates channel bans. It does not directly dispatch IRC
commands. Public command handlers call this module to create, list, remove and
expire bans.

=head1 SECURITY

The minimum ban level is 75. Dangerous masks such as C<*!*@*> are refused.

=cut
