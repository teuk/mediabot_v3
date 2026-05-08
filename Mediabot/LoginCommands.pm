package Mediabot::LoginCommands;

# =============================================================================
# Mediabot::Auth — User authentication and registration
#
# Provides all auth-related commands and helpers:
#   init_auth, checkAuth, checkAuthByUser, getUserAutologin,
#   userLogin_ctx, mbRegister_ctx, userPass, userIdent,
#   userPass_ctx, userIdent_ctx, xLogin_ctx,
#   userWhoAmI_ctx, _ensure_logged_in_state, _dbg_auth_snapshot
#
# External dependencies (botNotice, logBot, getMessageHostmask, userAdd, etc.)
# remain in Mediabot.pm and are available as package functions.
# =============================================================================

use strict;
use warnings;
use POSIX qw(strftime);

use Exporter 'import';
use List::Util qw(min);
use Mediabot::Helpers;
use Mediabot::ChannelCommands;

our @EXPORT = qw(
    init_auth
    checkAuth
    checkAuthByUser
    getUserAutologin
    userLogin_ctx
    userLogout_ctx
    mbRegister_ctx
    userPass
    userIdent
    userPass_ctx
    userIdent_ctx
    xLogin_ctx
    userWhoAmI_ctx
    _ensure_logged_in_state
    _dbg_auth_snapshot
);


sub init_auth {
    my ($self) = @_;

    $self->{auth} = Mediabot::Auth->new(
        dbh    => $self->{dbh},
        logger => $self->{logger},
        bot    => $self,   # B1/A1: needed for noticeConsoleChan in cleanup_stale_sessions
    );

    $self->{logger}->log(1, "Authentication module initialized");
}


# Get autologin status for a user handle (returns 1 if username='#AUTOLOGIN#', else 0)
# Get autologin status for a user handle (returns 1 if username='#AUTOLOGIN#', else 0)
sub getUserAutologin {
    my ($self, $sMatchingUserHandle) = @_;

    return 0 unless defined($sMatchingUserHandle) && $sMatchingUserHandle ne '';

    my $sQuery = "SELECT 1 FROM USER WHERE nickname = ? AND username = '#AUTOLOGIN#'";
    my $sth = $self->{dbh}->prepare($sQuery);

    unless ($sth) {
        $self->{logger}->log(1, "getUserAutologin() SQL prepare error : " . $DBI::errstr . " Query : " . $sQuery)
            if $self->{logger};
        return 0;
    }

    unless ($sth->execute($sMatchingUserHandle)) {
        $self->{logger}->log(1, "getUserAutologin() SQL execute error : " . $DBI::errstr . " Query : " . $sQuery)
            if $self->{logger};
        $sth->finish;
        return 0;
    }

    my $ok = $sth->fetchrow_hashref() ? 1 : 0;
    $sth->finish;

    return $ok;
}


# Get user id from user handle
sub checkAuth {
    my ($self, $iUserId, $sUserHandle, $sPassword) = @_;

    # B4: eval around make_password_hash in case import is broken
    my $sHashedPw = eval { make_password_hash($sPassword) };
    unless (defined $sHashedPw) {
        $self->{logger}->log(1, "checkAuth() make_password_hash failed: $@");
        return 0;
    }

    # A3: prefer Auth::verify_credentials (supports BCrypt) when available
    if ($self->{auth} && $self->{auth}->can('verify_credentials')) {
        my $ok = eval { $self->{auth}->verify_credentials($iUserId, $sUserHandle, $sPassword) };
        return $ok ? 1 : 0;
    }

    # Fallback: legacy make_password_hash path (MD5/SHA)
    my $sth = $self->{dbh}->prepare(
        "SELECT id_user FROM USER WHERE id_user = ? AND nickname = ? AND password = ?"
    );
    unless ($sth && $sth->execute($iUserId, $sUserHandle, $sHashedPw)) {
        $self->{logger}->log(1, "checkAuth() SQL Error: $DBI::errstr");
        return 0;
    }

    my $found = $sth->fetchrow_hashref;
    $sth->finish;

    unless ($found) { return 0; }

    my $sth2 = $self->{dbh}->prepare(
        "UPDATE USER SET auth=1, last_login=NOW() WHERE id_user=?"
    );
    unless ($sth2 && $sth2->execute($iUserId)) {
        $self->{logger}->log(1, "checkAuth() UPDATE SQL Error: $DBI::errstr");
        $sth2->finish if $sth2;
        return 0;
    }
    $sth2->finish;
    return 1;
}

