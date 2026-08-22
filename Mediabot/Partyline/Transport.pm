package Mediabot::Partyline::Transport;

# =============================================================================
# Mediabot::Partyline::Transport
# =============================================================================
# mb678: transport extraction from Mediabot::Partyline.
#
# The historical Mediabot::Partyline method surface is imported back into the
# parent package. Callbacks continue dispatching through $self so subclass/local
# overrides keep working exactly as before.
# =============================================================================

use strict;
use warnings;
use utf8;
use Exporter 'import';
use bytes ();
use Time::HiRes ();
use IO::Async::Listener;
use IO::Async::Stream;
use IO::Async::Timer::Countdown;
use Socket qw(unpack_sockaddr_in sockaddr_family inet_ntoa inet_aton AF_INET);
use Scalar::Util qw(weaken);
use Mediabot::DCC qw(validate_dcc_active_target);

our @EXPORT_OK = qw(
    accept_dcc_chat
    _resolve_dcc_public_ip
    _dcc_listen_port
    _dcc_offer_key
    _dcc_pending_offer_for_nick
    _dcc_offer_register
    _dcc_offer_remove
    _dcc_offer_mark_connected
    _dcc_offers_snapshot
    offer_dcc_chat
    _dcc_token_hint
    accept_dcc_chat_passive
    _extract_input_lines
    _reject_oversized_input
    _dispatch_line_safely
    _report_operation_error
    _init_dcc_session
    _peer_ip_from_handle
    _start_listener
);

# The public compatibility constant remains owned by Mediabot::Partyline.
# Moved transport methods resolve it through the historical package at runtime.
sub MAX_PARTYLINE_LINE_BYTES { Mediabot::Partyline::MAX_PARTYLINE_LINE_BYTES() }

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

    # MB332-B1 defense in depth: validate again at the network sink. The
    # primary IRC handler already rejects unsafe destinations, but keeping the
    # guard here protects future/internal callers of accept_dcc_chat().
    my ($target_ok, $ip, $target_reason)
        = validate_dcc_active_target($ip_int, $port);

    unless ($target_ok) {
        my $safe_ip   = defined($ip)   ? $ip   : 'invalid';
        my $safe_port = defined($port) ? $port : 'undef';
        $bot->{logger}->log(
            1,
            "DCC CHAT: refusing unsafe target for $nick at "
            . "$safe_ip:$safe_port reason=$target_reason"
        );
        return;
    }

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
    my $timeout; # mb145-B1: stopped/removed as soon as the DCC client connects

    $listener = IO::Async::Listener->new(
        on_stream => sub {
            my (undef, $stream) = @_;

            return if $connected;
            $connected = 1;
            $self->_dcc_offer_mark_connected('ctcp_chat', $nick);
            $self->_dcc_offer_remove('ctcp_chat', $nick);

            # mb145-B1: the client connected, so the pending-offer timeout is
            # no longer useful. Stop/remove it now instead of keeping the
            # countdown closure alive until the original 60s expiry.
            if ($timeout) {
                eval {
                    $timeout->stop if $timeout->can('stop');
                    $loop->remove($timeout);
                };
            }

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
            if ($timeout) {
                eval {
                    $timeout->stop if $timeout->can('stop');
                    $loop->remove($timeout);
                };
            }
            eval { $loop->remove($listener) };
        },
    );

    $timeout = IO::Async::Timer::Countdown->new(
        delay     => 60,
        on_expire => sub {
            return if $connected;

            $logger->log(2, "CTCP CHAT: timeout waiting for $nick to connect");
            $self->_dcc_offer_remove('ctcp_chat', $nick);
            eval { $loop->remove($listener) } if $listener;
            eval { $loop->remove($timeout) }  if $timeout;
        },
    );

    $loop->add($timeout);
    $timeout->start;

    # MB337-B1: the loop and pending-offer registry own the live objects.
    # Keep only weak lexical references inside their callbacks so removing
    # a listener/timeout before expiry cannot leave a closure reference cycle.
    weaken($listener);
    weaken($timeout);
}

