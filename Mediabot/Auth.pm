package Mediabot::Auth;
use strict;
use warnings;
use Digest::SHA qw(sha1 sha1_hex);
use Scalar::Util qw(blessed);

# ------------------------------------------------------------------------------
# Simple logger wrapper (falls back to STDOUT if no logger was provided)
# ------------------------------------------------------------------------------
sub _log {
    my ($self, $level, $msg) = @_;
    $level ||= 3; # 0=ERROR 1=WARN 2=INFO 3=DEBUG
    if ($self->{logger} && $self->{logger}->can('log')) {
        $self->{logger}->log($level, $msg);
    } else {
        my $lvl = ('ERROR','WARN','INFO','DEBUG')[$level] // $level;
        my ($sec,$min,$hour,$mday,$mon,$year) = (localtime())[0..5];
        $year += 1900; $mon += 1;
        printf STDERR "[%02d/%02d/%04d %02d:%02d:%02d] [%s] %s\n",
            $mday,$mon,$year,$hour,$min,$sec,$lvl,$msg;
    }
}

# ------------------------------------------------------------------------------
# Constructor
# ------------------------------------------------------------------------------
sub new {
    my ($class, %args) = @_;
    my $self = bless {
        dbh    => $args{dbh},       # DBI handle
        logger => $args{logger},    # optional object with ->log($level,$msg)
        conf   => $args{conf} || {},# optional config hash
    }, $class;
    return $self;
}

# ------------------------------------------------------------------------------
# Public API
# ------------------------------------------------------------------------------