# Context-based: Handle user login via private message (strictly DB nickname + password)
sub userLogin_ctx {
    my ($ctx) = @_;

    my $self  = $ctx->bot;
    my $sNick = $ctx->nick;

    my @tArgs = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # If parser prepended caller nick: [caller, user, pass] -> shift caller
    if (@tArgs >= 3 && defined $sNick && $sNick ne '' && defined $tArgs[0] && lc($tArgs[0]) eq lc($sNick)) {
        shift @tArgs;
    }

    # Expect: login <nickname_in_db> <password>
    unless (defined $tArgs[0] && $tArgs[0] ne "" && defined $tArgs[1] && $tArgs[1] ne "") {
        botNotice($self, $sNick, "Syntax error: /msg " . $self->{irc}->nick_folded . " login <username> <password>");
        return;
    }

    # B2/A2: brute-force throttle — tracked by IRC nick AND DB username
    # Protects the account even if the attacker changes nick between attempts.
    {
        my $now      = time();
        my $window   = 60;
        my $max_fail = 5;

        $self->{_login_failures} //= {};

        # A3: periodic cleanup of expired entries (older than 2x window)
        if (!$self->{_login_fail_cleanup} || ($now - ($self->{_login_fail_cleanup} // 0)) >= 120) {
            for my $k (keys %{ $self->{_login_failures} }) {
                delete $self->{_login_failures}{$k}
                    if ($now - ($self->{_login_failures}{$k}{ts} // 0)) > 120;
            }
            $self->{_login_fail_cleanup} = $now;
        }

        # Check both IRC nick and DB username
        for my $fail_key (lc($sNick // ''), lc($tArgs[0] // '')) {
            next unless $fail_key ne '';
            my $rec = $self->{_login_failures}{$fail_key} //= { ts => $now, count => 0 };
            if ($now - $rec->{ts} >= $window) {
                $rec->{ts} = $now;
                $rec->{count} = 0;
            }
            if ($rec->{count} >= $max_fail) {
                my $wait = $window - ($now - $rec->{ts});
                $self->{logger}->log(2, "Login throttle: key=$fail_key blocked ($rec->{count} failures, ${wait}s remaining)")
                    if $self->{logger};
                botNotice($self, $sNick, "Too many failed login attempts. Please wait " . int($wait + 1) . " seconds.");
                return;
            }
        }
    }

    my $typed_user = $tArgs[0];     # MUST match USER.nickname strictly (e.g., 'teuk')
    my $typed_pass = $tArgs[1];

    my $dbh = $self->{dbh};
    unless ($dbh) {
        botNotice($self, $sNick, "Internal error (DB unavailable).");
        return;
    }

    my $run_select_one = sub {
        my ($sql, @bind) = @_;

        my $sth = $dbh->prepare($sql);
        unless ($sth) {
            $self->{logger}->log(1, "userLogin_ctx() SQL prepare error: $DBI::errstr Query: $sql")
                if $self->{logger};
            return (undef, "prepare");
        }

        unless ($sth->execute(@bind)) {
            $self->{logger}->log(1, "userLogin_ctx() SQL execute error: $DBI::errstr Query: $sql")
                if $self->{logger};
            $sth->finish;
            return (undef, "execute");
        }

        my $row = $sth->fetchrow_hashref;
        $sth->finish;

        return ($row, undef);
    };

    my $run_update = sub {
        my ($sql, @bind) = @_;

        my $sth = $dbh->prepare($sql);
        unless ($sth) {
            $self->{logger}->log(1, "userLogin_ctx() update SQL prepare error: $DBI::errstr Query: $sql")
                if $self->{logger};
            return (0, "prepare");
        }

        unless ($sth->execute(@bind)) {
            $self->{logger}->log(1, "userLogin_ctx() update SQL execute error: $DBI::errstr Query: $sql")
                if $self->{logger};
            $sth->finish;
            return (0, "execute");
        }

        my $rows = $sth->rows;
        $sth->finish;

        return ($rows, undef);
    };

    # 1) Fetch account strictly by DB nickname.
    # Do not SELECT the password/hash here; credential verification belongs to
    # Mediabot::Auth::verify_credentials().
    my ($row, $select_err) = $run_select_one->(q{
        SELECT
            id_user,
            nickname,
            CASE
                WHEN password IS NOT NULL AND password <> '' THEN 1
                ELSE 0
            END AS has_password,
            id_user_level
        FROM USER
        WHERE nickname = ?
        LIMIT 1
    }, $typed_user);

    if ($select_err) {
        botNotice($self, $sNick, "Internal error (query failed).");
        return;
    }

    unless ($row) {
        for my $k (lc($sNick // ''), lc($typed_user // '')) {
            next unless defined($k) && $k ne '';
            my $r = ($self->{_login_failures}{$k} //= { ts => time(), count => 0 });
            $r->{count}++;
            $r->{ts} //= time();
        }

        botNotice($self, $sNick, "Login failed (Unknown user).");
        $self->{metrics}->inc('mediabot_auth_failure_total') if $self->{metrics};

        my $msg = (($ctx->message && $ctx->message->can('prefix')) ? ($ctx->message->prefix // '') : '')
                . " Failed login (Unknown user: $typed_user)";
        $self->noticeConsoleChan($msg) if $self->can('noticeConsoleChan');
        logBot($self, $ctx->message, undef, "login", $typed_user, "Failed (Unknown user)");
        return;
    }

    my $id_user      = $row->{id_user};
    my $db_nick      = $row->{nickname};
    my $has_password = defined($row->{has_password}) ? int($row->{has_password}) : 0;
    my $level_id     = $row->{id_user_level};

    unless ($has_password) {
        botNotice($self, $sNick, "Your password is not set. Use /msg " . $self->{irc}->nick_folded . " pass <password>");
        return;
    }

    unless ($self->{auth} && $self->{auth}->can('verify_credentials')) {
        $self->{logger}->log(1, "userLogin_ctx() Auth module unavailable for credential verification")
            if $self->{logger};
        botNotice($self, $sNick, "Internal error (auth module unavailable).");
        return;
    }

    # 2) Verify credentials through Mediabot::Auth.
    if ($self->{auth}->verify_credentials($id_user, $db_nick, $typed_pass)) {
        # 3) Mark authenticated and stamp last_login
        my ($rows, $upd_err) = $run_update->(
            "UPDATE USER SET auth=1, last_login=NOW() WHERE id_user=?",
            $id_user,
        );

        if ($upd_err) {
            botNotice($self, $sNick, "Internal error (auth update failed).");
            return;
        }

        # 4) Register the caller's hostmask in USER_HOSTMASK if not already present
        my $fullmask = ($ctx->message && $ctx->message->can('prefix')) ? ($ctx->message->prefix // '') : '';
        my $hostmask = getMessageHostmask($self, $ctx->message);

        if ($hostmask && $hostmask ne '') {
            my ($hm_row, $hm_err) = $run_select_one->(
                "SELECT id_user_hostmask FROM USER_HOSTMASK WHERE id_user=? AND hostmask=? LIMIT 1",
                $id_user,
                $hostmask,
            );

            if ($hm_err) {
                $self->{logger}->log(1, "login: failed to check hostmask registration for id_user=$id_user hostmask=$hostmask")
                    if $self->{logger};
            }
            elsif (!$hm_row) {
                my ($hm_rows, $hm_ins_err) = $run_update->(
                    "INSERT INTO USER_HOSTMASK (id_user, hostmask) VALUES (?, ?)",
                    $id_user,
                    $hostmask,
                );

                if ($hm_ins_err) {
                    $self->{logger}->log(1, "login: failed to register hostmask '$hostmask' for id_user=$id_user")
                        if $self->{logger};
                }
                else {
                    $self->{logger}->log(2, "login: registered hostmask '$hostmask' for id_user=$id_user")
                        if $self->{logger};
                    clear_user_cache($self, $fullmask);
                }
            }
        }

        # Best-effort in-memory flags (ignore if structure differs)
        eval {
            $self->{auth}->{logged_in}{$id_user} = 1
                if ref($self->{auth}) eq 'HASH' && ref($self->{auth}->{logged_in}) eq 'HASH';
            $self->{auth}->{sessions}{lc $db_nick} = { id_user => $id_user, auth => 1 }
                if ref($self->{auth}) eq 'HASH' && ref($self->{auth}->{sessions}) eq 'HASH';
            1;
        };

        # Resolve level description from USER_LEVEL
        my $level_desc = $level_id // "unknown";
        my ($level_row, $level_err) = $run_select_one->(
            "SELECT description FROM USER_LEVEL WHERE id_user_level=?",
            $level_id,
        );

        if (!$level_err && $level_row && defined $level_row->{description}) {
            $level_desc = $level_row->{description};
        }

        delete $self->{_login_failures}{lc($sNick // '')};       # reset on success
        delete $self->{_login_failures}{lc($typed_user // '')};  # reset target account too

        botNotice($self, $sNick, "Login successful as $db_nick (Level: $level_desc)");
        $self->{metrics}->inc('mediabot_auth_success_total') if $self->{metrics};

        my $msg = (($ctx->message && $ctx->message->can('prefix')) ? ($ctx->message->prefix // '') : '')
                . " Successful login as $db_nick (Level: $level_desc)";
        $self->noticeConsoleChan($msg) if $self->can('noticeConsoleChan');
        logBot($self, $ctx->message, undef, "login", $typed_user, "Success");
    }
    else {
        for my $k (lc($sNick // ''), lc($typed_user // '')) {
            next unless $k ne '';
            my $r = ($self->{_login_failures}{$k} //= { ts => time(), count => 0 });
            $r->{count}++;
        }

        botNotice($self, $sNick, "Login failed (Bad password).");
        $self->{metrics}->inc('mediabot_auth_failure_total') if $self->{metrics};

        my $msg = (($ctx->message && $ctx->message->can('prefix')) ? ($ctx->message->prefix // '') : '')
                . " Failed login (Bad password)";
        $self->noticeConsoleChan($msg) if $self->can('noticeConsoleChan');
        logBot($self, $ctx->message, undef, "login", $typed_user, "Failed (Bad password)");
    }
}



# Context-based logout command
sub userLogout_ctx {
    my ($ctx) = @_;
    return unless $ctx;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;
    my $user = $ctx->user;

    unless ($user && $user->is_authenticated) {
        botNotice($self, $nick, "You are not logged in.");
        return;
    }

    my $uid      = eval { $user->id } // 0;
    my $username = eval { $user->nickname } // $nick;

    my $dbh = $self->{dbh};
    unless ($dbh) {
        $self->{logger}->log(1, "userLogout_ctx() no database handle")
            if $self->{logger};
        botNotice($self, $nick, "Internal error during logout.");
        return;
    }

    my $sql = "UPDATE USER SET auth=0 WHERE id_user=?";
    my $sth = $dbh->prepare($sql);

    unless ($sth) {
        $self->{logger}->log(1, "userLogout_ctx() SQL prepare error: $DBI::errstr Query: $sql")
            if $self->{logger};
        botNotice($self, $nick, "Internal error during logout.");
        return;
    }

    unless ($sth->execute($uid)) {
        $self->{logger}->log(1, "userLogout_ctx() SQL execute error: $DBI::errstr Query: $sql")
            if $self->{logger};
        $sth->finish;
        botNotice($self, $nick, "Internal error during logout.");
        return;
    }

    $sth->finish;

    # Invalidate user cache so subsequent commands see auth=0 immediately
    my $logout_mask = eval { $ctx->message->prefix } // '';
    clear_user_cache($self, $logout_mask) if $logout_mask;

    $self->{logger}->log(1, "logout: $username (id=$uid) logged out")
        if $self->{logger};
    botNotice($self, $nick, "Logged out successfully.");
    logBot($self, $ctx->message, undef, "logout", $username);
    return 1;
}


# check user Level
sub mbRegister_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
    my ($user, $pass) = @args;

    unless (defined($user) && $user ne '' && defined($pass) && $pass ne '') {
        $self->botNotice($nick, "Syntax: register <username> <password>");
        return;
    }

    if (userCount($self) > 0) {
        $self->{logger}->log(1, "Register attempt ignored (users already exist): " . ($ctx->message->prefix // ''));
        return;
    }

    my $mask = getMessageHostmask($self, $ctx->message);
    my $id = userAdd($self, $mask, $user, $pass, "Owner");

    if (defined $id) {
        # Auto-register the console channel at level 500 for the new Owner
        my ($id_console_chan, $console_name) = getConsoleChan($self);
        if (defined $id_console_chan && defined $console_name) {
            registerChannel($self, $ctx->message, $nick, $id_console_chan, $id);
            $self->{logger}->log(1, "Register: auto-registered $user (id=$id) on console channel $console_name at level 500");
        } else {
            $self->{logger}->log(1, "Register: could not find console channel to auto-register $user");
        }
        botNotice($self, $nick, "Registered $user as Owner (id_user: $id) with hostmask $mask");
        logBot($self, $ctx->message, undef, 'register', 'Success');
    } else {
        botNotice($self, $nick, "Register failed");
        logBot($self, $ctx->message, undef, 'register', 'Failed');
    }
}

# Context-based: Allows the bot Owner to send a raw IRC command manually
sub userPass {
    my ($self, $message, $sNick, @tArgs) = @_;

    my $user = $self->get_user_from_message($message);

    unless (defined($user) && defined($user->nickname)) {
        my $msg = $message->prefix . " Failed pass command, unknown user $sNick (" . $message->prefix . ")";
        noticeConsoleChan($self, $msg);
        logBot($self, $message, undef, "pass", "Failed - unknown user $sNick");
        botNotice($self, $sNick, "You must be known by the bot before setting a password.");
        return 0;
    }

    my $uid = $user->id;

    my $sth_current = $self->{dbh}->prepare(
        "SELECT password FROM USER WHERE id_user = ? LIMIT 1"
    );

    unless ($sth_current && $sth_current->execute($uid)) {
        $self->{logger}->log(1, "userPass() SQL error while reading current password: $DBI::errstr")
            if $self->{logger};
        botNotice($self, $sNick, "Internal error (password check failed).");
        return 0;
    }

    my ($stored_hash) = $sth_current->fetchrow_array;
    $sth_current->finish;

    my $has_password = defined($stored_hash) && $stored_hash ne '' ? 1 : 0;

    my ($old_password, $new_password);

    if ($has_password) {
        ($old_password, $new_password) = @tArgs;

        unless (defined($old_password) && $old_password ne '' && defined($new_password) && $new_password ne '') {
            botNotice($self, $sNick, "Syntax: pass <oldpassword> <newpassword>");
            return 0;
        }

        my $old_hash;
        my $old_hash_ok = eval {
            $old_hash = make_password_hash($old_password);
            1;
        };

        unless ($old_hash_ok && defined($old_hash)) {
            my $err = $@ || 'make_password_hash returned undef';
            chomp $err;

            $self->{logger}->log(1, "userPass() old password hash compute failed: $err")
                if $self->{logger};

            botNotice($self, $sNick, "Internal error (password check failed).");
            logBot($self, $message, undef, "pass", "Failed - old hash error");
            return 0;
        }

        unless ($stored_hash eq $old_hash) {
            botNotice($self, $sNick, "Current password is invalid.");
            logBot($self, $message, undef, "pass", "Failed - bad old password");
            return 0;
        }
    }
    else {
        ($new_password) = @tArgs;

        unless (defined($new_password) && $new_password ne '') {
            botNotice($self, $sNick, "Syntax: pass <newpassword>");
            return 0;
        }
    }

    my $sHashedNewPw;
    my $hash_ok = eval {
        $sHashedNewPw = make_password_hash($new_password);
        1;
    };

    unless ($hash_ok && defined $sHashedNewPw) {
        my $err = $@ || 'make_password_hash returned undef';
        chomp $err;

        $self->{logger}->log(1, "userPass() make_password_hash failed: $err")
            if $self->{logger};

        botNotice($self, $sNick, "Internal error (hash compute failed).");
        logBot($self, $message, undef, "pass", "Failed - hash error");
        return 0;
    }

    my $sQuery = "UPDATE USER SET password=? WHERE id_user=?";
    my $sth = $self->{dbh}->prepare($sQuery);

    unless ($sth && $sth->execute($sHashedNewPw, $uid)) {
        $self->{logger}->log(1, "SQL Error: $DBI::errstr - Query: $sQuery")
            if $self->{logger};
        $sth->finish if $sth;
        botNotice($self, $sNick, "Internal error (password update failed).");
        return 0;
    }

    $sth->finish;

    my $msg = "userPass() Set password for $sNick (user_id: $uid, host: " . $message->prefix . ")";
    $self->{logger}->log(3, $msg) if $self->{logger};
    noticeConsoleChan($self, $msg);

    botNotice($self, $sNick, "Password set.");
    botNotice($self, $sNick, "You may now login with /msg " . $self->{irc}->nick_folded . " login " . $user->nickname . " <password>");
    logBot($self, $message, undef, "pass", "Success");

    return 1;
}



sub userIdent {
	my ($self,$message,$sNick,@tArgs) = @_;
	#login <username> <password>
	if (defined($tArgs[0]) && ($tArgs[0] ne "") && defined($tArgs[1]) && ($tArgs[1] ne "")) {
		my ($id_user,$bAlreadyExists) = checkAuthByUser($self,$message,$tArgs[0],$tArgs[1]);
		if ( $bAlreadyExists ) {
			botNotice($self,$sNick,"This hostmask is already set");
		}
		elsif ( $id_user ) {
			botNotice($self,$sNick,"Ident successfull as " . $tArgs[0] . " new hostmask added");
			my $sNoticeMsg = $message->prefix . " Ident successfull from $sNick as " . $tArgs[0] . " id_user : $id_user";
			noticeConsoleChan($self,$sNoticeMsg);
			logBot($self,$message,undef,"ident",$tArgs[0]);
		}
		else {
			my $sNoticeMsg = $message->prefix . " Ident failed (Bad password)";
			$self->{logger}->log(0,$sNoticeMsg);
			noticeConsoleChan($self,$sNoticeMsg);
			logBot($self,$message,undef,"ident",$sNoticeMsg);
		}
	}
}

sub checkAuthByUser {
    my ($self, $message, $sUserHandle, $sPassword) = @_;

    return (0, 0) unless defined($sUserHandle) && $sUserHandle ne '';
    return (0, 0) unless defined($sPassword)   && $sPassword   ne '';

    my $dbh = $self->{dbh};
    unless ($dbh) {
        $self->{logger}->log(1, "checkAuthByUser() no database handle")
            if $self->{logger};
        return (0, 0);
    }

    my $sHashedPw;
    my $hash_ok = eval {
        $sHashedPw = make_password_hash($sPassword);
        1;
    };

    unless ($hash_ok && defined $sHashedPw) {
        my $err = $@ || 'make_password_hash returned undef';
        chomp $err;

        $self->{logger}->log(1, "checkAuthByUser() make_password_hash failed: $err")
            if $self->{logger};

        return (0, 0);
    }

    my $sCheckAuthQuery = "SELECT id_user FROM USER WHERE nickname = ? AND password = ?";
    my $sth = $dbh->prepare($sCheckAuthQuery);

    unless ($sth) {
        $self->{logger}->log(1, "checkAuthByUser() SQL prepare error: " . $DBI::errstr . " Query: " . $sCheckAuthQuery)
            if $self->{logger};
        return (0, 0);
    }

    unless ($sth->execute($sUserHandle, $sHashedPw)) {
        $self->{logger}->log(1, "checkAuthByUser() SQL execute error: " . $DBI::errstr . " Query: " . $sCheckAuthQuery)
            if $self->{logger};
        $sth->finish;
        return (0, 0);
    }

    my $ref = $sth->fetchrow_hashref();
    unless ($ref) {
        $sth->finish;
        return (0, 0);
    }

    my $id_user = $ref->{id_user};
    $sth->finish;

    my $sHostmask = getMessageHostmask($self, $message);
    unless (defined($sHostmask) && $sHostmask ne '') {
        $self->{logger}->log(1, "checkAuthByUser() could not resolve hostmask for $sUserHandle")
            if $self->{logger};
        return (0, 0);
    }

    $self->{logger}->log(3, "checkAuthByUser() Hostmask : $sHostmask to add to $sUserHandle")
        if $self->{logger};

    my $sql_check_hostmask = "SELECT id_user_hostmask FROM USER_HOSTMASK WHERE id_user=? AND hostmask=? LIMIT 1";
    my $chk = $dbh->prepare($sql_check_hostmask);

    unless ($chk) {
        $self->{logger}->log(1, "checkAuthByUser() hostmask SQL prepare error: " . $DBI::errstr . " Query: " . $sql_check_hostmask)
            if $self->{logger};
        return (0, 0);
    }

    unless ($chk->execute($id_user, $sHostmask)) {
        $self->{logger}->log(1, "checkAuthByUser() hostmask SQL execute error: " . $DBI::errstr . " Query: " . $sql_check_hostmask)
            if $self->{logger};
        $chk->finish;
        return (0, 0);
    }

    if ($chk->fetchrow_arrayref) {
        $chk->finish;
        return ($id_user, 1);
    }

    $chk->finish;

    my $sql_insert_hostmask = "INSERT INTO USER_HOSTMASK (id_user, hostmask) VALUES (?, ?)";
    my $ins = $dbh->prepare($sql_insert_hostmask);

    unless ($ins) {
        $self->{logger}->log(1, "checkAuthByUser() insert hostmask SQL prepare error: " . $DBI::errstr . " Query: " . $sql_insert_hostmask)
            if $self->{logger};
        return (0, 0);
    }

    unless ($ins->execute($id_user, $sHostmask)) {
        $self->{logger}->log(1, "checkAuthByUser() insert hostmask SQL execute error: " . $DBI::errstr . " Query: " . $sql_insert_hostmask)
            if $self->{logger};
        $ins->finish;
        return (0, 0);
    }

    $ins->finish;
    return ($id_user, 0);
}


# Context-based cstat: one-line output, truncated with "..."
sub userWhoAmI_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;
    my $user = $ctx->user;

    # Ensure we have a user object
    unless ($user && defined(eval { $user->id })) {
        botNotice($self, $nick, "User not found with this hostmask");
        return;
    }

    # Require authentication (whoami is meant for "current logged-in identity")
    unless ($user->is_authenticated) {
        botNotice(
            $self, $nick,
            "You must be logged in: /msg "
            . $self->{irc}->nick_folded
            . " login <username> <password>"
        );
        return;
    }

    my $uid   = eval { $user->id } // 0;
    my $uname = eval { $user->nickname } // eval { $user->handle } // $nick;

    my $lvl_desc = eval { $user->level_description } || eval { $user->level } || 'Unknown';

    # Base line
    botNotice($self, $nick, "User: $uname (Id: $uid - $lvl_desc)");

    my $dbh = $self->{dbh};
    unless ($dbh) {
        $self->{logger}->log(1, "userWhoAmI_ctx() no database handle")
            if $self->{logger};
        botNotice($self, $nick, "Internal error (DB unavailable).");
        return;
    }

    # Pull DB details.
    # Do not SELECT the password/hash value here: whoami only needs to know
    # whether a password exists.
    my $sql = q{
        SELECT
            username,
            CASE
                WHEN password IS NOT NULL AND password <> '' THEN 1
                ELSE 0
            END AS has_password,
            creation_date,
            last_login,
            auth
        FROM USER
        WHERE id_user = ?
        LIMIT 1
    };
    my $sth = $dbh->prepare($sql);

    unless ($sth) {
        $self->{logger}->log(1, "userWhoAmI_ctx() SQL prepare error: $DBI::errstr | Query: $sql")
            if $self->{logger};
        botNotice($self, $nick, "Internal error (query failed).");
        return;
    }

    unless ($sth->execute($uid)) {
        $self->{logger}->log(1, "userWhoAmI_ctx() SQL execute error: $DBI::errstr | Query: $sql")
            if $self->{logger};
        $sth->finish;
        botNotice($self, $nick, "Internal error (query failed).");
        return;
    }

    my $ref = $sth->fetchrow_hashref();
    $sth->finish;

    unless ($ref) {
        botNotice($self, $nick, "User record not found in database (id=$uid)");
        logBot($self, $ctx->message, undef, "whoami");
        return;
    }

    my $created    = $ref->{creation_date} // 'N/A';
    my $last_login = $ref->{last_login}    // 'never';

    # Fetch hostmasks from USER_HOSTMASK.
    # Do not GROUP_CONCAT everything into one huge IRC line: hostmasks can
    # grow over time, so we paginate them below.
    my @hostmasks;
    my $hm_sql = "SELECT hostmask FROM USER_HOSTMASK WHERE id_user=? ORDER BY id_user_hostmask LIMIT 20";
    my $hm_sth = $dbh->prepare($hm_sql);

    unless ($hm_sth) {
        $self->{logger}->log(1, "userWhoAmI_ctx() hostmask SQL prepare error: $DBI::errstr | Query: $hm_sql")
            if $self->{logger};
    }
    elsif (!$hm_sth->execute($uid)) {
        $self->{logger}->log(1, "userWhoAmI_ctx() hostmask SQL execute error: $DBI::errstr | Query: $hm_sql")
            if $self->{logger};
        $hm_sth->finish;
    }
    else {
        while (my $hm_ref = $hm_sth->fetchrow_hashref) {
            push @hostmasks, $hm_ref->{hostmask}
                if defined($hm_ref->{hostmask}) && $hm_ref->{hostmask} ne '';
        }

        $hm_sth->finish;
    }

    my $db_auth = $ref->{auth} ? 1 : 0;

    # Password set: use the SQL boolean, never the password/hash value.
    my $has_password = defined($ref->{has_password}) ? int($ref->{has_password}) : 0;
    my $pass_set     = $has_password ? "Password set" : "Password not set";

    # AUTOLOGIN status
    my $db_username = defined($ref->{username}) ? $ref->{username} : '';
    my $autologin   = ($db_username eq '#AUTOLOGIN#') ? "ON" : "OFF";

    my $auth_status = $db_auth ? "logged in" : "not logged in";

    # Compact — 2 NOTICE lines to avoid Excess Flood
    my $info1 = eval { $user->info1 } // eval { $user->{info1} } // '';
    my $info2 = eval { $user->info2 } // eval { $user->{info2} } // '';

    botNotice($self, $nick, "$pass_set | Status: $auth_status | AUTOLOGIN: $autologin");

    if (@hostmasks) {
        my $mask_count = scalar(@hostmasks);
        botNotice($self, $nick, "Masks: $mask_count shown, max 20");

        my $per_line = 2;
        my $page     = 1;

        while (@hostmasks) {
            my @chunk = splice(@hostmasks, 0, $per_line);
            my $line  = sprintf("whoami-masks[%02d]: %s", $page, join(' | ', @chunk));

            if (length($line) > 360) {
                $line = substr($line, 0, 357) . '...';
            }

            botNotice($self, $nick, $line);
            $page++;
        }
    }
    else {
        botNotice($self, $nick, "Masks: N/A");
    }

    botNotice(
        $self,
        $nick,
        "Created: $created | Last: $last_login"
        . ($info1 ne '' && $info1 ne 'N/A' ? " | $info1" : "")
        . ($info2 ne '' && $info2 ne 'N/A' ? " | $info2" : "")
    );

    logBot($self, $ctx->message, undef, "whoami");
    return 1;
}


# Add a new public command to the database (Administrator+)
sub userPass_ctx {
    my ($ctx) = @_;

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    userPass($ctx->bot, $ctx->message, $ctx->nick, @args);
}

sub userIdent_ctx {
    my ($ctx) = @_;

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    userIdent($ctx->bot, $ctx->message, $ctx->nick, @args);
}

sub xLogin_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my $message = $ctx->message;

    my $conf = $self->{conf};

    # --- Resolve user from context ---
    my $user = $ctx->user;
    unless ($user && $user->is_authenticated) {
        my $who = $user ? $user->nickname : "unknown";
        my $sNoticeMsg = $message->prefix . " xLogin command attempt (user $who is not logged in)";
        noticeConsoleChan($self, $sNoticeMsg);
        botNotice(
            $self,
            $nick,
            "You must be logged to use this command : /msg "
              . $self->{irc}->nick_folded
              . " login username password"
        );
        logBot($self, $message, undef, "xLogin", $sNoticeMsg);
        return;
    }

    # --- Check privileges (Master+) ---
    unless (eval { $user->has_level("Master") }) {
        my $lvl = eval { $user->level_description } || eval { $user->level } || '?';
        my $sNoticeMsg = $message->prefix
            . " xLogin command attempt (command level [Master] for user "
            . $user->nickname . " [$lvl])";
        noticeConsoleChan($self, $sNoticeMsg);
        botNotice(
            $self,
            $nick,
            "This command is not available for your level. Contact a bot master."
        );
        logBot($self, $message, undef, "xLogin", $sNoticeMsg);
        return;
    }

    # --- Read configuration ---
    my $xService = $conf->get('undernet.UNET_CSERVICE_LOGIN');
    unless (defined($xService) && $xService ne "") {
        botNotice($self, $nick, "undernet.UNET_CSERVICE_LOGIN is undefined in configuration file");
        return;
    }

    my $xUsername = $conf->get('undernet.UNET_CSERVICE_USERNAME');
    unless (defined($xUsername) && $xUsername ne "") {
        botNotice($self, $nick, "undernet.UNET_CSERVICE_USERNAME is undefined in configuration file");
        return;
    }

    my $xPassword = $conf->get('undernet.UNET_CSERVICE_PASSWORD');
    unless (defined($xPassword) && $xPassword ne "") {
        botNotice($self, $nick, "undernet.UNET_CSERVICE_PASSWORD is undefined in configuration file");
        return;
    }

    # --- Perform login to CSERVICE ---
    my $sNoticeMsg = "Authenticating to $xService with username $xUsername";
    botNotice($self, $nick, $sNoticeMsg);
    noticeConsoleChan($self, $sNoticeMsg);

    # Send login command to service
    botPrivmsg($self, $xService, "login $xUsername $xPassword");

    # Request +x on the bot nick
    if ($self->{irc} && $self->{irc}->is_connected) {
        my $botnick = $self->{irc}->nick_folded;
        $self->{irc}->write("MODE $botnick +x\x0d\x0a");
    } else {
        $self->{logger}->log(1, "xLogin_ctx: cannot set +x, not connected to IRC");
    }

    # Log action
    logBot($self, $message, undef, "xLogin", "$xUsername\@$xService");
    return 1;
}

# yomomma
# Send a random "Yomomma" joke, or a specific one by ID.
# Usage:
#   yomomma           -> random joke
#   yomomma <id>      -> joke with given id_yomomma
sub _dbg_auth_snapshot {
    my ($self, $stage, $user, $nick, $fullmask) = @_;

    my $uid = eval { $user && $user->can('id') ? $user->id : undef } // ($user->{id_user} // $user->{id} // undef);
    my $user_auth = $user ? $user->{auth} : undef;

    my $db_auth   = 'n/a';
    if ($uid) {
        eval { ($db_auth) = $self->{dbh}->selectrow_array('SELECT auth FROM USER WHERE id_user=?', undef, $uid); 1; }
          or do { $db_auth = 'err'; };
    }

    my $auth_mod = 'n/a';
    if ($self->{auth} && $uid) {
        my $ok = eval { $self->{auth}->is_logged_in_id($uid) };
        $auth_mod = defined $ok ? $ok : 'err';
    }

    my $sess_auth = eval { $self->{sessions}{lc($nick)}{auth} } // undef;
    my $cache_id  = eval { $self->{logged_in}{$uid} } // undef;

    $self->{logger}->log(
        3,
        sprintf("🔎 AUTH[%s] uid=%s user.auth=%s db.auth=%s authmod=%s cache.logged_in=%s session[%s].auth=%s mask='%s'",
            $stage,
            (defined $uid ? $uid : 'undef'),
            _bool_str($user_auth),
            ( $db_auth eq 'n/a' || $db_auth eq 'err' ? $db_auth : _bool_str($db_auth) ),
            ( $auth_mod eq 'n/a' || $auth_mod eq 'err' ? $auth_mod : _bool_str($auth_mod) ),
            _bool_str($cache_id),
            (defined $nick ? $nick : ''),
            _bool_str($sess_auth),
            (defined $fullmask ? $fullmask : '')
        )
    );
}

# Force les caches mémoire si la DB dit auth=1 (utile si du vieux code lit ailleurs)
sub _ensure_logged_in_state {
    my ($self, $user, $nick, $fullmask) = @_;
    return unless $user;

    my $uid = eval { $user->can('id') ? $user->id : undef } // ($user->{id_user} // $user->{id} // undef);
    return unless $uid;

    my ($auth_db) = $self->{dbh}->selectrow_array('SELECT auth FROM USER WHERE id_user=?', undef, $uid);
    return unless $auth_db;

    $user->{auth} = 1;

    if ($self->{auth}) {
        eval { $self->{auth}->set_logged_in($uid, 1) };
        eval {
            $self->{auth}->set_session_user($nick, {
                id_user        => $uid,
                nickname       => $user->{nickname},
                username       => $user->{username},
                id_user_level  => $user->{id_user_level},
                auth           => 1,
                hostmask       => $fullmask,
            })
        };
        eval { $self->{auth}->update_last_login($uid) };
    }

    $self->{logged_in}{$uid}           = 1;
    $self->{logged_in_by_nick}{lc $nick} = 1;
    $self->{sessions}{lc $nick} = {
        id_user        => $uid,
        nickname       => $user->{nickname},
        username       => $user->{username},
        id_user_level  => $user->{id_user_level},
        auth           => 1,
        hostmask       => $fullmask,
    };
    $self->{users_by_id}{$uid} = {
        id_user        => $uid,
        nickname       => $user->{nickname},
        username       => $user->{username},
        id_user_level  => $user->{id_user_level},
        auth           => 1,
        hostmask       => $fullmask,
    };
    $self->{users_by_nick}{lc $nick} = {
        id_user        => $uid,
        nickname       => $user->{nickname},
        username       => $user->{username},
        id_user_level  => $user->{id_user_level},
        auth           => 1,
        hostmask       => $fullmask,
    };
}

# Simple echo command using Mediabot::Context as a first integration step

1;