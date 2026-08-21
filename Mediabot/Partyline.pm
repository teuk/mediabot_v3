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
    _cmd_floodset
    _cmd_cmdcooldown
    _cmd_netsplit
    _cmd_floodstatus
    _cmd_flushcooldown
    _cmd_history
    _cmd_say
    _cmd_who
    _cmd_chanlog
    _cmd_nickinfo
    _cmd_who_chan
    _cmd_kv
    _cmd_achievementprofile
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
# MB678-IV-N: .history implementation moved to Mediabot::Partyline::Commands.

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
# MB678-IV-N: .say implementation moved to Mediabot::Partyline::Commands.

# ---------------------------------------------------------------------------
# .who #chan - list nicks in a channel
# ---------------------------------------------------------------------------
# MB678-IV-N: .who implementation moved to Mediabot::Partyline::Commands.

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


# MB678-IV-N: .chanlog implementation moved to Mediabot::Partyline::Commands.

# MB678-IV-N: .nickinfo implementation moved to Mediabot::Partyline::Commands.

# MB678-IV-N: .who_chan implementation moved to Mediabot::Partyline::Commands.

# MB678-IV-L: _cmd_kick implementation moved to Mediabot::Partyline::Commands.

# MB678-IV-L: _cmd_unmute implementation moved to Mediabot::Partyline::Commands.

# MB678-IV-N: .kv implementation moved to Mediabot::Partyline::Commands.

# MB678-IV-M: anti-flood/cooldown operator commands moved to Mediabot::Partyline::Commands.

# .achievementprofile <nick> <#channel>
# Read-only visibility into mb646 durable identity resolution.  The source of
# truth stays in Mediabot::Achievements; Partyline only renders the facts.
# MB678-IV-N: .achievementprofile implementation moved to Mediabot::Partyline::Commands.

# MB678-IV-K: .dbstats implementation moved to Mediabot::Partyline::Commands.

1;
