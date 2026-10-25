package Mediabot::Users::Seen;

use strict;
use warnings;
use utf8;
use Exporter 'import';
use Mediabot::Helpers ();

our @EXPORT_OK = qw(mbSeen_ctx);

# Preserve the historical facade's call-time transport hooks.
sub botPrivmsg { goto &Mediabot::UserCommands::botPrivmsg }
sub botNotice  { goto &Mediabot::UserCommands::botNotice }
sub logBot     { goto &Mediabot::UserCommands::logBot }

# Online, persisted and archived last-seen lookups, scoped by the requested channel.
sub mbSeen_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
    @args = grep { defined && $_ ne '' } @args;

    unless (@args) {
        botNotice($self, $nick, "Syntax: seen <nick> [#channel]  (wildcard: seen teu*)");
        return;
    }

    my $target_input = shift @args;
    $target_input =~ s/^\s+|\s+\z//g;

    my $targetNick = lc($target_input);  # normalize for USER_SEEN PK lookup

    # mb86-IMP1: wildcard support — seen teu* → liste jusqu'à 5 nicks correspondants
    if ($target_input =~ /[*?]/) {
        my $is_private = !defined($ctx->channel) || $ctx->channel eq '';
        my $dest       = $is_private ? $nick : ($ctx->channel);
        # mb127-B3: convert IRC glob (*, ?) to SQL LIKE while escaping literal
        # LIKE metacharacters from the user input. Without ESCAPE, nicks such
        # as "bob_foo*" made "_" behave as a wildcard.
        my $like_pat = '';
        for my $ch (split //, lc($target_input)) {
            if    ($ch eq '*') { $like_pat .= '%';  }
            elsif ($ch eq '?') { $like_pat .= '_';  }
            elsif ($ch eq '!') { $like_pat .= '!!'; }
            elsif ($ch eq '%') { $like_pat .= '!%'; }
            elsif ($ch eq '_') { $like_pat .= '!_'; }
            else               { $like_pat .= $ch;  }
        }
        my $chan_for_wc;
        if (@args && defined $args[0] && $args[0] =~ /^#/) {
            $chan_for_wc = shift @args;
        } else {
            my $cc = $ctx->channel // '';
            $chan_for_wc = ($cc =~ /^#/) ? $cc : undef;
        }
        my ($sql_wc, @bind_wc);
        if ($chan_for_wc) {
            $sql_wc = q{
                SELECT nick, channel, seen_at, event_type
                FROM USER_SEEN
                WHERE nick LIKE ? ESCAPE '!' AND channel = ?
                ORDER BY seen_at DESC LIMIT 5
            };
            @bind_wc = ($like_pat, $chan_for_wc);
        } else {
            $sql_wc = q{
                SELECT nick, channel, seen_at, event_type
                FROM USER_SEEN
                WHERE nick LIKE ? ESCAPE '!'
                ORDER BY seen_at DESC LIMIT 5
            };
            @bind_wc = ($like_pat);
        }
        my $sth_wc = $self->{dbh}->prepare($sql_wc);
        unless ($sth_wc && $sth_wc->execute(@bind_wc)) {
            botNotice($self, $nick, 'Database error.'); return;
        }
        my @wc_rows;
        while (my $r = $sth_wc->fetchrow_hashref) { push @wc_rows, $r; }
        $sth_wc->finish;
        unless (@wc_rows) {
            my $scope = $chan_for_wc ? " on $chan_for_wc" : '';
            botNotice($self, $nick, "No nicks matching '$target_input'$scope.");
            return 1;
        }
        my $count = scalar @wc_rows;
        botNotice($self, $nick, "$count nick(s) matching '$target_input':");
        for my $r (@wc_rows) {
            botNotice($self, $nick, sprintf('  %s — last seen %s on %s (%s)',
                $r->{nick}, $r->{seen_at}, $r->{channel}, $r->{event_type}));
        }
        logBot($self, $ctx->message, ($is_private ? undef : $dest), 'seen', $target_input);
        return 1;
    }

    my $chan_for_part;
    if (@args && defined $args[0] && $args[0] =~ /^#/) {
        $chan_for_part = shift @args;
    } else {
        my $cc = $ctx->channel // '';
        $chan_for_part = ($cc =~ /^#/) ? $cc : undef;
    }

    my $is_private = !defined($ctx->channel) || $ctx->channel eq '';
    my $dest_chan  = $ctx->channel;

    # Check if the nick is currently online before hitting the DB.
    # If seen <nick> #channel was requested, keep this online check scoped
    # to that channel instead of reporting an unrelated channel.
    {
        my %hChannelsNicks = %{ $self->gethChannelNicks() // {} };

        for my $chan (sort keys %hChannelsNicks) {
            next if defined($chan_for_part) && lc($chan) ne lc($chan_for_part);

            my @nicks = $self->gethChannelsNicksOnChan($chan);
            my ($online_nick) = grep { lc($_) eq $targetNick } @nicks;

            if (defined($online_nick) && $online_nick ne '') {
                my $msg = "$online_nick is currently online on $chan.";

                if ($is_private) {
                    botNotice($self, $ctx->nick, $msg);
                } else {
                    botPrivmsg($self, $dest_chan, $msg);
                }

                logBot($self, $ctx->message, ($is_private ? undef : $dest_chan), "seen", $targetNick);
                return 1;
            }
        }
    }

    my $fmt_host = sub {
        my ($h) = @_; $h //= ''; $h =~ s/^.*!//; return $h;
    };

    # mb497: sanitize a stored last_msg for display — strip IRC formatting
    # codes and control chars, collapse whitespace, bound length so a single
    # seen line stays readable on IRC.
    my $fmt_last = sub {
        my ($txt) = @_;
        return '' unless defined $txt && $txt ne '';
        $txt =~ s/[\x02\x0f\x16\x1d\x1f]//g;         # bold/reset/reverse/italic/underline
        $txt =~ s/\x03\d{0,2}(?:,\d{1,2})?//g;       # mIRC colour codes
        $txt =~ s/[\x00-\x08\x0a-\x1f]/ /g;          # remaining control chars -> space
        $txt =~ s/\s{2,}/ /g;
        $txt =~ s/^\s+|\s+$//g;
        $txt = Mediabot::Helpers::truncate_utf8($txt, 200, '...') if length($txt) > 200;
        return $txt;
    };

    my $fmt_ago = sub {
        my ($uts) = @_;
        my $secs = time() - ($uts // 0);
        return 'just now' if $secs < 5;
        # V7: show seconds for small intervals (avoids '0m ago')
        return "${secs}s ago" if $secs < 60;
        my $d = int($secs / 86400);
        my $h = int(($secs % 86400) / 3600);
        my $m = int(($secs % 3600) / 60);
        my @p;
        push @p, "${d}d" if $d;
        push @p, "${h}h" if $h;
        push @p, "${m}m" if $m || (!$d && !$h);
        return join(' ', @p) . ' ago';
    };

    # --- 1. Check USER_SEEN first (persisted, covers messages + joins) ---
    # If seen <nick> #channel was requested, keep the persisted lookup scoped
    # to that channel too. Otherwise, keep the historical global lookup.
    my $seen_row;
    {
        my ($sql, @bind);

        if (defined($chan_for_part) && $chan_for_part ne '') {
            $sql = q{
                SELECT nick, channel, userhost, event_type, last_msg, new_nick,
                       seen_at, UNIX_TIMESTAMP(seen_at) AS seen_uts
                FROM USER_SEEN
                WHERE nick = ? AND channel = ?
                ORDER BY seen_at DESC
                LIMIT 1
            };
            @bind = ($targetNick, $chan_for_part);
        }
        else {
            # mb86-B3: ORDER BY seen_at DESC — sans ORDER BY, MariaDB retourne
            # une ligne arbitraire quand le nick est présent sur plusieurs canaux
            $sql = q{
                SELECT nick, channel, userhost, event_type, last_msg, new_nick,
                       seen_at, UNIX_TIMESTAMP(seen_at) AS seen_uts
                FROM USER_SEEN
                WHERE nick = ?
                ORDER BY seen_at DESC
                LIMIT 1
            };
            @bind = ($targetNick);
        }

        my $sth = $self->{dbh}->prepare($sql);
        if ($sth && $sth->execute(@bind)) {
            $seen_row = $sth->fetchrow_hashref;
            $sth->finish;
        }
    }

    # --- 2. Fallback: CHANNEL_LOG events (older data pre-USER_SEEN) ---
    my ($quit, $part, $chanlog);

    unless ($seen_row) {
        # mb576-B1: pre-USER_SEEN history may already live in the archive.
        my $id_channel = 0;

        if (defined $chan_for_part) {
            my $channel_obj = $self->{channels}{lc $chan_for_part}
                           || $self->{channels}{lc($chan_for_part)};
            $id_channel = eval { $channel_obj->get_id } || 0;
        }

        if (defined($chan_for_part) && $id_channel) {
            # mb576-B1: LIMIT 1 par table, la fusion garde la plus recente
            # (le dernier passage d'un ancien vit dans l'archive).
            my $seen_best;
            my $seen_chan_g = Mediabot::Helpers::channel_log_gather($self, $self->{dbh},
                "SELECT ts, UNIX_TIMESTAMP(ts) AS uts, userhost, publictext, event_type
                 FROM __CLSRC__ cl
                 WHERE id_channel = ?
                   AND nick = ?
                   AND event_type IN ('message', 'public', 'action', 'join', 'part', 'quit')
                 ORDER BY ts DESC LIMIT 1",
                [ $id_channel, $targetNick ], sub {
                    my ($r) = @_;
                    $seen_best = $r
                        if !$seen_best
                        || (($r->{uts} // 0) > ($seen_best->{uts} // 0));
                }, 'all');
            # mb578-B1: panne LIVE = echec franc — sans quoi seen pourrait
            # repondre depuis une archive ancienne seule.
            unless ($seen_chan_g->{live_ok}) {
                botNotice($self, $nick, 'Database error.');
                return;
            }
            {
                if (my $r = $seen_best) {
                    $chanlog = {
                        ts    => $r->{ts},
                        uts   => $r->{uts} // 0,
                        host  => $r->{userhost} // '',
                        text  => $r->{publictext} // '',
                        event => (($r->{event_type} // 'message') =~ /\A(?:public|action)\z/
                            ? 'message' : ($r->{event_type} // 'message')),
                    };
                }
            }
        }
        else {
            # mb576-B1: LIMIT 1 par table, fusion = le quit le plus recent.
            my $quit_best;
            my $seen_quit_g = Mediabot::Helpers::channel_log_gather($self, $self->{dbh},
                "SELECT ts, UNIX_TIMESTAMP(ts) AS uts, userhost, publictext
                 FROM __CLSRC__ cl
                 WHERE nick = ? AND event_type = 'quit'
                 ORDER BY ts DESC LIMIT 1",
                [ $targetNick ], sub {
                    my ($r) = @_;
                    $quit_best = $r
                        if !$quit_best
                        || (($r->{uts} // 0) > ($quit_best->{uts} // 0));
                }, 'presence');
            unless ($seen_quit_g->{live_ok}) {
                botNotice($self, $nick, 'Database error.');
                return;
            }
            if (my $r = $quit_best) {
                $quit = {
                    ts   => $r->{ts},
                    uts  => $r->{uts} // 0,
                    host => $r->{userhost} // '',
                    text => $r->{publictext} // '',
                };
            }
        }
    }

    # --- Build message ---
    my $msg;

    if ($seen_row) {
        my $host = $fmt_host->($seen_row->{userhost});
        my $ago  = $fmt_ago->($seen_row->{seen_uts});
        my $ev   = $seen_row->{event_type} // 'message';
        my $chan  = $seen_row->{channel} // '';

        if ($ev eq 'message') {
            my $last = $fmt_last->($seen_row->{last_msg});
            $msg = "$targetNick ($host) was last seen $ago"
                 . ($chan ? " on $chan" : '')
                 . ($last ne '' ? " saying: $last" : '');
        } elsif ($ev eq 'join') {
            $msg = "$targetNick ($host) was last seen joining $chan $ago";
        } elsif ($ev eq 'part') {
            my $last = $fmt_last->($seen_row->{last_msg});
            $msg = "$targetNick ($host) was last seen parting $chan $ago"
                 . ($last ne '' ? " ($last)" : '');
        } elsif ($ev eq 'quit') {
            my $last = $fmt_last->($seen_row->{last_msg});
            $msg = "$targetNick ($host) was last seen quitting $ago"
                 . ($last ne '' ? " ($last)" : '');
        } elsif ($ev eq 'nick') {
            my $nn = $seen_row->{new_nick} // '?';
            $msg = "$targetNick ($host) was last seen $ago changing nick to $nn";
        } else {
            $msg = "$targetNick ($host) was last seen $ago ($ev)";
        }
    } elsif ($chanlog) {
        my $host = $fmt_host->($chanlog->{host});
        my $txt  = $chanlog->{text} // '';
        my $ev   = $chanlog->{event} // 'message';
        my $ago  = $fmt_ago->($chanlog->{uts});

        if ($ev eq 'message') {
            $msg = "$targetNick ($host) was last seen $ago on $chan_for_part"
                 . ($txt ne '' ? " saying: $txt" : '');
        }
        elsif ($ev eq 'join') {
            $msg = "$targetNick ($host) was last seen joining $chan_for_part $ago";
        }
        elsif ($ev eq 'part') {
            $msg = "$targetNick ($host) was last seen parting $chan_for_part $ago"
                 . ($txt ne '' ? " ($txt)" : '');
        }
        elsif ($ev eq 'quit') {
            $msg = "$targetNick ($host) was last seen quitting $ago"
                 . ($txt ne '' ? " ($txt)" : '');
        }
        else {
            $msg = "$targetNick ($host) was last seen $ago on $chan_for_part ($ev)";
        }
    } elsif ($quit || $part) {
        # Fallback CHANNEL_LOG path for global seen lookup.
        my $quit_uts = $quit ? ($quit->{uts} // 0) : 0;
        my $part_uts = $part ? ($part->{uts} // 0) : 0;
        if ($part_uts && $part_uts >= $quit_uts && $chan_for_part) {
            my $host = $fmt_host->($part->{host});
            my $txt  = $part->{text} // '';
            $msg = "$targetNick ($host) was last seen parting $chan_for_part : $part->{ts}"
                 . ($txt ne '' ? " ($txt)" : '');
        } else {
            my $host = $fmt_host->($quit->{host});
            my $txt  = $quit->{text} // '';
            $msg = "$targetNick ($host) was last seen quitting : $quit->{ts}"
                 . ($txt ne '' ? " ($txt)" : '');
        }
    } else {
        $msg = "I don't remember seeing nick $targetNick.";
    }

    # mb497: activity hint — append how many messages this nick posted in the
    # last 24h on the relevant channel, so "seen 3h ago" also tells you whether
    # they are an active regular or a ghost. Best-effort, never blocks the
    # answer; only when we can resolve a channel and the nick was actually seen.
    if ($msg !~ /^I don't remember/) {
        my $act_chan = $chan_for_part
            || ($seen_row ? $seen_row->{channel} : undef);
        if (defined $act_chan && $act_chan =~ /^[#&]/) {
            my $chan_obj = $self->{channels}{lc $act_chan};
            my $id_channel = $chan_obj ? eval { $chan_obj->get_id } : undef;
            if (defined $id_channel) {
                my $sth_act = $self->{dbh}->prepare(q{
                    SELECT COUNT(*) AS c
                    FROM CHANNEL_LOG
                    WHERE id_channel = ?
                      AND nick = ?
                      AND event_type IN ('public','action')
                      AND ts >= NOW() - INTERVAL 24 HOUR
                });
                if ($sth_act && eval { $sth_act->execute($id_channel, $targetNick) }) {
                    my $row = $sth_act->fetchrow_hashref;
                    $sth_act->finish;
                    my $c = $row ? ($row->{c} // 0) : 0;
                    $msg .= " [$c msg in last 24h]" if $c > 0;
                }
            }
        }
    }

    if ($is_private) {
        botNotice($self, $nick, $msg);
        logBot($self, $ctx->message, undef, "seen", $targetNick);
    } else {
        botPrivmsg($self, $dest_chan, $msg);
        logBot($self, $ctx->message, $dest_chan, "seen", $targetNick);
    }

    return 1;
}

1;
