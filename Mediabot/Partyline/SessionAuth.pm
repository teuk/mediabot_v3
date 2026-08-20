package Mediabot::Partyline::SessionAuth;

# =============================================================================
# Mediabot::Partyline::SessionAuth
# =============================================================================
# mb678-II: session/auth extraction from Mediabot::Partyline.
#
# Session lifecycle, reverse-DNS identity, Telnet authentication helpers and
# brute-force protection live here. The historical Mediabot::Partyline method
# surface is imported back into the parent package so existing callers and
# subclasses keep the same API.
# =============================================================================

use strict;
use warnings;
use utf8;
use Exporter 'import';
use IO::Async::Stream;
use IO::Async::Timer::Countdown;
use POSIX qw(WNOHANG);
use Socket qw(inet_aton AF_INET);

our @EXPORT_OK = qw(
    _cancel_auth_timeout
    _close_session
    _reverse_dns_timeout
    _schedule_reverse_dns_lookup
    _display_nick
    _broadcast
    _broadcast_chat
    _telnet_echo_off
    _telnet_echo_on
    _strip_telnet_iac
    _pl_bf_blocked
    _pl_bf_record
    _pl_bf_clear
    _do_login
);

sub _cancel_auth_timeout {
    my ($self, $id) = @_;

    return unless defined $id;
    return unless $self->{users}{$id};

    my $timer = delete $self->{users}{$id}{auth_timeout_timer};
    return unless $timer;

    eval {
        $timer->stop if $timer->can('stop');
        $self->{loop}->remove($timer) if $self->{loop};
    };

    return;
}


# +---------------------------------------------------------------------------+
# ! Internal : clean up a session                                             !
# +---------------------------------------------------------------------------+

sub _close_session {
    my ($self, $id) = @_;

    return 0 unless defined $id;

    # mb366-B2: EOF, on_closed, .quit, .boot and forced input rejection can
    # converge on the same fd.  Only the first close owns the session metric;
    # later callbacks must be harmless no-ops instead of decrementing another
    # live user's gauge value.
    my $had_user   = exists $self->{users}{$id};
    my $had_stream = exists $self->{streams}{$id};
    my $eval_key   = "_eval_pending_$id";
    my $had_eval   = exists $self->{$eval_key};
    return 0 unless $had_user || $had_stream || $had_eval;

    # mb147-B1: close/disconnect before auth must not leave the 60s DCC auth
    # timeout scheduled until expiry.
    $self->_cancel_auth_timeout($id) if $had_user;

    if ($had_user && $self->{bot}->{metrics}) {
        my $current = $self->{bot}->{metrics}->get('mediabot_partyline_sessions_current');
        $current = 0 unless defined $current;
        if ($current > 0) {
            $self->{bot}->{metrics}->add('mediabot_partyline_sessions_current', -1);
        }
    }

    # Remove console hook from logger if active
    if ($had_user && $self->{bot} && $self->{bot}->{logger}
        && $self->{bot}->{logger}->can('remove_console_hook')) {
        $self->{bot}->{logger}->remove_console_hook($id);
    }

    delete $self->{users}{$id};
    delete $self->{streams}{$id};
    delete $self->{$eval_key};  # clean up any pending .eval confirmation

    $self->_write_runtime_status();
    return 1;
}


# ---------------------------------------------------------------------------
# _reverse_dns_timeout($ip, $timeout)
#
# Compatibility wrapper kept for older callers/tests. Reverse DNS must never
# run synchronously in the IO::Async process, so this helper now returns the
# validated IP immediately. New session code uses _schedule_reverse_dns_lookup()
# to update peer_host asynchronously.
# ---------------------------------------------------------------------------
sub _reverse_dns_timeout {
    my ($self, $ip, $timeout) = @_;

    return 'unknown' unless defined $ip && $ip ne '';
    return $ip;
}


