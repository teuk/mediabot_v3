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
use Time::HiRes ();
use warnings;
use utf8;   # mb621-B1: les litteraux de ce fichier sont des CARACTERES.
            # Sans cela ils sont des OCTETS, et interpoler une variable
            # venue d'IRC (mediabot.pl decode les messages entrants) fait
            # basculer toute la chaine : les octets sont relus en latin-1
            # puis re-encodes a l'envoi -> mojibake (« humeur Ã©lectrique »).

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

use Mediabot::Partyline::Transport qw(
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

use Mediabot::Partyline::SessionAuth qw(
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

use Mediabot::Partyline::Dispatcher qw(
    _handle_line
);

use Mediabot::Partyline::Commands qw(
    _cmd_scriptdryrun
    _plugin_info_text
    _plugin_config_display_value
    _cmd_plugins
    _cmd_help
    _cmd_console
    _cmd_motd
    _send_motd
    _cmd_whom
    _cmd_match
    _cmd_boot
    _cmd_whois
    _cmd_log
    _cmd_timers
    _format_duration
    _seconds_to_human
    _cmd_schedule
    _cmd_status
    _cmd_metrics
    _cmd_channels
    _cmd_bcast
    _cmd_whochan
    _cmd_top
    _cmd_remind
    _cmd_seen
    _cmd_purgereminders
    _cmd_karma
    _cmd_karmahist
    _reload_configuration_file
    _cmd_reloadconf
    _cmd_reload
    _cmd_lusers
    _cmd_stats
    _cmd_join
    _cmd_part
    _cmd_nick
    _cmd_raw
    _cmd_rehash
    _cmd_restart
    _cmd_ai
    _cmd_persona
    _cmd_quota
    _cmd_ping
    _cmd_uptime
    _cmd_dccstat
    _cmd_stat
    _cmd_dbstats
    _cmd_bans
    _cmd_ban
    _cmd_unban
    _cmd_topic
    _cmd_kick
    _cmd_unmute
);


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
    my $start    = eval { $bot->{metrics} ? $bot->{metrics}->{started} : undef }  # mb384-B1: pas d'autoviv
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


# mb678: TCP/DCC transport implementation moved to Mediabot::Partyline::Transport.

# mb678-II: session lifecycle helpers moved to Mediabot::Partyline::SessionAuth.

# +---------------------------------------------------------------------------+
# ! Internal : dispatch an incoming line                                      !
# +---------------------------------------------------------------------------+

# MB678-III: line/auth/command dispatcher moved to Mediabot::Partyline::Dispatcher.

# +---------------------------------------------------------------------------+
# ! Internal : authentication                                                 !
# +---------------------------------------------------------------------------+

# mb678-II: authentication implementation moved to Mediabot::Partyline::SessionAuth.

# +---------------------------------------------------------------------------+
# ! Commands                                                                  !
# +---------------------------------------------------------------------------+

# MB678-IV-A: plugin/ScriptDryRun commands moved to Mediabot::Partyline::Commands.
# MB678-IV-B: core operator/session commands moved to Mediabot::Partyline::Commands.

# MB678-IV-E: reminder / seen commands moved to Mediabot::Partyline::Commands.
# MB678-IV-F: karma visibility commands moved to Mediabot::Partyline::Commands.


# MB678-IV-G: configuration reload commands moved to Mediabot::Partyline::Commands.

# MB678-IV-H: network visibility/statistics commands moved to Mediabot::Partyline::Commands.

# MB678-IV-G: .reloadconf/.reload implementations moved to Mediabot::Partyline::Commands.


# MB678-IV-J: Claude/AI Partyline commands moved to Mediabot::Partyline::Commands.

# MB678-IV-K: .ping implementation moved to Mediabot::Partyline::Commands.

# ---------------------------------------------------------------------------
# .uptime - show bot and server uptime from the Partyline
# ---------------------------------------------------------------------------
# MB678-IV-K: .uptime implementation moved to Mediabot::Partyline::Commands.

# ---------------------------------------------------------------------------
# .bans [#chan] - list active bans (from ChannelBan) on a channel
# ---------------------------------------------------------------------------
# MB678-IV-L: _cmd_bans implementation moved to Mediabot::Partyline::Commands.

# ---------------------------------------------------------------------------
# .ban #chan <nick> [duration] [reason]
#
# Bans a connected nick from a channel via Partyline.
# Sends a WHOIS to the IRC server to get the real hostmask, then the
# partylineBan callback in on_message_RPL_WHOISUSER performs the actual ban.
# Duration formats: 10m 2h 3d 1w perm/permanent (default: permanent)
# ---------------------------------------------------------------------------
# MB678-IV-L: _cmd_ban implementation moved to Mediabot::Partyline::Commands.

# ---------------------------------------------------------------------------
# .unban #chan <mask|ban_id>  - remove an active ban (Master+)
# ---------------------------------------------------------------------------
# MB678-IV-L: _cmd_unban implementation moved to Mediabot::Partyline::Commands.

# ---------------------------------------------------------------------------
# .topic #chan [new topic]  - show or change channel topic (Master+)
# ---------------------------------------------------------------------------
# MB678-IV-L: _cmd_topic implementation moved to Mediabot::Partyline::Commands.

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
# MB678-IV-K: .dccstat implementation moved to Mediabot::Partyline::Commands.

# MB678-IV-K: .stat implementation moved to Mediabot::Partyline::Commands.

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
        unless (exists $bot->{channels}{lc $target} || exists $bot->{channels}{lc $target_lc}) {
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

# MB678-IV-I: IRC control/lifecycle commands moved to Mediabot::Partyline::Commands.

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

    # mb645: `.die` is an intentional final shutdown, not a restart request.
    # Exit 75 is reserved by the shipped systemd unit via
    # RestartPreventExitStatus=75.
    $bot->setShutdownExitCode($bot->getNoRestartExitCode());
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

# MB678-IV-L: _cmd_kick implementation moved to Mediabot::Partyline::Commands.

# MB678-IV-L: _cmd_unmute implementation moved to Mediabot::Partyline::Commands.

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

# .achievementprofile <nick> <#channel>
# Read-only visibility into mb646 durable identity resolution.  The source of
# truth stays in Mediabot::Achievements; Partyline only renders the facts.
sub _cmd_achievementprofile {
    my ($self, $stream, $id, $arg) = @_;
    $arg //= '';
    $arg =~ s/^\s+|\s+$//g;

    unless ($arg =~ /\A(\S+)\s+(#\S+)\z/) {
        $stream->write("Usage: .achievementprofile <nick> <#channel>\r\n");
        return 0;
    }
    my ($nick, $channel) = ($1, $2);

    my $ach = eval { $self->{bot}{achievements} };
    unless ($ach && eval { $ach->can('identity_profile_diagnostic') }) {
        $stream->write("Achievement diagnostics unavailable.\r\n");
        return 0;
    }

    my $diag = eval { $ach->identity_profile_diagnostic($nick, $channel) };
    if (!$diag || ref($diag) ne 'HASH') {
        $stream->write("Achievement diagnostic failed safely.\r\n");
        return 0;
    }

    my $status = $diag->{status} // 'unknown';
    my $backend = $diag->{storage_label} // $diag->{backend} // 'unknown';
    $stream->write("Achievement identity diagnostic (read-only)\r\n");
    $stream->write("  Query    : $nick on $channel\r\n");
    $stream->write("  Storage  : $backend\r\n");

    if ($status eq 'legacy_json') {
        $stream->write("  Identity : legacy nick+channel key (no durable alias graph)\r\n");
        $stream->write("  Unlocks  : " . ($diag->{unlock_count} // 0) . "\r\n");
        $stream->write("  Progress : " . ($diag->{progress_counters} // 0) . " counter(s)\r\n");
        return 1;
    }
    if ($status eq 'channel_not_found') {
        $stream->write("  Result   : channel not found in DB\r\n");
        return 1;
    }
    if ($status eq 'not_found') {
        $stream->write("  Result   : no durable achievement profile matches this nick on the channel\r\n");
        return 1;
    }
    if ($status eq 'ambiguous') {
        my $candidates = $diag->{candidates};
        $candidates = [] unless ref($candidates) eq 'ARRAY';
        $stream->write("  Result   : ambiguous nick; " . scalar(@$candidates) . " durable profiles match\r\n");
        for my $p (@$candidates) {
            next unless ref($p) eq 'HASH';
            $stream->write(sprintf(
                "    profile=%d display=%s aliases=%d unlocks=%d progress=%d\r\n",
                $p->{id_achievement_profile} // 0,
                $p->{display_nick} // '',
                $p->{alias_count} // 0,
                $p->{unlock_count} // 0,
                $p->{progress_counters} // 0,
            ));
        }
        if ($diag->{candidates_truncated}) {
            $stream->write("    ... additional candidate profiles omitted (display capped at 20)\r\n");
        }
        $stream->write("  Note     : nick-only diagnostics never choose between plausible profiles\r\n");
        return 1;
    }
    if ($status ne 'ok') {
        $stream->write("  Result   : diagnostic unavailable ($status)\r\n");
        return 0;
    }

    my $p = $diag->{profile};
    $p = {} unless ref($p) eq 'HASH';
    $stream->write("  Profile  : " . ($p->{id_achievement_profile} // '?') . "\r\n");
    $stream->write("  Display  : " . ($p->{display_nick} // '') . "\r\n");
    if (defined $p->{id_user}) {
        my $reg = defined($p->{registered_nick}) && length($p->{registered_nick})
            ? " ($p->{registered_nick})" : '';
        $stream->write("  USER     : " . $p->{id_user} . $reg
            . " [authoritative resolver anchor on this channel]\r\n");
    }
    else {
        $stream->write("  USER     : none attached\r\n");
    }
    $stream->write("  Unlocks  : " . ($p->{unlock_count} // 0) . "\r\n");
    $stream->write("  Progress : " . ($p->{progress_counters} // 0) . " counter(s)\r\n");
    $stream->write("  Aliases  : " . ($p->{alias_count} // 0) . " durable identity record(s)\r\n");

    my $aliases = $diag->{aliases};
    $aliases = [] unless ref($aliases) eq 'ARRAY';
    for my $alias (@$aliases) {
        next unless ref($alias) eq 'HASH';
        my $anick = $alias->{nick} // '';
        my $uh = $alias->{userhost} // '';
        my $identity = length($uh) ? "$anick!$uh" : "$anick [legacy alias]";
        my $last = defined($alias->{last_seen_at}) ? $alias->{last_seen_at} : '?';
        $stream->write("    $identity  last_seen=$last\r\n");
    }
    if ($diag->{aliases_truncated}) {
        $stream->write("    ... additional aliases omitted (display capped at 20)\r\n");
    }

    $stream->write("  Evidence : nick maps to one stored profile on this channel");
    $stream->write("; registered USER id is authoritative") if defined $p->{id_user};
    $stream->write("\r\n");
    $stream->write("  Note     : mb646 does not persist historical merge reasons; this shows current durable evidence only.\r\n");
    return 1;
}

# MB678-IV-K: .dbstats implementation moved to Mediabot::Partyline::Commands.

1;