# ---------------------------------------------------------------------------
# accept_dcc_chat_passive($bot, $nick, $token)
#
# Handle passive DCC CHAT (RFC-style reverse DCC).
# The client sent ip=0 port=0 token=opaque-safe-id meaning it wants US to listen and
# it will connect to us. We:
#   1. Open a temporary TCP listener on an ephemeral port
#   2. Send back to the client: CTCP DCC CHAT chat <our_ip_int> <port> <token>
#   3. Wait for the client to connect (60s timeout)
#   4. On connection: close the listener, init DCC session normally
# ---------------------------------------------------------------------------

sub _dcc_token_hint {
    my ($token) = @_;

    return 'none' unless defined $token && $token ne '';

    my $s = "$token";
    return 'redacted' if length($s) <= 4;

    my $prefix = substr($s, 0, 2);
    my $suffix = substr($s, -2);

    return $prefix . '...' . $suffix;
}


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

    $logger->log(2, "DCC CHAT passive from $nick: listening on $public_ip token=" . _dcc_token_hint($token));

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
    my $timeout; # mb145-B1: stopped/removed as soon as the passive DCC client connects

    $listener = IO::Async::Listener->new(
        on_stream => sub {
            my (undef, $stream) = @_;

            return if $connected;   # accept only one connection
            $connected = 1;
            $self->_dcc_offer_mark_connected('passive_chat', $nick);
            $self->_dcc_offer_remove('passive_chat', $nick);

            # mb145-B1: passive client connected, so cancel the 60s listener
            # timeout immediately instead of keeping its closure alive.
            if ($timeout) {
                eval {
                    $timeout->stop if $timeout->can('stop');
                    $loop->remove($timeout);
                };
            }

            $logger->log(2, "DCC CHAT passive: $nick connected (token=" . _dcc_token_hint($token) . ")");

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
            $logger->log(2, "DCC CHAT passive: listening on port $listen_port for $nick (token=" . _dcc_token_hint($token) . ")");

            # ── Send CTCP reply to client ─────────────────────────────────
            my $ctcp = "\001DCC CHAT chat $ip_int $listen_port $token\001";
            # Raw PRIVMSG — bypass botPrivmsg() side effects for CTCP payloads.
            $bot->{irc}->send_message('PRIVMSG', undef, $nick, $ctcp);
            $logger->log(2, "DCC CHAT passive: sent CTCP reply to $nick");
        },

        on_listen_error => sub {
            $logger->log(1, "DCC CHAT passive: listen error for $nick - $_[1]");
            $self->_dcc_offer_remove('passive_chat', $nick);
            if ($timeout) {
                eval {
                    $timeout->stop if $timeout->can('stop');
                    $loop->remove($timeout);
                };
            }
            eval { $loop->remove($listener) };
        },
    );

    # ── 60-second timeout - close listener if client never connects ───────────
    $timeout = IO::Async::Timer::Countdown->new(
        delay     => 60,
        on_expire => sub {
            return if $connected;
            $logger->log(2, "DCC CHAT passive: timeout waiting for $nick (token=" . _dcc_token_hint($token) . ")");
            # mb146-B1: when a passive DCC offer times out, remove the pending
            # offer entry too. Otherwise _dcc_pending_offer_for_nick() keeps
            # refusing future DCC attempts for this nick even after listener close.
            $self->_dcc_offer_remove('passive_chat', $nick);
            eval { $loop->remove($listener) } if $listener;
            eval { $loop->remove($timeout) }  if $timeout;
        },
    );
    $loop->add($timeout);
    $timeout->start;

    # MB337-B1: the loop and pending-offer registry own the live objects.
    # Keep only weak lexical references inside their callbacks so removing
    # a listener/timeout before expiry cannot leave a closure reference cycle.
    weaken($listener);
    weaken($timeout);
}

# ---------------------------------------------------------------------------
# _extract_input_lines($buffref)
#
# mb366-B1: IO::Async keeps unread bytes in the supplied buffer.  Both Telnet
# and DCC previously waited for LF without a maximum, so an unauthenticated
# peer could grow the bot process indefinitely by sending one endless line.
# Return (ARRAYREF lines, too_long_bool) and clear an oversized remainder.
# ---------------------------------------------------------------------------
sub _extract_input_lines {
    my ($self, $buffref) = @_;

    return ([], 0) unless ref($buffref) eq 'SCALAR';

    my @lines;
    while ($$buffref =~ s/^([^\n]*)\n//) {
        my $line = $1;
        $line =~ s/\r$//;

        if (bytes::length($line) > MAX_PARTYLINE_LINE_BYTES) {
            $$buffref = '';
            return (\@lines, 1);
        }

        push @lines, $line;
    }

    # A CR immediately before a future LF is framing, not command content.
    # Allow exactly MAX bytes plus that one pending CR.
    my $pending = $$buffref;
    $pending =~ s/\r$//;
    if (bytes::length($pending) > MAX_PARTYLINE_LINE_BYTES) {
        $$buffref = '';
        return (\@lines, 1);
    }

    return (\@lines, 0);
}