# ---------------------------------------------------------------------------
# _schedule_reverse_dns_lookup($session_id, $ip, $timeout)
#
# MB313: gethostbyaddr() is a potentially blocking libc resolver call. Run it
# in a short-lived child, read its pipe through IO::Async, and keep the original
# IP visible until a valid hostname is available. Session identity is guarded
# with a unique lookup key so an old callback cannot update a reused fd.
# ---------------------------------------------------------------------------
sub _schedule_reverse_dns_lookup {
    my ($self, $id, $ip, $timeout) = @_;

    return 0 unless defined $id;
    return 0 unless $self->{users}{$id};
    return 0 unless defined $ip && $ip =~ /^\d{1,3}(?:\.\d{1,3}){3}$/;
    return 0 unless inet_aton($ip);

    my $loop = $self->{loop};
    return 0 unless $loop;

    $timeout = 2 unless defined($timeout) && $timeout =~ /^\d+(?:\.\d+)?$/;
    $timeout = 0.25 if $timeout < 0.25;
    $timeout = 10   if $timeout > 10;

    my $resolver_code = <<'RESOLVER';
use strict;
use warnings;
use Socket qw(inet_aton AF_INET);

my $ip = shift // '';
my $packed = inet_aton($ip);
exit 2 unless $packed;

my $host = gethostbyaddr($packed, AF_INET);
if (defined $host && $host ne '') {
    $host =~ s/[\r\n\0]+//g;
    print substr($host, 0, 253);
}
RESOLVER

    my $child_pid = open(
        my $pipe,
        '-|',
        $^X,
        '-e',
        $resolver_code,
        $ip,
    );

    unless (defined $child_pid) {
        $self->{bot}->{logger}->log(3,
            "Partyline reverse DNS: could not spawn lookup for $ip")
            if $self->{bot} && $self->{bot}->{logger};
        return 0;
    }

    my $lookup_key = join(':', $id, ++$self->{_reverse_dns_lookup_serial});
    my $session_ref = $self->{users}{$id};
    $session_ref->{reverse_dns_lookup_key} = $lookup_key;

    my $state = {
        output      => '',
        pipe_eof    => 0,
        child_done  => 0,
        finalized   => 0,
        timed_out   => 0,
        wait_status => undef,
        term_sent   => 0,
        kill_sent   => 0,
        session_ref => $session_ref,
        session_id  => $id,
        lookup_key  => $lookup_key,
        ip          => $ip,
    };

    $self->{_reverse_dns_lookups}{$lookup_key} = $state;

    my ($stream, $timeout_timer, $kill_timer, $reap_timer);
    my ($finish, $schedule_reap);

    my $remove_timer = sub {
        my ($timer) = @_;
        return unless $timer;

        eval { $timer->stop if $timer->can('stop') };
        eval { $loop->remove($timer) };
    };

    $finish = sub {
        return if $state->{finalized};
        return unless $state->{child_done};
        return unless $state->{pipe_eof} || $state->{timed_out};

        $state->{finalized} = 1;

        $remove_timer->($timeout_timer);
        $remove_timer->($kill_timer);
        $remove_timer->($reap_timer);

        eval { $loop->remove($stream) } if $stream;
        eval { close $pipe };

        my $current = $self->{users}{ $state->{session_id} };
        my $same_session = $current
            && $current == $state->{session_ref}
            && ($current->{reverse_dns_lookup_key} // '') eq $state->{lookup_key};

        if ($same_session) {
            delete $current->{reverse_dns_lookup_key};

            my $status = $state->{wait_status} // 0;
            my $signal = $status & 127;
            my $exit   = ($status >> 8) & 255;

            my $host = $state->{output} // '';
            $host =~ s/[\r\n\0]+//g;
            $host =~ s/^\s+|\s+$//g;

            if (!$state->{timed_out}
                && !$signal
                && $exit == 0
                && length($host)
                && length($host) <= 253) {
                $current->{peer_host} = $host;
                $self->_write_runtime_status()
                    if $current->{authenticated};
            }
        }

        delete $self->{_reverse_dns_lookups}{ $state->{lookup_key} };

        $finish        = undef;
        $schedule_reap = undef;
    };

    $schedule_reap = sub {
        return if $state->{finalized} || $state->{child_done};
        return if $reap_timer;

        $reap_timer = IO::Async::Timer::Countdown->new(
            delay     => 0.05,
            on_expire => sub {
                my $expired = $reap_timer;
                $reap_timer = undef;
                $remove_timer->($expired);

                return if $state->{finalized};

                my $waited = waitpid($child_pid, WNOHANG);

                if ($waited == $child_pid) {
                    $state->{wait_status} = $?;
                    $state->{child_done}  = 1;
                    $finish->();
                    return;
                }

                if ($waited == -1) {
                    $state->{wait_status} = 0;
                    $state->{child_done}  = 1;
                    $finish->();
                    return;
                }

                $schedule_reap->();
            },
        );

        $loop->add($reap_timer);
        $reap_timer->start;
    };

    $timeout_timer = IO::Async::Timer::Countdown->new(
        delay     => $timeout,
        on_expire => sub {
            return if $state->{finalized};

            $state->{timed_out} = 1;

            unless ($state->{term_sent}) {
                kill 'TERM', $child_pid;
                $state->{term_sent} = 1;
            }

            $schedule_reap->();

            $kill_timer = IO::Async::Timer::Countdown->new(
                delay     => 0.2,
                on_expire => sub {
                    return if $state->{finalized} || $state->{child_done};

                    my $waited = waitpid($child_pid, WNOHANG);

                    if ($waited == $child_pid) {
                        $state->{wait_status} = $?;
                        $state->{child_done}  = 1;
                        $finish->();
                        return;
                    }

                    if ($waited == -1) {
                        $state->{wait_status} = 0;
                        $state->{child_done}  = 1;
                        $finish->();
                        return;
                    }

                    unless ($state->{kill_sent}) {
                        kill 'KILL', $child_pid;
                        $state->{kill_sent} = 1;
                    }

                    $schedule_reap->();
                },
            );

            $loop->add($kill_timer);
            $kill_timer->start;
        },
    );

    $loop->add($timeout_timer);
    $timeout_timer->start;

    $stream = IO::Async::Stream->new(
        read_handle => $pipe,
        on_read     => sub {
            my ($io, $buffref, $eof) = @_;

            if (length $$buffref) {
                my $remaining = 1024 - length($state->{output});
                $state->{output} .= substr($$buffref, 0, $remaining)
                    if $remaining > 0;
                $$buffref = '';
            }

            if ($eof && !$state->{pipe_eof}++) {
                eval { $loop->remove($io) };
                $schedule_reap->();
            }

            return 0;
        },
    );

    $loop->add($stream);

    return 1;
}


sub _display_nick {
    my ($self, $id, $max_host_len) = @_;

    my $nick = $self->{users}{$id}{login}     // 'unknown';
    my $host = $self->{users}{$id}{peer_host} // 'unknown';
    my $ip   = $self->{users}{$id}{peer_ip}   // '';

    # If both reverse DNS and IP are known, preserve the IP entirely.
    # Only the reverse DNS part may be shortened for display.
    if ($ip ne '' && $host ne 'unknown' && $host ne $ip) {
        if ($max_host_len && length($host) > $max_host_len) {
            my $keep = $max_host_len - 3;
            $keep = 1 if $keep < 1;
            $host = substr($host, 0, $keep) . '...';
        }

        return "$nick\@$host/$ip";
    }

    # No separate IP available, so this is either already an IP or unknown.
    # Do not shorten here: better to keep the exact peer value.
    return "$nick\@$host";
}


# ---------------------------------------------------------------------------
# _broadcast(\$msg, \$exclude_id)
# Send a message to all authenticated partyline users, optionally skipping
# one session (typically the sender).
# ---------------------------------------------------------------------------
sub _broadcast {
    my ($self, $msg, $exclude_id) = @_;
    $exclude_id //= -1;

    for my $fid (keys %{ $self->{users} }) {
        next if $fid == $exclude_id;
        next unless $self->{users}{$fid}{authenticated};
        my $stream = $self->{streams}{$fid};
        next unless $stream;
        $stream->write($msg . "\r\n");
    }
}

# ---------------------------------------------------------------------------
# _broadcast_chat($nick, $text, $exclude_id)
# Broadcast a chat line in Eggdrop partyline style:
#   <nick> text
# ---------------------------------------------------------------------------
sub _broadcast_chat {
    my ($self, $id, $text, $exclude_id) = @_;
    my $display = $self->_display_nick($id);
    $self->_broadcast("<$display> $text", $exclude_id);
    $self->{bot}->{logger}->log(2, "Partyline chat <$display> $text");
}

# +---------------------------------------------------------------------------+
# ! Telnet helpers                                                            !
# +---------------------------------------------------------------------------+

sub _telnet_echo_off {
    my ($self, $stream) = @_;

    return unless $stream;

    # IAC WILL ECHO
    # This asks the telnet client to stop doing local echo because the server
    # will handle echoing. We intentionally do not echo password characters.
    $stream->write(pack('C*', 255, 251, 1));
}

sub _telnet_echo_on {
    my ($self, $stream) = @_;

    return unless $stream;

    # IAC WONT ECHO
    # This lets the telnet client resume local echo after password input.
    $stream->write(pack('C*', 255, 252, 1));
}

sub _strip_telnet_iac {
    my ($self, $data) = @_;

    return '' unless defined $data;

    my $iac = chr(255);

    # Remove simple TELNET negotiation sequences:
    # IAC WILL/WONT/DO/DONT <option>
    $data =~ s/\Q$iac\E[\xFB-\xFE].//gs;

    # Collapse escaped IAC IAC to a literal IAC, just in case.
    $data =~ s/\Q$iac\E\Q$iac\E/$iac/gs;

    return $data;
}

# mb343-B1: suivi anti-brute-force du login partyline PAR IP.
#
# Le compteur login_failures est porté par connexion (fd) : un attaquant qui se
# reconnecte repart à zéro, ce qui annule la protection. On ajoute un suivi par
# IP distante (peer_ip, fiable IPv4+IPv6 depuis mb340) qui PERSISTE à travers les
# reconnexions, dans une fenêtre temporelle. La clé est l'IP (jamais le login),
# pour ne JAMAIS verrouiller un compte légitime (pas de lockout-DoS).
#
# Helpers purs (opèrent sur la map passée) -> faciles à tester unitairement.
sub _pl_bf_blocked {
    my ($map, $ip, $now, $max, $window) = @_;
    return 0 unless defined($ip) && $ip ne '' && ref($map) eq 'HASH';
    my $e = $map->{$ip} or return 0;
    return 0 if !defined($e->{first_ts}) || ($now - $e->{first_ts}) >= $window;  # fenêtre expirée
    return (($e->{count} // 0) >= $max) ? 1 : 0;
}

sub _pl_bf_record {
    my ($map, $ip, $now, $window, $max_entries) = @_;
    return unless defined($ip) && $ip ne '' && ref($map) eq 'HASH';

    # mb352-B1: la limite annoncée doit être une vraie borne, pas seulement un
    # déclencheur de purge des entrées expirées. Valeur par défaut conservée pour
    # les anciens appelants/tests ; _do_login passe explicitement la limite.
    $max_entries = 1024
        unless defined($max_entries) && $max_entries =~ /^\d+$/ && $max_entries > 0;

    my $e = $map->{$ip};
    if (ref($e) ne 'HASH'
            || !defined($e->{first_ts})
            || ($now - $e->{first_ts}) >= $window) {
        $map->{$ip} = { count => 1, first_ts => $now };   # nouvelle fenêtre
    }
    else {
        $e->{count} = ($e->{count} // 0) + 1;
    }

    # Purger d'abord les entrées expirées ou mal formées. Le bucket courant est
    # conservé : il vient d'être enregistré et ne doit pas être évincé par sa
    # propre tentative.
    for my $k (keys %$map) {
        next if $k eq $ip;
        my $ek = $map->{$k};
        delete $map->{$k}
            if ref($ek) ne 'HASH'
            || !defined($ek->{first_ts})
            || ($now - $ek->{first_ts}) >= $window;
    }

    # Si toutes les entrées sont encore actives, retirer les plus anciennes
    # jusqu'à respecter réellement la borne. Le tri lexical rend les égalités
    # de timestamp déterministes et facilite les diagnostics/tests.
    if (keys(%$map) > $max_entries) {
        my @oldest = sort {
            (($map->{$a}{first_ts} // 0) <=> ($map->{$b}{first_ts} // 0))
                || ($a cmp $b)
        } grep { $_ ne $ip } keys %$map;

        while (keys(%$map) > $max_entries && @oldest) {
            delete $map->{shift @oldest};
        }
    }
    return;
}

sub _pl_bf_clear {
    my ($map, $ip) = @_;
    return unless defined($ip) && $ip ne '' && ref($map) eq 'HASH';
    delete $map->{$ip};
    return;
}

sub _do_login {
    my ($self, $stream, $id, $login, $password) = @_;

    my $bot = $self->{bot};
    my $dbh = $bot->{dbh};

    # mb354-B1: policy is configurable, with safe defaults and hard bounds.
    # Missing/malformed values fall back; numeric outliers are clamped by Conf.
    my $max_failures = eval {
        $bot->{conf}->get_int(
            'main.PARTYLINE_LOGIN_MAX_FAILURES',
            default => 5, min => 1, max => 100,
        )
    } // 5;
    my $failures = $self->{users}{$id}{login_failures} // 0;
    if ($failures >= $max_failures) {
        $bot->{logger}->log(1, "Partyline: too many login failures for fd=$id - closing connection");
        $stream->write("Too many authentication failures. Disconnecting.\r\n");
        $stream->close_when_empty;  # flush write before closing
        return;
    }

    # mb343-B1: brute-force par IP (persiste à travers les reconnexions).
    my $bf_map    = ($self->{_pl_login_fail_by_ip} //= {});
    my $bf_now    = time();
    my $bf_max = eval {
        $bot->{conf}->get_int(
            'main.PARTYLINE_LOGIN_IP_MAX_FAILURES',
            default => 15, min => 1, max => 1000,
        )
    } // 15;
    my $bf_window = eval {
        $bot->{conf}->get_int(
            'main.PARTYLINE_LOGIN_IP_WINDOW_SECONDS',
            default => 600, min => 30, max => 86400,
        )
    } // 600;
    my $bf_entries = eval {
        $bot->{conf}->get_int(
            'main.PARTYLINE_LOGIN_IP_MAX_ENTRIES',
            default => 1024, min => 16, max => 65536,
        )
    } // 1024;
    my $bf_ip     = $self->{users}{$id}{peer_ip} // '';
    $bf_ip = '' if $bf_ip eq 'unknown';   # IP inconnue -> repli sur le compteur par-connexion

    if ($bf_ip ne '' && _pl_bf_blocked($bf_map, $bf_ip, $bf_now, $bf_max, $bf_window)) {
        $bot->{logger}->log(1, "Partyline: address $bf_ip temporarily blocked (brute-force) - closing fd=$id");
        $stream->write("Too many authentication failures from your address. Try again later.\r\n");
        $stream->close_when_empty;
        return;
    }

    my $sth = $dbh->prepare(
        "SELECT u.id_user, u.nickname, ul.level, ul.description
         FROM USER u
         JOIN USER_LEVEL ul ON ul.id_user_level = u.id_user_level
         WHERE u.nickname = ?"
    );

    unless ($sth && $sth->execute($login)) {
        $bot->{logger}->log(1, "Partyline: SQL error on login query: " . $DBI::errstr);
        $stream->write("Internal error during authentication.\r\n");
        $sth->finish if $sth;
        return;
    }

    my $row = $sth->fetchrow_hashref;
    $sth->finish;

    unless ($row) {
        $bot->{logger}->log(2, "Partyline: unknown user '$login' (fd=$id)");
        $self->{users}{$id}{login_failures}++;
        _pl_bf_record($bf_map, $bf_ip, $bf_now, $bf_window, $bf_entries) if $bf_ip ne '';   # mb343-B1
        $stream->write("Authentication failed.\r\n");
        return;
    }

    unless ($bot->{auth}->verify_credentials($row->{id_user}, $login, $password)) {
        $bot->{logger}->log(2, "Partyline: bad password for '$login' (fd=$id)");
        $self->{users}{$id}{login_failures}++;
        _pl_bf_record($bf_map, $bf_ip, $bf_now, $bf_window, $bf_entries) if $bf_ip ne '';   # mb343-B1
        $stream->write("Authentication failed.\r\n");
        return;
    }

    # Minimum level : Master (Owner=0, Master=1 => level <= 1)
    unless (defined($row->{level}) && $row->{level} <= 1) {
        $bot->{logger}->log(2, "Partyline: '$login' level=" . ($row->{level} // 'undef') . " insufficient (fd=$id)");
        $self->{users}{$id}{login_failures}++;
        _pl_bf_record($bf_map, $bf_ip, $bf_now, $bf_window, $bf_entries) if $bf_ip ne '';   # mb343-B1
        $stream->write("Access denied: Master level or above required.\r\n");
        return;
    }

    # Reset counter on success
    $self->{users}{$id}{login_failures} = 0;
    _pl_bf_clear($bf_map, $bf_ip) if $bf_ip ne '';   # mb343-B1: succès -> on oublie les échecs de cette IP

    $self->{users}{$id}{authenticated} = 1;
    $self->{users}{$id}{login}         = $login;
    $self->{users}{$id}{level}         = $row->{level};
    $self->{users}{$id}{level_desc}    = $row->{description};
    $self->{users}{$id}{auth_stage}    = undef;   # clear — stop masking log lines
    $self->{users}{$id}{authenticated_at} = time();

    # mb147-B1: authentication succeeded, so the DCC auth timeout is obsolete.
    $self->_cancel_auth_timeout($id);

    $self->_write_runtime_status();

    if ($bot->{metrics}) {
        $bot->{metrics}->inc('mediabot_partyline_logins_total');
    }

    $bot->{logger}->log(2, "Partyline: '$login' authenticated (level=" . $row->{description} . ", fd=$id)");

    my ($sec, $min, $hour) = localtime(time);
    my $local_time = sprintf("%02d:%02d", $hour, $min);

    $stream->write("\r\nConnected to Mediabot Partyline.\r\n");
    $stream->write("\r\nHey $login! Welcome to the Mediabot partyline.\r\n");
    $stream->write("Local time is now $local_time.\r\n");
    $stream->write("You are authenticated as " . $row->{description} . ".\r\n");
    $stream->write("\r\nCommands start with '.' (like '.quit' or '.help').\r\n");
    $stream->write("Everything else goes out to the partyline.\r\n\r\n");

    # Display MOTD if set
    $self->_send_motd($stream) if @{ $self->{motd} || [] };

    # Show who is on the partyline (Eggdrop-style auto .whom on join)
    $self->_cmd_whom($stream, $id);

    # Announce arrival to other partyline users
    $self->_broadcast("*** " . $self->_display_nick($id) . " joined the partyline. ***", $id);
}

1;
