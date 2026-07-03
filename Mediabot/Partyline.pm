package Mediabot::Partyline;

# +---------------------------------------------------------------------------+
# ! Mediabot::Partyline                                                       !
# ! TCP telnet-style partyline for bot administration                        !
# !                                                                           !
# ! Access : telnet <host> <PARTYLINE_PORT>, DCC CHAT or CTCP CHAT       !
# !                                                                           !
# ! Authentication : interactive nickname/password prompt                    !
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
use bytes ();
use IO::Async::Listener;
use IO::Async::Stream;
use IO::Async::Timer::Countdown;
use POSIX qw(WNOHANG);
use Socket qw(unpack_sockaddr_in sockaddr_family inet_ntoa inet_aton AF_INET);
use Scalar::Util qw(weaken);
use JSON qw(encode_json);
use Encode qw(encode);
use Mediabot::External ();
use Mediabot::DCC qw(validate_dcc_active_target);
use Mediabot::Helpers qw(getProcessStartTimestamp);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Temp qw(tempfile);

our @EXPORT_OK = qw();

# mb366-B1: keep unauthenticated Telnet/DCC input bounded while waiting for LF.
use constant MAX_PARTYLINE_LINE_BYTES => 4 * 1024;

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

    my $ok = eval {
        $self->_handle_line($stream, $id, $line);
        1;
    };

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
        # Z8: store with timestamp for .history display
        my @_ht = localtime(time); my $_hts = sprintf('%02d:%02d', $_ht[2], $_ht[1]);
        push @{ $self->{users}{$id}{history} }, "$_hts $line";
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
    elsif ($line =~ /^\.plugins(?:\s+(.*))?$/i) {
        $self->{bot}->{metrics}->inc('mediabot_commands_partyline_total', { command => '.plugins' }) if $self->{bot}->{metrics};
        $self->_cmd_plugins($stream, $id, $1);
    }
    elsif ($line =~ /^\.scriptdryrun(?:\s+(.*))?$/i) {
        $self->{bot}->{metrics}->inc('mediabot_commands_partyline_total', { command => '.scriptdryrun' }) if $self->{bot}->{metrics};
        $self->_cmd_scriptdryrun($stream, $id, $1);
    }
    elsif ($line =~ /^\.top(?:\s+(.*))?$/i) {
        $self->{bot}->{metrics}->inc('mediabot_commands_partyline_total', { command => '.top' }) if $self->{bot}->{metrics};
        $self->_cmd_top($stream, $id, $1 // '');
    }
    elsif ($line =~ /^\.remind(?:\s+(.*))?$/i) {
        $self->_cmd_remind($stream, $id, $1);
    }
    elsif ($line =~ /^\.aistats$/i) {
        $self->{bot}->{metrics}->inc('mediabot_commands_partyline_total', { command => '.aistats' }) if $self->{bot}->{metrics};
        $self->_cmd_ai($stream, $id, 'stats');
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
    elsif ($line =~ /^\.kv\s+(.*)/i) {
        $self->_cmd_kv($stream, $id, $1);
    }
    elsif ($line =~ /^\.floodset\s+(.*)/i) {
        $self->_cmd_floodset($stream, $id, $1);
    }
    elsif ($line =~ /^\.cmdcooldown\s+(.*)/i) {
        $self->_cmd_cmdcooldown($stream, $id, $1);
    }
    elsif ($line =~ /^\.netsplit$/i) {
        $self->_cmd_netsplit($stream, $id, undef);
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
        $self->{bot}->{metrics}->inc('mediabot_commands_partyline_total', { command => '.who' }) if $self->{bot}->{metrics};
        $self->_cmd_who_chan($stream, $id, $1);
    }
    elsif ($line =~ /^\.who\s+(\S+)/i) {
        $self->{bot}->{metrics}->inc('mediabot_commands_partyline_total', { command => '.who' }) if $self->{bot}->{metrics};
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
        $self->_cmd_reloadconf($stream, $id);
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

# +---------------------------------------------------------------------------+
# ! Commands                                                                  !
# +---------------------------------------------------------------------------+

# ---------------------------------------------------------------------------
# .scriptdryrun [status|last|config] - read-only ScriptDryRun plugin visibility
sub _cmd_scriptdryrun {
    my ($self, $stream, $id, $arg) = @_;

    $arg //= '';
    $arg =~ s/^\s+|\s+$//g;
    my $mode = lc($arg || 'status');

    my $bot = $self->{bot};
    unless ($bot && $bot->can('plugin_manager') && $bot->plugin_manager) {
        $stream->write("ScriptDryRun: PluginManager not initialized\r\n");
        return;
    }

    my $pm = $bot->plugin_manager;
    my $plugin = eval { $pm->object_for('Mediabot::Plugin::ScriptDryRun') };

    # mb180-B1: read-only partyline visibility for the ScriptDryRun bridge.
    # This command never loads plugins, executes scripts, applies actions,
    # sends IRC messages, creates timers or touches the database.
    if ($mode eq 'config') {
        $stream->write("ScriptDryRun config:\r\n");
        $stream->write("  plugin module: Mediabot::Plugin::ScriptDryRun\r\n");
        $stream->write("  script path keys:\r\n");
        $stream->write("    plugins.ScriptDryRun.SCRIPT\r\n");
        $stream->write("    plugins.ScriptDryRun.script\r\n");
        $stream->write("    plugins.script_dryrun.SCRIPT\r\n");
        $stream->write("    plugins.script_dryrun.script\r\n");
        $stream->write("    SCRIPT_DRYRUN_SCRIPT\r\n");
        $stream->write("    SCRIPT_DRYRUN_PATH\r\n");
        $stream->write("  command filter keys:\r\n");
        $stream->write("    plugins.ScriptDryRun.COMMANDS\r\n");
        $stream->write("    plugins.ScriptDryRun.commands\r\n");
        $stream->write("    plugins.script_dryrun.COMMANDS\r\n");
        $stream->write("    plugins.script_dryrun.commands\r\n");
        $stream->write("    SCRIPT_DRYRUN_COMMANDS\r\n");
        $stream->write("  command route keys:\r\n");
        $stream->write("    plugins.ScriptDryRun.ROUTES\r\n");
        $stream->write("    plugins.ScriptDryRun.routes\r\n");
        $stream->write("    plugins.script_dryrun.ROUTES\r\n");
        $stream->write("    plugins.script_dryrun.routes\r\n");
        $stream->write("    SCRIPT_DRYRUN_ROUTES\r\n");
        $stream->write("  route format: command=script, other=script2\r\n");
        $stream->write("  command filter: optional explicit allow-list\r\n");
        $stream->write("  command routes: mapped commands are explicitly scoped and authorized\r\n");
        $stream->write("  SCRIPT fallback: used only when no route matches; keep scoped in apply mode\r\n");
        $stream->write("  action mode keys:\r\n");
        $stream->write("    plugins.ScriptDryRun.ACTION_MODE\r\n");
        $stream->write("    plugins.ScriptDryRun.action_mode\r\n");
        $stream->write("    plugins.script_dryrun.ACTION_MODE\r\n");
        $stream->write("    plugins.script_dryrun.action_mode\r\n");
        $stream->write("    SCRIPT_DRYRUN_ACTION_MODE\r\n");
        $stream->write("  allowed IRC keys:\r\n");
        $stream->write("    plugins.ScriptDryRun.ALLOW_IRC\r\n");
        $stream->write("    plugins.ScriptDryRun.allow_irc\r\n");
        $stream->write("    plugins.script_dryrun.ALLOW_IRC\r\n");
        $stream->write("    plugins.script_dryrun.allow_irc\r\n");
        $stream->write("    SCRIPT_DRYRUN_ALLOW_IRC\r\n");
        $stream->write("  apply scope guard keys:\r\n");
        $stream->write("    plugins.ScriptDryRun.APPLY_REQUIRE_SCOPE\r\n");
        $stream->write("    plugins.ScriptDryRun.apply_require_scope\r\n");
        $stream->write("    plugins.script_dryrun.APPLY_REQUIRE_SCOPE\r\n");
        $stream->write("    plugins.script_dryrun.apply_require_scope\r\n");
        $stream->write("    SCRIPT_DRYRUN_APPLY_REQUIRE_SCOPE\r\n");
        $stream->write("  action modes: dry-run, apply\r\n");
        $stream->write("  IRC output requires: ACTION_MODE=apply and ALLOW_IRC=yes\r\n");
        $stream->write("  apply scope guard: when enabled, ACTION_MODE=apply requires COMMANDS or ROUTES\r\n");
        return;
    }

    if ($mode ne 'status' && $mode ne 'last') {
        $stream->write("Usage: .scriptdryrun [status|last|config]\r\n");
        return;
    }

    unless ($plugin) {
        $stream->write("ScriptDryRun: not loaded\r\n");
        $stream->write("  hint: load Mediabot::Plugin::ScriptDryRun explicitly or enable plugin autoload\r\n");
        return;
    }

    my $script_path = eval { $plugin->script_path };
    my $observed    = eval { $plugin->observed_public } || 0;
    my $skipped     = eval { $plugin->skipped_public } || 0;
    my $filtered    = eval { $plugin->can('filtered_public') ? $plugin->filtered_public : 0 } || 0;
    my $filter_on   = eval { $plugin->can('command_filter_enabled') ? $plugin->command_filter_enabled : 0 } ? 1 : 0;
    my @filter_list = eval { $plugin->can('command_filter_list') ? $plugin->command_filter_list : () };
    my $routes_on   = eval { $plugin->can('command_routes_enabled') ? $plugin->command_routes_enabled : 0 } ? 1 : 0;
    my @route_list  = eval { $plugin->can('command_route_list') ? $plugin->command_route_list : () };
    my $route_map   = eval { $plugin->can('command_routes') ? $plugin->command_routes : {} };
    $route_map = {} unless ref($route_map) eq 'HASH';
    my $action_mode = eval { $plugin->can('action_mode') ? $plugin->action_mode : 'dry-run' } || 'dry-run';
    my $allow_irc   = eval { $plugin->can('allow_irc') ? $plugin->allow_irc : 0 } ? 1 : 0;
    my $scope_guard = eval { $plugin->can('apply_require_scope') ? $plugin->apply_require_scope : 0 } ? 1 : 0;
    my $scope_restricted = eval { $plugin->can('apply_scope_is_restricted') ? $plugin->apply_scope_is_restricted : 0 } ? 1 : 0;
    my $scope_warning = eval { $plugin->can('apply_scope_warning') ? $plugin->apply_scope_warning : undef };
    my $last_error  = eval { $plugin->last_error };
    my $last_result = eval { $plugin->last_result };

    $stream->write("ScriptDryRun:\r\n");
    $stream->write("  loaded: yes\r\n");
    $stream->write("  script: " . (defined($script_path) && length("$script_path") ? $script_path : 'not configured') . "\r\n");
    $stream->write("  observed_public: $observed\r\n");
    $stream->write("  skipped_public: $skipped\r\n");
    $stream->write("  filtered_public: $filtered\r\n");
    # mb183-B1: include ScriptDryRun command filter visibility in read-only partyline status.
    $stream->write("  command_filter: " . ($filter_on ? 'enabled' : 'disabled') . "\r\n");
    if ($filter_on) {
        my $filter_text = @filter_list ? join(',', @filter_list) : 'none';
        $stream->write("  allowed_commands: $filter_text\r\n");
    }
    # mb185-B1: include ScriptDryRun command route visibility in read-only partyline status.
    $stream->write("  command_routes: " . ($routes_on ? 'enabled' : 'disabled') . "\r\n");
    if ($routes_on) {
        my @route_pairs = map { $_ . '=' . ($route_map->{$_} // '') } @route_list;
        my $route_text = @route_pairs ? join(',', @route_pairs) : 'none';
        $stream->write("  route_map: $route_text\r\n");
    }
    # mb188-B1: expose ScriptDryRun ACTION_MODE / ALLOW_IRC state in read-only partyline status.
    $stream->write("  action_mode: $action_mode\r\n");
    $stream->write("  allow_irc: " . ($allow_irc ? 'yes' : 'no') . "\r\n");
    # mb190-B1: expose ScriptDryRun apply-scope guard state without executing scripts.
    $stream->write("  apply_require_scope: " . ($scope_guard ? 'yes' : 'no') . "\r\n");
    $stream->write("  apply_scope_restricted: " . ($scope_restricted ? 'yes' : 'no') . "\r\n");
    if (defined $scope_warning && length "$scope_warning") {
        $scope_warning =~ s/[\r\n]+/ /g;
        $stream->write("  apply_scope_warning: $scope_warning\r\n");
    }

    if (defined $last_error && length "$last_error") {
        $last_error =~ s/[\r\n]+/ /g;
        $stream->write("  last_error: $last_error\r\n");
    }

    unless ($last_result && ref($last_result) eq 'HASH') {
        $stream->write("  last_result: none\r\n");
        return;
    }

    my $script_result = $last_result->{script_result} || {};
    my $action_plan   = $last_result->{action_plan}   || {};

    $stream->write("  last_result_ok: " . ($last_result->{ok} ? 'yes' : 'no') . "\r\n");
    $stream->write("  dry_run: " . ($last_result->{dry_run} ? 'yes' : 'no') . "\r\n");

    if ($mode eq 'status') {
        my $planned = ref($action_plan->{planned}) eq 'ARRAY' ? scalar @{ $action_plan->{planned} } : 0;
        my $errors  = ref($action_plan->{errors})  eq 'ARRAY' ? scalar @{ $action_plan->{errors} }  : 0;
        my $applied = ref($action_plan->{applied}) eq 'ARRAY' ? scalar @{ $action_plan->{applied} } : 0;
        my $apply_errors = ref($action_plan->{apply_errors}) eq 'ARRAY' ? scalar @{ $action_plan->{apply_errors} } : 0;
        my $has_apply_result = exists $action_plan->{applied_ok} || $applied || $apply_errors;

        $stream->write("  script_ok: " . ($script_result->{ok} ? 'yes' : 'no') . "\r\n");
        $stream->write("  action_plan_ok: " . ($action_plan->{ok} ? 'yes' : 'no') . "\r\n");
        $stream->write("  planned_actions: $planned\r\n");
        $stream->write("  action_errors: $errors\r\n");
        # mb191-B1: expose ScriptActionRunner apply results in read-only partyline status.
        if ($has_apply_result) {
            $stream->write("  applied_ok: " . ($action_plan->{applied_ok} ? 'yes' : 'no') . "\r\n");
            $stream->write("  applied_actions: $applied\r\n");
            $stream->write("  apply_errors: $apply_errors\r\n");
        }
        return;
    }

    my $timeout = $script_result->{timeout} ? 'yes' : 'no';
    my $exit = defined($script_result->{exit_code}) ? $script_result->{exit_code} : 'n/a';
    my $planned = ref($action_plan->{planned}) eq 'ARRAY' ? $action_plan->{planned} : [];
    my $errors  = ref($action_plan->{errors})  eq 'ARRAY' ? $action_plan->{errors}  : [];
    my $applied = ref($action_plan->{applied}) eq 'ARRAY' ? $action_plan->{applied} : [];
    my $apply_errors = ref($action_plan->{apply_errors}) eq 'ARRAY' ? $action_plan->{apply_errors} : [];
    my $has_apply_result = exists $action_plan->{applied_ok} || @$applied || @$apply_errors;

    $stream->write("  script_ok: " . ($script_result->{ok} ? 'yes' : 'no') . "\r\n");
    $stream->write("  script_timeout: $timeout\r\n");
    $stream->write("  script_exit_code: $exit\r\n");
    $stream->write("  command_filter: " . ($filter_on ? 'enabled' : 'disabled') . "\r\n");
    if ($filter_on) {
        my $filter_text = @filter_list ? join(',', @filter_list) : 'none';
        $stream->write("  allowed_commands: $filter_text\r\n");
    }
    $stream->write("  command_routes: " . ($routes_on ? 'enabled' : 'disabled') . "\r\n");
    if ($routes_on) {
        my @route_pairs = map { $_ . '=' . ($route_map->{$_} // '') } @route_list;
        my $route_text = @route_pairs ? join(',', @route_pairs) : 'none';
        $stream->write("  route_map: $route_text\r\n");
    }
    $stream->write("  action_mode: $action_mode\r\n");
    $stream->write("  allow_irc: " . ($allow_irc ? 'yes' : 'no') . "\r\n");
    $stream->write("  apply_require_scope: " . ($scope_guard ? 'yes' : 'no') . "\r\n");
    $stream->write("  apply_scope_restricted: " . ($scope_restricted ? 'yes' : 'no') . "\r\n");
    if (defined $scope_warning && length "$scope_warning") {
        $scope_warning =~ s/[\r\n]+/ /g;
        $stream->write("  apply_scope_warning: $scope_warning\r\n");
    }
    $stream->write("  planned_actions:\r\n");

    if (!@$planned) {
        $stream->write("    none\r\n");
    }
    else {
        my $idx = 0;
        for my $action (@$planned) {
            $idx++;
            my $type = defined($action->{type}) ? $action->{type} : '?';
            my $target = defined($action->{target}) ? $action->{target} : '';
            my $text = defined($action->{text}) ? $action->{text} : '';
            $text =~ s/[\r\n]+/ /g;
            $text = substr($text, 0, 160) . '...' if length($text) > 160;
            $stream->write("    $idx. type=$type target=$target text=$text\r\n");
        }
    }

    $stream->write("  action_errors:\r\n");
    if (!@$errors) {
        $stream->write("    none\r\n");
    }
    else {
        for my $err (@$errors) {
            my $index = defined($err->{index}) ? $err->{index} : '?';
            my $msg = defined($err->{error}) ? $err->{error} : 'unknown error';
            $msg =~ s/[\r\n]+/ /g;
            $stream->write("    index=$index error=$msg\r\n");
        }
    }

    if ($has_apply_result) {
        $stream->write("  applied_ok: " . ($action_plan->{applied_ok} ? 'yes' : 'no') . "\r\n");

        $stream->write("  applied_actions:\r\n");
        if (!@$applied) {
            $stream->write("    none\r\n");
        }
        else {
            for my $item (@$applied) {
                my $index = defined($item->{index}) ? $item->{index} : '?';
                my $type = defined($item->{type}) ? $item->{type} : '?';
                my $target = defined($item->{target}) ? $item->{target} : '';
                $target =~ s/[\r\n]+/ /g;
                $stream->write("    index=$index type=$type target=$target\r\n");
            }
        }

        $stream->write("  apply_errors:\r\n");
        if (!@$apply_errors) {
            $stream->write("    none\r\n");
        }
        else {
            for my $err (@$apply_errors) {
                my $index = defined($err->{index}) ? $err->{index} : '?';
                my $type = defined($err->{type}) ? $err->{type} : '?';
                my $msg = defined($err->{error}) ? $err->{error} : 'unknown error';
                $msg =~ s/[\r\n]+/ /g;
                $stream->write("    index=$index type=$type error=$msg\r\n");
            }
        }
    }

    return;
}


# ---------------------------------------------------------------------------
# .plugins [loaded|config] - read-only PluginManager visibility
sub _cmd_plugins {
    my ($self, $stream, $id, $arg) = @_;

    $arg //= '';
    $arg =~ s/^\s+|\s+$//g;
    my $mode = lc($arg || 'summary');

    my $bot = $self->{bot};
    unless ($bot && $bot->can('plugin_manager') && $bot->plugin_manager) {
        $stream->write("PluginManager: not initialized\r\n");
        return;
    }

    my $pm = $bot->plugin_manager;

    # Read-only Partyline visibility for the active PluginManager state. This
    # command does not load, unload, enable, or disable anything.
    my $autoload = eval { $bot->can('plugin_autoload_enabled') ? $bot->plugin_autoload_enabled : 0 } ? 'enabled' : 'disabled';
    my @all      = eval { $pm->list } ? $pm->list : ();
    my @enabled  = eval { $pm->list(enabled => 1) } ? $pm->list(enabled => 1) : ();
    my @disabled = eval { $pm->list(enabled => 0) } ? $pm->list(enabled => 0) : ();

    if ($mode eq 'config') {
        $stream->write("Plugin config:\r\n");
        $stream->write("  autoload: $autoload\r\n");

        if ($bot && $bot->can('plugin_autoload_enabled') && !$bot->plugin_autoload_enabled) {
            $stream->write("  boot loading: skipped unless plugins.AUTOLOAD=1 (or compatible key)\r\n");
        }
        else {
            $stream->write("  boot loading: enabled by configuration gate\r\n");
        }

        $stream->write("  autoload keys: plugins.AUTOLOAD, plugins.autoload, plugins.ENABLED_AUTOLOAD, PLUGIN_AUTOLOAD, PLUGINS_AUTOLOAD\r\n");
        $stream->write("  plugin list keys: plugins.ENABLED, plugins.enabled, plugins.PLUGINS, plugins.plugins, PLUGINS_ENABLED, PLUGIN_ENABLED, PLUGINS\r\n");
        $stream->write("  module safety: Perl module names only, no paths\r\n");
        return;
    }

    if ($mode ne 'summary' && $mode ne 'loaded') {
        $stream->write("Usage: .plugins [loaded|config]\r\n");
        return;
    }

    $stream->write("PluginManager:\r\n");
    $stream->write("  autoload: $autoload\r\n");
    $stream->write("  registered: " . scalar(@all) . "\r\n");
    $stream->write("  enabled: " . scalar(@enabled) . "\r\n");
    $stream->write("  disabled: " . scalar(@disabled) . "\r\n");

    if (!@all) {
        $stream->write("  plugins: none loaded\r\n");
        return;
    }

    $stream->write("Loaded plugins:\r\n");
    for my $entry (@all) {
        next unless ref($entry) eq 'HASH';

        my $name    = $entry->{name}    // '(unknown)';
        my $module  = $entry->{module}  // '-';
        my $version = defined $entry->{version} ? $entry->{version} : '-';
        my $state   = $entry->{enabled} ? 'enabled' : 'disabled';
        my $desc    = $entry->{description} // '';

        $stream->write("  - $name [$state] module=$module version=$version");
        $stream->write(" - $desc") if length $desc;
        $stream->write("\r\n");
    }

    return;
}



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
      . "  .plugins [loaded|config] - show plugin manager/autoload status\r\n"
      . "  .scriptdryrun [status|last|config] - show external script bridge status and last run\r\n"
      . "  .ai <prompt>        - ask Claude (subcommands: quota, stats, models, history, reset, forget, pin, summary)\r\n"
      . "  .aistats            - show Claude AI usage stats\r\n"
      . "  .top [n]            - top N speakers across all channels (default 5)\r\n"
      . "  .seen <nick>        - last activity for a nick in channel logs\r\n"
      . "  .logs <#chan> [n]   - show last N lines from CHANNEL_LOG (default 10)\r\n"
      . "  .nickinfo <nick>    - show DB info for a registered nick\r\n"
      . "  .kick <nick> <#chan> [reason] - kick a nick from channel\r\n"
      . "  .unmute <nick>               - lift a CC3/AF7 temporary nick mute\r\n"
      . "  .kv set|get|del|list [key] [val]- persistent in-memory key-value store\r\n"
      . "  .floodset <#chan> [w] [n] [s]- override AF4 params (window/max/silence)\r\n"
      . "  .cmdcooldown <#chan> <cmd> <s>- set per-cmd cooldown in seconds (CC1)\r\n"
      . "  .netsplit                    - show netsplit state and channel nicklist status\r\n"
      . "  .floodstatus                 - show live antiflood state (AF1/AF3/AF4)\r\n"
      . "  .flushcooldown [#chan]        - clear karma anti-spam cooldown\r\n"
      . "  .dbstats            - show DB connection and query stats\r\n"
      . "  .remind <nick> <#chan> <msg> - set a reminder from Partyline\r\n"
      . "  .karmahist [nick]   - show karma history for a channel or nick\r\n"
      . "  .persona [nick]     - view/clear Claude persona (all or specific nick)\r\n"
      . "  .quota [nick]       - show Claude rate limit (all or specific nick)\r\n"
      . "  .ai quota           - show your own Claude rate limit\r\n"
      . "  .stats [#chan]      - top 3 speakers + karma for a channel\r\n"
      . "  .karma <nick> [#chan] - show karma for a nick\r\n"
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
    # V1: delegate to _cmd_schedule list — single source of truth with next_run
    return $self->_cmd_schedule($stream, $id, 'list', undef);
}

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

# ---------------------------------------------------------------------------
# _seconds_to_human($secs) — format a duration as '3h 25m 12s' (SL1)
# ---------------------------------------------------------------------------
sub _seconds_to_human {
    my ($secs) = @_;
    $secs = int($secs // 0);
    return '0s' unless $secs > 0;
    my $d = int($secs / 86400); $secs %= 86400;
    my $h = int($secs / 3600);  $secs %= 3600;
    my $m = int($secs / 60);    $secs %= 60;
    my $s = $secs;
    return "${d}d ${h}h"  if $d;
    return "${h}h ${m}m"  if $h;
    return "${m}m ${s}s"  if $m;
    return "${s}s";
}

sub _cmd_schedule {
    my ($self, $stream, $id, $action, $name) = @_;
    my $bot   = $self->{bot};
    my $sched = $bot->{scheduler};

    # mb356-B2: keep the control command explicitly restricted even though the
    # current Partyline login gate already requires Master or Owner.
    my $level = $self->{users}{$id}{level};
    unless (defined($level) && $level <= 1) {
        $stream->write("Access denied: .schedule requires Master or Owner level.\r\n");
        return;
    }

    unless ($sched) {
        $stream->write("Scheduler not available.\r\n");
        return;
    }

    my $act = lc($action // 'list');

    my $find_info = sub {
        my ($wanted) = @_;
        return undef unless defined($wanted) && $wanted ne '';

        if ($sched->can('task_info')) {
            return $sched->task_info($wanted);
        }

        for my $info ($sched->all_info) {
            return $info if $info && ($info->{name} // '') eq $wanted;
        }
        return undef;
    };

    if ($act eq 'list' || !defined $action) {
        my @infos = $sched->all_info;
        unless (@infos) {
            $stream->write("No scheduled tasks.\r\n");
            return;
        }

        my $now = time();
        $stream->write(sprintf("%-28s %-9s %-8s %-6s %s\r\n",
            'Name', 'Interval', 'Status', 'Ticks', 'Next run'));
        $stream->write(("-" x 70) . "\r\n");

        for my $t (@infos) {
            my $next_str;
            if (!$t->{started}) {
                $next_str = 'stopped';
            }
            else {
                my $next = $t->{next_run} // 0;
                if ($next > 0) {
                    my $diff = $next - $now;
                    if ($diff <= 0) {
                        $next_str = 'imminent';
                    }
                    else {
                        my @nt = localtime($next);
                        $next_str = sprintf('%04d-%02d-%02d %02d:%02d:%02d (in %s)',
                            $nt[5] + 1900, $nt[4] + 1, $nt[3],
                            $nt[2], $nt[1], $nt[0], _seconds_to_human($diff));
                    }
                }
                else {
                    $next_str = 'soon';
                }
            }

            my $iv = $t->{interval} // 0;
            my $iv_str = $iv >= 3600 ? sprintf("%dh%02dm", int($iv/3600), int(($iv%3600)/60))
                       : $iv >= 60   ? sprintf("%dm%02ds", int($iv/60), $iv%60)
                       :               "${iv}s";
            $stream->write(sprintf("%-28s %-9s %-8s %-6d %s\r\n",
                $t->{name}, $iv_str,
                ($t->{started} ? 'running' : 'stopped'),
                $t->{ticks}, $next_str));
        }
        return;
    }

    if ($act eq 'status') {
        my $info = $find_info->($name);
        unless ($info) {
            $stream->write("Usage: .schedule status <task_name>\r\n");
            $stream->write("Tasks: " . join(', ', $sched->task_names) . "\r\n");
            return;
        }

        my $last;
        if ($info->{last_tick}) {
            my @lt = localtime($info->{last_tick});
            my $ago = time() - $info->{last_tick};
            $last = sprintf("%02d:%02d:%02d (%s ago)",
                $lt[2], $lt[1], $lt[0], _seconds_to_human($ago));
        }
        else {
            $last = 'never';
        }

        $stream->write("Task:     $info->{name}\r\n");
        $stream->write("Mode:     " . ($info->{mode} // 'periodic') . "\r\n");
        $stream->write("Interval: $info->{interval}s\r\n");
        $stream->write("Status:   " . ($info->{started} ? "running" : "stopped") . "\r\n");
        $stream->write("Ticks:    $info->{ticks}\r\n");
        $stream->write("Last run: $last\r\n");

        my $next_run_s;
        if (!$info->{started}) {
            $next_run_s = 'n/a (stopped)';
        }
        else {
            my $next = $info->{next_run} // 0;
            if ($next > 0) {
                my $diff = $next - time();
                if ($diff <= 0) {
                    $next_run_s = 'imminent';
                }
                else {
                    my @nt = localtime($next);
                    $next_run_s = sprintf('%04d-%02d-%02d %02d:%02d:%02d (in %s)',
                        $nt[5] + 1900, $nt[4] + 1, $nt[3],
                        $nt[2], $nt[1], $nt[0], _seconds_to_human($diff));
                }
            }
            else {
                $next_run_s = 'soon';
            }
        }
        $stream->write("Next run: $next_run_s\r\n");
        return;
    }

    unless (defined $name && $name ne '') {
        $stream->write("Usage: .schedule <list|status|start|stop|restart> [task_name]\r\n");
        return;
    }

    unless ($act eq 'start' || $act eq 'stop' || $act eq 'restart') {
        $stream->write("Unknown action '$act'. Use: list status start stop restart\r\n");
        return;
    }

    my $before = $find_info->($name);
    unless ($before) {
        $stream->write("Scheduler task '$name' not found.\r\n");
        return;
    }

    if ($act eq 'start' && $before->{started}) {
        $stream->write("Task '$name' is already running.\r\n");
        return;
    }

    if ($act eq 'stop' && !$before->{started}) {
        $stream->write("Task '$name' is already stopped.\r\n");
        return;
    }

    my $ok = eval {
        if ($act eq 'start') {
            $sched->start($name);
        }
        elsif ($act eq 'stop') {
            $sched->stop($name);
        }
        else {
            $sched->restart($name);
        }
    };

    if ($@ || !$ok) {
        my $err = $@ || 'scheduler returned failure';
        $err =~ s/\s+/ /g;
        $bot->{logger}->log(1,
            "Partyline .schedule $act $name failed: $err") if $bot->{logger};
        $stream->write("Scheduler action failed for '$name' ($act).\r\n");
        return;
    }

    my $verb = $act eq 'start' ? 'started'
             : $act eq 'stop'  ? 'stopped'
             :                   'restarted';
    $bot->{logger}->log(2,
        "Scheduler task '$name' $verb from Partyline") if $bot->{logger};
    $stream->write("Task '$name' $verb.\r\n");
    return;
}


# ---------------------------------------------------------------------------
# .status  - display the runtime status payload in the partyline session
# ---------------------------------------------------------------------------
sub _cmd_status {
    my ($self, $stream, $id) = @_;

    my $payload = eval { $self->_runtime_status_payload };
    if ($@) {
        my $err = $@;
        $self->_report_operation_error(
            $stream,
            'Partyline .status failed',
            'Status unavailable.',
            $err,
        );
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
    # IMP24: add global AF status
    my $bot_s = $self->{bot};
    my $gaf = $bot_s->{_global_af} // {};
    if (($gaf->{silenced_until} // 0) > time()) {
        my $rem = $gaf->{silenced_until} - time();
        $stream->write("GlobalAF: SILENCED for ${rem}s\r\n");
    } else {
        my $hits = scalar @{ $gaf->{hits} // [] };
        $stream->write("GlobalAF: ok ($hits msgs in window)\r\n");
    }

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
        my $err = $@;
        $self->_report_operation_error(
            $stream,
            'Partyline .metrics failed',
            'Metrics render error.',
            $err,
        );
        return;
    }

    # IMP23: show only non-zero metrics, sorted, with category grouping
    my %grouped;
    for my $line (split /\n/, $rendered) {
        next if $line =~ /^#/ || $line =~ /^\s*$/;
        if ($line =~ /^(\w+?)(?:\{[^}]*\})?\s+([\d.e+\-]+)/) {
            my ($metric, $val) = ($1, $2);
            next if $val == 0;          # IMP23: skip zeroes
            my ($cat) = $metric =~ /^([^_]+(?:_[^_]+)?)_/;
            $cat //= 'other';
            push @{ $grouped{$cat} }, $line;
        }
    }
    $stream->write("--- Prometheus metrics (non-zero) ---\r\n");
    for my $cat (sort keys %grouped) {
        $stream->write("[$cat]\r\n");
        $stream->write("  $_ \r\n") for @{ $grouped{$cat} };
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
    # Safe Partyline top:
    #   .top              -> usage only, no implicit full scan
    #   .top #chan [n]   -> top N on explicit channel
    #   .top all [n]     -> explicit all-channel aggregate
    my ($self, $stream, $id, $args) = @_;

    my $bot = $self->{bot};
    my $dbh = eval { $bot->{db}->ensure_connected } // $bot->{dbh};
    unless ($dbh) {
        $stream->write("DB unavailable.\r\n");
        return;
    }

    if (!defined($args) || $args !~ /\S/) {
        $stream->write("Usage: .top <#chan> [n] or .top all [n] (default n=5, max=15)\r\n");
        $stream->write("Example: .top #teuk 10\r\n");
        return;
    }

    my $all_chans = ($args =~ /\ball\b/i) ? 1 : 0;
    my ($chan) = ($args =~ /(#\S+)/i);

    # mb122-B2: avant ce fix, ($args =~ /(\d+)/) matchait le PREMIER chiffre
    # rencontre, donc `.top #chan42 10` produisait n=42 (clampe a 15).
    # On retire d'abord le nom du canal et le mot "all" pour ne considerer
    # que les arguments numeriques restants.
    my $args_for_n = $args;
    $args_for_n =~ s/#\S+//g;
    $args_for_n =~ s/\ball\b//gi;
    # mb124-B4: only accept standalone numeric tokens as n.
    # Avoid treating arbitrary words such as foo10bar as a valid limit.
    my ($n) = ($args_for_n =~ /(?:^|\s)(\d+)(?=\s|$)/);
    $n //= 5;
    $n = 5  if !$n || $n < 1;
    $n = 15 if $n > 15;

    unless ($all_chans || (defined($chan) && $chan =~ /^#/)) {
        $stream->write("Usage: .top <#chan> [n] or .top all [n] (default n=5, max=15)\r\n");
        $stream->write("Example: .top #teuk 10\r\n");
        return;
    }

    my ($sth, $label);
    if ($all_chans) {
        $sth = $dbh->prepare(
            "SELECT cl.nick, COUNT(*) AS cnt FROM CHANNEL_LOG cl"
            . " GROUP BY cl.nick ORDER BY cnt DESC LIMIT ?"
        );
        unless ($sth && $sth->execute($n)) {
            $stream->write("DB error.\r\n");
            $sth->finish if $sth;
            return;
        }
        $label = "Top $n speakers (all channels)";
    }
    else {
        $sth = $dbh->prepare(
            "SELECT cl.nick, COUNT(*) AS cnt FROM CHANNEL_LOG cl"
            . " JOIN CHANNEL c ON c.id_channel = cl.id_channel"
            . " WHERE c.name = ? GROUP BY cl.nick ORDER BY cnt DESC LIMIT ?"
        );
        unless ($sth && $sth->execute($chan, $n)) {
            $stream->write("DB error.\r\n");
            $sth->finish if $sth;
            return;
        }
        $label = "Top $n on $chan";
    }

    my $total_pl = 0;
    my $sth_t = $all_chans
        ? $dbh->prepare('SELECT COUNT(*) AS t FROM CHANNEL_LOG')
        : $dbh->prepare('SELECT COUNT(*) AS t FROM CHANNEL_LOG cl'
                      . ' JOIN CHANNEL c ON c.id_channel = cl.id_channel'
                      . ' WHERE c.name = ?');

    if ($sth_t) {
        my $ok = $all_chans ? $sth_t->execute : $sth_t->execute($chan);
        if ($ok) {
            my $r = $sth_t->fetchrow_hashref;
            $total_pl = $r->{t} // 0;
        }
        $sth_t->finish;
    }

    $stream->write("$label:\r\n");

    my $rank = 1;
    while (my $row = $sth->fetchrow_hashref) {
        my $pct = ($total_pl && $total_pl > 0)
            ? sprintf(' (%.1f%%)', 100 * $row->{cnt} / $total_pl)
            : '';

        $stream->write(sprintf("  %2d. %-20s %d msgs%s\r\n",
            $rank++, $row->{nick}, $row->{cnt}, $pct));
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

    # mb93-B3: valider le nick destinataire (cohérence avec mb92-B3 dans UserCommands)
    {
        my $target_known = 0;
        # Vérifier nicklist en mémoire sur tous les canaux
        my $chans_chk = $bot->{channels} // {};
        for my $cname (keys %$chans_chk) {
            my @nicks = eval { $bot->gethChannelsNicksOnChan($cname) };
            if (grep { defined($_) && lc($_) eq lc($target) } @nicks) {
                $target_known = 1; last;
            }
        }
        unless ($target_known) {
            my $sth_seen = $dbh->prepare('SELECT 1 FROM USER_SEEN WHERE nick = ? LIMIT 1');
            if ($sth_seen && $sth_seen->execute(lc($target))) {
                $target_known = 1 if $sth_seen->fetchrow_array;
                $sth_seen->finish;
            }
        }
        unless ($target_known) {
            my $sth_user = $dbh->prepare('SELECT 1 FROM USER WHERE nickname = ? LIMIT 1');
            if ($sth_user && $sth_user->execute(lc($target))) {
                $target_known = 1 if $sth_user->fetchrow_array;
                $sth_user->finish;
            }
        }
        unless ($target_known) {
            $stream->write("Unknown nick '$target'. Remind not created.\r\n");
            return;
        }
    }

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
        $stream->write("Usage: .seen <nick>  (wildcard: .seen teu*)\r\n"); return;
    }

    # mb94-B1 / mb127-B3: support wildcard (* -> %, ? -> _) while escaping
    # literal SQL LIKE metacharacters from the user input.
    if ($target =~ /[*?]/) {
        my $like = '';
        for my $ch (split //, lc($target)) {
            if    ($ch eq '*') { $like .= '%';  }
            elsif ($ch eq '?') { $like .= '_';  }
            elsif ($ch eq '!') { $like .= '!!'; }
            elsif ($ch eq '%') { $like .= '!%'; }
            elsif ($ch eq '_') { $like .= '!_'; }
            else               { $like .= $ch;  }
        }
        my $sth = $dbh->prepare(q{
            SELECT nick, channel, event_type, seen_at
            FROM USER_SEEN WHERE nick LIKE ? ESCAPE '!'
            ORDER BY seen_at DESC LIMIT 5
        });
        unless ($sth && $sth->execute($like)) {
            $stream->write("DB error.\r\n"); $sth->finish if $sth; return;
        }
        my @rows;
        while (my $r = $sth->fetchrow_hashref) { push @rows, $r; }
        $sth->finish;
        unless (@rows) {
            $stream->write("No nicks matching '$target'.\r\n"); return;
        }
        for my $r (@rows) {
            $stream->write(sprintf("  %-20s  %s  on %s  (%s)\r\n",
                $r->{nick}, $r->{seen_at}, $r->{channel}, $r->{event_type}));
        }
        return;
    }

    my $sth = $dbh->prepare(q{
        SELECT nick, channel, event_type, seen_at, last_msg
        FROM USER_SEEN WHERE nick = ? ORDER BY seen_at DESC LIMIT 1
    });
    # mb100-B1: USER_SEEN stocke les nicks en lc() — normaliser $target
    unless ($sth && $sth->execute(lc($target))) {
        $stream->write("DB error.\r\n"); $sth->finish if $sth; return;
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
        $stream->write("DB error.\r\n"); $sth->finish if $sth; return;
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

    unless ($dbh) {
        $stream->write("DB error.\r\n");
        return;
    }

    my ($target, $chan) = split /\s+/, ($args // ''), 2;
    unless ($target) {
        $stream->write("Usage: .karma <nick> [#channel]\r\n");
        return;
    }

    my $target_lc = lc($target);

    # Explicit channel: keep old useful behavior and show zero if no row exists.
    if (defined $chan && $chan =~ /^#/) {
        my $sth_c = $dbh->prepare(
            'SELECT id_channel, name FROM CHANNEL WHERE LOWER(name) = LOWER(?)'
        );

        unless ($sth_c && $sth_c->execute($chan)) {
            $stream->write("DB error.\r\n");
            $sth_c->finish if $sth_c;
            return;
        }

        my $c = $sth_c->fetchrow_hashref;
        $sth_c->finish;

        unless ($c && $c->{id_channel}) {
            $stream->write("Channel $chan not found.\r\n");
            return;
        }

        my $sth = $dbh->prepare(
            'SELECT score FROM KARMA WHERE id_channel = ? AND nick = ?'
        );

        unless ($sth && $sth->execute($c->{id_channel}, $target_lc)) {
            $stream->write("DB error.\r\n");
            $sth->finish if $sth;
            return;
        }

        my $row = $sth->fetchrow_hashref;
        $sth->finish;

        my $score = $row ? ($row->{score} // 0) : 0;
        my $sign  = $score > 0 ? '+' : '';

        $stream->write("$target on $c->{name}: karma ${sign}${score}\r\n");
        return;
    }

    # No explicit channel: show only non-zero karma across all channels.
    # This avoids the old misleading behavior: first joined channel, often 0.
    my $sth = $dbh->prepare(q{
        SELECT c.name AS channel, k.score AS score
        FROM KARMA k
        JOIN CHANNEL c ON c.id_channel = k.id_channel
        WHERE LOWER(k.nick) = ?
          AND k.score <> 0
        ORDER BY ABS(k.score) DESC, k.score DESC, c.name ASC
    });

    unless ($sth && $sth->execute($target_lc)) {
        $stream->write("DB error.\r\n");
        $sth->finish if $sth;
        return;
    }

    my @rows;
    while (my $r = $sth->fetchrow_hashref) {
        push @rows, $r;
    }
    $sth->finish;

    unless (@rows) {
        $stream->write("$target has no karma on any channel.\r\n");
        return;
    }

    $stream->write("Karma for $target:\r\n");
    for my $r (@rows) {
        my $score = $r->{score} // 0;
        my $sign  = $score > 0 ? '+' : '';
        $stream->write(sprintf("  %-25s %s%d\r\n",
            $r->{channel} // '?', $sign, $score));
    }
}

# mb368-B1: one checked path for both Partyline configuration reload commands.
# Mediabot::Conf exposes reload(), not the historical/non-existent load().
sub _reload_configuration_file {
    my ($self) = @_;

    my $conf = $self->{bot}{conf};
    die "configuration object unavailable\n" unless $conf;
    die "configuration object has no reload method\n"
        unless $conf->can('reload');

    my $ok = $conf->reload();
    die "configuration reload returned failure\n" unless $ok;

    return 1;
}

# ---------------------------------------------------------------------------
# .reloadconf  - reload only the configuration file in place
# ---------------------------------------------------------------------------
sub _cmd_reloadconf {
    my ($self, $stream, $id) = @_;

    my $ok = eval { $self->_reload_configuration_file() };
    if ($ok) {
        $stream->write("Configuration reloaded.\r\n");
        return 1;
    }

    my $err = $@ || 'configuration reload returned failure';
    return $self->_report_operation_error(
        $stream,
        'Partyline .reloadconf failed',
        'Configuration reload failed.',
        $err,
    );
}

# ---------------------------------------------------------------------------
# .reload  - Owner-only alias for an in-place configuration file reload
# ---------------------------------------------------------------------------
sub _cmd_reload {
    my ($self, $stream, $id) = @_;
    my $session = $self->{users}{$id} // {};
    unless (($session->{level} // 99) <= 0) {  # Owner only
        $stream->write("Permission denied (Owner required).\r\n"); return;
    }

    my $ok = eval { $self->_reload_configuration_file() };
    if ($ok) {
        my $logger = $self->{bot}{logger};
        eval {
            $logger->log(2, "Partyline: config reloaded by " . ($session->{login} // '?'))
                if $logger && $logger->can('log');
            1;
        };
        $stream->write("Configuration reloaded.\r\n");
        return 1;
    }

    my $err = $@ || 'configuration reload returned failure';
    return $self->_report_operation_error(
        $stream,
        'Partyline .reload failed',
        'Reload failed.',
        $err,
    );
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
        $stream->write("Usage: .ai <prompt> | .ai reset | .ai history | .ai quota | .ai stats | .ai models | .ai forget | .ai pin [clear|text] | .ai summary [n]\r\n");
        return;
    }

    $prompt =~ s/^\s+|\s+$//g;

    my $session = $self->{users}{$id} // {};
    my $pl_nick = $session->{login} // 'partyline';

    # Resolve a stable Partyline AI scope. We use the first active joined
    # channel when possible, otherwise a dedicated partyline scope.
    my $bot_nick = eval { $bot->{irc}->nick_folded } // '';
    my $chan;
    for my $name (sort keys %{ $bot->{channels} || {} }) {
        my @n = eval { $bot->gethChannelsNicksOnChan($name) };
        if (grep { lc($_) eq lc($bot_nick) } @n) {
            $chan = $name;
            last;
        }
    }
    $chan //= 'partyline';

    my ($subcmd, $rest) = split /\s+/, $prompt, 2;
    $subcmd = lc($subcmd // '');
    $rest //= '';

    # .ai reset — clear history for this Partyline AI scope.
    # DD9: .ai status — show session + char + persona counts

    if ($subcmd eq 'status') {
        my $hist    = $bot->{_claude_history} // {};
        my $pins    = $bot->{_claude_pinned}  // {};
        my $n_h     = scalar keys %$hist;
        my $n_p     = scalar keys %$pins;
        my $n_per   = scalar keys %{ $bot->{_claude_persona} // {} };
        my $chars   = 0;
        $chars += length($_->{content}//'') for map { @{ $hist->{$_} // [] } } keys %$hist;
        my $ck = $chars > 1000 ? sprintf('~%.1fk chars', $chars/1000) : "$chars chars";
        $stream->write("Claude: $n_h session(s) ($ck), $n_p pinned, $n_per persona(s).\r\n");
        return;
    }

    if ($subcmd eq 'reset') {
        my $hist_key = "$pl_nick\x00$chan";
        delete $bot->{_claude_history}{$hist_key};
        $stream->write("Conversation history cleared.\r\n");
        return;
    }

    # .ai forget — clear history, persona and pinned context for this scope.
    if ($subcmd eq 'forget') {
        my $hist_key_raw = "$pl_nick\x00$chan";
        my $hist_key_lc  = lc($pl_nick) . "\x00$chan";

        my $had = 0;
        for my $key ($hist_key_raw, $hist_key_lc) {
            $had ||= exists $bot->{_claude_history}{$key};
            $had ||= exists $bot->{_claude_persona}{$key};
            $had ||= exists $bot->{_claude_pinned}{$key};

            delete $bot->{_claude_history}{$key};
            delete $bot->{_claude_persona}{$key};
            delete $bot->{_claude_pinned}{$key};
        }

        $stream->write($had
            ? "Claude history, persona and pinned context cleared for $pl_nick on $chan.\r\n"
            : "No active Claude session found for $pl_nick on $chan.\r\n");
        return;
    }

    # .ai history — show current context.
    if ($subcmd eq 'history') {
        # AA15: 'history clear [nick]' — wipe history
        if (defined $rest && $rest =~ /^clear(?:\s+(\S+))?$/i) {
            my $tgt = defined $1 ? lc($1) : $pl_nick;
            my $cleared = 0;
            for my $k (keys %{ $bot->{_claude_history} // {} }) {
                my ($nk) = split /\x00/, $k, 2;
                if (lc($nk) eq $tgt) {
                    delete $bot->{_claude_history}{$k};
                    delete $bot->{_ai_last_active}{$k} if $bot->{_ai_last_active};
                    $cleared++;
                }
            }
            $stream->write("Cleared $cleared history session(s) for $tgt\r\n");
            return;
        }
        my $hist_key = "$pl_nick\x00$chan";
        my $history  = $bot->{_claude_history}{$hist_key} // [];

        unless (@$history) {
            $stream->write("No conversation history.\r\n");
            return;
        }

        # IMP13: also show estimated size in chars
        my $hist_chars = 0;
        $hist_chars += length($_->{content} // '') for @$history;
        my $hist_exchanges = int(scalar(@$history) / 2);
        # CC20: show exchanges + char count
        my $_cc20_chars = 0;
        $_cc20_chars += length($_->{content}//'') for @$history;
        my $_cc20_ex = int(scalar(@$history)/2);
        $stream->write(scalar(@$history)
            . " message(s) in context"
            . " ($_cc20_ex exchange(s), ~$_cc20_chars chars):\r\n");
        my @display = @$history > 6 ? @{$history}[-6..-1] : @$history;

        for my $msg (@display) {
            my $role    = $msg->{role}    // '?';
            my $content = $msg->{content} // '';
            $content = substr($content, 0, 120) . '...' if length($content) > 120;
            $stream->write("  [$role] $content\r\n");
        }
        return;
    }

    # .ai quota — show own Claude rate limit.
    if ($subcmd eq 'quota') {
        return $self->_cmd_quota($stream, $id, lc($pl_nick));
    }

    # .ai stats — same idea as .aistats, but available as a real .ai subcommand.
    if ($subcmd eq 'stats') {
        my $reqs = eval { $bot->{metrics}->get('mediabot_claude_requests_total') } // 0;
        my $errs = eval { $bot->{metrics}->get('mediabot_claude_errors_total') }   // 0;
        my $rl   = eval { $bot->{metrics}->get('mediabot_claude_ratelimit_total') } // 0;
        my $hc   = scalar keys %{ $bot->{_claude_history} // {} };
        my $pc   = scalar keys %{ $bot->{_claude_persona} // {} };
        my $pin  = scalar keys %{ $bot->{_claude_pinned}  // {} };

        $stream->write("Claude stats:\r\n");
        $stream->write("  Requests     : $reqs\r\n");
        $stream->write("  Errors       : $errs\r\n");
        $stream->write("  Rate-limited : $rl\r\n");
        $stream->write("  Histories    : $hc\r\n");
        $stream->write("  Personas     : $pc\r\n");
        $stream->write("  Pinned ctx   : $pin\r\n");
        return;
    }

    # .ai model / .ai models — show known model list and current config.
    if ($subcmd eq 'model' || $subcmd eq 'models') {
        my @known = qw(
            claude-opus-4-6
            claude-sonnet-4-6
            claude-haiku-4-5-20251001
        );

        my $current = eval { $bot->{conf}->get('anthropic.MODEL') } || 'unknown';
        my @labeled = map { $_ eq $current ? "$_ (current)" : $_ } @known;

        $stream->write("Current Claude model: $current\r\n");
        $stream->write("Known Claude models:\r\n");
        $stream->write("  $_\r\n") for @labeled;
        return;
    }

    # .ai pin            — show pinned context
    # .ai pin clear      — clear pinned context
    # .ai pin <text>     — set pinned context
    if ($subcmd eq 'pin' && (($rest // '') =~ /^list$/i || ($rest // '') eq '')) {
        # AA10: '.ai pin list' or '.ai pin' alone → list all active pins
        if (($rest // '') =~ /^list$/i || ($rest // '') eq '') {
            my $pins = $bot->{_claude_pinned} // {};
            unless (%$pins) { $stream->write("No active pins.\r\n"); }
            else {
                $stream->write("Active Claude pins:\r\n");
                for my $key (sort keys %$pins) {
                    my ($nk,$ck) = split /\x00/, $key, 2;
                    $stream->write(sprintf("  %-15s %-12s %.60s\r\n",
                        $nk, $ck, $pins->{$key}));
                }
            }
            return;
        }
    }
    if ($subcmd eq 'pin') {
        my $pin_key = lc($pl_nick) . "\x00$chan";
        my $action = $rest;
        $action =~ s/^\s+|\s+$//g;

        if ($action eq '') {
            my $current = $bot->{_claude_pinned}{$pin_key};
            $stream->write($current
                ? "Pinned context for $pl_nick on $chan: $current\r\n"
                : "No pinned context for $pl_nick on $chan.\r\n");
            return;
        }

        if (lc($action) eq 'clear') {
            delete $bot->{_claude_pinned}{$pin_key};
            $stream->write("Pinned context cleared for $pl_nick on $chan.\r\n");
            return;
        }

        # IMP9: raised to 500 chars max (was 300), warn if truncated
        my $was_long = length($action) > 500;
        my $pinned   = $was_long ? substr($action, 0, 500) : $action;
        $bot->{_claude_pinned}{$pin_key} = $pinned;
        my $notice = $was_long
            ? "Pinned context set (truncated to 500 chars): $pinned"
            : "Pinned context set: $pinned";
        $stream->write("$notice\r\n");
        return;
    }

    # .ai summary [n] — summarize recent CHANNEL_LOG messages for the resolved scope.
    if ($subcmd eq 'summary') {
        my $n_msgs = ($rest =~ /^\s*(\d+)/) ? int($1) : 10;
        $n_msgs = 5  if $n_msgs < 5;
        $n_msgs = 50 if $n_msgs > 50;

        if (!defined $chan || $chan eq 'partyline') {
            $stream->write("No IRC channel available for summary.\r\n");
            return;
        }

        my $dbh = eval { $bot->{db}->ensure_connected } // $bot->{dbh};
        unless ($dbh) {
            $stream->write("DB error.\r\n");
            return;
        }

        # mb348-B1: contexte IA = vraie conversation -> event_type IN ('public','action')
        # (et non publictext IS NOT NULL qui inclut join/part/kick/mode/topic).
        my $sth = $dbh->prepare(q{
            SELECT cl.nick, cl.publictext AS text
            FROM CHANNEL_LOG cl
            JOIN CHANNEL c ON c.id_channel = cl.id_channel
            WHERE c.name = ?
              AND cl.event_type IN ('public','action')
              AND cl.publictext <> ''
            ORDER BY cl.id_channel_log DESC
            LIMIT ?
        });

        unless ($sth && $sth->execute($chan, $n_msgs)) {
            $stream->write("DB error.\r\n");
            $sth->finish if $sth;
            return;
        }

        my @rows;
        while (my $r = $sth->fetchrow_hashref) {
            unshift @rows, "$r->{nick}: $r->{text}";
        }
        $sth->finish;

        unless (@rows) {
            $stream->write("No recent messages found on $chan.\r\n");
            return;
        }

        my $transcript = join("\n", @rows);
        my $summary_prompt = "Summarise this IRC conversation from $chan in 2-3 sentences:\n$transcript";

        my $output_fn = sub {
            my ($text) = @_;
            $text =~ s/[\r\n]+$//;
            $stream->write("[Claude] $text\r\n");
        };

        eval {
            Mediabot::External::claudeAI($bot, undef, $pl_nick, $chan,
                $output_fn, $summary_prompt);
        };
        if ($@) {
            my $err = $@;
            $self->_report_operation_error(
                $stream,
                'Partyline .ai summary failed',
                'AI request failed.',
                $err,
            );
        }
        return;
    }

    # Normal .ai <prompt> path.
    my $output_fn = sub {
        my ($text) = @_;
        $text =~ s/[\r\n]+$//;
        $stream->write("[Claude] $text\r\n");
    };

    eval {
        Mediabot::External::claudeAI($bot, undef, $pl_nick, $chan,
            $output_fn, split(/\s+/, $prompt));
    };
    if ($@) {
        my $err = $@;
        $self->_report_operation_error(
            $stream,
            'Partyline .ai failed',
            'AI request failed.',
            $err,
        );
    }
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
        my $now_p = time();
        for my $key (sort keys %$personas) {
            my ($nick_k, $chan_k) = split /\x00/, $key, 2;
            my $text = substr($personas->{$key}, 0, 55);
            # IMP25: show time since last use from _ai_last_active
            my $last_ts = $bot->{_ai_last_active}{$key} // 0;
            my $age_str = '';
            if ($last_ts > 0) {
                my $diff = $now_p - $last_ts;
                $age_str = $diff >= 3600
                    ? sprintf(' (%dh%02dm ago)', int($diff/3600), int(($diff%3600)/60))
                    : sprintf(' (%dm ago)', int($diff/60));
            }
            $stream->write(sprintf("  %-15s %-12s %s...%s\r\n",
                $nick_k, $chan_k, $text, $age_str));
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

    # Keep .quota aligned with claudeAI() / !ai quota rate-limit settings.
    my $rate_max = eval { int($bot->{conf}->get('anthropic.RATE_MAX') // 5) } // 5;
    my $rate_window = eval { int($bot->{conf}->get('anthropic.RATE_WINDOW') // 60) } // 60;
    $rate_max = 1 if $rate_max < 1;
    $rate_window = 10 if $rate_window < 10;

    my $fmt_wait = sub {
        my ($wait) = @_;
        $wait = int($wait // 0);
        $wait = 0 if $wait < 0;
        return $wait >= 60
            ? sprintf('%dm %ds', int($wait/60), $wait % 60)
            : "${wait}s";
    };

    my $fmt_reset = sub {
        my ($entry) = @_;
        return '' unless $entry && defined $entry->{window};
        my $reset_at = $entry->{window} + $rate_window;
        my @rt = localtime($reset_at);
        return sprintf('resets %02d:%02d', $rt[2], $rt[1]);
    };

    if (!defined $args || $args !~ /\S/) {
        my $rl = $bot->{_claude_ratelimit} // {};
        unless (%$rl) {
            $stream->write("No active rate limit windows.\r\n");
            return;
        }

        $stream->write("Active Claude rate limit windows:\r\n");
        # A6: sort by nick then channel for readable output
        for my $key (sort {
                (split /\x00/, $a, 2)[0] cmp (split /\x00/, $b, 2)[0]
                || $a cmp $b
            } keys %$rl) {
            my $entry = $rl->{$key};
            next if ($now - ($entry->{window} // 0)) >= $rate_window;

            my ($nick_k, $chan_k) = split /\x00/, $key, 2;
            my $used = $entry->{count} // 0;
            my $remaining = $rate_max - $used;
            $remaining = 0 if $remaining < 0;

            my $wait = $rate_window - ($now - ($entry->{window} // $now));
            my $wait_h = $fmt_wait->($wait);
            my $reset_str = $fmt_reset->($entry);

            $stream->write(sprintf("  %-20s %-15s %d/%d req (%s left, %s)\r\n",
                $nick_k, $chan_k, $used, $rate_max, $wait_h, $reset_str));
        }
        return;
    }

    my $target = lc($args);
    $target =~ s/^\s+|\s+$//g;

    my $rl = $bot->{_claude_ratelimit} // {};
    my @found;

    for my $key (sort keys %$rl) {
        my ($nick_k, $chan_k) = split /\x00/, $key, 2;
        next unless lc($nick_k) eq $target;

        my $entry = $rl->{$key};
        next if ($now - ($entry->{window} // 0)) >= $rate_window;

        my $used = $entry->{count} // 0;
        my $remaining = $rate_max - $used;
        $remaining = 0 if $remaining < 0;

        my $wait = $rate_window - ($now - ($entry->{window} // $now));
        my $wait_h = $fmt_wait->($wait);
        my $reset_str = $fmt_reset->($entry);

        push @found, sprintf("  %-15s %d/%d req — %d remaining (%s left, %s)",
            $chan_k, $used, $rate_max, $remaining, $wait_h, $reset_str);
    }

    if (@found) {
        $stream->write("Claude quota for $target:\r\n");
        $stream->write("$_\r\n") for @found;
    }
    else {
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

    my $bot_start = getProcessStartTimestamp($bot, $now);

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
        $sth->finish if $sth;
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
            # G1/fix: guard undef $now_sth (prepare may fail when DB is down)
            my $secs = 0;
            if ($now_sth && $now_sth->execute($ban->{expires_at})) {
                my $r = $now_sth->fetchrow_hashref;
                $now_sth->finish;
                $secs = ($r && defined $r->{secs} && $r->{secs} > 0) ? $r->{secs} : 0;
            }
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
        $sth->finish if $sth;
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
            # Z4: human-readable age for DCC offers
            my $age_h = $age >= 60
                ? sprintf('%dm %ds', int($age/60), $age%60)
                : "${age}s";
            $stream->write(sprintf("  %-12s %-14s %-16s %-8s %s\r\n",
                $o->{type}      || '?',
                $o->{nick}      || '?',
                $o->{public_ip} || '?',
                $o->{port}      || '?',
                $age_h
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

    # EE3: bottom section — uptime, Claude sessions, memory, AF state
    $stream->write(("=" x 90) . "\r\n");
    my $started  = $bot->{metrics} ? ($bot->{metrics}{started} // time()) : time();
    my $uptime   = time() - $started;
    my $ud = int($uptime/86400); my $uh = int(($uptime%86400)/3600);
    my $um = int(($uptime%3600)/60);  my $us = $uptime%60;
    $stream->write(sprintf("Uptime: %dd %02dh%02dm%02ds\r\n", $ud,$uh,$um,$us));

    my $claude_sessions = scalar keys %{ $bot->{_claude_history} // {} };
    my $ai_cache        = scalar keys %{ $bot->{_claude_prompt_cache} // {} };
    $stream->write("Claude: $claude_sessions active session(s), $ai_cache cached prompt(s)\r\n");

    # IMP18/mb115: IRC command totals from real Prometheus counters.
    # Use public + private command counters; there is no aggregate IRC counter.
    if ($bot->{metrics}) {
        my $cmds_pub  = eval { $bot->{metrics}->get('mediabot_commands_public_total') } // 0;
        my $cmds_priv = eval { $bot->{metrics}->get('mediabot_commands_private_total') } // 0;
        my $cmds_pl   = eval { $bot->{metrics}->get('mediabot_commands_partyline_total') } // 0;
        my $msgs_out  = eval { $bot->{metrics}->get('mediabot_privmsg_out_total') } // 0;
        $stream->write("Commands: ${cmds_pub} IRC public, ${cmds_priv} IRC private, ${cmds_pl} partyline\r\n");
        $stream->write("Messages: ${msgs_out} PRIVMSG sent\r\n");
    }

    my $mutes   = scalar grep { ($bot->{_nick_mute}{$_} // 0) > time() }
                        keys %{ $bot->{_nick_mute} // {} };
    my $sil_af  = scalar grep { ($_->{silenced_until} // 0) > time() }
                        values %{ $bot->{_af} // {} };
    my $sil_cf  = scalar grep { ($_->{silenced_until} // 0) > time() }
                        values %{ $bot->{_chan_flood} // {} };
    $stream->write("Flood: $sil_af chan(s) AF-silenced, $sil_cf chan(s) CF-silenced, "
                 . "$mutes nick(s) muted\r\n");

    if (eval { require Scalar::Util::Numeric; 1 } || 1) {
        my $mem = 0;
        if (open my $fh, '<', '/proc/self/status') {
            while (<$fh>) { if (/^VmRSS:\s+(\d+)/) { $mem = int($1/1024); last; } }
            close $fh;
        }
        $stream->write("Memory: ${mem} MB RSS\r\n") if $mem;
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

    $bot->{logger}->log(2, "Partyline: $nick requested JOIN $chan" . ($key ? " (key: [redacted])" : ""));
    $stream->write("Joining $chan" . ($key ? " with key [redacted]" : "") . "...\r\n");
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

    # MB309: read the eval pipe asynchronously and reap the child without
    # ever blocking the IRC loop. User-supplied eval code can close STDOUT and
    # continue running; EOF on the pipe therefore does not prove process exit.
    my $eval_ctx = {
        lines            => [],
        truncated        => 0,
        timed_out        => 0,
        timeout_reported => 0,
        errors           => [],
        finalized        => 0,
        pipe_eof         => 0,
        wait_status      => undef,
    };

    my ($watchdog, $kill_timer, $reap_timer, $io);
    my ($finalize, $schedule_reap);

    my $remove_timer = sub {
        my ($timer_ref) = @_;
        return unless $timer_ref && $$timer_ref;

        my $timer = $$timer_ref;
        $$timer_ref = undef;
        eval { $timer->stop if $timer->can('stop') };
        eval { $bot->{loop}->remove($timer) };
    };

    my $report_timeout = sub {
        return if $eval_ctx->{timeout_reported}++;

        if ($self->{streams}{$id}) {
            $stream->write("--- timeout ---\r\n");
            $stream->write("Eval timed out after ${eval_timeout}s.\r\n");
        }

        $bot->{logger}->log(1,
            "Partyline: $nick eval timed out after ${eval_timeout}s");
    };

    $finalize = sub {
        return if $eval_ctx->{finalized}++;

        $remove_timer->(\$watchdog);
        $remove_timer->(\$kill_timer);
        $remove_timer->(\$reap_timer);
        eval { $bot->{loop}->remove($io) if $io };

        if ($eval_ctx->{timed_out}) {
            $report_timeout->();
            return;
        }

        my $status = $eval_ctx->{wait_status};
        if (defined $status) {
            my $signal = $status & 127;
            my $exit   = ($status >> 8) & 255;

            if ($signal && !@{ $eval_ctx->{errors} }) {
                push @{ $eval_ctx->{errors} },
                    "eval subprocess terminated by signal $signal";
            }
            elsif ($exit != 0 && !@{ $eval_ctx->{errors} }) {
                push @{ $eval_ctx->{errors} },
                    "eval subprocess exited with status $exit";
            }
        }

        return unless $self->{streams}{$id};

        $stream->write("--- eval output ---\r\n");
        if (@{ $eval_ctx->{lines} }) {
            $stream->write("$_\r\n") for @{ $eval_ctx->{lines} };
        }
        else {
            $stream->write("(no output)\r\n")
                unless @{ $eval_ctx->{errors} };
        }

        $stream->write("[... output truncated at 20 lines ...]\r\n")
            if $eval_ctx->{truncated};

        if (@{ $eval_ctx->{errors} }) {
            $stream->write("--- error ---\r\n");
            for my $err (@{ $eval_ctx->{errors} }) {
                $err =~ s/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]//g;
                $stream->write("$err\r\n");
            }
            $bot->{logger}->log(1, "Partyline: $nick eval error: "
                . join(' | ', @{ $eval_ctx->{errors} }));
        }
        else {
            $stream->write("--- ok ---\r\n");
            $bot->{logger}->log(1, "Partyline: $nick eval done");
        }
    };

    $schedule_reap = sub {
        return if $eval_ctx->{finalized};
        return if $reap_timer;

        my $waited = waitpid($pid, WNOHANG);
        if ($waited == $pid) {
            $eval_ctx->{wait_status} = $?;
            $finalize->();
            return;
        }

        if ($waited == -1) {
            push @{ $eval_ctx->{errors} }, "waitpid failed: $!"
                unless $eval_ctx->{timed_out};
            $finalize->();
            return;
        }

        $reap_timer = IO::Async::Timer::Countdown->new(
            delay     => 0.05,
            on_expire => sub {
                my $expired = $reap_timer;
                $reap_timer = undef;
                eval { $bot->{loop}->remove($expired) if $expired };
                $schedule_reap->();
            },
        );
        $bot->{loop}->add($reap_timer);
        $reap_timer->start;
    };

    # Parent-side watchdog. TERM and KILL are separated by an asynchronous
    # grace timer; no sleep/usleep is allowed in the IO::Async event loop.
    $watchdog = IO::Async::Timer::Countdown->new(
        delay     => $eval_timeout,
        on_expire => sub {
            return if $eval_ctx->{finalized};

            $eval_ctx->{timed_out} = 1;
            $report_timeout->();
            kill 'TERM', $pid;
            $schedule_reap->();

            $kill_timer = IO::Async::Timer::Countdown->new(
                delay     => 0.5,
                on_expire => sub {
                    return if $eval_ctx->{finalized};

                    my $waited = waitpid($pid, WNOHANG);
                    if ($waited == $pid) {
                        $eval_ctx->{wait_status} = $?;
                        $finalize->();
                        return;
                    }

                    if ($waited == -1) {
                        $finalize->();
                        return;
                    }

                    kill 'KILL', $pid;
                    $schedule_reap->();
                },
            );
            $bot->{loop}->add($kill_timer);
            $kill_timer->start;
        },
    );
    $bot->{loop}->add($watchdog);
    $watchdog->start;

    $io = IO::Async::Stream->new(
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
                $line = substr($line, 0, 497) . '...'
                    if length($line) > 500;

                if (@{ $eval_ctx->{lines} } < 20) {
                    push @{ $eval_ctx->{lines} }, $line;
                }
                else {
                    $eval_ctx->{truncated} = 1;
                }
            }

            if ($eof && !$eval_ctx->{pipe_eof}++) {
                # Preserve a final line that is not newline-terminated.
                if (length $$buffref) {
                    my $line = $$buffref;
                    $$buffref = '';
                    $line =~ s/\r//g;
                    $line =~ s/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]//g;
                    $line = substr($line, 0, 497) . '...'
                        if length($line) > 500;
                    if (@{ $eval_ctx->{lines} } < 20) {
                        push @{ $eval_ctx->{lines} }, $line;
                    }
                    else {
                        $eval_ctx->{truncated} = 1;
                    }
                }

                eval { $bot->{loop}->remove($s) };
                $schedule_reap->();
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
    # mb349-B1: .logs affiche un log de CONVERSATION ([ts] <nick> texte), donc on
    # ne montre que les vrais messages (event_type IN ('public','action')) et plus
    # publictext IS NOT NULL, qui faisait apparaître join/part/kick/mode/topic
    # comme si le nick les avait "dits" (ex. <bob> +o alice).
    my $sth = $dbh->prepare(q{
        SELECT cl.ts, cl.nick, cl.publictext AS text FROM CHANNEL_LOG cl
        JOIN CHANNEL c ON c.id_channel = cl.id_channel
        WHERE c.name = ? AND cl.event_type IN ('public','action')
        ORDER BY cl.id_channel_log DESC LIMIT ?
    });
    unless ($sth && $sth->execute($chan, $n)) {
        $stream->write("DB error.\r\n"); $sth->finish if $sth; return;
    }
    my @rows;
    while (my $r = $sth->fetchrow_hashref) { unshift @rows, $r; }
    $sth->finish;
    unless (@rows) { $stream->write("No logs found for $chan.\r\n"); return; }
    $stream->write("Last " . scalar(@rows) . " lines on $chan:\r\n");
    for my $r (@rows) {
        # X9: show full date if entry is not from today
        my $raw_ts = $r->{ts} // '';
        my $ts;
        if ($raw_ts =~ /^(\d{4}-\d{2}-\d{2})\s+(\d{2}:\d{2})/) {
            my ($date, $hhmm) = ($1, $2);
            my $today = do { my @t=localtime(time); sprintf('%04d-%02d-%02d',$t[5]+1900,$t[4]+1,$t[3]); };
            $ts = $date eq $today ? $hhmm : "$date $hhmm";
        } else {
            $ts = substr($raw_ts, 11, 5);
        }
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
    # mb109-B1: USER a 'nickname' pas 'nick', pas de email/USER_LOG/USER_HOST
    my $sth = $dbh->prepare(q{
        SELECT u.nickname, u.id_user, u.username, u.info1, u.info2,
               u.birthday, u.last_login,
               ul.description AS level
        FROM USER u
        JOIN USER_LEVEL ul ON ul.id_user_level = u.id_user_level
        WHERE LOWER(u.nickname) = ?
    });
    unless ($sth && $sth->execute($target)) {
        $stream->write("DB error.\r\n"); $sth->finish if $sth; return;
    }
    my $r = $sth->fetchrow_hashref; $sth->finish;
    unless ($r) {
        $stream->write("$target: not found in DB.\r\n"); return;
    }
    $stream->write("Nick     : $r->{nickname}\r\n");
    $stream->write("ID       : $r->{id_user}\r\n");
    $stream->write("Level    : " . ($r->{level}    // 'N/A') . "\r\n");
    $stream->write("Username : " . ($r->{username} // 'N/A') . "\r\n");
    $stream->write("Info1    : " . ($r->{info1}    // 'N/A') . "\r\n") if $r->{info1};
    $stream->write("Info2    : " . ($r->{info2}    // 'N/A') . "\r\n") if $r->{info2};
    $stream->write("Birthday : " . ($r->{birthday} // 'N/A') . "\r\n") if $r->{birthday};
    # Y1: compute age of last login
    my $ll = $r->{last_login} // '';
    if ($ll =~ /^(\d{4})-(\d{2})-(\d{2})/) {
        require Time::Local;
        my ($y,$mo,$d) = ($1,$2,$3);
        my $ep = eval { Time::Local::timelocal(0,0,12,$d,$mo-1,$y-1900) };
        if ($ep) {
            my $diff = int((time()-$ep)/86400);
            $ll .= $diff > 0 ? " (${diff}d ago)" : " (today)";
        }
    }
    $stream->write("Last login: " . ($ll || 'never') . "\r\n");
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
            # mb109-B1: USER a 'nickname' pas 'nick'
            my $sth = $dbh->prepare(q{
                SELECT u.nickname, ul.description AS level FROM USER u
                JOIN USER_CHANNEL uc ON uc.id_user = u.id_user
                JOIN CHANNEL c ON c.id_channel = uc.id_channel
                JOIN USER_LEVEL ul ON ul.id_user_level = u.id_user_level
                WHERE c.name = ?
            });
            if ($sth && $sth->execute($chan)) {
                while (my $r = $sth->fetchrow_hashref) {
                    $levels{lc $r->{nickname}} = $r->{level};
                }
                $sth->finish;
            }
        };
    }
    # FF3: fetch IRC modes (op/voice) from the IRC channel object
    my %irc_flag;
    eval {
        my $irc = $bot->{irc};
        if ($irc && $irc->is_connected) {
            my $irc_chan = $irc->channel($chan);
            if ($irc_chan) {
                for my $n ($irc_chan->nicks) {
                    my $mode = $irc_chan->mode_for_nick($n) // '';
                    $irc_flag{lc($n->nick)} = $mode =~ /o/ ? '@'
                                           : $mode =~ /v/ ? '+'
                                           : '';
                }
            }
        }
    };
    my @lines;
    # Y6: sort by level desc (highest first), then alphabetically
    my @sorted_nicks = sort {
        ($levels{lc $b} // 0) <=> ($levels{lc $a} // 0)
        || lc($a) cmp lc($b)
    } @nicks;
    for my $nick (@sorted_nicks) {
        my $flag = $irc_flag{lc $nick} // '';
        my $lvl  = $levels{lc $nick}   ? " [" . $levels{lc $nick} . "]" : '';
        push @lines, "$flag$nick$lvl";
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
    if ($@) {
        my $err = $@;
        $self->_report_operation_error(
            $stream,
            'Partyline .kick failed',
            'Kick failed.',
            $err,
        );
    }
    else {
        $stream->write("Kicked $target from $chan ($reason)\r\n");
    }
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

sub _cmd_kv {
    # FF8: in-memory key-value store — .kv set <key> <val>  .kv get <key>  .kv del <key>  .kv list
    my ($self, $stream, $id, $args) = @_;
    my $bot = $self->{bot};
    unless (defined $args && $args =~ /^(\w+)(?:\s+(\S+)(?:\s+(.*))?)?/) {
        $stream->write("Usage: .kv set <key> <value>  |  .kv get <key>  |  .kv del <key>  |  .kv list\r\n");
        return;
    }
    my ($op, $key, $val) = (lc($1), $2, $3);
    my $store = $bot->{_kv} //= {};
    if ($op eq 'set') {
        unless (defined $key && defined $val) {
            $stream->write("Usage: .kv set <key> <value>\r\n"); return;
        }
        $store->{$key} = $val;
        $stream->write("kv: $key = $val\r\n");
    } elsif ($op eq 'get') {
        unless (defined $key) {
            $stream->write("Usage: .kv get <key>\r\n"); return;
        }
        if (exists $store->{$key}) {
            $stream->write("kv: $key = $store->{$key}\r\n");
        } else {
            $stream->write("kv: key '$key' not found.\r\n");
        }
    } elsif ($op eq 'del') {
        unless (defined $key) {
            $stream->write("Usage: .kv del <key>\r\n"); return;
        }
        if (delete $store->{$key}) {
            $stream->write("kv: '$key' deleted.\r\n");
        } else {
            $stream->write("kv: key '$key' not found.\r\n");
        }
    } elsif ($op eq 'list') {
        unless (%$store) {
            $stream->write("kv: store is empty.\r\n"); return;
        }
        $stream->write("kv store (" . scalar(keys %$store) . " entries):\r\n");
        for my $k (sort keys %$store) {
            $stream->write("  $k = $store->{$k}\r\n");
        }
    } else {
        $stream->write("kv: unknown op '$op'. Use set/get/del/list.\r\n");
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
    # A-68-1: clamp override values to sane minimums (matches checkChanFlood)
    my $safe_window  = defined $window  ? (int($window)  >= 1 ? int($window)  : 1) : undef;
    my $safe_max     = defined $max     ? (int($max)     >= 1 ? int($max)     : 1) : undef;
    my $safe_silence = defined $silence ? (int($silence) >= 1 ? int($silence) : 1) : undef;
    if ((defined $window && int($window) < 1) || (defined $max && int($max) < 1)) {
        $stream->write("Warning: values below 1 clamped to 1.\r\n");
    }
    # FF6: optional warn-only mode — bot warns but does not silence
    my $warn_only = ($args && $args =~ /\bwarn.?only\b/i) ? 1 : 0;
    $bot->{_chan_flood_conf}{$chan} = {
        window    => $safe_window,
        max       => $safe_max,
        silence   => $safe_silence,
        warn_only => $warn_only,
    };
    # Also reset current flood state for this channel
    delete $bot->{_chan_flood}{$chan};
    my $conf = $bot->{_chan_flood_conf}{$chan};
    my $w = $conf->{window}  // '(default)';
    my $m = $conf->{max}     // '(default)';
    my $s = $conf->{silence} // '(default)';
    my $wo = $bot->{_chan_flood_conf}{$chan}{warn_only} ? ' warn-only' : '';
    $stream->write("CC2: floodset $chan — window=$w max=$m silence=$s${wo}\r\n");
    $stream->write("Current flood state reset.\r\n");
}

sub _cmd_cmdcooldown {
    # CC2: set per-command cooldown for a channel: .cmdcooldown #chan <cmd> <secs>
    my ($self, $stream, $id, $args) = @_;
    my $bot = $self->{bot};
    # V15: no args → list active cooldowns
    unless (defined $args && $args =~ /\S/) {
        my $conf = $bot->{_cmd_cooldown_conf} // {};
        unless (%$conf) {
            $stream->write("No cooldowns configured.\r\n"); return;
        }
        $stream->write("Active cooldowns:\r\n");
        for my $ch (sort keys %$conf) {
            for my $cmd (sort keys %{ $conf->{$ch} }) {
                my $secs = $conf->{$ch}{$cmd};
                # HH9: human-readable cooldown duration
                my $cd_str = $secs >= 60
                    ? sprintf("%dm%02ds", int($secs/60), $secs%60)
                    : "${secs}s";
                $stream->write(sprintf("  %-20s %-12s %s\r\n", $ch, "!$cmd", $cd_str));
            }
        }
        return;
    }
    unless ($args =~ /^(#\S+)\s+(\w+)\s+(\d+)$/) {
        $stream->write("Usage: .cmdcooldown <#chan> <cmd> <seconds>\r\n");
        $stream->write("  Example: .cmdcooldown #boulets ai 20\r\n");
        return;
    }
    my ($chan, $cmd, $secs) = ($1, lc($2), int($3));
    $secs = 0 if $secs < 0; $secs = 3600 if $secs > 3600;  # A-68-2: clamp range
    $bot->{_cmd_cooldown_conf}{$chan}{$cmd} = $secs;
    # Reset any active cooldown for this cmd+chan
    delete $bot->{_cmd_cooldown}{"$cmd:" . lc($chan)};
    # HH16: human-readable confirmation
    my $secs_h = $secs >= 60 ? sprintf("%dm%02ds", int($secs/60), $secs%60) : "${secs}s";
    my $action_str = $secs == 0 ? "removed" : "set to $secs_h";
    $stream->write("Cooldown for !$cmd on $chan $action_str.\r\n");
}

sub _cmd_netsplit {
    # NS: show current netsplit state
    my ($self, $stream, $id, $args) = @_;
    my $bot = $self->{bot};
    my $now = time();
    my $count = $bot->{_netsplit_quit_count} // 0;
    $stream->write("--- Netsplit state ---\r\n");
    # BB5: show time since last netsplit event if available
    my $ns_ts = $bot->{_netsplit_last_ts} // 0;
    my $ns_age_str = '';
    if ($ns_ts > 0) {
        my $ns_diff = time() - $ns_ts;
        $ns_age_str = $ns_diff >= 3600
            ? sprintf(' (last: %dh%02dm ago)', int($ns_diff/3600), int(($ns_diff%3600)/60))
            : sprintf(' (last: %dm%02ds ago)', int($ns_diff/60), $ns_diff%60);
    }
    $stream->write("  Netsplit QUITs since last reconnect: $count$ns_age_str\r\n");
    # Show antiflood state that was reset
    my $af_chans = scalar keys %{ $bot->{_af} // {} };
    my $cf_chans = scalar keys %{ $bot->{_chan_flood} // {} };
    $stream->write("  AF1 channels in state: $af_chans\r\n");
    $stream->write("  AF4 channels in state: $cf_chans\r\n");
    # Channel nicklist freshness
    $stream->write("\r\n--- Channel nicklist status ---\r\n");
    for my $chan (sort keys %{ $bot->{channels} // {} }) {
        my @nicks = eval { $bot->gethChannelsNicksOnChan($chan) };
        $stream->write(sprintf("  %-22s %d nicks\r\n", $chan, scalar @nicks));
    }
}

sub _cmd_floodstatus {
    my ($self, $stream, $id, $args) = @_;
    my $bot = $self->{bot};
    my $now = time();

    # AF1: checkAntiFlood in-memory state
    # V8: show global AF state first
    my $gaf = $bot->{_global_af} // {};
    my $gaf_hits = scalar @{ $gaf->{hits} // [] };
    my $gaf_sil  = ($gaf->{silenced_until} // 0) > time()
        ? sprintf(" SILENCED %ds", $gaf->{silenced_until} - time()) : '';
    $stream->write("--- Global AF (IMP7/IMP16) ---\r\n");
    $stream->write(sprintf("  hits in window: %d%s\r\n", $gaf_hits, $gaf_sil));
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