# ---------------------------------------------------------------------------
# _reject_oversized_input($stream, $id, $transport)
# ---------------------------------------------------------------------------
sub _reject_oversized_input {
    my ($self, $stream, $id, $transport) = @_;

    $transport = 'Partyline' unless defined($transport) && length($transport);

    my $logger = eval { $self->{bot}->{logger} };
    eval {
        $logger->log(
            1,
            "$transport: input line exceeds " . MAX_PARTYLINE_LINE_BYTES
                . " bytes for fd=$id; closing session"
        );
    } if $logger && $logger->can('log');

    eval { $stream->write("Input line too long.\r\n") }
        if $stream && $stream->can('write');
    eval { $stream->close_when_empty }
        if $stream && $stream->can('close_when_empty');

    $self->_close_session($id);
    return 0;
}

# ---------------------------------------------------------------------------
# _dispatch_line_safely($stream, $id, $line, $transport)
#
# mb365-B1: Partyline commands may throw because of a DB/runtime failure. Keep
# the useful exception details in the server log, but never echo $@ to a Telnet
# or DCC client: it may contain filesystem paths, SQL text or module internals,
# including before authentication has completed.
# ---------------------------------------------------------------------------
sub _dispatch_line_safely {
    my ($self, $stream, $id, $line, $transport) = @_;

    $transport = 'Partyline' unless defined($transport) && length($transport);

    # mb552-B1: same discipline as the PRIVMSG wrapper — any partyline
    # command slower than one second names itself at level 3.
    my $t0_552 = [ Time::HiRes::gettimeofday() ];
    my $ok = eval {
        $self->_handle_line($stream, $id, $line);
        1;
    };
    my $elapsed_552 = Time::HiRes::tv_interval($t0_552);
    if ($elapsed_552 > 1.0) {
        my $cmd = $line;
        $cmd = (split ' ', $cmd)[0] // '';
        eval {
            $self->{bot}->{logger}->log(3,
                sprintf('SLOW PARTYLINE: %s took %.2fs', $cmd, $elapsed_552));
        };
    }

    return 1 if $ok;

    my $err = $@ || 'unknown error';
    return $self->_report_operation_error(
        $stream,
        "$transport exception",
        'Internal error.',
        $err,
    );
}

