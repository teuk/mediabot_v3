package Mediabot::IRC::CommandThrottle;

use strict;
use warnings;
use utf8;
use Exporter 'import';

our @EXPORT_OK = qw(_af_conf_int checkCmdCooldown checkChanFlood checkNickFlood);

# Existing parent-side command admission policies; state stays in the bot.
# Output AntiFlood, CHANNEL_FLOOD and deferred delivery remain with their owners.
# Keep configuration and notification hooks late-bound through Helpers when present.
sub _conf_int {
    return Mediabot::Helpers::_af_conf_int(@_)
        if defined &Mediabot::Helpers::_af_conf_int;
    return _af_conf_int(@_);
}

sub noticeConsoleChan {
    require Mediabot::Helpers unless defined &Mediabot::Helpers::noticeConsoleChan;
    return Mediabot::Helpers::noticeConsoleChan(@_);
}

sub botNotice {
    require Mediabot::Helpers unless defined &Mediabot::Helpers::botNotice;
    return Mediabot::Helpers::botNotice(@_);
}

sub _af_conf_int {
    my ($self, $key, $default, $min, $max) = @_;

    my $value = eval { $self->{conf}->get("antiflood.$key") };

    $value = $default
        if !defined $value || $value eq '' || $value !~ /^\d+$/;

    $value = int($value);

    $value = $min if defined $min && $value < $min;
    $value = $max if defined $max && $value > $max;

    return $value;
}