# verify_credentials($user_id_or_nick, $login_nickname, $clear_password)
# Returns: boolean
sub verify_credentials {
    my ($self, $user_id_or_nick, $login_nick, $clear) = @_;
    my $dbh = $self->{dbh};

    # Resolve the user row
    my ($where, $val) = ($user_id_or_nick =~ /^\d+$/)
        ? ('id_user = ?', $user_id_or_nick)
        : ('nickname = ?', $user_id_or_nick);

    my $sql = "SELECT id_user, nickname, password FROM USER WHERE $where";
    my $row;
    eval {
        my $sth = $dbh->prepare($sql);
        $sth->execute($val);
        $row = $sth->fetchrow_hashref;
        $sth->finish;
    };
    if ($@) {
        $self->_log(0, "verify_credentials: DB error while fetching user ($val): $@");
        return 0;
    }
    unless ($row) {
        $self->_log(2, "verify_credentials: no such user for '$val'");
        return 0;
    }

    my $stored = $row->{password} // '';
    my $uid    = $row->{id_user};
    my $nick   = $row->{nickname};

    # Handle empty password in DB
    unless (defined $stored && length $stored) {
        $self->_log(2, "verify_credentials: user id=$uid nick=$nick has no password set");
        return 0;
    }

    # Compare against multiple formats
    my ($ok, $why) = _password_matches($clear, $stored);
    $self->_log(3, sprintf("🔐 verify_credentials: id=%s nick=%s login_nick=%s match=%s (%s)",
                           $uid, $nick, ($login_nick//''), $ok ? 'YES' : 'NO', $why));
    return $ok ? 1 : 0;
}

# maybe_autologin($user_like, $fullmask)
# $user_like can be a hashref, Mediabot::User object, or user id/nick
# Returns: (did_autologin:boolean, reason:string)
sub maybe_autologin {
    my ($self, $user_like, $fullmask) = @_;
    my $dbh = $self->{dbh};

    my ($user, $err) = $self->_resolve_user($user_like);
    if (!$user) {
        return (0, "resolve_user_failed: $err");
    }

    my $uid  = $user->{id_user};
    my $nick = $user->{nickname} // '';
    my $username = $user->{username} // '';
    my $hostmasks = $user->{hostmasks} // '';

    # Only when username is '#AUTOLOGIN#'
    unless (defined $username && $username eq '#AUTOLOGIN#') {
        return (0, "autologin_disabled(username='$username')");
    }

    # Extract userhost from fullmask (nick!user@host -> user@host)
    my $userhost = $fullmask;
    $userhost =~ s/^.*?!(.+)$/$1/; # keep everything after '!'
    $self->_log(3, "AUTOLOGIN: uid=$uid nick=$nick userhost='$userhost' masks='$hostmasks'");

    # Iterate masks
    my @masks = grep { length } map { _trim($_) } split /,/, ($hostmasks // '');
    unless (@masks) {
        return (0, "no_hostmasks_configured");
    }

    my $matched;
    for my $mask (@masks) {
        my $rx = _glob_to_re($mask);
        if ($userhost =~ $rx) {
            $matched = $mask;
            last;
        }
    }

    unless ($matched) {
        return (0, "no_mask_matched(userhost='$userhost')");
    }

    # Flip auth=1 in DB and last_login NOW()
    my $rows = 0;
    eval {
        my $sth = $dbh->prepare("UPDATE USER SET auth=1, last_login=NOW() WHERE id_user=?");
        $sth->execute($uid);
        $rows = $sth->rows;
        $sth->finish;
    };
    if ($@) {
        $self->_log(0, "AUTOLOGIN: DB error while updating auth for uid=$uid: $@");
        return (0, "db_update_failed");
    }

    $self->_log(3, "AUTOLOGIN: success uid=$uid nick=$nick mask_matched='$matched' rows=$rows");
    return (1, "ok");
}

# Check if userhost matches any stored masks without mutating state
# Returns: (boolean, matched_mask|string, regex_used)
sub hostmask_matches {
    my ($self, $user_like, $fullmask) = @_;
    my ($user, $err) = $self->_resolve_user($user_like);
    return (0, "resolve_user_failed: $err") unless $user;

    my $userhost = $fullmask;
    $userhost =~ s/^.*?!(.+)$/$1/;
    for my $mask (grep { length } map { _trim($_) } split /,/, ($user->{hostmasks}//'')) {
        my $rx = _glob_to_re($mask);
        if ($userhost =~ $rx) {
            return (1, $mask, $rx);
        }
    }
    return (0, undef, undef);
}

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

sub _resolve_user {
    my ($self, $user_like) = @_;
    my $dbh = $self->{dbh};

    # Already a hashref with required fields
    if (ref $user_like eq 'HASH' && exists $user_like->{id_user}) {
        return ($user_like, undef);
    }
    # Mediabot::User object -> try known accessors or hash internals
    if (blessed($user_like)) {
        my $uid  = eval { $user_like->id } // eval { $user_like->{id} };
        my $nick = eval { $user_like->nickname } // eval { $user_like->{nickname} };
        if ($uid) {
            my $sth = $dbh->prepare("SELECT id_user, nickname, username, hostmasks FROM USER WHERE id_user=?");
            $sth->execute($uid);
            my $row = $sth->fetchrow_hashref;
            $sth->finish;
            return ($row, undef) if $row;
            return (undef, "object_id_not_found:$uid");
        }
        if ($nick) {
            my $sth = $dbh->prepare("SELECT id_user, nickname, username, hostmasks FROM USER WHERE nickname=?");
            $sth->execute($nick);
            my $row = $sth->fetchrow_hashref;
            $sth->finish;
            return ($row, undef) if $row;
            return (undef, "object_nick_not_found:$nick");
        }
        return (undef, "unknown_object_type");
    }
    # Scalar -> assume id first, then nickname
    if (defined $user_like && $user_like ne '') {
        my ($where, $val) = ($user_like =~ /^\d+$/)
            ? ('id_user = ?', $user_like)
            : ('nickname = ?', $user_like);
        my $sth = $dbh->prepare("SELECT id_user, nickname, username, hostmasks FROM USER WHERE $where");
        $sth->execute($val);
        my $row = $sth->fetchrow_hashref;
        $sth->finish;
        return ($row, undef) if $row;
        return (undef, "scalar_not_found:$user_like");
    }
    return (undef, "undef_input");
}

# Returns (ok:boolean, why:string)
sub _password_matches {
    my ($clear, $stored) = @_;

    return (0, 'no_clear_password') unless defined $clear && length $clear;
    return (0, 'no_stored_password') unless defined $stored && length $stored;

    # MySQL old PASSWORD() format: 41 chars, starts with '*', uppercase hex of SHA1(SHA1(pass))
    if ($stored =~ /^\*[0-9A-F]{40}\z/) {
        my $hash1 = sha1($clear);
        my $hash2 = sha1($hash1);
        my $calc  = '*' . uc(unpack('H*', $hash2));
        return ($calc eq $stored ? 1 : 0, 'mysql_password_hash');
    }

    # phpMyAdmin / other variants: lowercase hex of double sha1 without '*'
    if ($stored =~ /^[0-9a-f]{40}\z/) {
        my $hash1 = sha1_hex($clear);
        my $hash2 = sha1_hex(pack('H*',$hash1));
        return ($hash2 eq $stored ? 1 : 0, 'double_sha1_hex');
    }

    # Fallback: compare plaintext (some historical rows)
    return ($clear eq $stored ? 1 : 0, 'plaintext_compare');
}

sub _glob_to_re {
    my ($glob) = @_;
    # Escape regex metachars then replace \* -> .*, \? -> .
    my $re = quotemeta($glob // '');
    $re =~ s/\\\*/.*/g;
    $re =~ s/\\\?././g;
    return qr/^$re\z/i;
}

sub _trim {
    my ($s) = @_;
    return '' unless defined $s;
    $s =~ s/^\s+//;
    $s =~ s/\s+$//;
    return $s;
}

1;

__END__

=head1 NAME

Mediabot::Auth - Authentication helpers for Mediabot (with verbose debug)

=head1 DESCRIPTION

This module centralizes credential verification and autologin logic and
produces detailed debug logs so you can see exactly why a login/autologin
succeeds or fails. It is defensive and never dies; callers always get a
boolean and a short "why" string.
