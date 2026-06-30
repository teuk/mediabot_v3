package Mediabot::Auth;
use strict;
use warnings;
use Digest::SHA qw(sha1 sha1_hex);
my $HAVE_BCRYPT = eval { require Crypt::Bcrypt; 1 } ? 1 : 0;
use Scalar::Util qw(blessed);

# ------------------------------------------------------------------------------
# Simple logger wrapper (falls back to STDOUT if no logger was provided)
# ------------------------------------------------------------------------------
sub _log {
    my ($self, $level, $msg) = @_;

    # MB304: level 0 is a valid and important severity. Using ||= here
    # changed every level-0 authentication error into DEBUG (3), which could
    # hide failures whenever the runtime debug level was below 3.
    $level = 3 unless defined $level; # 0=ERROR 1=WARN 2=INFO 3=DEBUG
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
        dbh     => $args{dbh},       # DBI handle
        logger  => $args{logger},    # optional object with ->log($level,$msg)
        conf    => $args{conf} || {},# optional config hash
        bot     => $args{bot},       # A1/B1: optional bot ref for noticeConsoleChan
        metrics => $args{metrics},   # mb362-B1: optional Metrics object, may be attached later
    }, $class;

    # mb362-B1: alternate construction paths may already have Metrics ready.
    # Publish an explicit zero immediately instead of waiting for a login/logout.
    $self->set_metrics($args{metrics}) if $args{metrics};

    return $self;
}

# ------------------------------------------------------------------------------
# Public API
# ------------------------------------------------------------------------------

