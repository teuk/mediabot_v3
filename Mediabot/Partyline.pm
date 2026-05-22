package Mediabot::Partyline;

# +---------------------------------------------------------------------------+
# ! Mediabot::Partyline                                                       !
# ! TCP telnet-style partyline for bot administration                        !
# !                                                                           !
# ! Access : telnet <host> <PARTYLINE_PORT>  or  nc <host> <PARTYLINE_PORT>  !
# !                                                                           !
# ! Authentication : login <user> <password>                                 !
# ! Required global level : Master (or above)                                !
# !                                                                           !
# ! Commands :                                                                !
# !   .help                  - this help                                     !
# !   .stat                  - channel status (owner, chansets, nick count)  !
# !   .say #chan <message>   - send a PRIVMSG to a channel                   !
# !   .who #chan             - list nicks present in a channel               !
# !   .join #chan [key]      - make the bot join a channel                   !
# !   .part #chan            - make the bot part a channel                   !
# !   .nick <newnick>        - change the bot's nick                         !
# !   .raw <IRC command>     - send a raw IRC command (Owner only)           !
# !   .quit                  - close this session                            !
# +---------------------------------------------------------------------------+

use strict;
use warnings;
use IO::Async::Listener;
use IO::Async::Stream;
use IO::Async::Timer::Countdown;
use Socket qw(unpack_sockaddr_in sockaddr_family inet_ntoa inet_aton AF_INET);
use Scalar::Util qw(weaken);
use Time::HiRes qw(usleep);
use JSON qw(encode_json);
use Encode qw(encode);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Temp qw(tempfile);

our @EXPORT_OK = qw();

# +---------------------------------------------------------------------------+
# ! Constructor                                                               !
# +---------------------------------------------------------------------------+

sub new {
    my ($class, %args) = @_;

    my $self = {
        bot        => $args{bot},           # Mediabot object
        loop       => $args{loop},          # IO::Async::Loop
        port       => $args{port} || 23456,
        streams    => {},                   # fd => IO::Async::Stream
        users      => {},                   # fd => { authenticated, login, level, level_desc }
        motd       => $args{motd} || [],    # MOTD lines shown after login
        dcc_offers => {},                   # key => pending DCC offer hash
    };

    bless $self, $class;

    $self->_start_listener;

    return $self;
}

# +---------------------------------------------------------------------------+
# ! Accessors                                                                 !
# +---------------------------------------------------------------------------+

sub get_port {
    my ($self) = @_;
    return $self->{bot}->{conf}->get("main.PARTYLINE_PORT") || 23456;
}

# +---------------------------------------------------------------------------+
# ! Runtime status export for mbweb                                           !
# +---------------------------------------------------------------------------+

