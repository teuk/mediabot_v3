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
    );

    $self->{logger}->log(1, "Authentication module initialized");
}


# Get autologin status for a user handle (returns 1 if username='#AUTOLOGIN#', else 0)
sub getUserAutologin {
    my ($self, $sMatchingUserHandle) = @_;

    my $sQuery = "SELECT 1 FROM USER WHERE nickname = ? AND username = '#AUTOLOGIN#'";
    my $sth = $self->{dbh}->prepare($sQuery);

    unless ($sth->execute($sMatchingUserHandle)) {
        $self->{logger}->log(1, "getUserAutologin() SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
    }
    else {
        if (my $ref = $sth->fetchrow_hashref()) {
            $sth->finish;
            return 1;
        }
        else {
            $sth->finish;
            return 0;
        }
    }
}

# Get user id from user handle
sub checkAuth {
	my ($self,$iUserId,$sUserHandle,$sPassword) = @_;
	my $sCheckAuthQuery = "SELECT id_user FROM USER WHERE id_user = ? AND nickname = ? AND password = PASSWORD(?)";
	my $sth = $self->{dbh}->prepare($sCheckAuthQuery);
	unless ($sth->execute($iUserId,$sUserHandle,$sPassword)) {
		$self->{logger}->log(1,"checkAuth() SQL Error : " . $DBI::errstr . " Query : " . $sCheckAuthQuery);
		return 0;
	}
	else {	
		if (my $ref = $sth->fetchrow_hashref()) {
			# Single UPDATE: set auth=1 and last_login in one statement
			my $sQuery = "UPDATE USER SET auth=1, last_login=NOW() WHERE id_user=?";
			my $sth2 = $self->{dbh}->prepare($sQuery);
			unless ($sth2->execute($iUserId)) {
				$self->{logger}->log(1,"checkAuth() SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
				$sth2->finish;
				return 0;
			}
			$sth2->finish;
			return 1;
		}
		else {
			return 0;
		}
	}
	$sth->finish;
}

# Context-based: Handle user login via private message (strictly DB nickname + password)
sub userLogin_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $sNick = $ctx->nick;

    my @tArgs = @{ $ctx->args // [] };

    # If parser prepended caller nick: [caller, user, pass] -> shift caller
    if (@tArgs >= 3 && defined $sNick && $sNick ne '' && defined $tArgs[0] && lc($tArgs[0]) eq lc($sNick)) {
        shift @tArgs;
    }

    # Expect: login <nickname_in_db> <password>
    unless (defined $tArgs[0] && $tArgs[0] ne "" && defined $tArgs[1] && $tArgs[1] ne "") {
        botNotice($self, $sNick, "Syntax error: /msg " . $self->{irc}->nick_folded . " login <username> <password>");
        return;
    }

    my $typed_user = $tArgs[0];     # MUST match USER.nickname strictly (e.g., 'teuk')
    my $typed_pass = $tArgs[1];

    my $dbh = $self->{dbh};
    unless ($dbh) {
        botNotice($self, $sNick, "Internal error (DB unavailable).");
        return;
    }

    # 1) Fetch account strictly by DB nickname
    my ($id_user, $db_nick, $stored_hash, $level_id);
    my $ok = eval {
        my $sth = $dbh->prepare(q{
            SELECT id_user, nickname, password, id_user_level
            FROM USER
            WHERE nickname = ?
            LIMIT 1
        });
        $sth->execute($typed_user);
        ($id_user, $db_nick, $stored_hash, $level_id) = $sth->fetchrow_array;
        $sth->finish;
        1;
    };

    unless ($ok) {
        botNotice($self, $sNick, "Internal error (query failed).");
        return;
    }

    unless (defined $id_user) {
        botNotice($self, $sNick, "Login failed (Unknown user).");
        my $msg = ($ctx->message->prefix // '') . " Failed login (Unknown user: $typed_user)";
        $self->noticeConsoleChan($msg) if $self->can('noticeConsoleChan');
        logBot($self, $ctx->message, undef, "login", $typed_user, "Failed (Unknown user)");
        return;
    }

    unless (defined $stored_hash && $stored_hash ne "") {
        botNotice($self, $sNick, "Your password is not set. Use /msg " . $self->{irc}->nick_folded . " pass <password>");
        return;
    }

    # 2) Compute MariaDB PASSWORD() candidate and compare
    my ($calc_hash) = eval { $dbh->selectrow_array('SELECT PASSWORD(?)', undef, $typed_pass) };
    unless (defined $calc_hash) {
        botNotice($self, $sNick, "Internal error (hash compute failed).");
        return;
    }

    if ($stored_hash eq $calc_hash) {
        # 3) Mark authenticated and stamp last_login
        eval {
            $dbh->do('UPDATE USER SET auth=1, last_login=NOW() WHERE id_user=?', undef, $id_user);
            1;
        };

        # 4) Register the caller's hostmask in USER_HOSTMASK if not already present
        my $fullmask = $ctx->message->prefix // '';
        my $hostmask = getMessageHostmask($self, $ctx->message);
        if ($hostmask && $hostmask ne '') {
            eval {
                my $chk = $dbh->prepare(
                    "SELECT id_user_hostmask FROM USER_HOSTMASK WHERE id_user=? AND hostmask=? LIMIT 1"
                );
                $chk->execute($id_user, $hostmask);
                my $exists = $chk->fetchrow_arrayref;
                $chk->finish;
                unless ($exists) {
                    my $ins = $dbh->prepare(
                        "INSERT INTO USER_HOSTMASK (id_user, hostmask) VALUES (?, ?)"
                    );
                    $ins->execute($id_user, $hostmask);
                    $ins->finish;
                    $self->{logger}->log(2, "login: registered hostmask '$hostmask' for id_user=$id_user");
                    $self->clear_user_cache($fullmask) if $self->can('clear_user_cache');
                }
                1;
            };
            if ($@) {
                $self->{logger}->log(1, "login: failed to register hostmask: $@");
            }
        }

        # Best-effort in-memory flags (ignore if structure differs)
        eval {
            $self->{auth}->{logged_in}{$id_user} = 1 if ref($self->{auth}) eq 'HASH' && ref($self->{auth}->{logged_in}) eq 'HASH';
            $self->{auth}->{sessions}{lc $db_nick} = { id_user => $id_user, auth => 1 } if ref($self->{auth}) eq 'HASH' && ref($self->{auth}->{sessions}) eq 'HASH';
            1;
        };

        # Résoudre la description du niveau depuis USER_LEVEL
        my $level_desc = eval {
            my ($desc) = $dbh->selectrow_array(
                'SELECT description FROM USER_LEVEL WHERE id_user_level=?', undef, $level_id
            );
            $desc;
        } // $level_id // "unknown";
        botNotice($self, $sNick, "Login successful as $db_nick (Level: $level_desc)");

        my $msg = ($ctx->message->prefix // '') . " Successful login as $db_nick (Level: $level_desc)";
        $self->noticeConsoleChan($msg) if $self->can('noticeConsoleChan');
        logBot($self, $ctx->message, undef, "login", $typed_user, "Success");
    }
    else {
        botNotice($self, $sNick, "Login failed (Bad password).");
        my $msg = ($ctx->message->prefix // '') . " Failed login (Bad password)";
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

    eval {
        $self->{dbh}->do(
            "UPDATE USER SET auth=0 WHERE id_user=?",
            undef, $uid
        );
        1;
    } or do {
        $self->{logger}->log(1, "userLogout_ctx() DB error: $@");
        botNotice($self, $nick, "Internal error during logout.");
        return;
    };

    # Invalidate user cache so subsequent commands see auth=0 immediately
    my $logout_mask = eval { $ctx->message->prefix } // '';
    $self->clear_user_cache($logout_mask) if $logout_mask && $self->can('clear_user_cache');

    $self->{logger}->log(1, "logout: $username (id=$uid) logged out");
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
        $self->{logger}->log(0, "Register attempt ignored (users already exist): " . ($ctx->message->prefix // ''));
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

    # Ensure the password is provided
    if (defined($tArgs[0]) && $tArgs[0] ne "") {

        # Attempt to find the user associated with the IRC message
        my $user = $self->get_user_from_message($message);

        if (defined($user) && defined($user->nickname)) {

            my $sNewPassword = $tArgs[0];
            my $sQuery = "UPDATE USER SET password=PASSWORD(?) WHERE id_user=?";
            my $sth = $self->{dbh}->prepare($sQuery);

            # Try to update the password in the database
            unless ($sth->execute($sNewPassword, $user->id)) {
                $self->{logger}->log(1, "SQL Error: $DBI::errstr - Query: $sQuery");
                $sth->finish;
                return 0;
            } else {
                # Log and notify success
                my $msg = "userPass() Set password for $sNick (user_id: " . $user->id . ", host: " . $message->prefix . ")";
                $self->{logger}->log(3, $msg);
                noticeConsoleChan($self, $msg);

                botNotice($self, $sNick, "Password set.");
                botNotice($self, $sNick, "You may now login with /msg " . $self->{irc}->nick_folded . " login " . $user->nickname . " <password>");
                logBot($self, $message, undef, "pass", "Success");

                $sth->finish;
                return 1;
            }

        } else {
            # Unknown user or hostmask not registered
            my $msg = $message->prefix . " Failed pass command, unknown user $sNick (" . $message->prefix . ")";
            noticeConsoleChan($self, $msg);
            logBot($self, $message, undef, "pass", "Failed - unknown user $sNick");
            return 0;
        }
    }
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
	my ($self,$message,$sUserHandle,$sPassword) = @_;
	my $sCheckAuthQuery = "SELECT id_user FROM USER WHERE nickname = ? AND password = PASSWORD(?)";
	my $sth = $self->{dbh}->prepare($sCheckAuthQuery);
	unless ($sth->execute($sUserHandle,$sPassword)) {
		$self->{logger}->log(1,"checkAuthByUser() SQL Error : " . $DBI::errstr . " Query : " . $sCheckAuthQuery);
		$sth->finish;
		return 0;
	}
	else {	
		if (my $ref = $sth->fetchrow_hashref()) {
			my $sHostmask = getMessageHostmask($self,$message);
			$self->{logger}->log(3,"checkAuthByUser() Hostmask : $sHostmask to add to $sUserHandle");
			my $id_user = $ref->{'id_user'};
			# Check in USER_HOSTMASK
			my $chk = $self->{dbh}->prepare(
			    "SELECT id_user_hostmask FROM USER_HOSTMASK WHERE id_user=? AND hostmask=? LIMIT 1"
			);
			$chk->execute($id_user, $sHostmask);
			if ($chk->fetchrow_arrayref) {
				$chk->finish;
				return ($id_user, 1);
			}
			$chk->finish;
			{
				my $ins = $self->{dbh}->prepare(
				    "INSERT INTO USER_HOSTMASK (id_user, hostmask) VALUES (?, ?)"
				);
				unless ($ins && $ins->execute($id_user, $sHostmask)) {
					$self->{logger}->log(1,"checkAuthByUser() SQL Error : " . $DBI::errstr);
					return (0,0);
				}
				$ins->finish;
				return ($id_user,0);
			}
		}
		else {
			$sth->finish;
			return (0,0);
		}
	}
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

    # Pull DB details (password set, created, last login, username)
    my $sql = "SELECT username, password, creation_date, last_login, auth FROM USER WHERE id_user=? LIMIT 1";
    my $sth = $self->{dbh}->prepare($sql);

    unless ($sth && $sth->execute($uid)) {
        $self->{logger}->log(1, "userWhoAmI_ctx() SQL Error: $DBI::errstr | Query: $sql");
        botNotice($self, $nick, "Internal error (query failed).");
        return;
    }

    if (my $ref = $sth->fetchrow_hashref()) {
        my $created    = $ref->{creation_date} // 'N/A';
        my $last_login = $ref->{last_login}    // 'never';
        # Fetch hostmasks from USER_HOSTMASK
        my $hm_sth2 = $self->{dbh}->prepare(
            "SELECT GROUP_CONCAT(hostmask ORDER BY id_user_hostmask SEPARATOR ', ') AS hm FROM USER_HOSTMASK WHERE id_user=?"
        );
        my $hostmasks = 'N/A';
        if ($hm_sth2 && $hm_sth2->execute($uid)) {
            my $hm_ref2 = $hm_sth2->fetchrow_hashref;
            $hostmasks = $hm_ref2->{hm} // 'N/A';
            $hm_sth2->finish;
        }
        my $db_auth    = $ref->{auth}          ? 1 : 0;

        # Password set: check the password field (NOT creation_date)
        my $pass_set = (defined $ref->{password} && $ref->{password} ne '') ? "Password set" : "Password not set";

        # AUTOLOGIN status
        my $db_username = defined($ref->{username}) ? $ref->{username} : '';
        my $autologin   = ($db_username eq '#AUTOLOGIN#') ? "ON" : "OFF";

        my $auth_status = $db_auth ? "logged in" : "not logged in";

        # Compact — 2 NOTICE lines to avoid Excess Flood
        my $info1 = eval { $user->info1 } // eval { $user->{info1} } // '';
        my $info2 = eval { $user->info2 } // eval { $user->{info2} } // '';
        botNotice($self, $nick,
            "$pass_set | Status: $auth_status | AUTOLOGIN: $autologin | Masks: $hostmasks"
        );
        botNotice($self, $nick,
            "Created: $created | Last: $last_login"
            . ($info1 ne '' && $info1 ne 'N/A' ? " | $info1" : "")
            . ($info2 ne '' && $info2 ne 'N/A' ? " | $info2" : "")
        );
    } else {
        botNotice($self, $nick, "User record not found in database (id=$uid)");
    }

    $sth->finish;

    logBot($self, $ctx->message, undef, "whoami");
    return 1;
}

# Add a new public command to the database (Administrator+)
sub userPass_ctx {
    my ($ctx) = @_;
    userPass($ctx->bot, $ctx->message, $ctx->nick, @{ $ctx->args });
}

sub userIdent_ctx {
    my ($ctx) = @_;
    userIdent($ctx->bot, $ctx->message, $ctx->nick, @{ $ctx->args });
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