# ---------------------------------------------------------------------------
# _report_operation_error($stream, $log_label, $client_message, $error)
#
# mb367-B1: individual Partyline commands sometimes catch their own exceptions
# before the outer mb365 dispatcher can see them. Keep diagnostic details in
# the server log, but send only a stable, context-specific message to the
# Telnet/DCC client. Error reporting itself must never raise a second exception.
# ---------------------------------------------------------------------------
sub _report_operation_error {
    my ($self, $stream, $log_label, $client_message, $error) = @_;

    $log_label = 'Partyline operation failed'
        unless defined($log_label) && length($log_label);
    $log_label =~ s/[\r\n]+/ /g;
    $log_label =~ s/^\s+|\s+$//g;

    my $err = defined($error) && length($error) ? $error : 'unknown error';
    $err =~ s/[\r\n]+/ /g;
    $err =~ s/^\s+|\s+$//g;
    $err = 'unknown error' unless length($err);

    my $reply = defined($client_message) && length($client_message)
        ? $client_message
        : 'Internal error.';
    $reply =~ s/[\r\n]+/ /g;
    $reply =~ s/^\s+|\s+$//g;
    $reply = 'Internal error.' unless length($reply);

    my $logger = eval { $self->{bot}->{logger} };
    eval { $logger->log(1, "$log_label: $err") }
        if $logger && $logger->can('log');

    eval { $stream->write("$reply\r\n") }
        if $stream && $stream->can('write');

    return 0;
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
        peer_host      => $peer_host,
    };
    $self->{streams}{$id} = $stream;
    $self->_schedule_reverse_dns_lookup($id, $peer_host, 2);

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
    $self->{users}{$id}{auth_timeout_timer} = $timeout_timer if $self->{users}{$id}; # mb147-B1

    $stream->configure(
        on_read => sub {
            my ($stream, $buffref, $eof) = @_;

            # DCC CHAT uses bare LF or CRLF - no TELNET IAC sequences.
            my ($lines, $too_long) = $self->_extract_input_lines($buffref);
            for my $line (@$lines) {
                # Mask password in logs — mask on stage 'pass' (standard flow)
                my $log_line = $line;
                if (($self->{users}{$id}{auth_stage} // '') eq 'pass') {
                    $log_line = '********';
                }
                else {
                    $log_line =~ s/^(login\s+\S+\s+).+/$1********/i;
                }

                $self->{bot}->{logger}->log(3, "DCC CHAT <- \'$log_line\' (fd=$id nick=$nick)");
                $self->_dispatch_line_safely($stream, $id, $line, 'DCC CHAT');
            }

            return $self->_reject_oversized_input($stream, $id, 'DCC CHAT')
                if $too_long;

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

sub _peer_ip_from_handle {
    # mb340-B1: capture l'IP distante du socket, IPv4 ET IPv6.
    #
    # L'ancien code ne gérait que AF_INET (inet_ntoa) : une connexion telnet
    # IPv6 au partyline retombait sur 'unknown' (visible dans .whom et les logs).
    # Le bot tourne sur OVH/Kimsufi où l'IPv6 est courant.
    #
    # Tout est défensif : la branche IPv6 utilise des symboles pleinement
    # qualifiés (Socket::AF_INET6 / unpack_sockaddr_in6 / inet_ntop) gardés par
    # un test de disponibilité, et l'ensemble est sous eval. Sur une plateforme
    # sans support IPv6 dans Socket, on retombe proprement sur 'unknown' comme
    # avant — aucun risque de compilation, le chemin IPv4 est inchangé.
    my ($handle) = @_;

    my $ip = 'unknown';
    return $ip unless $handle;

    eval {
        my $pn = $handle->peername;
        if ($pn) {
            my $fam = sockaddr_family($pn);
            if ($fam == AF_INET) {
                my (undef, $addr) = unpack_sockaddr_in($pn);
                $ip = inet_ntoa($addr);
            }
            elsif (defined(&Socket::AF_INET6) && $fam == Socket::AF_INET6()) {
                my (undef, $addr6) = Socket::unpack_sockaddr_in6($pn);
                my $str = eval { Socket::inet_ntop(Socket::AF_INET6(), $addr6) };
                $ip = $str if defined($str) && $str ne '';
            }
        }
        1;
    };

    return $ip;
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

            # mb340-B1: capture IPv4 ET IPv6 (l'ancien inline ne gérait qu'AF_INET).
            my $peer_host = _peer_ip_from_handle($stream->read_handle);

            my $peer_ip = $peer_host;

            $self->{users}{$id} = {
                authenticated  => 0,
                login          => '',
                level          => undef,
                level_desc     => '',
                peer_ip        => $peer_ip,
                peer_host      => $peer_ip,
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
            $self->_schedule_reverse_dns_lookup($id, $peer_ip, 2);

            $stream->configure(
                on_read => sub {
                    my ($stream, $buffref, $eof) = @_;

                    # Strip TELNET IAC negotiation replies generated by clients
                    # after we toggle ECHO for password input.
                    $$buffref = $self->_strip_telnet_iac($$buffref);

                    my ($lines, $too_long) = $self->_extract_input_lines($buffref);
                    for my $line (@$lines) {
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
                        $self->_dispatch_line_safely($stream, $id, $line, 'Partyline');
                    }

                    return $self->_reject_oversized_input($stream, $id, 'Partyline')
                        if $too_long;

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


# ---------------------------------------------------------------------------
# _cancel_auth_timeout($id)
#
# Stop and remove the DCC authentication timeout timer attached to a session.
# This is intentionally safe for normal telnet sessions where no timer exists.
# ---------------------------------------------------------------------------

1;
