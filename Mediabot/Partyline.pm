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

    if    ($line =~ /^\.ping$/i) {
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
    elsif ($line =~ /^\.ban\s+(#\S+)\s+(\S+)(?:\s+(.*))?$/i) {
        $self->{bot}->{metrics}->inc('mediabot_commands_partyline_total', { command => '.ban' }) if $self->{bot}->{metrics};
        my ($chan_b, $nick_b, $rest_b) = ($1, $2, $3 // '');
        my @rest_args_b = split(/\s+/, $rest_b);
        $self->_cmd_ban($stream, $id, $chan_b, $nick_b, @rest_args_b)
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
        "SELECT u.id_user, u.nickname, u.password, ul.level, ul.description
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
      . "  .ping               - check partyline session is alive\r\n"
      . "  .match <handle>     - show user record (wildcards * ? allowed)\r\n"
      . "  .say <#chan|nick> <msg> - send a message to channel or user\r\n"
      . "  .who #chan          - list nicks present in a channel\r\n"
      . "  .join #chan [key]   - make the bot join a channel\r\n"
      . "  .part #chan         - make the bot part a channel\r\n"
      . "  .nick <newnick>     - change the bot's nick\r\n"
      . "  .raw <IRC command>  - send a raw IRC command (Owner only)\r\n"
      . "  .rehash             - reload configuration and runtime state\r\n"
      . "  .restart            - reconnect IRC without killing process (Owner)\r\n"
      . "  .die                - terminate bot process entirely (Owner only)\r\n"
      . "  .eval <perl>        - execute Perl in bot context (Owner, dangerous)\r\n"
      . "  .console [0-5|off]  - redirect bot log to this session\r\n"
      . "  .ban #chan <nick> [duration] [reason] - ban a nick via WHOIS\r\n"
      . "  .ban #chan <nick> [dur] [reason] - ban a nick (WHOIS lookup)\r\n"
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
            $stream->write("Console is ON at level $cur (0=INFO, 1=DEBUG1 … 5=DEBUG5).\r\n");
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
        eval { $s->write($line . "\r\n") };
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

    my @lines;
    my $count = 0;

    for my $fid (sort { $a <=> $b } keys %{ $self->{users} }) {
        my $u = $self->{users}{$fid};
        next unless $u && $u->{authenticated};

        my $nick       = $self->_display_nick($fid, 48);
        my $level_desc = $u->{level_desc}   // '?';
        my $con_level  = defined $u->{console_level}
            ? "console:" . $u->{console_level}
            : "console:off";
        my $is_me      = ($fid == $id) ? " *" : "";

        push @lines, sprintf("  %-14s  %-14s  fd=%-4d  %s%s",
            $nick, $level_desc, $fid, $con_level, $is_me);
        $count++;
    }

    if ($count == 0) {
        $stream->write("No users currently on the partyline.\r\n");
        return;
    }

    $stream->write(sprintf("Partyline users (%d):\r\n", $count));
    $stream->write("  Nick            Level           Socket  Console\r\n");
    $stream->write("  " . ("-" x 60) . "\r\n");
    $stream->write("$_\r\n") for @lines;
}

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

    # Convert Eggdrop-style wildcards to SQL LIKE wildcards
    my $sql_pat = $pattern;
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
            ul.level        AS level_num,
            GROUP_CONCAT(uh.hostmask ORDER BY uh.id_user_hostmask SEPARATOR ' ')
                AS hostmasks
        FROM USER u
        JOIN USER_LEVEL ul ON ul.id_user_level = u.id_user_level
        LEFT JOIN USER_HOSTMASK uh ON uh.id_user = u.id_user
        WHERE u.nickname LIKE ?
        GROUP BY u.id_user, u.nickname, u.auth, u.info1, u.info2,
                 ul.description, ul.level
        ORDER BY u.nickname
        LIMIT 21
    }); # fetch 21 to detect truncation (display only 20)

    unless ($sth->execute($sql_pat)) {
        $bot->{logger}->log(1, "Partyline .match SQL error: $DBI::errstr");
        $stream->write("Database error.\r\n");
        return;
    }

    my $found = 0;
    while (my $row = $sth->fetchrow_hashref) {
        $found++;
        my $auth  = $row->{auth} ? "logged in" : "not logged in";
        my $masks = $row->{hostmasks} // "(none)";
        my $info1 = $row->{info1}     // "";
        my $info2 = $row->{info2}     // "";

        $stream->write("\r\n");
        $stream->write(sprintf("  Handle  : %s\r\n", $row->{nickname}));
        $stream->write(sprintf("  Level   : %s (%d)\r\n", $row->{level_desc}, $row->{level_num}));
        $stream->write(sprintf("  Status  : %s\r\n", $auth));
        $stream->write(sprintf("  Hosts   : %s\r\n", $masks));
        $stream->write(sprintf("  Info1   : %s\r\n", $info1)) if $info1 ne '';
        $stream->write(sprintf("  Info2   : %s\r\n", $info2)) if $info2 ne '';
    }
    $sth->finish;

    if ($found == 0) {
        $stream->write("No match for '$pattern'.\r\n");
    } elsif ($found > 20) {
        $stream->write(sprintf("\r\nShowing first 20 matches for '%s' (more exist — narrow your search).\r\n", $pattern));
    } elsif ($found > 1) {
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
# .ping - check if partyline session is still alive
# ---------------------------------------------------------------------------
sub _cmd_ping {
    my ($self, $stream, $id) = @_;
    my ($sec, $min, $hour) = localtime(time);
    $stream->write(sprintf("PONG %02d:%02d:%02d\r\n", $hour, $min, $sec));
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
    my @bans = $bot->{channel_ban}->list_active_bans($id_channel);

    unless (@bans) {
        $stream->write("No active bans on $chan.\r\n");
        return;
    }

    $stream->write(sprintf("%d active ban(s) on $chan:\r\n", scalar @bans));
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

    unless (defined $code && $code =~ /\S/) {
        $stream->write("Usage: .eval <perl code>\r\n");
        $stream->write("WARNING: code runs in the bot process. Confirmation required.\r\n");
        return;
    }

    # One-step confirmation: check for pending eval
    my $pending_key = "_eval_pending_$id";
    my $now_eval = time();
    if (!$self->{$pending_key}
        || $self->{$pending_key}{code} ne $code
        || ($now_eval - ($self->{$pending_key}{at} // 0)) > 30)
    {
        # First invocation (or expired): store and ask for confirmation
        $self->{$pending_key} = { code => $code, at => $now_eval };
        $stream->write("--- .eval confirmation required ---\r\n");
        $stream->write("Code: $code\r\n");
        $stream->write("Type the same .eval command again to execute.\r\n");
        return;
    }

    # Second invocation with same code: execute
    delete $self->{$pending_key};

    $bot->{logger}->log(1, "Partyline: $nick executing eval: $code");
    $self->_broadcast("[${nick}\@partyline] .eval $code", $id);

    # Capture STDOUT and STDERR, limit output
    my $output = '';
    {
        local *STDOUT;
        open(STDOUT, '>>', \$output) or do {
            $stream->write("Cannot capture STDOUT.\r\n");
            return;
        };
        local *STDERR;
        open(STDERR, '>>', \$output) or do {
            $stream->write("Cannot capture STDERR.\r\n");
            return;
        };

        eval { local $_ = undef; eval $code; };
    }

    my $err = $@;

    my @lines = split /\n/, $output;
    my $truncated = 0;
    if (@lines > 20) {
        @lines = @lines[0..19];
        $truncated = 1;
    }

    $stream->write("--- eval output ---\r\n");
    $stream->write("$_\r\n") for @lines;
    $stream->write("[... output truncated at 20 lines ...]\r\n") if $truncated;

    if ($err) {
        $err =~ s/\n/ /g;
        $stream->write("--- error ---\r\n");
        $stream->write("$err\r\n");
    } else {
        $stream->write("--- ok ---\r\n");
    }

    $bot->{logger}->log(1, "Partyline: $nick eval completed" . ($err ? " with error: $err" : ""));
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

1;
