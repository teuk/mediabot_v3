package Mediabot::Partyline::Dispatcher;

# =============================================================================
# Mediabot::Partyline::Dispatcher
# =============================================================================
# MB678-III: authenticated/pre-auth line state machine and command dispatcher.
#
# The historical Mediabot::Partyline::_handle_line method remains available via
# import. Command implementations stay on Mediabot::Partyline in this round.
# =============================================================================

use strict;
use warnings;
use utf8;
use Exporter 'import';

our @EXPORT_OK = qw(
    _handle_line
);

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
            $session->{rate_warned} = 0;
        }
        $session->{rate_count}++;
        if ($session->{rate_count} > 10) {
            # mb596-B1: anti-amplification et anti-flood. L'ancien code
            # repondait « Rate limit exceeded » a CHAQUE ligne au-dela de la
            # limite : un collage accidentel de 1000 lignes recevait 990
            # refus — le throttle devenait lui-meme un amplificateur. Regles :
            # le refus s'annonce UNE fois par fenetre, les lignes suivantes
            # sont ignorees en silence (comptees), et au-dela de 3x la
            # limite dans la meme fenetre la session est deconnectee
            # proprement (flood caracterise, modele .boot). Les compteurs
            # cumules alimentent le .status.
            $self->{_rate_stats} ||= {};
            if ($session->{rate_count} >= 30) {
                $self->{_rate_stats}{flood_boots}++;
                $self->{bot}->{logger}->log(1,
                    "Partyline: flood protection boot fd=$id login="
                    . ($session->{login} || 'anon')
                    . " (" . $session->{rate_count} . " lines in window)");
                eval { $stream->write("Flood protection: disconnecting.\r\n") };
                eval { $stream->close_when_empty }
                    if $stream && eval { $stream->can('close_when_empty') };
                $self->_close_session($id);
                return;
            }
            if (!$session->{rate_warned}) {
                $session->{rate_warned} = 1;
                $self->{_rate_stats}{hits}++;
                $self->{bot}->{logger}->log(2, "Partyline: rate limit hit for fd=$id login=" . ($session->{login} || 'anon'));
                $stream->write("Rate limit exceeded. Slow down.\r\n");
                return;
            }
            $self->{_rate_stats}{silent_drops}++;
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
    elsif ($line =~ /^\.achievementprofile(?:\s+(.*))?$/i) {
        $self->{bot}->{metrics}->inc('mediabot_commands_partyline_total', { command => '.achievementprofile' }) if $self->{bot}->{metrics};
        $self->_cmd_achievementprofile($stream, $id, $1);
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
    elsif ($line =~ /^\.lusers(?:\s+(refresh))?$/i) {
        $self->{bot}->{metrics}->inc('mediabot_commands_partyline_total', { command => '.lusers' }) if $self->{bot}->{metrics};
        $self->_cmd_lusers($stream, $id, $1);
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

1;