sub _runtime_status_path {
    my ($self) = @_;

    my $path = eval { $self->{bot}->{conf}->get('main.PARTYLINE_STATUS_JSON') };
    $path ||= $ENV{MEDIABOT_PARTYLINE_STATUS_JSON};
    # F4/fix: default to a path writable by the bot user
    $path ||= ($ENV{HOME} // '/tmp') . '/mediabot-partyline.json';

    return $path;
}

sub _runtime_status_payload {
    my ($self) = @_;

    my @sessions;

    for my $fid (sort { $a <=> $b } keys %{ $self->{users} || {} }) {
        my $u = $self->{users}{$fid} || next;
        next unless $u->{authenticated};

        my $connected_at = $u->{connected_at} || $u->{authenticated_at} || time();

        push @sessions, {
            fd             => 0 + $fid,
            login          => $u->{login} // '',
            level          => defined($u->{level}) ? 0 + $u->{level} : undef,
            level_desc     => $u->{level_desc} // '',
            display        => eval { $self->_display_nick($fid, 80) } || ($u->{login} // ''),
            peer_host      => $u->{peer_host} // '',
            session_type   => $u->{is_dcc} ? 'dcc' : 'telnet',
            console_level  => defined($u->{console_level}) ? 0 + $u->{console_level} : undef,
            connected_at   => 0 + $connected_at,
            authenticated_at => 0 + ($u->{authenticated_at} || $connected_at),
            age_seconds    => time() - $connected_at,
        };
    }

    # Bot nick + uptime
    my $bot      = $self->{bot};
    my $bot_nick = eval { $bot->{irc}->nick_folded } // '?';
    my $start    = eval { $bot->{metrics}->{started} }
                // eval { $bot->{conf}->get('main.MAIN_PROG_BIRTHDATE') }
                // 0;
    my $uptime_secs = time() - $start;
    my $ud = int($uptime_secs / 86400);
    my $uh = int(($uptime_secs % 86400) / 3600);
    my $um = int(($uptime_secs % 3600) / 60);
    my $us = $uptime_secs % 60;
    my $uptime_str = '';
    $uptime_str .= "${ud}d " if $ud;
    $uptime_str .= "${uh}h " if $uh;
    $uptime_str .= "${um}m " if $um;
    $uptime_str .= "${us}s";
    $uptime_str =~ s/\s+$//;

    return {
        ok           => 1,
        generated_at => time(),
        count        => scalar(@sessions),
        sessions     => \@sessions,
        bot          => { nick => $bot_nick, uptime => $uptime_str },
    };
}

sub _write_runtime_status {
    my ($self) = @_;

    my $path = $self->_runtime_status_path;
    return unless defined($path) && $path ne '';

    my $payload = $self->_runtime_status_payload;
    my $json    = encode_json($payload);

    my $dir = dirname($path);

    eval {
        make_path($dir) if defined($dir) && $dir ne '' && !-d $dir;

        my ($fh, $tmp) = tempfile('.partyline-runtime-XXXXXX', DIR => $dir, UNLINK => 0);
        print {$fh} $json;
        print {$fh} "\n";
        close($fh);

        chmod 0640, $tmp;
        rename($tmp, $path) or die "rename($tmp, $path): $!";
    };

    if ($@) {
        my $err = $@;
        chomp($err);
        $self->{bot}->{logger}->log(2, "Partyline: could not write runtime status JSON '$path': $err")
            if $self->{bot} && $self->{bot}->{logger};
    }
}


# +---------------------------------------------------------------------------+
# ! Internal : start TCP listener                                             !
# +---------------------------------------------------------------------------+


# ---------------------------------------------------------------------------
# accept_dcc_chat($nick, $ip_int, $port)
#
# Open an outbound TCP connection to the DCC CHAT initiator and wire it
# up as a Partyline session. Called from Mediabot::_handle_dcc_chat_request
# after the user has been validated (level <= 1).
# ---------------------------------------------------------------------------
sub accept_dcc_chat {
    my ($self, $nick, $ip_int, $port) = @_;

    my $loop = $self->{loop};
    my $bot  = $self->{bot};

    # Convert 32-bit integer IP to dotted-quad
    my $ip = join('.', unpack('C4', pack('N', $ip_int)));

    $bot->{logger}->log(2, "DCC CHAT: connecting to $nick at $ip:$port");

    $loop->connect(
        host     => $ip,
        service  => $port,
        socktype => 'stream',

        on_stream => sub {
            my ($stream) = @_;
            $bot->{logger}->log(2, "DCC CHAT: connected to $nick at $ip:$port");
            $self->_init_dcc_session($stream, $nick, $ip);
        },

        on_connect_error => sub {
            my (undef, $err) = @_;
            $bot->{logger}->log(1, "DCC CHAT: connect to $nick at $ip:$port failed - $err");
        },

        on_resolve_error => sub {
            my ($err) = @_;
            $bot->{logger}->log(1, "DCC CHAT: resolve error for $ip - $err");
        },
    );
}

# ---------------------------------------------------------------------------
# _resolve_dcc_public_ip($bot)
#
# Return the public IPv4 address to advertise in DCC CHAT offers.
# Reads historical Mediabot config keys first, then the environment,
# then falls back to the local IRC socket address when possible.
# ---------------------------------------------------------------------------
sub _resolve_dcc_public_ip {
    my ($self, $bot) = @_;

    $bot //= $self->{bot};

    my $public_ip = '';

    for my $key (
        'DCC_PUBLIC_IP',
        'main.DCC_PUBLIC_IP',
        'PARTYLINE_DCC_PUBLIC_IP',
        'main.PARTYLINE_DCC_PUBLIC_IP',
    ) {
        my $v;
        eval { $v = $bot->{conf}->get($key); };
        next unless defined $v;

        $v =~ s/^\s+|\s+$//g;
        next if $v eq '';

        $public_ip = $v;
        last;
    }

    if (!$public_ip && defined $ENV{MEDIABOT_DCC_PUBLIC_IP}) {
        $public_ip = $ENV{MEDIABOT_DCC_PUBLIC_IP};
        $public_ip =~ s/^\s+|\s+$//g;
    }

    if (!$public_ip) {
        eval {
            my $sockname = $bot->{irc}->read_handle->sockname;
            if ($sockname) {
                my $family = Socket::sockaddr_family($sockname);
                if ($family == AF_INET) {
                    my (undef, $addr) = unpack_sockaddr_in($sockname);
                    $public_ip = inet_ntoa($addr);
                }
            }
        };
    }

    return unless $public_ip;
    return if $public_ip eq '0.0.0.0';
    return unless inet_aton($public_ip);

    return $public_ip;
}

# ---------------------------------------------------------------------------
# _dcc_listen_port($bot)
#
# Return the TCP port to use for temporary DCC CHAT listeners.
#
# If DCC_PORT_MIN and DCC_PORT_MAX are configured, pick a random port inside
# that range. This makes firewalling DCC CHAT predictable.
#
# If the range is missing or invalid, return 0 and let the OS pick an
# ephemeral port, preserving the old behavior.
# ---------------------------------------------------------------------------
sub _dcc_listen_port {
    my ($self, $bot) = @_;

    $bot //= $self->{bot};

    my ($min, $max);

    for my $pair (
        [ 'DCC_PORT_MIN',       'DCC_PORT_MAX' ],
        [ 'main.DCC_PORT_MIN',  'main.DCC_PORT_MAX' ],
        [ 'PARTYLINE_DCC_PORT_MIN',      'PARTYLINE_DCC_PORT_MAX' ],
        [ 'main.PARTYLINE_DCC_PORT_MIN', 'main.PARTYLINE_DCC_PORT_MAX' ],
    ) {
        my ($kmin, $kmax) = @$pair;
        my ($vmin, $vmax);

        eval { $vmin = $bot->{conf}->get($kmin); };
        eval { $vmax = $bot->{conf}->get($kmax); };

        next unless defined $vmin && defined $vmax;
        next unless $vmin =~ /^\d+$/ && $vmax =~ /^\d+$/;

        $min = int($vmin);
        $max = int($vmax);
        last;
    }

    if (!defined $min || !defined $max) {
        return 0;
    }

    if ($min < 1 || $max > 65535 || $min > $max) {
        eval {
            $bot->{logger}->log(1, "DCC port range invalid: min=$min max=$max - falling back to OS ephemeral port");
        };
        return 0;
    }

    return $min + int(rand($max - $min + 1));
}



# ---------------------------------------------------------------------------
# DCC pending offer tracking helpers
# ---------------------------------------------------------------------------

sub _dcc_offer_key {
    my ($self, $type, $nick) = @_;

    $type ||= 'dcc_chat';
    $nick ||= 'unknown';

    return lc($type) . ':' . lc($nick);
}

sub _dcc_pending_offer_for_nick {
    my ($self, $nick) = @_;

    return unless defined $nick && $nick ne '';

    my $offers = $self->{dcc_offers} ||= {};

    for my $key (sort keys %$offers) {
        my $offer = $offers->{$key} || next;
        next if $offer->{connected};

        if (lc($offer->{nick} || '') eq lc($nick)) {
            return $offer;
        }
    }

    return;
}

sub _dcc_offer_register {
    my ($self, $type, $nick, $port, $public_ip, $listener) = @_;

    my $offers = $self->{dcc_offers} ||= {};
    my $key    = $self->_dcc_offer_key($type, $nick);

    $offers->{$key} = {
        key        => $key,
        type       => $type || 'dcc_chat',
        nick       => $nick || 'unknown',
        port       => $port || 0,
        public_ip  => $public_ip || '',
        listener   => $listener,
        created_at => time,
        connected  => 0,
    };

    return $offers->{$key};
}

sub _dcc_offer_remove {
    my ($self, $type, $nick) = @_;

    my $offers = $self->{dcc_offers} ||= {};
    my $key    = $self->_dcc_offer_key($type, $nick);

    delete $offers->{$key};
    return;
}

sub _dcc_offer_mark_connected {
    my ($self, $type, $nick) = @_;

    my $offers = $self->{dcc_offers} ||= {};
    my $key    = $self->_dcc_offer_key($type, $nick);

    if ($offers->{$key}) {
        $offers->{$key}{connected} = 1;
    }

    return;
}

sub _dcc_offers_snapshot {
    my ($self) = @_;

    my $offers = $self->{dcc_offers} ||= {};

    return [
        map {
            my $o = $offers->{$_};
            +{
                key        => $o->{key},
                type       => $o->{type},
                nick       => $o->{nick},
                port       => $o->{port},
                public_ip  => $o->{public_ip},
                created_at => $o->{created_at},
                connected  => $o->{connected} ? 1 : 0,
            }
        }
        sort keys %$offers
    ];
}

# ---------------------------------------------------------------------------
# offer_dcc_chat($bot, $nick)
#
# Handle Eggdrop-style:
#   /ctcp <botnick> CHAT
#
# In this mode the user asks the bot to open a DCC CHAT listener.
# We:
#   1. Open a temporary TCP listener on an ephemeral port
#   2. Send back: CTCP DCC CHAT chat <our_ip_int> <port>
#   3. Wait for the client to connect
#   4. On connection: init a DCC Partyline session
# ---------------------------------------------------------------------------
sub offer_dcc_chat {
    my ($self, $nick) = @_;

    my $bot = $self->{bot};

    my $loop   = $self->{loop};
    my $logger = $bot->{logger};

    my $public_ip = $self->_resolve_dcc_public_ip($bot);

    unless ($public_ip && $public_ip ne '0.0.0.0') {
        $logger->log(1, "CTCP CHAT from $nick: cannot determine public IP - set DCC_PUBLIC_IP in config");
        return;
    }

    my $packed_ip = inet_aton($public_ip);
    unless ($packed_ip) {
        $logger->log(1, "CTCP CHAT from $nick: invalid DCC_PUBLIC_IP '$public_ip'");
        return;
    }

    my $ip_int = unpack('N', $packed_ip);

    $logger->log(2, "CTCP CHAT from $nick: opening DCC CHAT offer on $public_ip");

    if (my $pending = $self->_dcc_pending_offer_for_nick($nick)) {
        my $age = time - ($pending->{created_at} || time);
        $logger->log(2, "DCC CHAT: refusing new CTCP offer for $nick - pending "
            . ($pending->{type} || 'dcc_chat')
            . " offer on port "
            . ($pending->{port} || '?')
            . " age=${age}s");

        eval {
            $bot->botPrivmsg($nick, "A DCC CHAT offer is already pending. Please connect to it or wait for timeout.");
        };

        return;
    }

    my $listener;
    my $listen_port;
    my $connected = 0;

    $listener = IO::Async::Listener->new(
        on_stream => sub {
            my (undef, $stream) = @_;

            return if $connected;
            $connected = 1;
            $self->_dcc_offer_mark_connected('ctcp_chat', $nick);
            $self->_dcc_offer_remove('ctcp_chat', $nick);

            $logger->log(2, "CTCP CHAT: $nick connected to offered DCC CHAT");

            eval { $loop->remove($listener) };

            $self->_init_dcc_session($stream, $nick, $public_ip);
        },
    );

    $loop->add($listener);

    my $dcc_port = $self->_dcc_listen_port($bot);

    $listener->listen(
        addr => { family => 'inet', socktype => 'stream', port => $dcc_port },

        on_listen => sub {
            my ($listener) = @_;
            $listen_port = $listener->read_handle->sockport;
            $self->_dcc_offer_register('ctcp_chat', $nick, $listen_port, $public_ip, $listener);

            $logger->log(2, "CTCP CHAT: listening on port $listen_port for $nick");

            # CTCP reply:
            # \001DCC CHAT chat <ip_int> <port>\001
            my $ctcp = "\001DCC CHAT chat $ip_int $listen_port\001";

            # DCC CHAT offers must go via a raw PRIVMSG to avoid botPrivmsg()
            # side effects (NoColors stripping, AntiFlood, Badword checks, LIVE log).
            $bot->{irc}->send_message('PRIVMSG', undef, $nick, $ctcp);

            $logger->log(2, "CTCP CHAT: sent DCC CHAT offer to $nick ip_int=$ip_int port=$listen_port");
        },

        on_listen_error => sub {
            $logger->log(1, "CTCP CHAT: listen error for $nick - $_[1]");
            $self->_dcc_offer_remove('ctcp_chat', $nick);
            eval { $loop->remove($listener) };
        },
    );

    my $timeout = IO::Async::Timer::Countdown->new(
        delay     => 60,
        on_expire => sub {
            return if $connected;

            $logger->log(2, "CTCP CHAT: timeout waiting for $nick to connect");
            $self->_dcc_offer_remove('ctcp_chat', $nick);
            eval { $loop->remove($listener) };
        },
    );

    $loop->add($timeout);
    $timeout->start;
}

# ---------------------------------------------------------------------------
# accept_dcc_chat_passive($bot, $nick, $token)
#
# Handle passive DCC CHAT (RFC-style reverse DCC).
# The client sent ip=0 port=0 token=N meaning it wants US to listen and
# it will connect to us. We:
#   1. Open a temporary TCP listener on an ephemeral port
#   2. Send back to the client: CTCP DCC CHAT chat <our_ip_int> <port> <token>
#   3. Wait for the client to connect (60s timeout)
#   4. On connection: close the listener, init DCC session normally
# ---------------------------------------------------------------------------
sub accept_dcc_chat_passive {
    my ($self, $nick, $token) = @_;

    my $bot    = $self->{bot};
    my $loop   = $self->{loop};
    my $logger = $bot->{logger};

    # ── Resolve our public IP via shared helper ──────────────────────────────
    my $public_ip = $self->_resolve_dcc_public_ip($bot);

    unless ($public_ip && $public_ip ne '0.0.0.0') {
        $logger->log(1, "DCC CHAT passive from $nick: cannot determine public IP - set main.DCC_PUBLIC_IP in config");
        return;
    }

    # Convert dotted-quad to 32-bit int for the CTCP reply
    my $ip_int = unpack('N', inet_aton($public_ip));

    $logger->log(2, "DCC CHAT passive from $nick: listening on $public_ip token=$token");

    # ── Open ephemeral listener ───────────────────────────────────────────────
    if (my $pending = $self->_dcc_pending_offer_for_nick($nick)) {
        my $age = time - ($pending->{created_at} || time);
        $logger->log(2, "DCC CHAT: refusing new passive offer for $nick - pending "
            . ($pending->{type} || 'dcc_chat')
            . " offer on port "
            . ($pending->{port} || '?')
            . " age=${age}s");

        eval {
            $bot->botPrivmsg($nick, "A DCC CHAT offer is already pending. Please connect to it or wait for timeout.");
        };

        return;
    }

    my $listener;
    my $listen_port;
    my $connected = 0;

    $listener = IO::Async::Listener->new(
        on_stream => sub {
            my (undef, $stream) = @_;

            return if $connected;   # accept only one connection
            $connected = 1;
            $self->_dcc_offer_mark_connected('passive_chat', $nick);
            $self->_dcc_offer_remove('passive_chat', $nick);

            $logger->log(2, "DCC CHAT passive: $nick connected (token=$token)");

            # Stop accepting new connections
            eval { $loop->remove($listener) };

            $self->_init_dcc_session($stream, $nick, $public_ip);
        },
    );

    $loop->add($listener);

    my $dcc_port = $self->_dcc_listen_port($bot);

    # Bind to configured DCC range if set, otherwise port 0 lets the OS choose.
    $listener->listen(
        addr => { family => 'inet', socktype => 'stream', port => $dcc_port },

        on_listen => sub {
            my ($listener) = @_;
            $listen_port = $listener->read_handle->sockport;
            $self->_dcc_offer_register('passive_chat', $nick, $listen_port, $public_ip, $listener);
            $logger->log(2, "DCC CHAT passive: listening on port $listen_port for $nick (token=$token)");

            # ── Send CTCP reply to client ─────────────────────────────────
            my $ctcp = "\001DCC CHAT chat $ip_int $listen_port $token\001";
            # Raw PRIVMSG — bypass botPrivmsg() side effects for CTCP payloads.
            $bot->{irc}->send_message('PRIVMSG', undef, $nick, $ctcp);
            $logger->log(2, "DCC CHAT passive: sent CTCP reply to $nick");
        },

        on_listen_error => sub {
            $logger->log(1, "DCC CHAT passive: listen error for $nick - $_[1]");
            eval { $loop->remove($listener) };
        },
    );

    # ── 60-second timeout - close listener if client never connects ───────────
    my $timeout = IO::Async::Timer::Countdown->new(
        delay     => 60,
        on_expire => sub {
            return if $connected;
            $logger->log(2, "DCC CHAT passive: timeout waiting for $nick (token=$token)");
            eval { $loop->remove($listener) };
        },
    );
    $loop->add($timeout);
    $timeout->start;
}

# ---------------------------------------------------------------------------
# _init_dcc_session($stream, $nick)
#
# Wire up a connected DCC CHAT stream as a Partyline session.
# Uses the standard nick → password flow (same as telnet).
# A 60-second authentication timeout is enforced.
# ---------------------------------------------------------------------------
sub _init_dcc_session {
    my ($self, $stream, $nick, $peer_host) = @_;
    $peer_host //= 'dcc';

    my $loop = $self->{loop};
    my $id   = fileno($stream->read_handle);

    $self->{users}{$id} = {
        authenticated  => 0,
        login          => '',
        level          => undef,
        level_desc     => '',
        rate_window    => time(),
        rate_count     => 0,
        login_failures => 0,
        console_level  => undef,
        connected_at   => time(),
        auth_stage     => 'nick',       # standard flow: nick then password
        pending_login  => undef,
        is_dcc         => 1,
        peer_ip        => $peer_host,
        peer_host      => $self->_reverse_dns_timeout($peer_host, 2),
    };
    $self->{streams}{$id} = $stream;

    # ── Authentication timeout: 60 seconds ───────────────────────────────────
    my $timeout_timer = IO::Async::Timer::Countdown->new(
        delay     => 60,
        on_expire => sub {
            return unless $self->{users}{$id};
            return if     $self->{users}{$id}{authenticated};
            $self->{bot}->{logger}->log(2, "DCC CHAT: auth timeout for $nick (fd=$id)");
            my $s = $self->{streams}{$id};
            if ($s) {
                $s->write("Authentication timeout.\r\n");
                $s->close_when_empty;
            }
            $self->_close_session($id);
        },
    );
    $loop->add($timeout_timer);
    $timeout_timer->start;

    $stream->configure(
        on_read => sub {
            my ($stream, $buffref, $eof) = @_;

            # DCC CHAT uses bare LF or CRLF - no TELNET IAC sequences
            while ($$buffref =~ s/^([^\n]*)\n//) {
                my $line = $1;
                $line =~ s/\r$//;

                # Mask password in logs — mask on stage 'pass' (standard flow)
                my $log_line = $line;
                if (($self->{users}{$id}{auth_stage} // '') eq 'pass') {
                    $log_line = '********';
                }
                else {
                    $log_line =~ s/^(login\s+\S+\s+).+/$1********/i;
                }

                $self->{bot}->{logger}->log(3, "DCC CHAT <- \'$log_line\' (fd=$id nick=$nick)");
                eval { $self->_handle_line($stream, $id, $line) };
                if ($@) {
                    $self->{bot}->{logger}->log(1, "DCC CHAT exception: $@");
                    $stream->write("Internal error.\r\n");
                }
            }

            if ($eof) {
                $self->{bot}->{logger}->log(3, "DCC CHAT EOF (fd=$id nick=$nick)");
                $self->_close_session($id);
            }

            return 0;
        },

        on_closed => sub {
            $self->{bot}->{logger}->log(3, "DCC CHAT connection closed (fd=$id nick=$nick)");
            # Capture display BEFORE _close_session deletes users{$id}
            my $authed = $self->{users}{$id} && $self->{users}{$id}{authenticated};
            my $display = $authed ? $self->_display_nick($id) : '';
            $self->_close_session($id);
            $self->_broadcast("*** $display left the partyline (DCC disconnected). ***")
                if $display;
        },
    );

    $loop->add($stream);

    $self->{bot}->{logger}->log(2, "DCC CHAT: session initialized for $nick (fd=$id)");

    if ($self->{bot}->{metrics}) {
        $self->{bot}->{metrics}->add('mediabot_partyline_sessions_current', 1);
    }

    # Standard login prompt — same flow as telnet
    $stream->write("DCC CHAT - Mediabot Partyline\r\n\r\n");
    $stream->write("Please enter your nickname.\r\n");
}

sub _start_listener {
    my ($self) = @_;

    my $loop = $self->{loop};
    my $bot  = $self->{bot};
    weaken($bot);

    $loop->listen(
        service  => $self->{port},
        socktype => 'stream',
        on_stream => sub {
            my ($stream) = @_;
            my $id = fileno($stream->read_handle);

            my $peer_host = 'unknown';
            eval {
                my $pn = $stream->read_handle->peername;
                if ($pn && sockaddr_family($pn) == AF_INET) {
                    my (undef, $addr) = unpack_sockaddr_in($pn);
                    $peer_host = inet_ntoa($addr);
                }
            };

            my $peer_ip = $peer_host;
            my $peer_rdns = $self->_reverse_dns_timeout($peer_ip, 2);

            $self->{users}{$id} = {
                authenticated  => 0,
                login          => '',
                level          => undef,
                level_desc     => '',
                peer_ip        => $peer_ip,
                peer_host      => $peer_rdns,
                # Rate limiting: max 10 commands per 5 seconds
                rate_window    => time(),
                rate_count     => 0,
                # Brute-force: max 5 failed login attempts before disconnect
                login_failures => 0,
                # Console: log level redirected to this session (undef = off)
                console_level  => undef,
                connected_at   => time(),

                # Eggdrop-style authentication prompt state:
                #   nick -> waiting for nickname
                #   pass -> waiting for password
                auth_stage     => 'nick',
                pending_login  => undef,
            };
            $self->{streams}{$id} = $stream;

            $stream->configure(
                on_read => sub {
                    my ($stream, $buffref, $eof) = @_;

                    # Strip TELNET IAC negotiation replies generated by clients
                    # after we toggle ECHO for password input.
                    $$buffref = $self->_strip_telnet_iac($$buffref);

                    while ($$buffref =~ s/^([^\n]*)\n//) {
                        my $line = $1;
                        $line =~ s/\r$//;

                        # Never log clear-text partyline passwords.
                        my $log_line = $line;
                        if (($self->{users}{$id}{auth_stage} // '') eq 'pass') {
                            $log_line = '********';
                        }
                        else {
                            # Backward-compatible masking if someone still types:
                            # login <user> <password>
                            $log_line =~ s/^(login\s+\S+\s+).+/$1********/i;
                        }

                        $self->{bot}->{logger}->log(3, "Partyline <- '$log_line' (fd=$id)");
                        eval {
                            $self->_handle_line($stream, $id, $line);
                        };
                        if ($@) {
                            $self->{bot}->{logger}->log(1, "Partyline exception: $@");
                            $stream->write("Internal error: $@\r\n");
                        }
                    }

                    if ($eof) {
                        $self->{bot}->{logger}->log(3, "Partyline EOF (fd=$id)");
                        $self->_close_session($id);
                    }

                    return 0;
                },
                on_closed => sub {
                    $self->{bot}->{logger}->log(3, "Partyline connection closed (fd=$id)");
                    # Capture display BEFORE _close_session deletes users{$id}
                    my $authed = $self->{users}{$id} && $self->{users}{$id}{authenticated};
                    my $display = $authed ? $self->_display_nick($id) : '';
                    $self->_close_session($id);
                    $self->_broadcast("*** $display left the partyline (disconnected). ***") if $display;
                },
            );

            $loop->add($stream);
            $stream->write("\r\n\r\nMediabot Partyline\r\n\r\nPlease enter your nickname.\r\n");
            $self->{bot}->{logger}->log(2, "Partyline: new connection (fd=$id)");

            if ($self->{bot}->{metrics}) {
                $self->{bot}->{metrics}->add('mediabot_partyline_sessions_current', 1);
            }
        },
        on_resolve_error => sub {
            $bot->{logger}->log(0, "Partyline: resolve error: $_[0]");
        },
        on_listen_error => sub {
            $bot->{logger}->log(0, "Partyline: listen error: $_[0]");
        },
    )->get;
}

# +---------------------------------------------------------------------------+
# ! Internal : clean up a session                                             !
# +---------------------------------------------------------------------------+

sub _close_session {
    my ($self, $id) = @_;

    if ($self->{bot}->{metrics}) {
        my $current = $self->{bot}->{metrics}->get('mediabot_partyline_sessions_current');
        $current = 0 unless defined $current;
        if ($current > 0) {
            $self->{bot}->{metrics}->add('mediabot_partyline_sessions_current', -1);
        }
    }

    # Remove console hook from logger if active
    if ($self->{bot} && $self->{bot}->{logger}
        && $self->{bot}->{logger}->can('remove_console_hook')) {
        $self->{bot}->{logger}->remove_console_hook($id);
    }

    delete $self->{users}{$id};
    delete $self->{streams}{$id};
    delete $self->{"_eval_pending_$id"};  # clean up any pending .eval confirmation

    $self->_write_runtime_status();
}


# ---------------------------------------------------------------------------
# _reverse_dns_timeout($ip, $timeout)
#
# Resolve an IPv4 address to a hostname.
#
# NOTE: alarm()/SIGALRM-based timeouts are unsafe inside an IO::Async event
# loop because SIGALRM can interrupt epoll_wait() or any in-flight socket I/O,
# causing spurious "Interrupted system call" errors.
#
# We therefore attempt the lookup without a signal-based timeout.
# gethostbyaddr() is a blocking call but its system-level timeout is typically
# 5 seconds on Debian (controlled by /etc/resolv.conf 'timeout' option).
# For the Partyline this is acceptable: connections are rare and the lookup
# runs synchronously only at session setup.  If it proves to be a problem in
# practice, migrate to $loop->resolver->getnameinfo() (async).
# ---------------------------------------------------------------------------
sub _reverse_dns_timeout {
    my ($self, $ip, $timeout) = @_;

    # $timeout parameter kept for API compatibility but no longer used.

    return $ip unless defined $ip && $ip ne '' && $ip ne 'unknown';
    return $ip unless $ip =~ /^\d{1,3}(?:\.\d{1,3}){3}$/;

    my $packed = inet_aton($ip);
    return $ip unless $packed;

    my $host = eval { scalar gethostbyaddr($packed, AF_INET) };
    return $ip if $@;

    return $host if defined $host && $host ne '';
    return $ip;
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

# +---------------------------------------------------------------------------+
# ! Internal : dispatch an incoming line                                      !
# +---------------------------------------------------------------------------+

sub _handle_line {
    my ($self, $stream, $id, $line) = @_;

    my $session = $self->{users}{$id};

    # ---- Rate limiting : max 10 commands per 5 seconds -------------------
    # Exempted during authentication: nick/pass prompts must not be throttled.
    # Brute-force on login is handled separately by login_failures counter.
    if ($session->{authenticated}) {
        my $now = time();
        if ($now - ($session->{rate_window} // $now) >= 5) {
            $session->{rate_window} = $now;
            $session->{rate_count}  = 0;
        }
        $session->{rate_count}++;
        if ($session->{rate_count} > 10) {
            $self->{bot}->{logger}->log(2, "Partyline: rate limit hit for fd=$id login=" . ($session->{login} || 'anon'));
            $stream->write("Rate limit exceeded. Slow down.\r\n");
            return;
        }
    }

        # ---- Not yet authenticated : Eggdrop-style login flow -----------------
    unless ($session->{authenticated}) {
        my $stage = $session->{auth_stage} || 'nick';

        # Backward compatibility with the former syntax:
        # login <user> <password>
        if ($line =~ /^login\s+(\S+)\s+(\S+)$/i) {
            $self->_do_login($stream, $id, $1, $2);

            unless ($self->{users}{$id} && $self->{users}{$id}{authenticated}) {
                $self->{users}{$id}{auth_stage}    = 'nick' if $self->{users}{$id};
                $self->{users}{$id}{pending_login} = undef  if $self->{users}{$id};
                $stream->write("\r\nPlease enter your nickname.\r\n") if $self->{streams}{$id};
            }

            return;
        }

        if ($stage eq 'nick') {
            $line =~ s/^\s+|\s+$//g;

            if ($line eq '') {
                $stream->write("Please enter your nickname.\r\n");
                return;
            }

            $session->{pending_login} = $line;
            $session->{auth_stage}    = 'pass';

            $stream->write("\r\nEnter your password.\r\n");
            $self->_telnet_echo_off($stream);
            return;
        }

        if ($stage eq 'pass') {
            my $login = $session->{pending_login} || '';

            if ($login eq '') {
                $session->{auth_stage} = 'nick';
                $stream->write("Please enter your nickname.\r\n");
                return;
            }

            $self->_telnet_echo_on($stream);
            $self->_do_login($stream, $id, $login, $line);

            unless ($self->{users}{$id} && $self->{users}{$id}{authenticated}) {
                $self->{users}{$id}{auth_stage}    = 'nick' if $self->{users}{$id};
                $self->{users}{$id}{pending_login} = undef  if $self->{users}{$id};
                $stream->write("\r\nPlease enter your nickname.\r\n") if $self->{streams}{$id};
            }

            return;
        }

        # Safety fallback.
        $self->_telnet_echo_on($stream);
        $session->{auth_stage} = 'nick';
        $stream->write("Please enter your nickname.\r\n");
        return;
    }

    # ---- Authenticated : dispatch commands --------------------------------
    # Record command in per-session history (max 10, skip .history itself)
    if ($line =~ /^\./ && $line !~ /^\.history$/i) {
        $self->{users}{$id}{history} //= [];
        push @{ $self->{users}{$id}{history} }, $line;
        if (scalar @{ $self->{users}{$id}{history} } > 10) {
            shift @{ $self->{users}{$id}{history} };
        }
    }

    # Announce dot-commands to all other partyline users so every session
    # knows who triggered what, without needing to run .whom.
    if ($line =~ /^\./ && $line !~ /^\.quit$/i) {
        my $cmd_display = $self->_display_nick($id);
        $self->_broadcast("[${cmd_display}] $line", $id);
    }

    if    ($line =~ /^\.whois\s+(\S+)$/i) {
        $self->{bot}->{metrics}->inc('mediabot_commands_partyline_total', { command => '.whois' }) if $self->{bot}->{metrics};
        $self->_cmd_whois($stream, $id, $1)
    }
    elsif ($line =~ /^\.timers$/i) {
        $self->{bot}->{metrics}->inc('mediabot_commands_partyline_total', { command => '.timers' }) if $self->{bot}->{metrics};
        $self->_cmd_timers($stream, $id)
    }
    elsif ($line =~ /^\.schedule(?:\s+(\S+)(?:\s+(\S+))?)?$/i) {
        $self->{bot}->{metrics}->inc('mediabot_commands_partyline_total', { command => '.schedule' }) if $self->{bot}->{metrics};
        $self->_cmd_schedule($stream, $id, $1, $2)
    }
    elsif ($line =~ /^\.log(?:\s+(\d+))?$/i) {
        $self->{bot}->{metrics}->inc('mediabot_commands_partyline_total', { command => '.log' }) if $self->{bot}->{metrics};
        $self->_cmd_log($stream, $id, $1)
    }
    elsif ($line =~ /^\.metrics$/i) {
        $self->{bot}->{metrics}->inc('mediabot_commands_partyline_total', { command => '.metrics' }) if $self->{bot}->{metrics};
        $self->_cmd_metrics($stream, $id);
    }
    elsif ($line =~ /^\.top(?:\s+(.*))?$/i) {
        $self->_cmd_top($stream, $id, $1 // '');
    }
    elsif ($line =~ /^\.remind\s+(.*)/i) {
        $self->_cmd_remind($stream, $id, $1);
    }
    elsif ($line =~ /^\.aistats$/i) {
        my $bot  = $self->{bot};
        my $reqs = eval { $bot->{metrics}->get('mediabot_claude_requests_total') } // 0;
        my $errs = eval { $bot->{metrics}->get('mediabot_claude_errors_total') }   // 0;
        my $rl   = eval { $bot->{metrics}->get('mediabot_claude_ratelimit_total') } // 0;
        my $hc   = scalar keys %{ $bot->{_claude_history} // {} };
        my $pc   = scalar keys %{ $bot->{_claude_persona}  // {} };
        $stream->write("Claude: $reqs req(s), $errs err(s), $rl rl — $hc hist, $pc persona\r\n");
    }
    elsif ($line =~ /^\.top(?:\s+(\d+))?$/i) {
        $self->_cmd_top($stream, $id, $1);
    }
    elsif ($line =~ /^\.seen\s+(\S+)/i) {
        $self->_cmd_seen($stream, $id, $1);
    }
    elsif ($line =~ /^\.kick\s+(.*)/i) {
        $self->_cmd_kick($stream, $id, $1);
    }
    elsif ($line =~ /^\.unmute\s+(.*)/i) {
        $self->_cmd_unmute($stream, $id, $1);
    }
    elsif ($line =~ /^\.floodset\s+(.*)/i) {
        $self->_cmd_floodset($stream, $id, $1);
    }
    elsif ($line =~ /^\.cmdcooldown\s+(.*)/i) {
        $self->_cmd_cmdcooldown($stream, $id, $1);
    }
    elsif ($line =~ /^\.floodstatus$/i) {
        $self->_cmd_floodstatus($stream, $id, undef);
    }
    elsif ($line =~ /^\.flushcooldown(?:\s+(.*?))?$/i) {
        $self->_cmd_flushcooldown($stream, $id, $1);
    }
    elsif ($line =~ /^\.kick\s+(.*)/i) {
        $self->_cmd_kick($stream, $id, $1);
    }
    elsif ($line =~ /^\.unmute\s+(.*)/i) {
        $self->_cmd_unmute($stream, $id, $1);
    }
    elsif ($line =~ /^\.floodset\s+(.*)/i) {
        $self->_cmd_floodset($stream, $id, $1);
    }
    elsif ($line =~ /^\.cmdcooldown\s+(.*)/i) {
        $self->_cmd_cmdcooldown($stream, $id, $1);
    }
    elsif ($line =~ /^\.floodstatus$/i) {
        $self->_cmd_floodstatus($stream, $id, undef);
    }
    elsif ($line =~ /^\.flushcooldown(?:\s+(.*?))?$/i) {
        $self->_cmd_flushcooldown($stream, $id, $1);
    }
    elsif ($line =~ /^\.dbstats$/i) {
        $self->_cmd_dbstats($stream, $id);
    }
    elsif ($line =~ /^\.remind(?:\s+(.*))?$/i) {
        $self->_cmd_remind($stream, $id, $1);
    }
    elsif ($line =~ /^\.karmahist(?:\s+(.*?))?$/i) {
        $self->_cmd_karmahist($stream, $id, $1);
    }
    elsif ($line =~ /^\.persona(?:\s+(.*))?$/i) {
        $self->_cmd_persona($stream, $id, $1);
    }
    elsif ($line =~ /^\.quota(?:\s+(.*))?$/i) {
        $self->_cmd_quota($stream, $id, $1);
    }
    elsif ($line =~ /^\.ai\s+(.*)/i) {
        $self->_cmd_ai($stream, $id, $1);
    }
    elsif ($line =~ /^\.stats(?:\s+(.*?))?$/i) {
        $self->_cmd_stats($stream, $id, $1);
    }
    elsif ($line =~ /^\.karma\s+(.*)/i) {
        $self->_cmd_karma($stream, $id, $1);
    }
    elsif ($line =~ /^\.reload$/i) {
        $self->_cmd_reload($stream, $id);
    }
    elsif ($line =~ /^\.seen\s+(\S+)/i) {
        $self->_cmd_seen($stream, $id, $1);
    }
    elsif ($line =~ /^\.purgereminders$/i) {
        $self->_cmd_purgereminders($stream, $id);
    }
    elsif ($line =~ /^\.logs\s+(.*)/i) {
        $self->_cmd_chanlog($stream, $id, $1);
    }
    elsif ($line =~ /^\.nickinfo\s+(\S+)/i) {
        $self->_cmd_nickinfo($stream, $id, $1);
    }
    elsif ($line =~ /^\.who\s+(#\S+)/i) {
        $self->_cmd_who_chan($stream, $id, $1);
    }
    elsif ($line =~ /^\.who\s+(\S+)/i) {
        $self->_cmd_whochan($stream, $id, $1);
    }
    elsif ($line =~ /^\.bcast\s+(.*)/i) {
        $self->{bot}->{metrics}->inc('mediabot_commands_partyline_total', { command => '.bcast' }) if $self->{bot}->{metrics};
        $self->_cmd_bcast($stream, $id, $1);
    }
    elsif ($line =~ /^\.channels$/i) {
        $self->{bot}->{metrics}->inc('mediabot_commands_partyline_total', { command => '.channels' }) if $self->{bot}->{metrics};
        $self->_cmd_channels($stream, $id);
    }
    elsif ($line =~ /^\.status$/i) {
        $self->{bot}->{metrics}->inc('mediabot_commands_partyline_total', { command => '.status' }) if $self->{bot}->{metrics};
        $self->_cmd_status($stream, $id);
    }
    elsif ($line =~ /^\.uptime$/i) {
        $self->{bot}->{metrics}->inc('mediabot_commands_partyline_total', { command => '.uptime' }) if $self->{bot}->{metrics};
        $self->_cmd_uptime($stream, $id)
    }

    elsif ($line =~ /^\.ping$/i) {
        $self->{bot}->{metrics}->inc('mediabot_commands_partyline_total', { command => '.ping' }) if $self->{bot}->{metrics};
        $self->_cmd_ping($stream, $id)
    }
    elsif ($line =~ /^\.unban\s+(#\S+)\s+(\S+)$/i) {
        $self->{bot}->{metrics}->inc('mediabot_commands_partyline_total', { command => '.unban' }) if $self->{bot}->{metrics};
        $self->_cmd_unban($stream, $id, $1, $2)
    }
    elsif ($line =~ /^\.topic\s+(#\S+)(?:\s+(.+))?$/i) {
        $self->{bot}->{metrics}->inc('mediabot_commands_partyline_total', { command => '.topic' }) if $self->{bot}->{metrics};
        $self->_cmd_topic($stream, $id, $1, $2)
    }
    elsif ($line =~ /^\.history$/i) {
        $self->{bot}->{metrics}->inc('mediabot_commands_partyline_total', { command => '.history' }) if $self->{bot}->{metrics};
        $self->_cmd_history($stream, $id)
    }
    elsif ($line =~ /^\.ban\s+(#\S+)\s+(\S+)(?:\s+(.*))?$/i) {
        $self->{bot}->{metrics}->inc('mediabot_commands_partyline_total', { command => '.ban' }) if $self->{bot}->{metrics};
        my ($chan, $nick_t, $rest) = ($1, $2, $3 // '');
        my @rest_args = split /\s+/, $rest;
        $self->_cmd_ban($stream, $id, $chan, $nick_t, @rest_args)
    }
    elsif ($line =~ /^\.bans?\s+(#\S+)$/i) {
        $self->{bot}->{metrics}->inc('mediabot_commands_partyline_total', { command => '.bans' }) if $self->{bot}->{metrics};
        $self->_cmd_bans($stream, $id, $1)
    }
    elsif ($line =~ /^\.help$/i) {
        $self->{bot}->{metrics}->inc('mediabot_commands_partyline_total', { command => '.help' }) if $self->{bot}->{metrics};
        $self->_cmd_help($stream, $id)
    }
    elsif ($line =~ /^\.stat$/i) {
        $self->{bot}->{metrics}->inc('mediabot_commands_partyline_total', { command => '.stat' }) if $self->{bot}->{metrics};
        $self->_cmd_stat($stream, $id)
    }
    elsif ($line =~ /^\.(?:dccstat|dcc)$/i) {
        $self->{bot}->{metrics}->inc('mediabot_commands_partyline_total', { command => '.dccstat' }) if $self->{bot}->{metrics};
        $self->_cmd_dccstat($stream, $id)
    }
    elsif ($line =~ /^\.console(?:\s+(.*))?$/i) {
        $self->{bot}->{metrics}->inc('mediabot_commands_partyline_total', { command => '.console' }) if $self->{bot}->{metrics};
        $self->_cmd_console($stream, $id, $1)
    }
    elsif ($line =~ /^\.whom$/i) {
        $self->{bot}->{metrics}->inc('mediabot_commands_partyline_total', { command => '.whom' }) if $self->{bot}->{metrics};
        $self->_cmd_whom($stream, $id)
    }
    elsif ($line =~ /^\.match\s+(\S+)$/i) {
        $self->{bot}->{metrics}->inc('mediabot_commands_partyline_total', { command => '.match' }) if $self->{bot}->{metrics};
        $self->_cmd_match($stream, $id, $1)
    }
    elsif ($line =~ /^\.boot\s+(\S+)$/i) {
        $self->{bot}->{metrics}->inc('mediabot_commands_partyline_total', { command => '.boot' }) if $self->{bot}->{metrics};
        $self->_cmd_boot($stream, $id, $1)
    }
    elsif ($line =~ /^\.motd(?:\s+(.*))?$/i) {
        $self->{bot}->{metrics}->inc('mediabot_commands_partyline_total', { command => '.motd' }) if $self->{bot}->{metrics};
        $self->_cmd_motd($stream, $id, $1)
    }
    elsif ($line =~ /^\.say\s+(\S+)\s+(.+)$/i) {
        $self->{bot}->{metrics}->inc('mediabot_commands_partyline_total', { command => '.say' }) if $self->{bot}->{metrics};
        $self->_cmd_say($stream, $id, $1, $2)
    }
    elsif ($line =~ /^\.who\s+(#\S+)$/i) {
        $self->{bot}->{metrics}->inc('mediabot_commands_partyline_total', { command => '.who' }) if $self->{bot}->{metrics};
        $self->_cmd_who($stream, $id, $1)
    }
    elsif ($line =~ /^\.join\s+(#\S+)(?:\s+(\S+))?$/i) {
        $self->{bot}->{metrics}->inc('mediabot_commands_partyline_total', { command => '.join' }) if $self->{bot}->{metrics};
        $self->_cmd_join($stream, $id, $1, $2)
    }
    elsif ($line =~ /^\.part\s+(#\S+)$/i) {
        $self->{bot}->{metrics}->inc('mediabot_commands_partyline_total', { command => '.part' }) if $self->{bot}->{metrics};
        $self->_cmd_part($stream, $id, $1)
    }
    elsif ($line =~ /^\.nick\s+(\S+)$/i) {
        $self->{bot}->{metrics}->inc('mediabot_commands_partyline_total', { command => '.nick' }) if $self->{bot}->{metrics};
        $self->_cmd_nick($stream, $id, $1)
    }
    elsif ($line =~ /^\.raw\s+(.+)$/i) {
        $self->{bot}->{metrics}->inc('mediabot_commands_partyline_total', { command => '.raw' }) if $self->{bot}->{metrics};
        $self->_cmd_raw($stream, $id, $1)
    }
    elsif ($line =~ /^\.reloadconf$/i) {
        my $bot = $self->{bot};
        eval {
            if ($bot->{conf} && $bot->{conf}->can('reload')) {
                $bot->{conf}->reload;
                $stream->write("Config reloaded.\r\n");
            } else {
                $stream->write("Config object has no reload method.\r\n");
            }
        };
        $stream->write("Error: $@\r\n") if $@;
    }
    elsif ($line =~ /^\.rehash$/i) {
        $self->{bot}->{metrics}->inc('mediabot_commands_partyline_total', { command => '.rehash' }) if $self->{bot}->{metrics};
        $self->_cmd_rehash($stream, $id)
    }
    elsif ($line =~ /^\.restart(?:\s+(.*))?$/i) {
        $self->{bot}->{metrics}->inc('mediabot_commands_partyline_total', { command => '.restart' }) if $self->{bot}->{metrics};
        $self->_cmd_restart($stream, $id, $1)
    }
    elsif ($line =~ /^\.eval\s+(.+)$/i) {
        $self->{bot}->{metrics}->inc('mediabot_commands_partyline_total', { command => '.eval' }) if $self->{bot}->{metrics};
        $self->_cmd_eval($stream, $id, $1)
    }
    elsif ($line =~ /^\.die(?:\s+(.*))?$/i) {
        $self->{bot}->{metrics}->inc('mediabot_commands_partyline_total', { command => '.die' }) if $self->{bot}->{metrics};
        $self->_cmd_die($stream, $id, $1 // "Partyline requested termination")
    }
    elsif ($line =~ /^\.quit$/i) {
        $self->{bot}->{metrics}->inc('mediabot_commands_partyline_total', { command => '.quit' }) if $self->{bot}->{metrics};
        my $nick = $self->{users}{$id}{login} // 'unknown';
        $self->_broadcast("*** " . $self->_display_nick($id) . " left the partyline. ***", $id);
        $stream->write("Goodbye.\r\n");
        $stream->close_when_empty;
        $self->_close_session($id);
    }
    elsif ($line =~ /^\./) {
        # Unknown dot-command
        $stream->write("Unknown command. Type .help for available commands.\r\n");
    }
    else {
        # Chat broadcast - anything not starting with '.' goes to everyone
        my $nick = $self->{users}{$id}{login} // 'unknown';
        $self->{bot}->{metrics}->inc('mediabot_commands_partyline_total', { command => 'chat' })
            if $self->{bot}->{metrics};
        # Echo back to sender with same format so they see their own message
        my $display = $self->_display_nick($id);
        $stream->write("<$display> $line\r\n");
        # Broadcast to all other authenticated users
        $self->_broadcast_chat($id, $line, $id);
    }
}

# +---------------------------------------------------------------------------+
# ! Internal : authentication                                                 !
# +---------------------------------------------------------------------------+

sub _do_login {
    my ($self, $stream, $id, $login, $password) = @_;

    my $bot = $self->{bot};
    my $dbh = $bot->{dbh};

    # Brute-force protection
    my $max_failures = 5;
    my $failures = $self->{users}{$id}{login_failures} // 0;
    if ($failures >= $max_failures) {
        $bot->{logger}->log(1, "Partyline: too many login failures for fd=$id - closing connection");
        $stream->write("Too many authentication failures. Disconnecting.\r\n");
        $stream->close_when_empty;  # flush write before closing
        return;
    }

    my $sth = $dbh->prepare(
        "SELECT u.id_user, u.nickname, ul.level, ul.description
         FROM USER u
         JOIN USER_LEVEL ul ON ul.id_user_level = u.id_user_level
         WHERE u.nickname = ?"
    );

    unless ($sth->execute($login)) {
        $bot->{logger}->log(1, "Partyline: SQL error on login query: " . $DBI::errstr);
        $stream->write("Internal error during authentication.\r\n");
        return;
    }

    my $row = $sth->fetchrow_hashref;
    $sth->finish;

    unless ($row) {
        $bot->{logger}->log(2, "Partyline: unknown user '$login' (fd=$id)");
        $self->{users}{$id}{login_failures}++;
        $stream->write("Authentication failed.\r\n");
        return;
    }

    unless ($bot->{auth}->verify_credentials($row->{id_user}, $login, $password)) {
        $bot->{logger}->log(2, "Partyline: bad password for '$login' (fd=$id)");
        $self->{users}{$id}{login_failures}++;
        $stream->write("Authentication failed.\r\n");
        return;
    }

    # Minimum level : Master (Owner=0, Master=1 => level <= 1)
    unless (defined($row->{level}) && $row->{level} <= 1) {
        $bot->{logger}->log(2, "Partyline: '$login' level=" . ($row->{level} // 'undef') . " insufficient (fd=$id)");
        $self->{users}{$id}{login_failures}++;
        $stream->write("Access denied: Master level or above required.\r\n");
        return;
    }

    # Reset counter on success
    $self->{users}{$id}{login_failures} = 0;

    $self->{users}{$id}{authenticated} = 1;
    $self->{users}{$id}{login}         = $login;
    $self->{users}{$id}{level}         = $row->{level};
    $self->{users}{$id}{level_desc}    = $row->{description};
    $self->{users}{$id}{auth_stage}    = undef;   # clear — stop masking log lines
    $self->{users}{$id}{authenticated_at} = time();

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

# +---------------------------------------------------------------------------+
# ! Commands                                                                  !
# +---------------------------------------------------------------------------+

# ---------------------------------------------------------------------------
# .help
# ---------------------------------------------------------------------------
sub _cmd_help {
    my ($self, $stream, $id) = @_;
    $stream->write(
        "Available commands:\r\n"
      . "  .help               - this help\r\n"
      . "  .stat               - channel status (owner, chansets, nick count)\r\n"
      . "  .dccstat            - show DCC Partyline listeners and sessions\r\n"
      . "  .whom               - list users currently on the partyline\r\n"
      . "  .whois <nick>       - send WHOIS to IRC and display result\r\n"
      . "  .timers             - list all scheduled tasks\r\n"
      . "  .schedule <list|status|start|stop|restart> [name] - control scheduler tasks\r\n"
      . "  .log [n]            - show last N lines of the bot log (default 20)\r\n"
      . "  .ping               - check partyline session is alive\r\n"
      . "  .metrics            - dump Prometheus metrics\r\n"
      . "  .ai <prompt>        - ask Claude (subcommands: reset, history)\r\n"
      . "  .aistats            - show Claude AI usage stats\r\n"
      . "  .top [n]            - top N speakers across all channels (default 5)\r\n"
      . "  .seen <nick>        - last activity for a nick in channel logs\r\n"
      . "  .logs <#chan> [n]   - show last N lines from CHANNEL_LOG (default 10)\r\n"
      . "  .nickinfo <nick>    - show DB info for a registered nick\r\n"
      . "  .kick <nick> <#chan> [reason] - kick a nick from channel\r\n"
      . "  .unmute <nick>               - lift a CC3/AF7 temporary nick mute\r\n"
      . "  .floodset <#chan> [w] [n] [s]- override AF4 params (window/max/silence)\r\n"
      . "  .cmdcooldown <#chan> <cmd> <s>- set per-cmd cooldown in seconds (CC1)\r\n"
      . "  .floodstatus                 - show live antiflood state (AF1/AF3/AF4)\r\n"
      . "  .flushcooldown [#chan]        - clear karma anti-spam cooldown\r\n"
      . "  .dbstats            - show DB connection and query stats\r\n"
      . "  .remind <nick> <#chan> <msg> - set a reminder from Partyline\r\n"
      . "  .karmahist [nick]   - show karma history for a channel or nick\r\n"
      . "  .persona [nick]     - view/clear Claude persona (all or specific nick)\r\n"
      . "  .quota [nick]       - show Claude rate limit (all or specific nick)\r\n"
      . "  .ai quota           - show your own Claude rate limit\r\n"
      . "  .stats [#chan]      - top 3 speakers + karma for a channel\r\n"
      . "  .karma <nick>       - show karma for a nick\r\n"
      . "  .reload             - reload bot configuration (Owner)\r\n"
      . "  .seen <nick>        - last seen event for a nick\r\n"
      . "  .purgereminders     - clean up delivered reminders\r\n"
      . "  .top [#chan] [n]    - top nicks on a channel\r\n"
      . "  .remind <nick> <msg> - set IRC reminder from partyline\r\n"
      . "  .who <nick>         - find nick on joined channels\r\n"
      . "  .bcast <msg>        - broadcast to all joined channels (Master+)\r\n"
      . "  .channels           - list joined channels with stats\r\n"
      . "  .status             - show runtime session status\r\n"
      . "  .uptime             - show bot and server uptime\r\n"
      . "  .match <handle>     - show user record (wildcards * ? allowed)\r\n"
      . "  .say <#chan|nick> <msg> - send a message to channel or user\r\n"
      . "  .who #chan          - list nicks present in a channel\r\n"
      . "  .join #chan [key]   - make the bot join a channel\r\n"
      . "  .part #chan         - make the bot part a channel\r\n"
      . "  .nick <newnick>     - change the bot's nick\r\n"
      . "  .raw <IRC command>  - send a raw IRC command (Owner only)\r\n"
      . "  .reloadconf         - reload config file without restart\r\n"
      . "  .rehash             - reload configuration and runtime state\r\n"
      . "  .restart            - reconnect IRC without killing process (Owner)\r\n"
      . "  .die                - terminate bot process entirely (Owner only)\r\n"
      . "  .eval <perl>        - execute Perl in bot context (Owner, dangerous)\r\n"
      . "  .console [0-5|off]  - redirect bot log to this session\r\n"
      . "  .ban #chan <nick> [duration] [reason] - ban a nick via WHOIS\r\n"
      . "  .bans #chan         - list active channel bans\r\n"
      . "  .unban #chan <mask|id> - remove an active ban\r\n"
      . "  .topic #chan [text] - show or change channel topic\r\n"
      . "  .history          - show last 10 commands this session\r\n"
      . "  .boot <handle>      - kick a user off the partyline (Owner)\r\n"
      . "  .motd [text|add <line>|clear]  - show/set/append/clear MOTD (Owner)\r\n"
      . "  .quit               - close this partyline session\r\n"
      . "\r\n"
      . "Chat:\r\n"
      . "  <text>              - broadcast to all partyline users\r\n"
    );
}

# ---------------------------------------------------------------------------
# .console - display or change per-session log redirect level
# Usage : .console          → show current level
#         .console <0-5>    → set level (0=INFO … 5=DEBUG5)
#         .console off      → disable console
sub _cmd_console {
    my ($self, $stream, $id, $arg) = @_;

    my $bot    = $self->{bot};
    my $logger = $bot->{logger};

    unless ($logger && $logger->can('add_console_hook')) {
        $stream->write("Console hooks not supported by this logger.\r\n");
        return;
    }

    if (!defined $arg || $arg eq '') {
        my $cur = $self->{users}{$id}{console_level};
        if (defined $cur) {
            my $level_name = ("INFO","DEBUG1","DEBUG2","DEBUG3","DEBUG4","DEBUG5")[$cur] // "UNKNOWN";
        $stream->write("Console is ON at level $cur ($level_name).\r\n");
        } else {
            $stream->write("Console is OFF. Use .console <0-5> to enable.\r\n");
        }
        return;
    }

    if (lc($arg) eq 'off') {
        $logger->remove_console_hook($id);
        $self->{users}{$id}{console_level} = undef;
        $stream->write("Console disabled.\r\n");
        $bot->{logger}->log(2, "Partyline: " . ($self->{users}{$id}{login} // '?') . " disabled console (fd=$id)");
        return;
    }

    unless ($arg =~ /^[0-5]$/) {
        $stream->write("Usage: .console [0-5|off]  (0=INFO only, 5=all debug)\r\n");
        return;
    }

    my $level = int($arg);
    my $nick  = $self->{users}{$id}{login} // 'unknown';

    $logger->add_console_hook($id, $level, sub {
        my ($line) = @_;
        my $s = $self->{streams}{$id};
        return unless $s;

        # IO::Async::Stream ultimately uses syswrite(), which expects bytes.
        # Logger lines may contain real Perl Unicode characters coming from
        # IRC output, e.g. heatmap bars (█/░), titles, emojis, etc.
        # Encode only at the transport boundary so IRC rendering stays intact.
        my $wire = encode('UTF-8', ($line // '') . "\r\n");

        eval { $s->write($wire) };
        if ($@) {
            # Stream gone — silently remove the hook so it stops firing
            eval { $logger->remove_console_hook($id) };
            $self->{users}{$id}{console_level} = undef if $self->{users}{$id};
        }
    });

    $self->{users}{$id}{console_level} = $level;
    $stream->write("Console enabled at level $level.\r\n");
    $bot->{logger}->log(2, "Partyline: $nick set console level=$level (fd=$id)");
}

# .motd - display or set the partyline message of the day
# Usage : .motd              → display current MOTD
#         .motd <text>       → replace MOTD with a single line (Owner)
#         .motd clear        → clear MOTD (Owner)
sub _cmd_motd {
    my ($self, $stream, $id, $arg) = @_;

    my $nick = $self->{users}{$id}{login} // 'unknown';

    if (!defined $arg || $arg eq '') {
        $self->_send_motd($stream);
        return;
    }

    # Modification requires Owner level
    unless (defined($self->{users}{$id}{level}) && $self->{users}{$id}{level} == 0) {
        $stream->write("Access denied: changing MOTD requires Owner level.\r\n");
        return;
    }

    if (lc($arg) eq 'clear') {
        $self->{motd} = [];
        $stream->write("MOTD cleared.\r\n");
        $self->{bot}->{logger}->log(2, "Partyline: $nick cleared MOTD");
        return;
    }

    # .motd add <line> — append a line to a multiline MOTD
    if ($arg =~ /^add\s+(.+)$/i) {
        push @{ $self->{motd} }, $1;
        $stream->write("MOTD line added (" . scalar(@{ $self->{motd} }) . " line(s) total).\r\n");
        $self->{bot}->{logger}->log(2, "Partyline: $nick added MOTD line: $1");
        return;
    }

    # .motd <text> — replace entire MOTD with a single line
    $self->{motd} = [ $arg ];
    $stream->write("MOTD set (1 line). Use '.motd add <line>' to append more.\r\n");
    $self->{bot}->{logger}->log(2, "Partyline: $nick set MOTD to: $arg");
}

# Internal helper - send MOTD lines to a stream
sub _send_motd {
    my ($self, $stream) = @_;

    my @lines = @{ $self->{motd} || [] };

    if (!@lines) {
        $stream->write("No MOTD set.\r\n");
        return;
    }

    $stream->write("--- MOTD ---\r\n");
    for my $line (@lines) {
        $stream->write("$line\r\n");
    }
    $stream->write("--- End of MOTD ---\r\n");
}

# .whom - list all authenticated partyline sessions (Eggdrop style)
sub _cmd_whom {
    my ($self, $stream, $id) = @_;

    my @rows;
    my $count = 0;
    my $nick_width = length('Nick/Host');

    for my $fid (sort { $a <=> $b } keys %{ $self->{users} }) {
        my $u = $self->{users}{$fid};
        next unless $u && $u->{authenticated};

        # Keep full IP visible. _display_nick only truncates reverse DNS.
        my $nick       = $self->_display_nick($fid, 48);
        my $level_desc = $u->{level_desc}   // '?';
        my $con_level  = defined $u->{console_level}
            ? "console:" . $u->{console_level}
            : "console:off";
        my $is_me      = ($fid == $id) ? " *" : "";

        $nick_width = length($nick) if length($nick) > $nick_width;

        push @rows, {
            nick       => $nick,
            level_desc => $level_desc,
            fd         => $fid,
            con_level  => $con_level,
            is_me      => $is_me,
        };

        $count++;
    }

    if ($count == 0) {
        $stream->write("No users currently on the partyline.\r\n");
        return;
    }

    $nick_width = 18 if $nick_width < 18;
    $nick_width = 80 if $nick_width > 80;

    my @lines;
    for my $row (@rows) {
        push @lines, sprintf("  %-*s  %-14s  fd=%-4d  %s%s",
            $nick_width,
            $row->{nick},
            $row->{level_desc},
            $row->{fd},
            $row->{con_level},
            $row->{is_me}
        );
    }

    $stream->write(sprintf("Partyline users (%d):\r\n", $count));
    $stream->write(sprintf("  %-*s  %-14s  %-7s %s\r\n",
        $nick_width, "Nick/Host", "Level", "Socket", "Console"));
    $stream->write("  " . ("-" x ($nick_width + 2 + 14 + 2 + 7 + 1 + 14)) . "\r\n");
    $stream->write("$_\r\n") for @lines;
}

# .match <handle> - show user record from database (Eggdrop whois-style)
# Accepts exact handle or wildcard pattern (* and ?)
# .match <handle> - show user record from database (Eggdrop whois-style)
# Accepts exact handle or wildcard pattern (* and ?)
sub _cmd_match {
    my ($self, $stream, $id, $pattern) = @_;

    my $bot = $self->{bot};
    my $dbh = $bot->{dbh};

    unless (defined $pattern && $pattern ne '') {
        $stream->write("Usage: .match <handle>  (wildcards * and ? allowed)\r\n");
        return;
    }

    # Convert Eggdrop-style wildcards to SQL LIKE wildcards.
    # This command intentionally supports wildcards, so * and ? become SQL
    # wildcards. Escape SQL LIKE escape char and literal SQL wildcards first.
    my $sql_pat = $pattern;
    $sql_pat =~ s/!/!!/g;
    $sql_pat =~ s/%/!%/g;
    $sql_pat =~ s/_/!_/g;
    $sql_pat =~ s/\*/%/g;
    $sql_pat =~ s/\?/_/g;

    my $sth = $dbh->prepare(q{
        SELECT
            u.id_user,
            u.nickname,
            u.auth,
            u.info1,
            u.info2,
            ul.description  AS level_desc,
            ul.level        AS level_num
        FROM USER u
        JOIN USER_LEVEL ul ON ul.id_user_level = u.id_user_level
        WHERE u.nickname LIKE ? ESCAPE '!'
        ORDER BY u.nickname
        LIMIT 21
    }); # fetch 21 to detect truncation (display only 20)

    unless ($sth && $sth->execute($sql_pat)) {
        $bot->{logger}->log(1, "Partyline .match SQL error: $DBI::errstr");
        $stream->write("Database error.\r\n");
        $sth->finish if $sth;
        return;
    }

    my $found = 0;

    while (my $row = $sth->fetchrow_hashref) {
        $found++;
        last if $found > 20;

        my $auth  = $row->{auth} ? "logged in" : "not logged in";
        my $info1 = $row->{info1}     // "";
        my $info2 = $row->{info2}     // "";

        $stream->write("\r\n");
        $stream->write(sprintf("  Handle  : %s\r\n", $row->{nickname}));
        $stream->write(sprintf("  Level   : %s (%d)\r\n", $row->{level_desc}, $row->{level_num}));
        $stream->write(sprintf("  Status  : %s\r\n", $auth));

        my @hostmasks;
        my $hm_sth = $dbh->prepare(q{
            SELECT hostmask
            FROM USER_HOSTMASK
            WHERE id_user = ?
            ORDER BY id_user_hostmask
            LIMIT 20
        });

        if ($hm_sth && $hm_sth->execute($row->{id_user})) {
            while (my $hm = $hm_sth->fetchrow_hashref) {
                push @hostmasks, $hm->{hostmask}
                    if defined($hm->{hostmask}) && $hm->{hostmask} ne '';
            }
            $hm_sth->finish;
        }
        else {
            $bot->{logger}->log(1, "Partyline .match hostmask SQL error: $DBI::errstr")
                if $bot->{logger};
            $hm_sth->finish if $hm_sth;
        }

        if (@hostmasks) {
            my $mask_count = scalar(@hostmasks);
            $stream->write(sprintf("  Hosts   : %d shown, max 20\r\n", $mask_count));

            my $per_line = 2;
            my $page     = 1;

            while (@hostmasks) {
                my @chunk = splice(@hostmasks, 0, $per_line);
                my $line  = sprintf("  Hosts[%02d]: %s", $page, join(' | ', @chunk));

                if (length($line) > 360) {
                    $line = substr($line, 0, 357) . '...';
                }

                $stream->write($line . "\r\n");
                $page++;
            }
        }
        else {
            $stream->write("  Hosts   : (none)\r\n");
        }

        $stream->write(sprintf("  Info1   : %s\r\n", $info1)) if $info1 ne '';
        $stream->write(sprintf("  Info2   : %s\r\n", $info2)) if $info2 ne '';
    }

    $sth->finish;

    if ($found == 0) {
        $stream->write("No match for '$pattern'.\r\n");
    }
    elsif ($found > 20) {
 $stream->write(sprintf("\r\nShowing first 20 matches for '%s' (more exist -- narrow your search).\r\n", $pattern));
    }
    elsif ($found > 1) {
        $stream->write(sprintf("\r\n%d match(es) for '%s'.\r\n", $found, $pattern));
    }
}


# .boot <handle> - kick a user off the partyline (Owner only)
sub _cmd_boot {
    my ($self, $stream, $id, $target_login) = @_;

    my $bot  = $self->{bot};
    my $nick = $self->{users}{$id}{login} // 'unknown';

    unless (defined($self->{users}{$id}{level}) && $self->{users}{$id}{level} == 0) {
        $stream->write("Access denied: .boot requires Owner level.\r\n");
        return;
    }

    unless (defined $target_login && $target_login ne '') {
        $stream->write("Usage: .boot <handle>\r\n");
        return;
    }

    # Find target session by login name
    my $target_id;
    for my $fid (keys %{ $self->{users} }) {
        next unless $self->{users}{$fid}{authenticated};
        if (lc($self->{users}{$fid}{login} // '') eq lc($target_login)) {
            $target_id = $fid;
            last;
        }
    }

    unless (defined $target_id) {
        $stream->write("No partyline session found for '$target_login'.\r\n");
        return;
    }

    if ($target_id == $id) {
        $stream->write("You cannot boot yourself. Use .quit instead.\r\n");
        return;
    }

    my $target_stream = $self->{streams}{$target_id};
    $bot->{logger}->log(2, "Partyline: $nick booted $target_login (fd=$target_id)");

    # Notify the victim
    if ($target_stream) {
        $target_stream->write("You have been booted by $nick.\r\n");
        $target_stream->close_when_empty;
    }

    # Announce to everyone else
    $self->_broadcast("*** " . $self->_display_nick($target_id) . " was booted by " . $self->_display_nick($id) . ". ***", $target_id);
    $stream->write("Booted $target_login.\r\n");

    $self->_close_session($target_id);
}



# ---------------------------------------------------------------------------
# .whois <nick>  - send WHOIS and display result in the partyline session
# Master+ only. The reply is captured via a console hook on the next
# RPL_WHOISUSER (311), RPL_WHOISCHANNELS (319), and RPL_ENDOFWHOIS (318).
# Because the WHOIS reply comes asynchronously, we store the session fd in a
# lightweight state key and let the bot's on_message_RPL_WHOISUSER handler
# write back to the stream.
# ---------------------------------------------------------------------------
sub _cmd_whois {
    my ($self, $stream, $id, $target) = @_;

    my $bot = $self->{bot};

    unless ($bot->{irc} && $bot->{irc}->is_connected) {
        $stream->write("Bot is not connected to IRC.\r\n");
        return;
    }

    unless (defined $target && $target =~ /\S/) {
        $stream->write("Usage: .whois <nick>\r\n");
        return;
    }

    # Store the session fd so the WHOIS reply callback can write back here
    $bot->{_partyline_whois_fd} = $id;
    $bot->{_partyline_whois_nick} = $target;
    $bot->{_partyline_whois_ts}   = time();

    $bot->{irc}->send_message('WHOIS', undef, $target);
    $stream->write("WHOIS sent for $target...\r\n");
    $bot->{logger}->log(3, "Partyline: $id requested WHOIS for $target");
}


# ---------------------------------------------------------------------------
# .log [n]  - show last N lines of the bot log (default: 20, max: 100)
# ---------------------------------------------------------------------------
sub _cmd_log {
    my ($self, $stream, $id, $n_arg) = @_;

    my $bot    = $self->{bot};
    my $logger = $bot->{logger};

    my $n = int($n_arg // 20);
    $n = 20  if $n < 1;
    $n = 100 if $n > 100;

    my $logfile = eval { $logger->{logfile} };
    unless ($logfile && -f $logfile) {
        $stream->write("No log file configured or file not found.\r\n");
        return;
    }

    # A6: re-check file existence just before open (may have been rotated)
    unless (-f $logfile && -r $logfile) {
        $stream->write("Log file not readable: $logfile\r\n");
        return;
    }

    open my $fh, '<:utf8', $logfile or do {  # A1: log written in UTF-8
        $stream->write("Cannot open log file: $!\r\n");
        return;
    };
    my @lines = <$fh>;
    close $fh;

    my @tail = @lines > $n ? @lines[-$n..-1] : @lines;

    $stream->write(sprintf("--- last %d line(s) of %s ---\r\n",
        scalar @tail, $logfile));
    for my $line (@tail) {
        $line =~ s/[\r\n]+$//;
        $stream->write("$line\r\n");
    }
    $stream->write("--- end ---\r\n");
}

# ---------------------------------------------------------------------------
# .timers  - list all registered scheduler tasks (Master+)
# ---------------------------------------------------------------------------
sub _cmd_timers {
    my ($self, $stream, $id) = @_;

    my $bot   = $self->{bot};
    my $sched = $bot->{scheduler};

    unless ($sched) {
        $stream->write("Scheduler not available.\r\n");
        return;
    }

    my @infos = $sched->all_info;
    unless (@infos) {
        $stream->write("No scheduled tasks registered.\r\n");
        return;
    }

    $stream->write(sprintf("%-30s %8s %8s %8s %s\r\n",
        "Name", "Interval", "Ticks", "Active", "Last tick"));
    $stream->write(("-" x 72) . "\r\n");

    for my $info (@infos) {
        my $last = $info->{last_tick}
            ? do {
                my @t = localtime($info->{last_tick});
                sprintf("%02d:%02d:%02d", $t[2], $t[1], $t[0]);
              }
            : "never";
        $stream->write(sprintf("%-30s %8ds %8d %8s %s\r\n",
            $info->{name},
            $info->{interval},
            $info->{ticks},
            $info->{started} ? "yes" : "no",
            $last,
        ));
    }
}


# ---------------------------------------------------------------------------
# _format_duration($seconds)
# ---------------------------------------------------------------------------
sub _format_duration {
    my ($self, $seconds) = @_;

    $seconds = 0 unless defined $seconds && $seconds =~ /^\d+(?:\.\d+)?$/;
    $seconds = int($seconds);

    my $days = int($seconds / 86400);
    $seconds %= 86400;

    my $hours = int($seconds / 3600);
    $seconds %= 3600;

    my $minutes = int($seconds / 60);
    my $secs    = $seconds % 60;

    my @parts;
    push @parts, "${days}d" if $days;
    push @parts, "${hours}h" if $hours;
    push @parts, "${minutes}m" if $minutes;
    push @parts, "${secs}s" if $secs || !@parts;

    return join(' ', @parts);
}



# ---------------------------------------------------------------------------
# .schedule <start|stop> <name>  - control a Scheduler task at runtime
# ---------------------------------------------------------------------------
sub _cmd_schedule {
    my ($self, $stream, $id, $action, $name) = @_;
    my $bot   = $self->{bot};
    my $sched = $bot->{scheduler};

    unless ($sched) {
        $stream->write("Scheduler not available.\r\n");
        return;
    }

    my $act = lc($action // 'list');

    # A3: list, status, start, stop
    if ($act eq 'list' || !defined $action) {
        my @infos = $sched->all_info;
        unless (@infos) {
            $stream->write("No scheduled tasks.\r\n");
            return;
        }
        $stream->write(sprintf("%-28s %-8s %-8s %s\r\n", "Name", "Interval", "Status", "Ticks"));
        $stream->write(("-" x 58) . "\r\n");
        for my $t (@infos) {
            $stream->write(sprintf("%-28s %-8s %-8s %d\r\n",
                $t->{name}, "$t->{interval}s",
                ($t->{started} ? "running" : "stopped"),
                $t->{ticks}));
        }
        return;
    }

    if ($act eq 'status') {
        my $info = defined $name ? $sched->task_info($name) : undef;
        unless ($info) {
            $stream->write("Usage: .schedule status <task_name>\r\n");
            $stream->write("Tasks: " . join(', ', $sched->task_names) . "\r\n");
            return;
        }
        my $last = $info->{last_tick}
            ? do { my @lt = localtime($info->{last_tick});
                   sprintf("%02d:%02d:%02d", $lt[2], $lt[1], $lt[0]) }
            : "never";
        $stream->write("Task:     $info->{name}\r\n");
        $stream->write("Interval: $info->{interval}s\r\n");
        $stream->write("Status:   " . ($info->{started} ? "running" : "stopped") . "\r\n");
        $stream->write("Ticks:    $info->{ticks}\r\n");
        $stream->write("Last run: $last\r\n");
        return;
    }

    unless (defined $name) {
        $stream->write("Usage: .schedule <list|status|start|stop> [task_name]\r\n");
        return;
    }

    if ($act eq 'start') {
        $sched->start($name);
        $stream->write("Task '$name' started.\r\n");
    } elsif ($act eq 'stop') {
        $sched->stop($name);
        $stream->write("Task '$name' stopped.\r\n");
    } elsif ($act eq 'restart') {
        # A2: new Scheduler::restart() method
        if ($sched->can('restart') && $sched->restart($name)) {
            $stream->write("Task '$name' restarted.\r\n");
        } else {
 $stream->write("Could not restart '$name' -- task not found or already stopped.\r\n");
        }
    } else {
        $stream->write("Unknown action '$act'. Use: list status start stop restart\r\n");
    }
}


# ---------------------------------------------------------------------------
# .status  - display the runtime status payload in the partyline session
# ---------------------------------------------------------------------------
sub _cmd_status {
    my ($self, $stream, $id) = @_;

    my $payload = eval { $self->_runtime_status_payload };
    if ($@) {
        $stream->write("Status unavailable: $@\r\n");
        return;
    }

    my $sessions  = $payload->{sessions}  // [];
    my $bot_info  = $payload->{bot}       // {};
    my $ts        = $payload->{generated_at} // time();

    $stream->write(sprintf("--- runtime status (generated %s) ---\r\n",
        scalar localtime($ts)));
    $stream->write(sprintf("Bot:      %s  uptime: %s\r\n",
        $bot_info->{nick} // '?', $bot_info->{uptime} // '?'));
    $stream->write(sprintf("Sessions: %d active\r\n", scalar @$sessions));

    for my $s (@$sessions) {
        my $lvl_display = $s->{level_desc} || $s->{level} // '?';
        my $con_display = defined($s->{console_level}) && $s->{console_level} ne '' && $s->{console_level} ne '0'
            ? $s->{console_level} : 'off';
        $stream->write(sprintf("  %-16s  fd=%-4s  level=%-10s  console=%s\r\n",
            $s->{login}  // '?',
            $s->{fd}     // '?',
            $lvl_display,
            $con_display));
    }
    # A5: joined channels summary
    my $bot        = $self->{bot};
    my $bot_nick_s = eval { $bot->{irc}->nick_folded } // '';
    my $chans_s    = $bot->{channels} || {};
    my @joined_s   = grep {
        my @n = eval { $bot->gethChannelsNicksOnChan($_) };
        grep { lc($_) eq lc($bot_nick_s) } @n;
    } sort keys %$chans_s;
    $stream->write(sprintf("Channels: %s\r\n",
        @joined_s ? join(", ", @joined_s) : "(none)"));
    $stream->write("--- end ---\r\n");
}


# ---------------------------------------------------------------------------
# .metrics  - dump current Prometheus metrics to the partyline session
# ---------------------------------------------------------------------------
sub _cmd_metrics {
    my ($self, $stream, $id) = @_;

    my $metrics = $self->{bot}->{metrics};
    unless ($metrics && $metrics->can('render_prometheus')) {
        $stream->write("Metrics not available.\r\n");
        return;
    }

    my $rendered = eval { $metrics->render_prometheus };
    if ($@) {
        $stream->write("Metrics render error: $@\r\n");
        return;
    }

    $stream->write("--- Prometheus metrics ---\r\n");
    for my $line (split /\n/, $rendered) {
        next if $line =~ /^#\s*(HELP|TYPE)/;   # skip metadata for compactness
        next if $line =~ /^\s*$/;
        $stream->write("$line\r\n");
    }
    $stream->write("--- end ---\r\n");
}


# ---------------------------------------------------------------------------
# .channels  - list joined channels with nick count and owner
# ---------------------------------------------------------------------------
sub _cmd_channels {
    my ($self, $stream, $id) = @_;

    my $bot      = $self->{bot};
    my $bot_nick = eval { $bot->{irc}->nick_folded } // '';
    my $chans    = $bot->{channels} || {};
    my $dbh      = eval { $bot->{db}->ensure_connected } // $bot->{dbh};

    my @names = sort keys %$chans;
    unless (@names) {
        $stream->write("No channels.\r\n");
        return;
    }

    # Batch-fetch owners (level 500) for all channels
    my %owners;
    if ($dbh) {
        my $sth_o = $dbh->prepare(
            "SELECT uc.id_channel, u.nickname FROM USER u
              JOIN USER_CHANNEL uc ON uc.id_user = u.id_user
              WHERE uc.level = 500"
        );
        if ($sth_o && $sth_o->execute()) {
            while (my $r = $sth_o->fetchrow_hashref) {
                $owners{ $r->{id_channel} } //= $r->{nickname};
            }
            $sth_o->finish;
        }
    }

    # AA3: also fetch Hailo flag and DB user count per channel
    my (%hailo_flags, %db_users);
    if ($dbh) {
        my $sth_h = $dbh->prepare(
            "SELECT c.name, cs.value FROM CHANNEL c
              JOIN CHANNEL_SET cs ON cs.id_channel = c.id_channel
              JOIN CHANSET_LIST cl ON cl.id_chanset_list = cs.id_chanset_list
              WHERE cl.name = 'Hailo'"
        );
        if ($sth_h && $sth_h->execute()) {
            while (my $r = $sth_h->fetchrow_hashref) {
                $hailo_flags{$r->{name}} = $r->{value};
            }
            $sth_h->finish;
        }
        my $sth_u = $dbh->prepare(
            "SELECT c.name, COUNT(*) AS cnt FROM USER_CHANNEL uc
              JOIN CHANNEL c ON c.id_channel = uc.id_channel
              GROUP BY uc.id_channel"
        );
        if ($sth_u && $sth_u->execute()) {
            while (my $r = $sth_u->fetchrow_hashref) {
                $db_users{$r->{name}} = $r->{cnt};
            }
            $sth_u->finish;
        }
    }

    $stream->write(sprintf("%-22s %-8s %-5s %-5s %-6s %s\r\n",
        'Channel', 'Status', 'IRC', 'DB', 'Hailo', 'Owner'));
    $stream->write("-" x 70 . "\r\n");

    for my $name (@names) {
        my $chan_obj   = $chans->{$name} or next;
        my $id_channel = eval { $chan_obj->get_id } // 0;

        my @nicks      = eval { $bot->gethChannelsNicksOnChan($name) };
        my $joined     = (grep { lc($_) eq lc($bot_nick) } @nicks) ? 'joined' : 'parted';
        my $nick_count = scalar @nicks;
        my $owner      = $owners{$id_channel} // 'none';
        my $hailo      = exists $hailo_flags{$name} ? ($hailo_flags{$name} ? 'on' : 'off') : '-';
        my $db_cnt     = $db_users{$name} // 0;

        $stream->write(sprintf("%-22s %-8s %-5d %-5d %-6s %s\r\n",
            $name, $joined, $nick_count, $db_cnt, $hailo, $owner));
    }
}


# ---------------------------------------------------------------------------
# .bcast <message>  - broadcast a message to all joined channels (Master+)
# ---------------------------------------------------------------------------
sub _cmd_bcast {
    my ($self, $stream, $id, $msg) = @_;

    my $bot      = $self->{bot};
    my $session  = $self->{users}{$id} // {};  # B1/fix: auth data in users{}, not sessions{}
    my $level    = $session->{level} // 99;

    unless (defined $level && $level <= 1) {  # Owner=0, Master=1 (inverted scale)
        $stream->write("Permission denied (Master+ required).\r\n");
        return;
    }

    unless (defined $msg && $msg =~ /\S/) {
        $stream->write("Usage: .bcast <message>\r\n");
        return;
    }

    my $bot_nick = eval { $bot->{irc}->nick_folded } // '';
    my $chans    = $bot->{channels} || {};
    my $sent     = 0;

    for my $name (sort keys %$chans) {
        my @nicks = eval { $bot->gethChannelsNicksOnChan($name) };
        next unless grep { lc($_) eq lc($bot_nick) } @nicks;
        Mediabot::Helpers::botPrivmsg($bot, $name, "[broadcast] $msg");
        $sent++;
    }

    $stream->write("Broadcast sent to $sent channel(s).\r\n");
    $bot->{logger}->log(2, "Partyline: bcast from $session->{login}: $msg");
}


# ---------------------------------------------------------------------------
# .who <nick>  - show which joined channels a nick is present on
# ---------------------------------------------------------------------------
sub _cmd_whochan {
    my ($self, $stream, $id, $target) = @_;

    my $bot      = $self->{bot};
    my $bot_nick = eval { $bot->{irc}->nick_folded } // '';

    unless (defined $target && $target =~ /\S/) {
        $stream->write("Usage: .who <nick>\r\n");
        return;
    }

    my $chans   = $bot->{channels} || {};
    my @found;

    for my $name (sort keys %$chans) {
        my @nicks = eval { $bot->gethChannelsNicksOnChan($name) };
        next unless grep { lc($_) eq lc($bot_nick) } @nicks;  # only joined
        if (grep { lc($_) eq lc($target) } @nicks) {
            push @found, $name;
        }
    }

    if (@found) {
        $stream->write("$target is on: " . join(', ', @found) . "\r\n");
    } else {
        $stream->write("$target not found on any joined channel.\r\n");
    }
}


# ---------------------------------------------------------------------------
# .top [#chan] [n]  - top n nicks on a channel (default current/first, 5)
# ---------------------------------------------------------------------------
sub _cmd_top {
    # CC6: .top [n] — top per channel; .top all [n] — all channels combined
    my ($self, $stream, $id, $args) = @_;

    my $bot = $self->{bot};
    my $dbh = eval { $bot->{db}->ensure_connected } // $bot->{dbh};
    return unless $dbh;

    my $all_chans = (defined $args && $args =~ /\ball\b/i);
    my ($chan, $n);
    if ($all_chans) {
        $n = ($args =~ /(\d+)/)[0] // 5;
    } elsif ($args =~ /(#\S+)/i) {
        $chan = $1;
        $n    = ($args =~ /(\d+)/)[0] // 5;
    } else {
        my @chans = sort keys %{ $bot->{channels} || {} };
        $chan = $chans[0];
        $n    = ($args =~ /(\d+)/)[0] // 5;
    }
    $n = 5 if !$n || $n < 1; $n = 15 if $n > 15;

    my ($sth, $label);
    if ($all_chans) {
        # CC6: aggregate across all channels
        $sth = $dbh->prepare(
            "SELECT cl.nick, COUNT(*) AS cnt FROM CHANNEL_LOG cl"
            . " GROUP BY cl.nick ORDER BY cnt DESC LIMIT ?"
        );
        unless ($sth && $sth->execute($n)) {
            $stream->write("DB error.\r\n"); return;
        }
        $label = "Top $n speakers (all channels)";
    } else {
        $sth = $dbh->prepare(
            "SELECT cl.nick, COUNT(*) AS cnt FROM CHANNEL_LOG cl"
            . " JOIN CHANNEL c ON c.id_channel = cl.id_channel"
            . " WHERE c.name = ? GROUP BY cl.nick ORDER BY cnt DESC LIMIT ?"
        );
        unless ($sth && $sth->execute($chan, $n)) {
            $stream->write("DB error.\r\n"); return;
        }
        $label = "Top $n on $chan";
    }
    $stream->write("$label:\r\n");
    my $rank = 1;
    while (my $row = $sth->fetchrow_hashref) {
        $stream->write(sprintf("  %2d. %-20s %d msgs\r\n",
            $rank++, $row->{nick}, $row->{cnt}));
    }
    $sth->finish;
}

# ---------------------------------------------------------------------------
# .remind <nick> <message>  - set a reminder from the Partyline
# ---------------------------------------------------------------------------
sub _cmd_remind {
    my ($self, $stream, $id, $args) = @_;

    my $bot = $self->{bot};
    my $dbh = eval { $bot->{db}->ensure_connected } // $bot->{dbh};

    my ($target, $message) = ($args =~ /^(\S+)\s+(.+)$/);
    unless ($target && $message) {
        $stream->write("Usage: .remind <nick> <message>\r\n"); return;
    }

    my $session  = $self->{users}{$id} // {};
    my $from     = $session->{login} // '?';

    # Use first joined channel
    my $bot_nick = eval { $bot->{irc}->nick_folded } // '';
    my $chans    = $bot->{channels} || {};
    my ($chan_name, $id_channel);
    for my $name (sort keys %$chans) {
        my @nicks = eval { $bot->gethChannelsNicksOnChan($name) };
        if (grep { lc($_) eq lc($bot_nick) } @nicks) {
            $chan_name = $name; last;
        }
    }
    unless ($chan_name) { $stream->write("Bot not joined on any channel.\r\n"); return; }

    unless ($dbh) { $stream->write("DB unavailable.\r\n"); return; }
    my $sth_c = $dbh->prepare('SELECT id_channel FROM CHANNEL WHERE name = ?');
    if ($sth_c && $sth_c->execute($chan_name)) {
        my $r = $sth_c->fetchrow_hashref; $sth_c->finish;
        $id_channel = $r ? $r->{id_channel} : undef;
    }
    unless ($id_channel) { $stream->write("Channel not found in DB.\r\n"); return; }

    my $sth = $dbh->prepare(q{
        INSERT INTO REMINDERS (id_channel, from_nick, to_nick, message) VALUES (?,?,?,?)
    });
    if ($sth && $sth->execute($id_channel, $from, lc($target), $message)) {
        $sth->finish;
        $stream->write("Reminder set for $target on $chan_name.\r\n");
    } else {
        $stream->write("DB error.\r\n");
    }
}


# ---------------------------------------------------------------------------
# .seen <nick>  - last seen event for a nick
# ---------------------------------------------------------------------------
sub _cmd_seen {
    my ($self, $stream, $id, $target) = @_;

    my $bot = $self->{bot};
    my $dbh = eval { $bot->{db}->ensure_connected } // $bot->{dbh};

    unless (defined $target && $target =~ /\S/) {
        $stream->write("Usage: .seen <nick>\r\n"); return;
    }

    my $sth = $dbh->prepare(q{
        SELECT nick, channel, event_type, seen_at, last_msg
        FROM USER_SEEN WHERE nick = ? ORDER BY seen_at DESC LIMIT 1
    });
    unless ($sth && $sth->execute($target)) {
        $stream->write("DB error.\r\n"); return;
    }
    my $row = $sth->fetchrow_hashref; $sth->finish;
    unless ($row) {
        $stream->write("$target: not found in seen log.\r\n"); return;
    }
    my $msg = $row->{last_msg} ? " saying: \"$row->{last_msg}\"" : '';
    $stream->write("$target last seen $row->{seen_at} on $row->{channel}"
        . " ($row->{event_type})$msg\r\n");
}

# ---------------------------------------------------------------------------
# .purgereminders  - clean up delivered/cancelled reminders older than 7 days
# ---------------------------------------------------------------------------
sub _cmd_purgereminders {
    my ($self, $stream, $id) = @_;

    my $bot = $self->{bot};
    my $dbh = eval { $bot->{db}->ensure_connected } // $bot->{dbh};

    my $sth = $dbh->prepare(q{
        DELETE FROM REMINDERS
        WHERE delivered > 0
          AND created_at < DATE_SUB(NOW(), INTERVAL 7 DAY)
    });
    unless ($sth && $sth->execute()) {
        $stream->write("DB error.\r\n"); return;
    }
    my $rows = $sth->rows; $sth->finish;
    $stream->write("Purged $rows reminder(s) older than 7 days.\r\n");
}


# ---------------------------------------------------------------------------
# .karma <nick> [#chan]  - show karma from partyline
# ---------------------------------------------------------------------------
sub _cmd_karma {
    my ($self, $stream, $id, $args) = @_;
    my $bot = $self->{bot};
    my $dbh = eval { $bot->{db}->ensure_connected } // $bot->{dbh};
    return unless $dbh;
    my ($target, $chan) = split /\s+/, ($args // ''), 2;
    unless ($target) { $stream->write("Usage: .karma <nick> [#channel]\r\n"); return; }
    unless ($chan) {
        # Use first joined channel
        my $bot_nick = eval { $bot->{irc}->nick_folded } // '';
        for my $name (sort keys %{ $bot->{channels} || {} }) {
            my @n = eval { $bot->gethChannelsNicksOnChan($name) };
            if (grep { lc($_) eq lc($bot_nick) } @n) { $chan = $name; last; }
        }
    }
    unless ($chan) { $stream->write("No channel found.\r\n"); return; }
    my $sth_c = $dbh->prepare('SELECT id_channel FROM CHANNEL WHERE name = ?');
    my $id_channel;
    if ($sth_c && $sth_c->execute($chan)) {
        my $r = $sth_c->fetchrow_hashref; $sth_c->finish;
        $id_channel = $r->{id_channel} if $r;
    }
    unless ($id_channel) { $stream->write("Channel $chan not found.\r\n"); return; }
    my $sth = $dbh->prepare('SELECT score FROM KARMA WHERE id_channel = ? AND nick = ?');
    unless ($sth && $sth->execute($id_channel, lc($target))) {
        $stream->write("DB error.\r\n"); return;
    }
    my $row   = $sth->fetchrow_hashref; $sth->finish;
    my $score = $row ? $row->{score} : 0;
    my $sign  = $score > 0 ? '+' : '';
    $stream->write("$target on $chan: karma ${sign}${score}\r\n");
}

# ---------------------------------------------------------------------------
# .reload  - reload bot configuration (calls mbRehash_ctx equivalent)
# ---------------------------------------------------------------------------
sub _cmd_reload {
    my ($self, $stream, $id) = @_;
    my $session = $self->{users}{$id} // {};
    unless (($session->{level} // 99) <= 0) {  # Owner only
        $stream->write("Permission denied (Owner required).\r\n"); return;
    }
    my $bot = $self->{bot};
    my $ok  = eval {
        $bot->{conf}->load();
        $bot->{logger}->log(2, "Partyline: config reloaded by $session->{login}");
        1;
    };
    if ($ok) {
        $stream->write("Configuration reloaded.\r\n");
    } else {
        $stream->write("Reload failed: $@\r\n");
    }
}


# ---------------------------------------------------------------------------
# .stats [#chan]  - top 3 msgs + karma top 3 for a channel
# ---------------------------------------------------------------------------
sub _cmd_stats {
    my ($self, $stream, $id, $args) = @_;

    my $bot = $self->{bot};
    my $dbh = eval { $bot->{db}->ensure_connected } // $bot->{dbh};
    return unless $dbh;

    # Determine channel
    my $chan;
    if (defined $args && $args =~ /^(#\S+)/) {
        $chan = $1;
    } else {
        # Default: first joined channel
        my $bot_nick = eval { $bot->{irc}->nick_folded } // '';
        for my $name (sort keys %{ $bot->{channels} || {} }) {
            my @n = eval { $bot->gethChannelsNicksOnChan($name) };
            if (grep { lc($_) eq lc($bot_nick) } @n) { $chan = $name; last; }
        }
    }
    unless ($chan) { $stream->write("No channel. Usage: .stats [#channel]\r\n"); return; }

    $stream->write("Stats for $chan:\r\n");
    $stream->write("-" x 40 . "\r\n");

    # Top 3 messages
    my $sth_top = $dbh->prepare(
        "SELECT cl.nick, COUNT(*) AS cnt FROM CHANNEL_LOG cl"
        . " JOIN CHANNEL c ON c.id_channel = cl.id_channel"
        . " WHERE c.name = ? GROUP BY cl.nick ORDER BY cnt DESC LIMIT 3"
    );
    if ($sth_top && $sth_top->execute($chan)) {
        $stream->write("  Top speakers:\r\n");
        my $rank = 1;
        while (my $r = $sth_top->fetchrow_hashref) {
            $stream->write(sprintf("    %d. %-20s %d msgs\r\n",
                $rank++, $r->{nick}, $r->{cnt}));
        }
        $sth_top->finish;
    }

    # Top 3 karma
    my $sth_chan = $dbh->prepare('SELECT id_channel FROM CHANNEL WHERE name = ?');
    my $id_channel;
    if ($sth_chan && $sth_chan->execute($chan)) {
        my $r = $sth_chan->fetchrow_hashref; $sth_chan->finish;
        $id_channel = $r->{id_channel} if $r;
    }
    if ($id_channel) {
        my $sth_k = $dbh->prepare(q{
            SELECT nick, score FROM KARMA
            WHERE id_channel = ? AND score != 0
            ORDER BY score DESC LIMIT 3
        });
        if ($sth_k && $sth_k->execute($id_channel)) {
            my @krows;
            while (my $r = $sth_k->fetchrow_hashref) { push @krows, $r; }
            $sth_k->finish;
            if (@krows) {
                $stream->write("  Top karma:\r\n");
                for my $r (@krows) {
                    my $sign = $r->{score} > 0 ? '+' : '';
                    $stream->write(sprintf("    %-20s %s%d\r\n",
                        $r->{nick}, $sign, $r->{score}));
                }
            } else {
                $stream->write("  No karma data yet.\r\n");
            }
        }
    }
    $stream->write("-" x 40 . "\r\n");
}


# ---------------------------------------------------------------------------
# .ai <prompt>  - send a prompt to Claude from the Partyline
# ---------------------------------------------------------------------------
sub _cmd_ai {
    my ($self, $stream, $id, $prompt) = @_;

    my $bot = $self->{bot};
    unless (defined $prompt && $prompt =~ /\S/) {
        $stream->write("Usage: .ai <prompt> | .ai reset | .ai history\r\n"); return;
    }

    my $session = $self->{users}{$id} // {};
    my $pl_nick = $session->{login} // 'partyline';

    # A3: resolve channel for shared history key (Partyline nick + fixed scope)
    my $bot_nick = eval { $bot->{irc}->nick_folded } // '';
    my $chan;
    for my $name (sort keys %{ $bot->{channels} || {} }) {
        my @n = eval { $bot->gethChannelsNicksOnChan($name) };
        if (grep { lc($_) eq lc($bot_nick) } @n) { $chan = $name; last; }
    }
    $chan //= 'partyline';

    # A3: .ai reset — clear history for this Partyline session
    if (lc($prompt) eq 'reset') {
        my $hist_key = "$pl_nick\x00$chan";
        delete $bot->{_claude_history}{$hist_key};
        $stream->write("Conversation history cleared.\r\n");
        return;
    }

    # A3: .ai history — show current context
    if (lc($prompt) eq 'history') {
        my $hist_key = "$pl_nick\x00$chan";
        my $history  = $bot->{_claude_history}{$hist_key} // [];
        unless (@$history) {
            $stream->write("No conversation history.\r\n"); return;
        }
        $stream->write(scalar(@$history) . " message(s) in context:\r\n");
        for my $msg (@$history) {
            my $role    = $msg->{role}    // '?';
            my $content = $msg->{content} // '';
            $content = substr($content, 0, 120) . '...' if length($content) > 120;
            $stream->write("  [$role] $content\r\n");
        }
        return;
    }

    # R1: use $output_fn callback — no monkey-patching needed
    my $output_fn = sub {
        my ($text) = @_;
        $text =~ s/[\r\n]+$//;
        $stream->write("[Claude] $text\r\n");
    };

    eval {
        Mediabot::External::claudeAI($bot, undef, $pl_nick, $chan,
            $output_fn, split(/\s+/, $prompt));
    };
    $stream->write("Error: $@\r\n") if $@;
}



# ---------------------------------------------------------------------------
# .karmahist [nick]  — show karma history from Partyline (K5)
# ---------------------------------------------------------------------------
sub _cmd_karmahist {
    my ($self, $stream, $id, $args) = @_;
    my $bot    = $self->{bot};
    my $filter = (defined $args && $args =~ /\S/) ? lc($args) : undef;
    $filter =~ s/^\s+|\s+$//g if $filter;

    # Resolve first active channel
    my $bot_nick = eval { $bot->{irc}->nick_folded } // '';
    my $chan;
    for my $name (sort keys %{ $bot->{channels} || {} }) {
        my @n = eval { $bot->gethChannelsNicksOnChan($name) };
        if (grep { lc($_) eq lc($bot_nick) } @n) { $chan = $name; last; }
    }
    unless ($chan) {
        $stream->write("Not on any channel.\r\n"); return;
    }

    my $klog = $bot->{_karma_log}{$chan} // [];
    unless (@$klog) {
        $stream->write("No karma history for $chan.\r\n"); return;
    }

    my @entries = reverse @$klog;
    if ($filter) {
        @entries = grep { lc($_->{nick}) eq $filter } @entries;
        unless (@entries) {
            $stream->write("No karma history for '$filter' on $chan.\r\n"); return;
        }
    }
    @entries = @entries[0..9] if @entries > 10;  # max 10 in PL

    my $label = $filter ? "Karma history for $filter" : "Recent karma changes";
    $stream->write("$label on $chan:\r\n");
    for my $e (@entries) {
        my $sign = $e->{score} > 0 ? '+' : '';
        my $ago  = Mediabot::UserCommands::_seconds_to_human(time() - $e->{ts});
        $stream->write(sprintf("  %-20s %s (now %s%d) by %-15s %s ago\r\n",
            $e->{nick}, $e->{delta}, $sign, $e->{score}, $e->{from}, $ago));
    }
}

# ---------------------------------------------------------------------------
# _cmd_persona [nick [#chan]]  — view/clear persona from Partyline
# I7: operators can inspect any nick's Claude persona
# ---------------------------------------------------------------------------
sub _cmd_persona {
    my ($self, $stream, $id, $args) = @_;
    my $bot = $self->{bot};
    my $personas = $bot->{_claude_persona} // {};

    # No args — list all active personas
    unless (defined $args && $args =~ /\S/) {
        unless (%$personas) {
            $stream->write("No active personas.\r\n"); return;
        }
        $stream->write("Active Claude personas:\r\n");
        for my $key (sort keys %$personas) {
            my ($nick_k, $chan_k) = split /\x00/, $key, 2;
            my $text = substr($personas->{$key}, 0, 60);
            $stream->write(sprintf("  %-15s %-12s %s...\r\n", $nick_k, $chan_k, $text));
        }
        return;
    }

    # .persona <nick> [#chan] [clear]
    my @parts  = split /\s+/, $args, 3;
    my $target = lc($parts[0]);
    my $chan   = $parts[1] && $parts[1] =~ /^#/ ? $parts[1] : undef;
    my $subcmd = $chan ? ($parts[2] // '') : ($parts[1] // '');

    # Find matching keys
    my @keys = grep {
        my ($n,$c) = split /\x00/, $_, 2;
        lc($n) eq $target && (!$chan || lc($c) eq lc($chan))
    } keys %$personas;

    unless (@keys) {
        $stream->write("No persona found for '$target'" . ($chan ? " on $chan" : '') . ".\r\n");
        return;
    }

    if (lc($subcmd) eq 'clear') {
        delete $personas->{$_} for @keys;
        $stream->write("Persona cleared for $target (" . scalar(@keys) . " entr" . (@keys == 1 ? 'y' : 'ies') . ").\r\n");
    } else {
        $stream->write("Persona(s) for $target:\r\n");
        for my $key (@keys) {
            my ($n, $c) = split /\x00/, $key, 2;
            $stream->write("  [$c] $personas->{$key}\r\n");
        }
    }
}

# ---------------------------------------------------------------------------
# _cmd_quota [nick]  - show Claude rate limit status from Partyline
# ---------------------------------------------------------------------------
sub _cmd_quota {
    my ($self, $stream, $id, $args) = @_;
    my $bot = $self->{bot};
    my $now = time();
    if (!defined $args || $args !~ /\S/) {
        my $rl = $bot->{_claude_ratelimit} // {};
        unless (%$rl) { $stream->write("No active rate limit windows.\r\n"); return; }
        $stream->write("Active Claude rate limit windows:\r\n");
        for my $key (sort keys %$rl) {
            my $entry = $rl->{$key};
            next if ($now - ($entry->{window} // 0)) >= 60;
            my ($nick_k, $chan_k) = split /\x00/, $key, 2;
            my $used = $entry->{count} // 0;
            my $remaining = 5 - $used; $remaining = 0 if $remaining < 0;
            my $wait = 60 - ($now - $entry->{window});
            $stream->write(sprintf("  %-20s %-15s %d/5 req (%ds left)\r\n",
                $nick_k, $chan_k, $used, $wait));
        }
        return;
    }
    my $target = lc($args); $target =~ s/^\s+|\s+\$//g;
    my $rl = $bot->{_claude_ratelimit} // {};
    my @found;
    for my $key (sort keys %$rl) {
        my ($nick_k, $chan_k) = split /\x00/, $key, 2;
        next unless lc($nick_k) eq $target;
        my $entry = $rl->{$key};
        next if ($now - ($entry->{window} // 0)) >= 60;
        my $used = $entry->{count} // 0;
        my $remaining = 5 - $used; $remaining = 0 if $remaining < 0;
        my $wait = 60 - ($now - $entry->{window});
        push @found, sprintf("  %-15s %d/5 req — %d remaining (%ds left)",
            $chan_k, $used, $remaining, $wait);
    }
    if (@found) {
        $stream->write("Claude quota for $target:\r\n");
        $stream->write("$_\r\n") for @found;
    } else {
        $stream->write("No active rate limit for '$target'.\r\n");
    }
}

sub _cmd_ping {
    my ($self, $stream, $id) = @_;
    my ($sec, $min, $hour) = localtime(time);
    $stream->write(sprintf("PONG %02d:%02d:%02d\r\n", $hour, $min, $sec));
}

# ---------------------------------------------------------------------------
# .uptime - show bot and server uptime from the Partyline
# ---------------------------------------------------------------------------
sub _cmd_uptime {
    my ($self, $stream, $id) = @_;

    my $bot = $self->{bot};
    my $now = time();

    my $bot_start = $bot->{iConnectionTimestamp}
                 // eval { $bot->{metrics}->{started} }
                 // $now;

    my $bot_uptime = $now - $bot_start;
    $bot_uptime = 0 if $bot_uptime < 0;

    my $server_uptime = undef;
    if (open my $fh, '<', '/proc/uptime') {
        my $line = <$fh>;
        close $fh;

        if (defined $line && $line =~ /^(\d+(?:\.\d+)?)/) {
            $server_uptime = int($1);
        }
    }

    my $bot_name = eval { $bot->{conf}->get('main.MAIN_PROG_NAME') } || 'Mediabot';
    my $version  = $bot->{main_prog_version} // '';

    $stream->write("Uptime:\r\n");
    $stream->write("  Bot     : " . $self->_format_duration($bot_uptime) . "\r\n");
    $stream->write("  Process : pid $$\r\n");
    $stream->write("  Name    : $bot_name" . ($version ne '' ? " v$version" : "") . "\r\n");

    if (defined $server_uptime) {
        $stream->write("  Server  : " . $self->_format_duration($server_uptime) . "\r\n");
    }
    else {
        $stream->write("  Server  : unavailable\r\n");
    }

    # J1: Claude stats in .uptime output
    my $claude_reqs   = eval { $bot->{metrics}->get('mediabot_claude_requests_total') } // 0;
    my $claude_errs   = eval { $bot->{metrics}->get('mediabot_claude_errors_total') } // 0;
    my $claude_rl     = eval { $bot->{metrics}->get('mediabot_claude_ratelimit_total') } // 0;
    my $persona_count = scalar keys %{ $bot->{_claude_persona} // {} };
    my $hist_count    = scalar keys %{ $bot->{_claude_history}  // {} };
    $stream->write("Claude AI:\r\n");
    $stream->write("  Requests : $claude_reqs (errors: $claude_errs, ratelimited: $claude_rl)\r\n");
    $stream->write("  Personas : $persona_count active\r\n");
    $stream->write("  History  : $hist_count active session(s)\r\n");
}


# ---------------------------------------------------------------------------
# .bans [#chan] - list active bans (from ChannelBan) on a channel
# ---------------------------------------------------------------------------
sub _cmd_bans {
    my ($self, $stream, $id, $chan) = @_;

    my $bot = $self->{bot};

    unless ($bot->{channel_ban} && $bot->{channel_ban}->can('list_active_bans')) {
        $stream->write("ChannelBan module not available.\r\n");
        return;
    }

    unless (defined $chan && $chan =~ /^#/) {
        $stream->write("Usage: .bans #channel\r\n");
        return;
    }

    # Resolve id_channel
    my $dbh = $bot->{dbh};
    my $sth = $dbh->prepare("SELECT id_channel FROM CHANNEL WHERE name = ? LIMIT 1");
    unless ($sth && $sth->execute($chan)) {
        $stream->write("DB error.\r\n");
        return;
    }
    my $row = $sth->fetchrow_hashref;
    $sth->finish;

    unless ($row) {
        $stream->write("Channel $chan not found in DB.\r\n");
        return;
    }

    my $id_channel = $row->{id_channel};
    # A2: fetch up to 11 to detect overflow without loading all bans
    my @bans = $bot->{channel_ban}->list_active_bans($id_channel, 11);

    unless (@bans) {
        $stream->write("No active bans on $chan.\r\n");
        return;
    }

    my $has_more  = scalar(@bans) > 10;
    @bans = @bans[0..9] if $has_more;  # trim to 10
    my $total_bans = scalar @bans + ($has_more ? 1 : 0);  # approximate
    my $shown_bans = scalar @bans;
    $stream->write(sprintf("%d active ban(s) on $chan (showing %d):\r\n", $total_bans, $shown_bans));
    $stream->write(sprintf("  %-4s %-30s %-8s %-16s %s\r\n",
        "#", "Mask", "Level", "By", "Expires"));
    $stream->write("  " . ("-" x 76) . "\r\n");

    my $now_sth = $dbh->prepare('SELECT TIMESTAMPDIFF(SECOND, NOW(), ?) AS secs');

    for my $ban (@bans) {
        my $expires_txt = 'permanent';
        if ($ban->{expires_at}) {
            $now_sth->execute($ban->{expires_at});
            my $r = $now_sth->fetchrow_hashref;
            $now_sth->finish;
            my $secs = ($r && defined $r->{secs} && $r->{secs} > 0) ? $r->{secs} : 0;
            if ($secs > 0) {
                my $d = int($secs / 86400);
                my $h = int(($secs % 86400) / 3600);
                my $m = int(($secs % 3600) / 60);
                $expires_txt = '';
                $expires_txt .= "${d}d " if $d;
                $expires_txt .= "${h}h " if $h;
                $expires_txt .= "${m}m"  if $m || (!$d && !$h);
                $expires_txt =~ s/\s+$//;
            } else {
                $expires_txt = 'expiring soon';
            }
        }

        $stream->write(sprintf("  %-4s %-30s %-8s %-16s %s\r\n",
            $ban->{id_channel_ban} // '?',
            $ban->{mask}           // '?',
            $ban->{ban_level}      // '?',
            $ban->{created_by_nick} // '?',
            $expires_txt
        ));
    }
}



# ---------------------------------------------------------------------------
# .ban #chan <nick> [duration] [reason]
#
# Bans a connected nick from a channel via Partyline.
# Sends a WHOIS to the IRC server to get the real hostmask, then the
# partylineBan callback in on_message_RPL_WHOISUSER performs the actual ban.
# Duration formats: 10m 2h 3d 1w perm/permanent (default: permanent)
# ---------------------------------------------------------------------------
sub _cmd_ban {
    my ($self, $stream, $id, $chan, $nick_target, @rest) = @_;

    my $bot    = $self->{bot};
    my $actor  = $self->{users}{$id}{login} // 'unknown';

    unless ($bot->{irc} && $bot->{irc}->is_connected) {
        $stream->write("Bot is not connected to IRC.\r\n");
        return;
    }

    unless ($bot->{channel_ban}) {
        $stream->write("ChannelBan module not available.\r\n");
        return;
    }

    unless (defined $chan && $chan =~ /^#/ && defined $nick_target && $nick_target ne '') {
        $stream->write("Usage: .ban #channel <nick> [duration] [reason]\r\n");
        $stream->write("Durations: 10m 2h 3d 1w perm (default: permanent)\r\n");
        return;
    }

    # Parse optional duration (first word of @rest if it looks like a duration)
    my ($duration_secs, $dur_label, $reason);
    if (@rest && $bot->{channel_ban}->looks_like_duration($rest[0])) {
        my $dur_str = shift @rest;
        my ($secs, $label, $err) = $bot->{channel_ban}->parse_duration($dur_str);
        if ($err) {
            $stream->write("Invalid duration: $err\r\n");
            return;
        }
        ($duration_secs, $dur_label) = ($secs, $label);
    } else {
        ($duration_secs, $dur_label) = (0, 'permanent');
    }
    $reason = join(' ', @rest) // '';

    # Store context for the async WHOIS callback
    # Guard against concurrent .ban calls overwriting WHOIS_VARS.
    # Store a unique token; the callback checks it matches before proceeding.
    my $ban_token = "partylineBan:${id}:" . time() . ":" . int(rand(1_000_000));

    # Keep the expected token on the Partyline session too.
    # The async WHOIS callback must compare both sides before applying the ban.
    $self->{users}{$id}{pending_whois_token} = $ban_token;
    $self->{users}{$id}{pending_whois_sub}   = 'partylineBan';

    %{ $bot->{WHOIS_VARS} } = (
        nick      => $nick_target,
        sub       => 'partylineBan',
        token     => $ban_token,
        caller    => $id,           # fd of the Partyline session
        channel   => $chan,
        duration  => $duration_secs,
        dur_label => $dur_label,
        reason    => $reason,
        actor     => $actor,
        ts        => time,
    );

    $bot->{irc}->send_message('WHOIS', undef, $nick_target);
    $bot->{logger}->log(2, "Partyline: $actor requested ban on $nick_target in $chan");
    $stream->write("WHOIS sent for $nick_target, ban will be applied on reply...\r\n");
    delete $self->{_stat_cache};   # B5/A5: invalidate .stat cache on ban
}

# ---------------------------------------------------------------------------
# .unban #chan <mask|ban_id>  - remove an active ban (Master+)
# ---------------------------------------------------------------------------
sub _cmd_unban {
    my ($self, $stream, $id, $chan, $target) = @_;

    my $bot  = $self->{bot};
    my $nick = $self->{users}{$id}{login} // 'unknown';

    unless ($bot->{channel_ban} && $bot->{channel_ban}->can('mark_removed')) {
        $stream->write("ChannelBan module not available.\r\n");
        return;
    }

    unless (defined $chan && $chan =~ /^#/ && defined $target && $target ne '') {
        $stream->write("Usage: .unban #channel <mask|ban_id>\r\n");
        return;
    }

    my $dbh = $bot->{dbh};
    my $sth = $dbh->prepare("SELECT id_channel FROM CHANNEL WHERE name = ? LIMIT 1");
    unless ($sth && $sth->execute($chan)) {
        $stream->write("DB error.\r\n");
        return;
    }
    my $row = $sth->fetchrow_hashref;
    $sth->finish;

    unless ($row) {
        $stream->write("Channel $chan not found in DB.\r\n");
        return;
    }

    my $id_channel = $row->{id_channel};
    my $level = $self->{users}{$id}{level};

    # Resolve ban: by numeric id or by mask
    my ($rows, $err, $mask_used);
    if ($target =~ /^\d+$/) {
        ($rows, $err) = $bot->{channel_ban}->mark_removed(
            id_channel_ban => $target,
            removed_by_nick => $nick,
        );
        $mask_used = "ban #$target";
    } else {
        ($rows, $err) = $bot->{channel_ban}->mark_removed(
            id_channel => $id_channel,
            mask       => $target,
            removed_by_nick => $nick,
        );
        $mask_used = $target;
    }

    if ($err) {
        $stream->write("Unban failed: $err\r\n");
        return;
    }

    if (!$rows) {
        $stream->write("No active ban found matching '$target' on $chan.\r\n");
        return;
    }

    # Send MODE -b to IRC
    eval {
        $bot->{irc}->send_message('MODE', undef, $chan, '-b', $target)
            if $target !~ /^\d+$/;
    };

    $bot->{logger}->log(2, "Partyline: $nick unbanned '$mask_used' on $chan");
    $stream->write("Unbanned '$mask_used' on $chan.\r\n");
    delete $self->{_stat_cache};   # invalidate .stat cache
}

# ---------------------------------------------------------------------------
# .topic #chan [new topic]  - show or change channel topic (Master+)
# ---------------------------------------------------------------------------
sub _cmd_topic {
    my ($self, $stream, $id, $chan, $topic) = @_;

    my $bot  = $self->{bot};
    my $nick = $self->{users}{$id}{login} // 'unknown';

    unless ($bot->{irc} && $bot->{irc}->is_connected) {
        $stream->write("Bot is not connected to IRC.\r\n");
        return;
    }

    unless (defined $chan && $chan =~ /^#/) {
        $stream->write("Usage: .topic #channel [new topic]\r\n");
        return;
    }

    if (defined $topic && $topic ne '') {
        # Set new topic
        $bot->{irc}->send_message('TOPIC', undef, $chan, $topic);
        $bot->{logger}->log(2, "Partyline: $nick set topic on $chan: $topic");
        $stream->write("Topic set on $chan.\r\n");
    } else {
        # Request current topic via TOPIC (server will reply with 332)
        $bot->{irc}->send_message('TOPIC', undef, $chan);
        $stream->write("Topic request sent for $chan (check .console for server reply).\r\n");
    }
}

# ---------------------------------------------------------------------------
# .history  - show last 10 commands in this session
# ---------------------------------------------------------------------------
sub _cmd_history {
    my ($self, $stream, $id) = @_;

    my $hist = $self->{users}{$id}{history} // [];
    unless (@$hist) {
        $stream->write("No command history for this session.\r\n");
        return;
    }

    $stream->write("Recent commands:\r\n");
    my $i = 1;
    for my $cmd (@$hist) {
        $stream->write(sprintf("  %2d  %s\r\n", $i++, $cmd));
    }
}

# .stat - for each known channel: joined?, nick count, owner, chansets
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# .dccstat - display DCC Partyline state
# ---------------------------------------------------------------------------
sub _cmd_dccstat {
    my ($self, $stream, $id) = @_;

    my $bot = $self->{bot};

    my $public_ip = eval { $self->_resolve_dcc_public_ip($bot) } || '(not configured)';

    # Use shared helpers to avoid duplicating config key lookup logic.
    my $dcc_port  = eval { $self->_dcc_listen_port($bot) } // 0;
    my $port_mode = $dcc_port > 0
        ? "configured port $dcc_port (from DCC_PORT_MIN/MAX range)"
        : 'OS ephemeral port';

    my $offers = eval { $self->_dcc_offers_snapshot } || [];

    my @dcc_sessions;
    my @telnet_sessions;

    for my $fid (sort { $a <=> $b } keys %{ $self->{users} || {} }) {
        my $u = $self->{users}{$fid} || next;
        next unless $u->{authenticated};

        my $entry = {
            fd         => $fid,
            login      => $u->{login}      || '?',
            level_desc => $u->{level_desc} || '?',
            peer_host  => $u->{peer_host}  || 'unknown',
            peer_ip    => $u->{peer_ip}    || '',
            console    => defined $u->{console_level} ? $u->{console_level} : 'off',
        };

        if ($u->{is_dcc}) {
            push @dcc_sessions, $entry;
        }
        else {
            push @telnet_sessions, $entry;
        }
    }

    $stream->write("DCC Partyline status:\r\n");
    $stream->write("  Public IP      : $public_ip\r\n");
    $stream->write("  Port mode      : $port_mode\r\n");
    $stream->write("  Pending offers : " . scalar(@$offers) . "\r\n");
    $stream->write("  DCC sessions   : " . scalar(@dcc_sessions) . "\r\n");
    $stream->write("  Telnet sessions: " . scalar(@telnet_sessions) . "\r\n");
    $stream->write("\r\n");

    if (@$offers) {
        $stream->write("Pending DCC offers:\r\n");
        $stream->write(sprintf("  %-12s %-14s %-16s %-8s %-6s\r\n",
            "Type", "Nick", "Public IP", "Port", "Age"));
        $stream->write("  " . ("-" x 64) . "\r\n");

        my $now = time;
        for my $o (@$offers) {
            my $age = $now - ($o->{created_at} || $now);
            $stream->write(sprintf("  %-12s %-14s %-16s %-8s %ss\r\n",
                $o->{type}      || '?',
                $o->{nick}      || '?',
                $o->{public_ip} || '?',
                $o->{port}      || '?',
                $age
            ));
        }

        $stream->write("\r\n");
    }
    else {
        $stream->write("No pending DCC offers.\r\n\r\n");
    }

    if (@dcc_sessions) {
        $stream->write("Active DCC sessions:\r\n");
        $stream->write(sprintf("  %-14s %-14s %-6s %-20s %-10s\r\n",
            "Nick", "Level", "FD", "Peer", "Console"));
        $stream->write("  " . ("-" x 76) . "\r\n");

        for my $u (@dcc_sessions) {
            $stream->write(sprintf("  %-14s %-14s fd=%-3s %-20s console:%s\r\n",
                $u->{login},
                $u->{level_desc},
                $u->{fd},
                $u->{peer_host},
                $u->{console}
            ));
        }

        $stream->write("\r\n");
    }
    else {
        $stream->write("No active DCC sessions.\r\n\r\n");
    }

    if (@telnet_sessions) {
        $stream->write("Active telnet sessions:\r\n");
        $stream->write(sprintf("  %-14s %-14s %-6s %-20s %-10s\r\n",
            "Nick", "Level", "FD", "Peer", "Console"));
        $stream->write("  " . ("-" x 76) . "\r\n");

        for my $u (@telnet_sessions) {
            $stream->write(sprintf("  %-14s %-14s fd=%-3s %-20s console:%s\r\n",
                $u->{login},
                $u->{level_desc},
                $u->{fd},
                $u->{peer_host},
                $u->{console}
            ));
        }

        $stream->write("\r\n");
    }
}

sub _cmd_stat {
    my ($self, $stream, $id) = @_;

    my $bot = $self->{bot};
    my $irc = $bot->{irc};
    my $dbh = $bot->{dbh};

    unless ($irc && $irc->is_connected) {
        $stream->write("Bot is not connected to IRC.\r\n");
        return;
    }

    my $bot_nick = $irc->nick_folded // '';

    # Header
    $stream->write(sprintf("%-30s %-12s %-5s %-20s %s\r\n",
        "Channel", "Status", "Nicks", "Owner", "Chansets"));
    $stream->write(("-" x 90) . "\r\n");

    my $channels = $bot->{channels};
    unless ($channels && ref($channels) eq 'HASH' && %$channels) {
        $stream->write("No channels known (bot not yet joined any channel).\r\n");
        return;
    }

    # Batch-fetch owners and chansets in two queries instead of N×2.
    # Results cached for 60 seconds to avoid hammering the DB on repeated .stat.
    my $stat_cache_key = '_stat_cache';
    my $stat_cache     = $self->{$stat_cache_key};
    my %owners;
    my %chansets;

    if (!$stat_cache || (time() - ($stat_cache->{at} // 0)) > 60) {
        # Owners: one query for all channels
        my $sth_o = $dbh->prepare(
            "SELECT uc.id_channel, u.nickname FROM USER u
              JOIN USER_CHANNEL uc ON uc.id_user = u.id_user
              WHERE uc.level = 500"
        );
        if ($sth_o && $sth_o->execute()) {
            while (my $r = $sth_o->fetchrow_hashref) {
                $owners{ $r->{id_channel} } //= $r->{nickname};
            }
            $sth_o->finish;
        }

        # Chansets: one query for all channels
        my $sth_c = $dbh->prepare(
            "SELECT cs.id_channel, cl.chanset FROM CHANSET_LIST cl
              JOIN CHANNEL_SET cs ON cs.id_chanset_list = cl.id_chanset_list
              ORDER BY cs.id_channel, cl.chanset"
        );
        if ($sth_c && $sth_c->execute()) {
            while (my $r = $sth_c->fetchrow_hashref) {
                $chansets{ $r->{id_channel} } //= '';
                $chansets{ $r->{id_channel} } .= '+' . $r->{chanset} . ' ';
            }
            $sth_c->finish;
        }

        $self->{$stat_cache_key} = { at => time(), owners => \%owners, chansets => \%chansets };
    } else {
        %owners   = %{ $stat_cache->{owners}   // {} };
        %chansets = %{ $stat_cache->{chansets} // {} };
    }

    foreach my $chan_name (sort keys %$channels) {
        my $chan_obj   = $bot->{channels}{$chan_name};
        my $id_channel = eval { $chan_obj->get_id } // 0;

        my @nicks      = $bot->gethChannelsNicksOnChan($chan_name);
        my $joined     = grep { lc($_) eq lc($bot_nick) } @nicks;
        my $nick_count = scalar @nicks;
        my $status     = $joined ? "joined" : "NOT joined";

        my $owner    = $owners{$id_channel}   // 'none';
        my $chanset_str = $chansets{$id_channel} // 'none';
        $chanset_str =~ s/\s+$//;

        $stream->write(sprintf("%-30s %-12s %-5d %-20s %s\r\n",
            $chan_name, $status, $nick_count, $owner, $chanset_str));
    }
}

# ---------------------------------------------------------------------------
# .say <#chan|nick> <message>
# Supports both channels (#chan) and private messages (nick).
# ---------------------------------------------------------------------------
sub _cmd_say {
    my ($self, $stream, $id, $target, $msg) = @_;

    my $bot  = $self->{bot};
    my $nick = $self->{users}{$id}{login};

    unless ($bot->{irc} && $bot->{irc}->is_connected) {
        $stream->write("Bot is not connected to IRC.\r\n");
        return;
    }

    if ($target =~ /^#/) {
        # Channel message — verify bot presence (warn only, still send)
        my $target_lc = lc($target);
        unless (exists $bot->{channels}{$target} || exists $bot->{channels}{$target_lc}) {
            $stream->write("Warning: bot does not appear to be in $target (sending anyway).\r\n");
        }
    }
    # No check needed for private messages — just send

    $bot->botPrivmsg($target, $msg);
    $bot->{logger}->log(2, "Partyline: $nick sent to $target: $msg");
    $stream->write("-> $target: $msg\r\n");
}

# ---------------------------------------------------------------------------
# .who #chan - list nicks in a channel
# ---------------------------------------------------------------------------
sub _cmd_who {
    my ($self, $stream, $id, $chan) = @_;

    my $bot = $self->{bot};

    my @nicks = $bot->gethChannelsNicksOnChan($chan);
    unless (@nicks) {
        $stream->write("No nicks known for $chan (not joined or channel is empty).\r\n");
        return;
    }

    $stream->write(scalar(@nicks) . " nick(s) in $chan:\r\n");
    $stream->write(join(', ', sort @nicks) . "\r\n");
}

# ---------------------------------------------------------------------------
# .join #chan [key]
# ---------------------------------------------------------------------------
sub _cmd_join {
    my ($self, $stream, $id, $chan, $key) = @_;

    my $bot  = $self->{bot};
    my $nick = $self->{users}{$id}{login};

    unless ($bot->{irc} && $bot->{irc}->is_connected) {
        $stream->write("Bot is not connected to IRC.\r\n");
        return;
    }

        $bot->joinChannel($chan, $key);

    if ($bot->can('refresh_channel_nicklist')) {
        eval { $bot->refresh_channel_nicklist($chan) };
    }

    $bot->{logger}->log(2, "Partyline: $nick requested JOIN $chan" . ($key ? " (key: $key)" : ""));
    $stream->write("Joining $chan" . ($key ? " with key $key" : "") . "...\r\n");
}

# ---------------------------------------------------------------------------
# .part #chan
# ---------------------------------------------------------------------------
sub _cmd_part {
    my ($self, $stream, $id, $chan) = @_;

    my $bot  = $self->{bot};
    my $nick = $self->{users}{$id}{login};

    unless ($bot->{irc} && $bot->{irc}->is_connected) {
        $stream->write("Bot is not connected to IRC.\r\n");
        return;
    }

    $bot->partChannel($chan, "Partyline requested part");

    if ($bot->can('stop_channel_nicklist_timer')) {
        $bot->stop_channel_nicklist_timer($chan);
    }

    $bot->sethChannelsNicksOnChan($chan, ());
    $bot->{logger}->log(2, "Partyline: $nick requested PART $chan");
    $stream->write("Parting $chan...\r\n");
}

# ---------------------------------------------------------------------------
# .nick <newnick>  - Master level required (already enforced by login,
#                    but validated explicitly here for clarity)
# ---------------------------------------------------------------------------
sub _cmd_nick {
    my ($self, $stream, $id, $newnick) = @_;

    my $bot  = $self->{bot};
    my $nick = $self->{users}{$id}{login};

    unless ($bot->{irc} && $bot->{irc}->is_connected) {
        $stream->write("Bot is not connected to IRC.\r\n");
        return;
    }

    # Validate nick: IRC nicks must not contain spaces or control chars
    unless ($newnick =~ /^[A-Za-z\[\]\\\`_\^\{\|\}][A-Za-z0-9\[\]\\\`_\-\^\{\|\}]{0,14}$/) {
        $stream->write("Invalid nick format.\r\n");
        return;
    }

    $bot->{irc}->change_nick($newnick);
    $bot->{logger}->log(2, "Partyline: $nick changed bot nick to $newnick");
    $stream->write("Nick change requested: $newnick\r\n");
}

# ---------------------------------------------------------------------------
# .raw <IRC command>  - Owner only
# ---------------------------------------------------------------------------
sub _cmd_raw {
    my ($self, $stream, $id, $raw) = @_;

    my $bot  = $self->{bot};
    my $nick = $self->{users}{$id}{login};

    unless ($bot->{irc} && $bot->{irc}->is_connected) {
        $stream->write("Bot is not connected to IRC.\r\n");
        return;
    }

    unless (defined($self->{users}{$id}{level}) && $self->{users}{$id}{level} == 0) {
        $stream->write("Access denied: .raw requires Owner level.\r\n");
        return;
    }

    $raw =~ s/[\r\n]//g;    # strip embedded CR/LF to prevent IRC command injection
    $bot->{irc}->write($raw . "\x0d\x0a");
    $bot->{logger}->log(2, "Partyline: $nick sent RAW: $raw");
    $stream->write("RAW -> $raw\r\n");
}

# ---------------------------------------------------------------------------
# .rehash
# ---------------------------------------------------------------------------
sub _cmd_rehash {
    my ($self, $stream, $id) = @_;

    my $bot   = $self->{bot};
    my $nick  = $self->{users}{$id}{login};
    my $level = $self->{users}{$id}{level};

    unless (defined($level) && $level <= 1) {   # Owner=0, Master=1
        $stream->write("Access denied: .rehash requires Master or Owner level.\r\n");
        return;
    }

    $bot->{logger}->log(2, "Partyline: $nick requested rehash");
    $stream->write("Rehashing...\r\n");

    my $result = eval { $bot->rehash_runtime_state() };
    if (!$result) {
        my $err = $@ || 'rehash failed';
        $bot->{logger}->log(1, "Partyline rehash failed for $nick: $err");
        $stream->write("ERR rehash failed\r\n");
        return;
    }

    $stream->write("OK rehash completed\r\n");
}

# ---------------------------------------------------------------------------
# .restart
# ---------------------------------------------------------------------------
sub _cmd_restart {
    my ($self, $stream, $id, $reason) = @_;

    my $bot   = $self->{bot};
    my $nick  = $self->{users}{$id}{login};
    my $level = $self->{users}{$id}{level};

    unless (defined($level) && $level == 0) {   # Owner only
        $stream->write("Access denied: .restart requires Owner level.\r\n");
        return;
    }

    $bot->{logger}->log(2, "Partyline: $nick requested IRC restart");

    # In-process IRC restart: the Partyline stays alive.
    # restart_irc() sends QUIT best-effort, detaches the IRC object from the loop,
    # and on_timer_tick() will trigger reconnect() in the same process on the same loop.
    if ($bot->can('restart_irc')) {
        $stream->write("Restarting IRC connection (Partyline stays up)...\r\n");
        $self->_broadcast("*** IRC restarting - bot will reconnect shortly. ***");
        my $msg = (defined $reason && $reason ne '') ? $reason : "Partyline .restart by $nick";
        $bot->restart_irc(reason => $msg);
    } else {
        $stream->write("ERR: restart_irc() not available.\r\n");
    }
}


# ---------------------------------------------------------------------------
# .eval <perl code>  - Owner only
#
# Executes arbitrary Perl in the bot process context.
# USE WITH EXTREME CAUTION: crashes and data corruption are possible.
# Output is capped at 20 lines. Confirmation required before execution.
# ---------------------------------------------------------------------------
sub _cmd_eval {
    my ($self, $stream, $id, $code) = @_;

    my $bot   = $self->{bot};
    my $nick  = $self->{users}{$id}{login} // 'unknown';
    my $level = $self->{users}{$id}{level};

    unless (defined($level) && $level == 0) {
        $stream->write("Access denied: .eval requires Owner level.\r\n");
        return;
    }

    my $eval_enabled = eval { $bot->{conf}->get('main.PARTYLINE_EVAL_ENABLED') } // 0;
    $eval_enabled = 0 unless defined($eval_enabled) && $eval_enabled =~ /^(?:1|yes|true|on)$/i;

    unless ($eval_enabled) {
        $stream->write("Access denied: .eval is disabled by configuration.\r\n");
        $stream->write("Set PARTYLINE_EVAL_ENABLED=1 in [main] to enable it.\r\n");
        return;
    }

    unless (defined $code && $code =~ /\S/) {
        $stream->write("Usage: .eval <perl code>\r\n");
        $stream->write("WARNING: code runs in a forked subprocess. Confirmation required.\r\n");
        return;
    }

    # One-step confirmation with hard 30-second expiry.
    my $pending_key = "_eval_pending_$id";
    my $now_eval = time();

    if (!$self->{$pending_key}
        || $self->{$pending_key}{code} ne $code
        || ($now_eval - ($self->{$pending_key}{at} // 0)) > 30)
    {
        $self->{$pending_key} = { code => $code, at => $now_eval };
        $stream->write("--- .eval confirmation required ---\r\n");
        $stream->write("Code: $code\r\n");
        $stream->write("Type the same .eval command again within 30 seconds to execute.\r\n");
        return;
    }

    delete $self->{$pending_key};

    my $eval_timeout = eval { $bot->{conf}->get('main.PARTYLINE_EVAL_TIMEOUT_SECONDS') } || 5;
    $eval_timeout = 5 unless defined($eval_timeout) && $eval_timeout =~ /^\d+$/;
    $eval_timeout = 1  if $eval_timeout < 1;
    $eval_timeout = 15 if $eval_timeout > 15;

    $bot->{logger}->log(1, "Partyline: $nick executing eval in subprocess timeout=${eval_timeout}s: $code");
    # A4: log code summary to consolechan (truncate long payloads)
    {
        my $summary = length($code) > 60
            ? substr($code, 0, 57) . "..."
            : $code;
        eval { noticeConsoleChan($bot, "[partyline] $nick .eval (${\ length($code)}c): $summary") };
    }
    $self->_broadcast("[${nick}\@partyline] .eval $code", $id);

    my $pid = open(my $pipe, "-|");

    unless (defined $pid) {
        $stream->write("Cannot fork eval subprocess.\r\n");
        $bot->{logger}->log(1, "Partyline: failed to fork eval subprocess for $nick");
        return;
    }

    if ($pid == 0) {
        # Child process. Never mutate the live bot from here: this is a forked copy.
        eval {
            open STDERR, '>&', \*STDOUT;

            local $SIG{ALRM} = sub { die "__MEDIABOT_EVAL_TIMEOUT__\n" };
            alarm($eval_timeout);

            local $_ = undef;
            my $result = eval $code;
            my $err = $@;

            alarm(0);

            if ($err) {
                if ($err =~ /__MEDIABOT_EVAL_TIMEOUT__/) {
                    print "__MEDIABOT_EVAL_TIMEOUT__\n";
                    exit 124;
                }

                $err =~ s/\r?\n/ /g;
                print "__MEDIABOT_EVAL_ERROR__ $err\n";
                exit 2;
            }

            print "$result\n" if defined($result) && $result ne '';
            exit 0;
        };

        my $fatal = $@ || 'unknown eval subprocess failure';
        alarm(0);
        $fatal =~ s/\r?\n/ /g;
        print "__MEDIABOT_EVAL_FATAL__ $fatal\n";
        exit 2;
    }

    # B1/A1: read pipe asynchronously via IO::Async::Stream so the parent
    # event loop is not blocked while the child runs.
    my $eval_ctx = {
        lines     => [],
        truncated => 0,
        timed_out => 0,
        errors    => [],
    };

    # Watchdog: kill child if it runs past $eval_timeout (parent side)
    my $watchdog = IO::Async::Timer::Countdown->new(
        delay     => $eval_timeout,
        on_expire => sub {
            kill('TERM', $pid);
            usleep(500_000);
            kill('KILL', $pid);
            $eval_ctx->{timed_out} = 1;
            $stream->write("--- timeout ---\r\n") if $self->{streams}{$id};
            $stream->write("Eval timed out after ${eval_timeout}s.\r\n") if $self->{streams}{$id};
            $bot->{logger}->log(1, "Partyline: $nick eval timed out after ${eval_timeout}s");
        },
    );
    $bot->{loop}->add($watchdog);
    $watchdog->start;

    my $io = IO::Async::Stream->new(
        read_handle => $pipe,
        on_read     => sub {
            my ($s, $buffref, $eof) = @_;
            while ($$buffref =~ s/^([^\n]*\n)//) {
                my $line = $1;
                chomp $line;
                $line =~ s/\r//g;

                if ($line =~ /^__MEDIABOT_EVAL_TIMEOUT__/) {
                    $eval_ctx->{timed_out} = 1;
                    next;
                }
                if ($line =~ /^__MEDIABOT_EVAL_(?:ERROR|FATAL)__\s*(.*)$/) {
                    push @{ $eval_ctx->{errors} }, $1;
                    next;
                }
                $line =~ s/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]//g;
                $line = substr($line, 0, 497) . '...' if length($line) > 500;
                if (@{ $eval_ctx->{lines} } < 20) {
                    push @{ $eval_ctx->{lines} }, $line;
                } else {
                    $eval_ctx->{truncated} = 1;
                }
            }

            if ($eof) {
                eval { $watchdog->stop; $bot->{loop}->remove($watchdog) };
                eval { $bot->{loop}->remove($s) };
                waitpid($pid, 0);

                return unless $self->{streams}{$id};

                $stream->write("--- eval output ---\r\n");
                if (@{ $eval_ctx->{lines} }) {
                    $stream->write("$_\r\n") for @{ $eval_ctx->{lines} };
                } else {
                    $stream->write("(no output)\r\n") unless @{ $eval_ctx->{errors} };
                }
                $stream->write("[... output truncated at 20 lines ...]\r\n")
                    if $eval_ctx->{truncated};

                if ($eval_ctx->{timed_out}) {
                    # already written by watchdog
                } elsif (@{ $eval_ctx->{errors} }) {
                    $stream->write("--- error ---\r\n");
                    for my $err (@{ $eval_ctx->{errors} }) {
                        $err =~ s/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]//g;
                        $stream->write("$err\r\n");
                    }
                    $bot->{logger}->log(1, "Partyline: $nick eval error: "
                        . join(' | ', @{ $eval_ctx->{errors} }));
                } else {
                    $stream->write("--- ok ---\r\n");
                    $bot->{logger}->log(1, "Partyline: $nick eval done");
                }
            }
            return 0;
        },
    );
    $bot->{loop}->add($io);
}


# ---------------------------------------------------------------------------
# .die
# ---------------------------------------------------------------------------
sub _cmd_die {
    my ($self, $stream, $id, $msg) = @_;

    my $bot   = $self->{bot};
    my $nick  = $self->{users}{$id}{login};
    my $level = $self->{users}{$id}{level};

    unless (defined($level) && $level == 0) {   # Owner only
        $stream->write("Access denied: .die requires Owner level.\r\n");
        return;
    }

    $msg //= "Partyline requested termination";

    $bot->{logger}->log(2, "Partyline: $nick requested die ($msg)");
    $stream->write("Terminating bot...\r\n");

    $stream->close_when_empty;
    $self->_close_session($id);

    $bot->{Quit} = 1;
    $bot->{irc}->send_message("QUIT", undef, $msg);
}


sub _cmd_chanlog {
    my ($self, $stream, $id, $args) = @_;
    unless (defined $args && $args =~ /^(#\S+)(?:\s+(\d+))?/) {
        $stream->write("Usage: .logs <#channel> [n]  (default n=10, max 50)\r\n"); return;
    }
    my ($chan, $n) = ($1, int($2 // 10));
    $n = 10 if $n < 1; $n = 50 if $n > 50;
    my $bot = $self->{bot};
    my $dbh = eval { $bot->{db}->ensure_connected } // $bot->{dbh};
    return unless $dbh;
    my $sth = $dbh->prepare(q{
        SELECT cl.ts, cl.nick, cl.text FROM CHANNEL_LOG cl
        JOIN CHANNEL c ON c.id_channel = cl.id_channel
        WHERE c.name = ? AND cl.text IS NOT NULL
        ORDER BY cl.id DESC LIMIT ?
    });
    unless ($sth && $sth->execute($chan, $n)) {
        $stream->write("DB error.\r\n"); return;
    }
    my @rows;
    while (my $r = $sth->fetchrow_hashref) { unshift @rows, $r; }
    $sth->finish;
    unless (@rows) { $stream->write("No logs found for $chan.\r\n"); return; }
    $stream->write("Last " . scalar(@rows) . " lines on $chan:\r\n");
    for my $r (@rows) {
        my $ts = substr($r->{ts} // '', 11, 5);  # HH:MM
        $stream->write(sprintf("[%s] <%s> %s\r\n", $ts, $r->{nick}, $r->{text}));
    }
}
sub _cmd_nickinfo {
    my ($self, $stream, $id, $args) = @_;
    unless (defined $args && $args =~ /^(\S+)$/) {
        $stream->write("Usage: .nickinfo <nick>\r\n"); return;
    }
    my $target = lc($1);
    my $bot = $self->{bot};
    my $dbh = eval { $bot->{db}->ensure_connected } // $bot->{dbh};
    return unless $dbh;
    my $sth = $dbh->prepare(q{
        SELECT u.nick, u.id_user, u.email,
               GROUP_CONCAT(DISTINCT h.hostname ORDER BY h.hostname SEPARATOR ' | ') AS hosts,
               MAX(ls.login_at) AS last_login
        FROM USER u
        LEFT JOIN USER_HOST h  ON h.id_user  = u.id_user
        LEFT JOIN USER_LOG  ls ON ls.id_user = u.id_user
        WHERE LOWER(u.nick) = ?
        GROUP BY u.id_user
    });
    unless ($sth && $sth->execute($target)) {
        $stream->write("DB error.\r\n"); return;
    }
    my $r = $sth->fetchrow_hashref; $sth->finish;
    unless ($r) {
        $stream->write("$target: not found in DB.\r\n"); return;
    }
    $stream->write("Nick     : $r->{nick}\r\n");
    $stream->write("ID       : $r->{id_user}\r\n");
    $stream->write("Email    : " . ($r->{email}  // 'N/A') . "\r\n");
    $stream->write("Hosts    : " . ($r->{hosts}  // 'none') . "\r\n");
    $stream->write("Last login: " . ($r->{last_login} // 'never') . "\r\n");
}

sub _cmd_who_chan {
    my ($self, $stream, $id, $args) = @_;
    my $bot  = $self->{bot};
    my $chan  = (defined $args && $args =~ /^(#\S+)/) ? $1 : undef;
    unless ($chan) { $stream->write("Usage: .who <#channel>\r\n"); return; }
    my @nicks = eval { $bot->gethChannelsNicksOnChan($chan) };
    unless (@nicks) {
        $stream->write("No nicks found on $chan (not joined or empty).\r\n"); return;
    }
    $stream->write(scalar(@nicks) . " nick(s) on $chan:\r\n");
    # Try to show level for each nick
    my $dbh = eval { $bot->{db}->ensure_connected } // $bot->{dbh};
    my %levels;
    if ($dbh) {
        eval {
            my $sth = $dbh->prepare(q{
                SELECT u.nick, l.level FROM USER u
                JOIN USER_CHANNEL uc ON uc.id_user = u.id_user
                JOIN CHANNEL c ON c.id_channel = uc.id_channel
                JOIN LEVEL l ON l.id_level = uc.id_level
                WHERE c.name = ?
            });
            if ($sth && $sth->execute($chan)) {
                while (my $r = $sth->fetchrow_hashref) {
                    $levels{lc $r->{nick}} = $r->{level};
                }
                $sth->finish;
            }
        };
    }
    my @lines;
    for my $nick (sort @nicks) {
        my $lvl = $levels{lc $nick} ? " [" . $levels{lc $nick} . "]" : '';
        push @lines, "$nick$lvl";
    }
    # Output in chunks of 8
    while (my @chunk = splice @lines, 0, 8) {
        $stream->write('  ' . join('  ', @chunk) . "\r\n");
    }
}

sub _cmd_kick {
    my ($self, $stream, $id, $args) = @_;
    unless (defined $args && $args =~ /^(\S+)\s+(#\S+)(?:\s+(.*))?$/) {
        $stream->write("Usage: .kick <nick> <#channel> [reason]\r\n"); return;
    }
    my ($target, $chan, $reason) = ($1, $2, $3 // 'Kicked by operator');
    my $bot = $self->{bot};
    eval { $bot->{irc}->send_message('KICK', undef, $chan, $target, $reason) };
    if ($@) { $stream->write("Error: $@\r\n"); }
    else    { $stream->write("Kicked $target from $chan ($reason)\r\n"); }
}

sub _cmd_unmute {
    # CC3: manually lift a temp mute set by AF7
    my ($self, $stream, $id, $args) = @_;
    unless (defined $args && $args =~ /^(\S+)/) {
        $stream->write("Usage: .unmute <nick>\r\n"); return;
    }
    my $target = lc($1);
    my $bot = $self->{bot};
    if (exists $bot->{_nick_mute}{$target}) {
        delete $bot->{_nick_mute}{$target};
        $stream->write("AF7 mute lifted for $target.\r\n");
    } else {
        $stream->write("$target is not muted.\r\n");
    }
}

sub _cmd_floodset {
    my ($self, $stream, $id, $args) = @_;
    my $bot = $self->{bot};
    unless (defined $args && $args =~ /^(#\S+)(?:\s+(\d+)(?:\s+(\d+)(?:\s+(\d+))?)?)?/) {
        $stream->write("Usage: .floodset <#chan> [window] [max_cmds] [silence_secs]\r\n");
        $stream->write("  Defaults: window=10 max=8 silence=30\r\n");
        $stream->write("  Example: .floodset #quebec 10 4 60\r\n");
        return;
    }
    my ($chan, $window, $max, $silence) = ($1, $2, $3, $4);
    # Store overrides in memory — used by checkChanFlood via _chan_flood_conf
    $bot->{_chan_flood_conf}{$chan} = {
        window  => defined $window  ? int($window)  : undef,
        max     => defined $max     ? int($max)      : undef,
        silence => defined $silence ? int($silence)  : undef,
    };
    # Also reset current flood state for this channel
    delete $bot->{_chan_flood}{$chan};
    my $conf = $bot->{_chan_flood_conf}{$chan};
    my $w = $conf->{window}  // '(default)';
    my $m = $conf->{max}     // '(default)';
    my $s = $conf->{silence} // '(default)';
    $stream->write("CC2: floodset $chan — window=$w max=$m silence=$s\r\n");
    $stream->write("Current flood state reset.\r\n");
}

sub _cmd_cmdcooldown {
    # CC2: set per-command cooldown for a channel: .cmdcooldown #chan <cmd> <secs>
    my ($self, $stream, $id, $args) = @_;
    my $bot = $self->{bot};
    unless (defined $args && $args =~ /^(#\S+)\s+(\w+)\s+(\d+)$/) {
        $stream->write("Usage: .cmdcooldown <#chan> <cmd> <seconds>\r\n");
        $stream->write("  Example: .cmdcooldown #quebec ai 20\r\n");
        return;
    }
    my ($chan, $cmd, $secs) = ($1, lc($2), int($3));
    $secs = 0 if $secs < 0; $secs = 3600 if $secs > 3600;
    $bot->{_cmd_cooldown_conf}{$chan}{$cmd} = $secs;
    # Reset any active cooldown for this cmd+chan
    delete $bot->{_cmd_cooldown}{"$cmd:" . lc($chan)};
    $stream->write("CC2: cooldown for !$cmd on $chan set to ${secs}s\r\n");
}

sub _cmd_floodstatus {
    my ($self, $stream, $id, $args) = @_;
    my $bot = $self->{bot};
    my $now = time();

    # AF1: checkAntiFlood in-memory state
    $stream->write("--- Channel antiflood (AF1 — output guard) ---\r\n");
    my $af = $bot->{_af} // {};
    if (%$af) {
        for my $chan (sort keys %$af) {
            my $st = $af->{$chan};
            my $sil = $st->{silenced_until} // 0;
            my $status = ($sil && $now < $sil)
                ? sprintf('SILENCED (%ds remaining)', $sil - $now)
                : sprintf('%d msgs in window', $st->{nbmsg} // 0);
            $stream->write(sprintf("  %-22s %s\r\n", $chan, $status));
        }
    } else {
        $stream->write("  (no active output flood state)\r\n");
    }

    # AF4: checkChanFlood in-memory state
    $stream->write("--- Channel flood (AF4 — input guard) ---\r\n");
    my $cf = $bot->{_chan_flood} // {};
    if (%$cf) {
        for my $chan (sort keys %$cf) {
            my $st = $cf->{$chan};
            my $sil = $st->{silenced_until} // 0;
            my $cnt = scalar @{ $st->{hits} // [] };
            my $status = ($sil && $now < $sil)
                ? sprintf('SILENCED (%ds remaining)', $sil - $now)
                : sprintf('%d cmds in window', $cnt);
            $stream->write(sprintf("  %-22s %s\r\n", $chan, $status));
        }
    } else {
        $stream->write("  (no active input flood state)\r\n");
    }

    # CC3: temp-muted nicks
    $stream->write("--- Temp mutes (CC3/AF7) ---\r\n");
    my $mutes = $bot->{_nick_mute} // {};
    my @active_mutes = sort grep { ($mutes->{$_} // 0) > $now } keys %$mutes;
    if (@active_mutes) {
        for my $nick (@active_mutes) {
            $stream->write(sprintf("  %-20s muted (%ds remaining)\r\n",
                $nick, $mutes->{$nick} - $now));
        }
    } else {
        $stream->write("  (no active mutes)\r\n");
    }

    # AF3: per-nick flood state
    $stream->write("--- Per-nick flood (AF3) ---\r\n");
    my $nf = $bot->{_nick_flood} // {};
    my @throttled = sort grep {
        scalar @{ $nf->{$_}{hits} // [] } >= 3
    } keys %$nf;
    if (@throttled) {
        for my $nick (@throttled) {
            my $cnt = scalar @{ $nf->{$nick}{hits} // [] };
            $stream->write(sprintf("  %-20s %d cmds in window\r\n", $nick, $cnt));
        }
    } else {
        $stream->write("  (no active nick flood state)\r\n");
    }
}

sub _cmd_flushcooldown {
    my ($self, $stream, $id, $args) = @_;
    my $bot = $self->{bot};
    # Z6: support targeted nick+chan clear: .flushcooldown <nick> <#chan>
    if (defined $args && $args =~ /^(\S+)\s+(#\S+)$/) {
        my ($target, $chan) = (lc($1), $2);
        my $cd_key = "$target:" . lc($chan);  # matches U6 format
        if (exists $bot->{_karma_cooldown}{$chan}{$cd_key}) {
            delete $bot->{_karma_cooldown}{$chan}{$cd_key};
            $stream->write("Karma cooldown cleared for $target on $chan.\r\n");
        } else {
            $stream->write("No active cooldown for $target on $chan.\r\n");
        }
    } elsif (defined $args && $args =~ /^(#\S+)$/) {
        delete $bot->{_karma_cooldown}{$1};
        $stream->write("Karma cooldown cleared for $1.\r\n");
    } else {
        $bot->{_karma_cooldown} = {};
        $stream->write("All karma cooldowns cleared.\r\n");
    }
}

sub _cmd_dbstats {
    my ($self, $stream, $id) = @_;
    my $bot = $self->{bot};
    my $dbh = eval { $bot->{db}->ensure_connected } // $bot->{dbh};
    unless ($dbh) { $stream->write("DB not connected.\r\n"); return; }
    my %stats;
    for my $like ('Questions', 'Slow_queries', 'Threads_connected') {
        my $sth = eval { $dbh->prepare("SHOW STATUS LIKE '$like'") };
        if ($sth && $sth->execute()) {
            while (my $r = $sth->fetchrow_arrayref) { $stats{$r->[0]} = $r->[1]; }
            $sth->finish;
        }
    }
    my $db_name = eval { ($dbh->selectrow_array('SELECT DATABASE()'))[0] } // '?';
    $stream->write("DB stats ($db_name):\r\n");
    $stream->write(sprintf("  Threads : %s | Questions : %s | Slow : %s\r\n",
        $stats{Threads_connected}//'N/A', $stats{Questions}//'N/A', $stats{Slow_queries}//'N/A'));
    my $reqs = eval { $bot->{metrics}->get('mediabot_claude_requests_total') } // 0;
    my $yts  = eval { $bot->{metrics}->get('mediabot_ytsearch_requests_total') } // 0;
    my $kh   = eval { $bot->{metrics}->get('mediabot_karmahist_requests_total') } // 0;
    $stream->write("Bot: Claude=$reqs YTsearch=$yts KarmaHist=$kh\r\n");
}

1;
