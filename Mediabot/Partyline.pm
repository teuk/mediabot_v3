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

# ---------------------------------------------------------------------------
# .lusers [refresh] - show cached network stats from LUSERS
# ---------------------------------------------------------------------------
# mb544-B1: les details du LUSERS en partyline — lit le cache coeur (source
# independante du systeme Metrics); .lusers refresh demande une mise a jour
# immediate au serveur (les numerics repeupleront le cache en retour).
sub _cmd_lusers {
    my ($self, $stream, $id, $arg) = @_;

    my $bot = $self->{bot};
    my $stats = ($bot && eval { $bot->can('network_stats') }) ? $bot->network_stats : {};
    $stats = {} unless ref($stats) eq 'HASH';

    if (defined $arg && lc($arg) eq 'refresh') {
        my $sent = eval { $bot->can('request_lusers_now') ? $bot->request_lusers_now : 0 } || 0;
        if ($sent) {
            $stream->write("LUSERS refresh requested; values below are pre-refresh.\r\n");
        }
        else {
            $stream->write("LUSERS refresh not sent (not connected).\r\n");
        }
    }

    unless (%$stats) {
        $stream->write("Network stats: none yet (no LUSERS numerics received).\r\n");
        return;
    }

    my $line = "Network:";
    $line .= " users=" . $stats->{users} if defined $stats->{users};
    $line .= " (max " . $stats->{users_max} . ")" if defined $stats->{users_max};
    $line .= " channels=" . $stats->{channels} if defined $stats->{channels};
    $line .= " servers=" . $stats->{servers} if defined $stats->{servers};
    $line .= " operators=" . $stats->{operators} if defined $stats->{operators};
    $stream->write("$line\r\n");

    if (defined $stats->{updated_at}) {
        my $age = time() - $stats->{updated_at};
        $age = 0 if $age < 0;
        $stream->write("  updated: ${age}s ago\r\n");
    }
}

# MB678-IV-G: .reloadconf/.reload implementations moved to Mediabot::Partyline::Commands.


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
    # mb412-R1: id canal via le helper central (cache d'abord, mb411).
    my $id_channel = Mediabot::Helpers::channel_id_cached($bot, $chan);
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
            $content = Mediabot::Helpers::truncate_utf8($content, 120);  # mb429-R1
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
        # mb631-B1: meme porte qu'en canal (Administrator+). L'echelle de la
        # partyline est INVERSEE : Owner=0, Master=1, Administrator=2, donc
        # « Administrator ou mieux » s'ecrit level <= 2.
        my $pl_level = $self->{users}{$id}{level} // 99;
        unless ($pl_level <= 2) {
            $stream->write("Permission denied (Administrator+ required).\r\n");
            return;
        }
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
    # mb412-R1: id canal via le helper central (cache d'abord, mb411).
    my $id_channel = Mediabot::Helpers::channel_id_cached($bot, $chan);
    unless ($id_channel) {
        $stream->write("Channel $chan not found in DB.\r\n");
        return;
    }
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
    # mb412-R1: id canal via le helper central (cache d'abord, mb411).
    my $id_channel = Mediabot::Helpers::channel_id_cached($bot, $chan);
    unless ($id_channel) {
        $stream->write("Channel $chan not found in DB.\r\n");
        return;
    }
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
        my $chan_obj   = $bot->{channels}{lc $chan_name};
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