sub checkCmdCooldown {
    my ($self, $channel, $cmd, $override_secs) = @_;
    return 0 unless defined $channel && $channel =~ /^#/ && defined $cmd;

    # Default cooldowns per command (seconds)
    my %defaults = (
        ai      => 10,
        trivia  => 5,
        openai  => 10,
        # mb666: awards performs bounded cross-feature aggregation in a worker.
        # Keep the cooldown here, in the PARENT, so it survives the child.
        awards  => 20,
        # mb667: two annual archive-aware aggregations can span millions of rows.
        yearbook => 60,
        # mb615-B1: 'actualites' enchaine deux appels reseau payants (Tavily
        # puis Claude). Le cooldown DOIT vivre ici, cote parent : la commande
        # s'execute dans un worker jetable, ou tout compteur pose meurt avec
        # le processus. Les alias partagent la meme cle, sinon le garde-fou
        # se contourne en tapant 'news' apres 'actualites'.
        actualites => 45,
        actualite  => 45,
        actu       => 45,
        news       => 45,
    );
    # mb616-B1: aliases of the same paid news command must share one bucket.
    # Keeping the typed alias in the key would let a user rotate
    # actualites -> news -> actu -> actualite and bypass the intended 45 s
    # parent-side guard. Canonicalise before both config lookup and state key.
    my $cooldown_cmd = lc $cmd;
    $cooldown_cmd = 'actualites'
        if $cooldown_cmd =~ /\A(?:actualites|actualite|actu|news)\z/;

    # CC2: per-channel override via .cmdcooldown takes priority
    my $chan_conf = defined $channel
        ? ($self->{_cmd_cooldown_conf}{$channel}{$cooldown_cmd} // undef)
        : undef;
    my $cooldown = defined $override_secs ? $override_secs
                 : defined $chan_conf      ? $chan_conf
                 : ($defaults{$cooldown_cmd} // 0);
    return 0 if $cooldown <= 0;

    my $now = time();
    my $key = $cooldown_cmd . ':' . lc($channel);
    my $last = $self->{_cmd_cooldown}{$key} // 0;
    my $elapsed = $now - $last;

    if ($elapsed < $cooldown) {
        # A-68-3: track cooldown blocks in Prometheus
        $self->{metrics}->inc('mediabot_cmdcooldown_blocks_total')
            if $self->{metrics};
        # CC16: debug log when cooldown blocks a command
        my $wait_cd = $cooldown - $elapsed;
        $self->{logger}->log(3,
            "checkCmdCooldown() blocking !$cmd on $channel — ${wait_cd}s remaining")
            if $self->{logger};
        return $wait_cd;
    }
    $self->{_cmd_cooldown}{$key} = $now;
    return 0;
}

sub checkChanFlood {
    my ($self, $channel) = @_;
    return 0 unless defined $channel && $channel =~ /^#/;

    my $now       = time();
    # CC2: per-channel overrides set by .floodset take priority
    my $conf_ov   = $self->{_chan_flood_conf}{$channel} // {};
    # B-68-3/fix: clamp CC2 overrides to sane minimums (0 would cause logic errors)
    my $window    = do { my $v = $conf_ov->{window};  defined($v) ? (int($v) >= 1 ? int($v) : 1) : _conf_int($self, 'CHANFLOOD_WINDOW', 10, 1, 3600) };
    my $max_cmds  = do { my $v = $conf_ov->{max};     defined($v) ? (int($v) >= 1 ? int($v) : 1) : _conf_int($self, 'CHANFLOOD_MAX_COMMANDS', 8, 1, 1000) };
    my $silence   = do { my $v = $conf_ov->{silence}; defined($v) ? (int($v) >= 1 ? int($v) : 1) : _conf_int($self, 'CHANFLOOD_SILENCE', 30, 1, 86400) };
    my $notify_cd = _conf_int($self, 'CHANFLOOD_NOTIFY_COOLDOWN', 60, 1, 86400);

    my $st = $self->{_chan_flood}{$channel} //= {
        hits          => [],
        silenced_until => 0,
        notified_at   => 0,
    };

    # Silenced?
    if ($st->{silenced_until} && $now < $st->{silenced_until}) {
        return 1;
    }
    # Silence lifted
    if ($st->{silenced_until} && $now >= $st->{silenced_until}) {
        $self->{logger}->log(1, "checkChanFlood/AF4: silence lifted on $channel");
        $st->{silenced_until} = 0;
        $st->{hits}           = [];
    }

    # Sliding window: push + prune
    push @{ $st->{hits} }, $now;
    @{ $st->{hits} } = grep { ($now - $_) < $window } @{ $st->{hits} };

    my $count = scalar @{ $st->{hits} };

    if ($count > $max_cmds) {
        # FF6: warn-only mode — notify but do not actually silence
        my $warn_only = $self->{_chan_flood_conf}{$channel}{warn_only} // 0;
        $st->{silenced_until} = $warn_only ? 0 : ($now + $silence);
        # B4/fix: log message reflects actual mode (warn-only vs silencing)
        $self->{logger}->log(1,
            "checkChanFlood/AF4: $channel — $count cmds in last ${window}s "
            . "(max $max_cmds) — " . ($warn_only ? 'warn-only' : "silencing ${silence}s"));
        if (($now - $st->{notified_at}) >= $notify_cd) {
            $st->{notified_at} = $now;
            noticeConsoleChan($self,
                "Chan flood detected on $channel ($count cmds/${window}s) "
                . ($warn_only ? '— warn-only (AF4)' : "— silencing ${silence}s (AF4)"));
        }
        $self->{metrics}->inc('mediabot_chanflood_blocks_total')
            if $self->{metrics};
        return $warn_only ? 0 : 1;  # FF6: warn-only returns 0 (allow command)
    }

    return 0;
}

sub checkNickFlood {
    # AF2: notify user once per throttle period (not silently drop)
    # AF3: sliding window (ring buffer of timestamps) instead of fixed window
    my ($self, $nick, $channel) = @_;
    return 0 unless defined $nick && $nick ne '';

    my $now     = time();

    # CC3/AF7: check temp mute (set by strike counter)
    my $mute_until = $self->{_nick_mute}{lc $nick} // 0;
    if ($mute_until > $now) {
        $self->{logger}->log(3, "NickFlood/AF7: " . lc($nick) . " is muted");
        return 1;  # silently drop — user was already notified
    } elsif ($mute_until) {
        delete $self->{_nick_mute}{lc $nick};  # expired, clean up
    }
    my $window  = _conf_int($self, 'NICKFLOOD_WINDOW', 5, 1, 3600);
    my $max_cmd = _conf_int($self, 'NICKFLOOD_MAX_COMMANDS', 5, 1, 1000);
    my $ttl     = _conf_int($self, 'NICKFLOOD_STATE_TTL', 120, 10, 86400);
    my $notify_cooldown = _conf_int($self, 'NICKFLOOD_NOTIFY_COOLDOWN', 30, 1, 86400);

    my $nick_key = lc($nick);

    $self->{_nick_flood} //= {};

    # Cheap periodic cleanup
    if (!defined($self->{_nick_flood_last_cleanup})
            || ($now - $self->{_nick_flood_last_cleanup}) >= $ttl) {
        for my $k (keys %{ $self->{_nick_flood} }) {
            my $st = $self->{_nick_flood}{$k};
            my $last = @{ $st->{hits} // [] } ? $st->{hits}[-1] : 0;
            delete $self->{_nick_flood}{$k} if ($now - $last) > $ttl;
        }
        # A muted nick may never return. Reclaim its expired sanction on the
        # same sweep, while retaining active mutes independently of history TTL.
        for my $k (keys %{ $self->{_nick_mute} // {} }) {
            delete $self->{_nick_mute}{$k} if ($self->{_nick_mute}{$k} // 0) <= $now;
        }
        $self->{_nick_flood_last_cleanup} = $now;
    }

    my $state = $self->{_nick_flood}{$nick_key} //= { hits => [], notified_at => 0 };

    # AF3: sliding window — push current ts, drop entries outside the window
    push @{ $state->{hits} }, $now;
    @{ $state->{hits} } = grep { ($now - $_) < $window } @{ $state->{hits} };

    my $count = scalar @{ $state->{hits} };

    if ($count > $max_cmd) {
        $self->{logger}->log(3,
            "NickFlood/AF3: $nick_key — $count cmds in last ${window}s (max $max_cmd)");
        $self->{metrics}->inc('mediabot_nickflood_blocks_total')
            if $self->{metrics};

        # CC3/AF7: consecutive strike counter — 3 strikes → temp ignore 5min
        $state->{strikes} = ($state->{strikes} // 0) + 1;
        if ($state->{strikes} >= 3) {
            my $mute_until = $now + 300;  # 5 minutes
            $self->{_nick_mute}{$nick_key} = $mute_until;
            $state->{strikes} = 0;
            $self->{logger}->log(1,
                "NickFlood/AF7: $nick_key auto-muted for 300s after 3 strikes");
            $self->{metrics}->inc('mediabot_nickflood_mutes_total')
                if $self->{metrics};
        }

        # AF2: notify the user — at most once per notify_cooldown
        if (defined $channel
                && ($now - ($state->{notified_at} // 0)) >= $notify_cooldown) {
            $state->{notified_at} = $now;
            my $wait = $window - ($now - $state->{hits}[0]);
            $wait = 1 if $wait < 1;
            botNotice($self, $nick,
                "You are sending commands too fast. Please wait ${wait}s.");
        }
        return 1;
    }

    return 0;
}

1;