# verify_credentials($user_id_or_nick, $login_nickname, $clear_password)
# Returns: boolean
# verify_credentials($user_id_or_nick, $login_nickname, $clear_password)
# Returns: boolean
sub verify_credentials {
    my ($self, $user_id_or_nick, $login_nick, $clear) = @_;
    my $dbh = $self->{dbh};

    unless ($dbh) {
        $self->_log(0, "verify_credentials: no database handle");
        return 0;
    }

    unless (defined($user_id_or_nick) && $user_id_or_nick ne '') {
        $self->_log(2, "verify_credentials: empty user lookup key");
        return 0;
    }

    # Resolve the user row.
    # Determine lookup key: numeric = id_user, otherwise nickname.
    my ($sql, $val);
    if ($user_id_or_nick =~ /^\d+$/) {
        $sql = "SELECT id_user, nickname, password FROM USER WHERE id_user = ?";
        $val = $user_id_or_nick;
    }
    else {
        $sql = "SELECT id_user, nickname, password FROM USER WHERE nickname = ?";
        $val = $user_id_or_nick;
    }

    my $sth = $dbh->prepare($sql);
    unless ($sth) {
        $self->_log(0, "verify_credentials: DB prepare error while fetching user ($val): $DBI::errstr");
        return 0;
    }

    unless ($sth->execute($val)) {
        $self->_log(0, "verify_credentials: DB execute error while fetching user ($val): $DBI::errstr");
        $sth->finish;
        return 0;
    }

    my $row = $sth->fetchrow_hashref;
    $sth->finish;

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
    $self->_log(3, sprintf(" verify_credentials: id=%s nick=%s login_nick=%s match=%s (%s)",
                           $uid, $nick, ($login_nick//''), $ok ? 'YES' : 'NO', $why));
    return $ok ? 1 : 0;
}


# maybe_autologin($user_like, $fullmask) returns (boolean, reason_string)
# maybe_autologin($user_like, $fullmask) returns (boolean, reason_string)
sub maybe_autologin {
    my ($self, $user_like, $fullmask) = @_;
    my $dbh = $self->{dbh};

    unless ($dbh) {
        return (0, "no_dbh");
    }

    my ($user, $err) = $self->_resolve_user($user_like);
    if (!$user) {
        return (0, "resolve_user_failed: $err");
    }

    my $uid      = $user->{id_user};
    my $nick     = $user->{nickname} // '';
    my $nick_lc  = lc($nick);
    my $username = $user->{username} // '';

    # Already authenticated in the current row/object state
    if ($user->{auth}) {
        return (0, "already_authenticated");
    }

    my ($host) = ($fullmask // '') =~ /@(.+)$/;
    $host = lc($host // '');

    # A) Regular DB autologin via USER_HOSTMASK, but only when username='#AUTOLOGIN#'
    my ($mask_ok, $matched_mask) = $self->hostmask_matches($user, $fullmask);

    # B) Undernet cloak autologin: "<nickname>.users.undernet.org"
    my $cloak_ok = 0;
    if ($host =~ /(^|\.)users\.undernet\.org\z/i) {
        my ($leftmost) = split(/\./, $host, 2);
        if (defined $leftmost && $leftmost ne '' && $nick_lc ne '' && lc($leftmost) eq $nick_lc) {
            $cloak_ok = 1;
        }
    }

    my $reason;
    if ($mask_ok && defined $username && $username eq '#AUTOLOGIN#') {
        $reason = "flag+hostmask:$matched_mask";
    }
    elsif ($cloak_ok) {
        $reason = "undernet_cloak";
    }
    else {
        if (defined $username && $username eq '#AUTOLOGIN#') {
            return (0, "no_mask_matched");
        }
        return (0, "autologin_disabled");
    }

    my $sql_update = "UPDATE USER SET auth=1, last_login=NOW() WHERE id_user=?";
    my $sth = $dbh->prepare($sql_update);

    unless ($sth) {
        $self->_log(0, "AUTOLOGIN: DB prepare error while updating auth for uid=$uid: $DBI::errstr");
        return (0, "db_update_prepare_failed");
    }

    unless ($sth->execute($uid)) {
        $self->_log(0, "AUTOLOGIN: DB execute error while updating auth for uid=$uid: $DBI::errstr");
        $sth->finish;
        return (0, "db_update_execute_failed");
    }

    my $rows = $sth->rows;
    $sth->finish;

    # mb372-B1: keep the session under the live IRC nickname, not only under
    # the registered database handle. QUIT/PART/KICK callbacks receive the
    # live nick and must be able to close the exact session later.
    my ($irc_nick) = ($fullmask // '') =~ /^([^!]+)/;
    $irc_nick = $nick unless defined($irc_nick) && $irc_nick ne '';

    $self->set_logged_in($uid, 1);
    $self->set_session_user($irc_nick, {
        id_user      => $uid,
        nickname     => $nick,
        irc_nick     => $irc_nick,
        auth         => 1,
        hostmask     => $fullmask,
        logged_in_at => time(),
    });

    $self->_log(3, "AUTOLOGIN: success uid=$uid nick=$nick irc_nick=$irc_nick reason=$reason rows=$rows");
    return (1, $reason);
}


# Checks if the given full hostmask matches any of the stored hostmask patterns for the user.
sub hostmask_matches {
    my ($self, $user_like, $fullmask) = @_;

    my ($user, $err) = $self->_resolve_user($user_like);
    return (0, undef, undef, -1) unless $user;

    my @stored_masks = grep { length } map { _trim($_) } split /,/, ($user->{hostmasks} // '');
    return (0, undef, undef, -1) unless @stored_masks;

    my @candidates = _hostmask_candidates($fullmask);

    my $best_mask;
    my $best_rx;
    my $best_score = -1;

    for my $mask (@stored_masks) {
        my $rx = _glob_to_re($mask);
        my $score = _mask_specificity($mask);

        for my $candidate (@candidates) {
            next unless defined $candidate && $candidate ne '';

            if ($candidate =~ $rx) {
                if ($score > $best_score) {
                    $best_mask  = $mask;
                    $best_rx    = $rx;
                    $best_score = $score;
                }
            }
        }
    }

    return (1, $best_mask, $best_rx, $best_score) if defined $best_mask;
    return (0, undef, undef, -1);
}


# logout($nick_or_uid, %opts) — close the live IRC session and, when the
# account has no other live session, clear USER.auth as well.
#
# mb372-B1: the former implementation only removed an in-memory hash entry.
# USER.auth stayed at 1, so get_user_from_message() could recreate authenticated
# state after a genuine QUIT/PART/KICK. It also keyed explicit logins by the DB
# handle instead of the live IRC nick, making many disconnects miss the session.
sub logout {
    my ($self, $nick_or_uid, %opts) = @_;
    return 0 unless defined $nick_or_uid;

    my $sessions = $self->{sessions} ||= {};
    my @keys;
    my $uid;

    if (!ref($nick_or_uid) && $nick_or_uid =~ /^\d+$/) {
        $uid = 0 + $nick_or_uid;
        @keys = grep {
            defined($sessions->{$_}{id_user})
                && $sessions->{$_}{id_user} =~ /^\d+$/
                && $sessions->{$_}{id_user} == $uid
        } keys %$sessions;
    }
    else {
        my $needle = lc("$nick_or_uid");
        @keys = grep {
            my $sess = $sessions->{$_} || {};
            lc($_) eq $needle
                || lc($sess->{irc_nick} // '') eq $needle
        } keys %$sessions;

        $uid = $sessions->{$keys[0]}{id_user} if @keys;
    }

    # A numeric logout is also a valid request when only the legacy logged_in
    # flag exists and no session hash survived.
    my $had_state = @keys || (defined($uid) && exists($self->{logged_in}{$uid}));

    for my $key (@keys) {
        my $sess = delete $sessions->{$key};
        $self->_invalidate_bot_session($key, $sess);
    }

    if (defined $uid && !$self->_has_session_for_uid($uid)) {
        delete $self->{logged_in}{$uid};
        $self->_set_db_auth($uid, 0) unless $opts{skip_db};
        $self->_invalidate_bot_uid($uid);
    }

    $self->_update_auth_session_metric() if $had_state || @keys;
    return $had_state ? 1 : 0;
}

# session_count() — return number of in-memory authenticated sessions
sub session_count {
    my ($self) = @_;
    return scalar keys %{ $self->{sessions} || {} };
}

# mb362-B1: Auth is initialized before Mediabot::Metrics in the main startup
# sequence because Metrics needs the IO::Async loop. Allow the metrics object to
# be attached afterwards and immediately publish the current session count.
sub set_metrics {
    my ($self, $metrics) = @_;

    unless ($metrics && ref($metrics) && $metrics->can('set')) {
        $self->{metrics} = undef;
        return 0;
    }

    $self->{metrics} = $metrics;
    $self->_update_auth_session_metric();
    return 1;
}

# is_logged_in_id($uid) — API already expected by LoginCommands.
# Before mb372 those calls were hidden inside eval and silently failed because
# the methods did not exist.
sub is_logged_in_id {
    my ($self, $uid) = @_;
    return 0 unless defined($uid) && !ref($uid) && $uid =~ /^\d+$/;
    return $self->{logged_in}{$uid} ? 1 : 0;
}

sub set_logged_in {
    my ($self, $uid, $value) = @_;
    return 0 unless defined($uid) && !ref($uid) && $uid =~ /^\d+$/;

    if ($value) {
        $self->{logged_in}{$uid} = 1;
    }
    else {
        delete $self->{logged_in}{$uid};
    }

    return 1;
}

sub set_session_user {
    my ($self, $irc_nick, $session) = @_;
    return 0 unless defined($irc_nick) && !ref($irc_nick) && $irc_nick ne '';
    return 0 unless ref($session) eq 'HASH';

    my $uid = $session->{id_user};
    return 0 unless defined($uid) && !ref($uid) && $uid =~ /^\d+$/;

    my $key = lc($irc_nick);
    my $old = $self->{sessions}{$key};
    my $old_uid = ref($old) eq 'HASH' ? $old->{id_user} : undef;

    my %copy = %$session;
    $copy{irc_nick}     = $irc_nick;
    $copy{auth}         = 1 unless defined $copy{auth};
    $copy{logged_in_at} = time() unless defined $copy{logged_in_at};

    $self->{sessions}{$key} = \%copy;
    $self->{logged_in}{$uid} = 1;

    # If the same live IRC nickname changes account, do not leave the previous
    # account authenticated forever after its only session was overwritten.
    if (defined($old_uid) && "$old_uid" =~ /^\d+$/ && $old_uid != $uid) {
        $self->_invalidate_bot_session($key, $old);
        unless ($self->_has_session_for_uid($old_uid)) {
            delete $self->{logged_in}{$old_uid};
            $self->_set_db_auth($old_uid, 0);
            $self->_invalidate_bot_uid($old_uid);
        }
    }

    $self->_update_auth_session_metric();
    return 1;
}

# mb372-B1: return true when another live session still represents the account.
sub _has_session_for_uid {
    my ($self, $uid) = @_;
    return 0 unless defined $uid;

    for my $sess (values %{ $self->{sessions} || {} }) {
        next unless ref($sess) eq 'HASH';
        return 1 if defined($sess->{id_user})
            && "$sess->{id_user}" =~ /^\d+$/
            && $sess->{id_user} == $uid;
    }

    return 0;
}

sub _set_db_auth {
    my ($self, $uid, $value) = @_;
    my $dbh = $self->{dbh};
    return undef unless $dbh;
    return 0 unless defined($uid) && "$uid" =~ /^\d+$/;

    my $sth = eval { $dbh->prepare("UPDATE USER SET auth=? WHERE id_user=?") };
    unless ($sth) {
        my $err = $@ || $DBI::errstr || 'prepare failed';
        $err =~ s/\s+/ /g;
        $self->_log(1, "Auth logout DB prepare failed for uid=$uid: $err");
        return 0;
    }

    my $ok = eval { $sth->execute($value ? 1 : 0, $uid) };
    unless ($ok) {
        my $err = $@ || $DBI::errstr || 'execute failed';
        $err =~ s/\s+/ /g;
        eval { $sth->finish };
        $self->_log(1, "Auth logout DB execute failed for uid=$uid: $err");
        return 0;
    }

    eval { $sth->finish };
    return 1;
}

sub _invalidate_bot_session {
    my ($self, $key, $sess) = @_;
    my $bot = $self->{bot};
    return unless $bot;

    my $hostmask = ref($sess) eq 'HASH' ? ($sess->{hostmask} // '') : '';

    if ($bot->can('clear_user_cache')) {
        eval {
            if ($hostmask ne '') {
                $bot->clear_user_cache($hostmask);
            }
            else {
                $bot->clear_user_cache();
            }
            1;
        };
    }

    for my $slot (qw(logged_in_by_nick sessions users_by_nick)) {
        next unless ref($bot->{$slot}) eq 'HASH';
        delete $bot->{$slot}{$key};
    }

    return 1;
}

sub _invalidate_bot_uid {
    my ($self, $uid) = @_;
    my $bot = $self->{bot};
    return unless $bot;

    delete $bot->{logged_in}{$uid} if ref($bot->{logged_in}) eq 'HASH';
    delete $bot->{users_by_id}{$uid} if ref($bot->{users_by_id}) eq 'HASH';
    return 1;
}

# ------------------------------------------------------------------------------
# Metrics helpers
# ------------------------------------------------------------------------------

sub _update_auth_session_metric {
    my ($self) = @_;

    return unless $self->{metrics} && $self->{metrics}->can('set');

    $self->{metrics}->set(
        'mediabot_auth_sessions_total',
        scalar keys %{ $self->{sessions} || {} }
    );

    return 1;
}

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

# Internal helper: resolve various user-like inputs to a user row hashref
# Internal helper: resolve various user-like inputs to a user row hashref
sub _resolve_user {
    my ($self, $user_like) = @_;
    my $dbh = $self->{dbh};

    return (undef, "no_dbh") unless $dbh;

    # Already a hashref with required fields
    if (ref $user_like eq 'HASH' && exists $user_like->{id_user}) {
        return ($user_like, undef);
    }

    # Mediabot::User object -> try known accessors or hash internals
    if (blessed($user_like)) {
        my $uid  = eval { $user_like->id }       // eval { $user_like->{id} }       // eval { $user_like->{id_user} };
        my $nick = eval { $user_like->nickname } // eval { $user_like->{nickname} };

        if ($uid) {
            my ($row, $err) = $self->_fetch_user_row(
                "SELECT id_user, nickname, username, auth FROM USER WHERE id_user = ?",
                $uid,
                "object_id:$uid",
            );

            return (undef, $err) unless $row;
            $row->{hostmasks} = _fetch_hostmasks($dbh, $row->{id_user}, $self->{logger});
            return ($row, undef);
        }

        if ($nick) {
            my ($row, $err) = $self->_fetch_user_row(
                "SELECT id_user, nickname, username, auth FROM USER WHERE nickname = ?",
                $nick,
                "object_nick:$nick",
            );

            return (undef, $err) unless $row;
            $row->{hostmasks} = _fetch_hostmasks($dbh, $row->{id_user}, $self->{logger});
            return ($row, undef);
        }

        return (undef, "unknown_object_type");
    }

    # Scalar -> assume id first, then nickname
    if (defined $user_like && $user_like ne '') {
        my ($sql_r, $val, $label);

        if ($user_like =~ /^\d+$/) {
            $sql_r = "SELECT id_user, nickname, username, auth FROM USER WHERE id_user = ?";
            $val   = $user_like;
            $label = "scalar_id:$user_like";
        }
        else {
            $sql_r = "SELECT id_user, nickname, username, auth FROM USER WHERE nickname = ?";
            $val   = $user_like;
            $label = "scalar_nick:$user_like";
        }

        my ($row, $err) = $self->_fetch_user_row($sql_r, $val, $label);
        return (undef, $err) unless $row;

        $row->{hostmasks} = _fetch_hostmasks($dbh, $row->{id_user}, $self->{logger});
        return ($row, undef);
    }

    return (undef, "undef_input");
}



sub _fetch_user_row {
    my ($self, $sql, $value, $label) = @_;

    my $dbh = $self->{dbh};
    return (undef, "no_dbh") unless $dbh;

    my $sth = $dbh->prepare($sql);
    unless ($sth) {
        $self->_log(0, "_resolve_user: prepare failed for $label: $DBI::errstr");
        return (undef, "prepare_failed:$label");
    }

    unless ($sth->execute($value)) {
        $self->_log(0, "_resolve_user: execute failed for $label: $DBI::errstr");
        $sth->finish;
        return (undef, "execute_failed:$label");
    }

    my $row = $sth->fetchrow_hashref;
    $sth->finish;

    return (undef, "not_found:$label") unless $row;
    return ($row, undef);
}


# Returns (ok:boolean, why:string)
# Internal helper: fetch comma-separated hostmasks from USER_HOSTMASK
# Returns (ok:boolean, why:string)
# Internal helper: fetch comma-separated hostmasks from USER_HOSTMASK
sub _fetch_hostmasks {
    my ($dbh, $id_user, $logger) = @_;

    return '' unless $dbh && $id_user;

    my $sql = "SELECT hostmask FROM USER_HOSTMASK WHERE id_user = ? ORDER BY id_user_hostmask";
    my $sth = $dbh->prepare($sql);

    unless ($sth) {
        $logger->log(1, "_fetch_hostmasks() SQL prepare error: $DBI::errstr Query: $sql")
            if $logger;
        return '';
    }

    unless ($sth->execute($id_user)) {
        $logger->log(1, "_fetch_hostmasks() SQL execute error: $DBI::errstr Query: $sql")
            if $logger;
        $sth->finish;
        return '';
    }

    my @masks;
    while (my $row = $sth->fetchrow_arrayref) {
        push @masks, $row->[0] if defined $row->[0] && $row->[0] ne '';
    }

    $sth->finish;
    return join(',', @masks);
}


sub _hostmask_candidates {
    my ($fullmask) = @_;

    my @candidates;
    my %seen;

    my $raw = defined($fullmask) ? $fullmask : '';
    if ($raw ne '' && !$seen{$raw}++) {
        push @candidates, $raw;
    }

    my ($nick, $userhost) = $raw =~ /^([^!]+)!(.+)$/;
    if (defined $userhost && $userhost ne '') {
        if (!$seen{$userhost}++) {
            push @candidates, $userhost;
        }

        my $userhost_no_tilde = $userhost;
        $userhost_no_tilde =~ s/^~//;
        if ($userhost_no_tilde ne '' && !$seen{$userhost_no_tilde}++) {
            push @candidates, $userhost_no_tilde;
        }

        my $star_userhost = '*' . $userhost_no_tilde;
        if ($star_userhost ne '' && !$seen{$star_userhost}++) {
            push @candidates, $star_userhost;
        }

        if (defined $nick && $nick ne '') {
            my $full_no_tilde = $nick . '!' . $userhost_no_tilde;
            if ($full_no_tilde ne '' && !$seen{$full_no_tilde}++) {
                push @candidates, $full_no_tilde;
            }
        }
    }

    return @candidates;
}

sub _mask_specificity {
    my ($mask) = @_;
    return -1 unless defined $mask;

    my $score = length($mask);

    my $stars = () = $mask =~ /\*/g;
    my $qms   = () = $mask =~ /\?/g;

    $score -= ($stars * 10);
    $score -= ($qms * 3);

    $score += 5 if $mask =~ /!/;
    $score += 5 if $mask =~ /\@/;

    return $score;
}

sub _password_matches {
    my ($clear, $stored) = @_;

    return (0, 'no_clear_password') unless defined $clear && length $clear;
    return (0, 'no_stored_password') unless defined $stored && length $stored;

    # Supported hash formats (in order of check):
    #   1. MySQL PASSWORD(): 41 chars, starts with '*', SHA1(SHA1(pass)) — legacy
    #   2. BCrypt: starts with '$2y$' or '$2b$' — preferred for new accounts
    # A2: SHA1 plain (legacy '#' prefix) is NOT supported — intentional security decision
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

    # BCrypt: $2b$, $2y$, $2a$ prefixes
    if ($stored =~ /^\$2[aby]\$/) {
        if ($HAVE_BCRYPT) {
            my $ok = eval { Crypt::Bcrypt::bcrypt_check($clear, $stored) };
            return $@ ? (0, 'bcrypt_check_error') : ($ok ? 1 : 0, 'bcrypt');
        } else {
            # Crypt::Bcrypt not installed — refuse rather than fall through
            return (0, 'bcrypt_not_available');
        }
    }

    # Fallback: compare plaintext (some historical rows)
    return ($clear eq $stored ? 1 : 0, 'plaintext_compare');
}

sub _glob_to_re {
    my ($glob) = @_;

    # Escape regex metacharacters first, then translate glob wildcards:
    #   *  -> .*
    #   ?  -> .
    my $re = quotemeta($glob // '');
    $re =~ s/\\\*/.*/g;
    $re =~ s/\\\?/./g;

    return qr/^$re\z/i;
}

sub _trim {
    my ($s) = @_;
    return '' unless defined $s;
    $s =~ s/^\s+//;
    $s =~ s/\s+$//;
    return $s;
}


# ---------------------------------------------------------------------------
# cleanup_stale_sessions($max_age_secs)
# Remove in-memory sessions older than $max_age_secs (default: 86400 = 24h).
# Called from the Scheduler or on every autologin attempt.
# ---------------------------------------------------------------------------
sub cleanup_stale_sessions {
    my ($self, $max_age) = @_;
    $max_age //= 86400;
    my $now  = time();
    my $gone = 0;
    my %affected_uid;

    for my $nick (keys %{ $self->{sessions} || {} }) {
        my $sess = $self->{sessions}{$nick};
        next unless ref($sess) eq 'HASH';

        my $age = $now - ($sess->{logged_in_at} // $now);
        next unless $age > $max_age;

        my $uid = $sess->{id_user};
        delete $self->{sessions}{$nick};
        $affected_uid{$uid} = 1 if defined $uid;
        $self->_invalidate_bot_session($nick, $sess);
        $gone++;
    }

    for my $uid (keys %affected_uid) {
        next if $self->_has_session_for_uid($uid);
        delete $self->{logged_in}{$uid};
        $self->_set_db_auth($uid, 0);
        $self->_invalidate_bot_uid($uid);
    }

    if ($gone) {
        $self->_log(2, "cleanup_stale_sessions: removed $gone session(s) older than ${max_age}s");
        # A5: also notify console channel if bot is connected
        if ($self->{bot} && $self->{bot}->can("noticeConsoleChan")) {
            eval { $self->{bot}->noticeConsoleChan(
                "auth: $gone stale session(s) purged (max_age=${max_age}s)") };
        }
        $self->_update_auth_session_metric();
    }
    return $gone;
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
