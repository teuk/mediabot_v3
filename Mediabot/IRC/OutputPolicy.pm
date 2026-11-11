package Mediabot::IRC::OutputPolicy;
use strict;
use warnings;
use utf8;
use Scalar::Util ();

# Owns output admission, channel parameter caching and global/channel budgets.
# State remains on the bot so existing invalidation and reconnect cleanup share
# the same objects. This module never loads Helpers or the IRC transport.
# The compatibility facade supplies clock, config_int, reply and console hooks;
# callbacks retain their historical arguments, exception policy and call order.
# OutputBudget owns monotonic credit accrual. Channel::FloodRules owns the
# read-only SQL boundary; cache freshness and failure decisions stay here.

sub checkAntiFlood {
	my ($self, $sChannel, $cost, $hooks) = @_;
    $cost = 1 unless defined $cost;
    return 1 unless !ref($cost) && $cost =~ /\A[1-9][0-9]*\z/;

    # MB1173: only the live queue currently being drained may wait without
    # creating a new penalty. Never infer retry status from caller options or
    # from another channel's (or a retired connection's) queue.
    my $queues = $self->{_flood_outq};
    my $queue = $queues ? $queues->{$sChannel} : undef;
    my $retry = $queue && (Scalar::Util::refaddr($self->{_flood_draining}) // 0)
        == Scalar::Util::refaddr($queue);

    # IMP7: cross-channel global rate limit per bot-output
    # A bot could send to N channels at full per-channel speed — cap globally.
    # Probe without charging: a locally blocked retry is not a new output.
    # Recheck on admission because callbacks may themselves send messages.
    my $global_check = sub {
        my ($commit) = @_;
        my $now_g = $hooks->{clock}->();
        my $g     = $self->{_global_af} //= { hits => [], silenced_until => 0 };
        if ($g->{silenced_until} > $now_g) {
            my $wait = $g->{silenced_until} - $now_g;
            $self->{logger}->log(3, "checkAntiFlood() global silence ${wait}s remaining");
            return 1;
        }
        # IMP16: configurable global sliding window via OUTPUT_GLOBAL_* conf keys
        my $g_window  = $hooks->{config_int}->($self, 'OUTPUT_GLOBAL_WINDOW',  10, 5, 60);
        my $g_max     = $hooks->{config_int}->($self, 'OUTPUT_GLOBAL_MAX_MSG', 20, 5, 200);
        my $g_silence = $hooks->{config_int}->($self, 'OUTPUT_GLOBAL_SILENCE', 15, 5, 120);
        @{ $g->{hits} } = grep { ($now_g - $_) < $g_window } @{ $g->{hits} };
        # V4: debug log current hit count
        my $hit_count = scalar @{ $g->{hits} };
        $self->{logger}->log(4, "checkAntiFlood() global: $hit_count/$g_max msgs in ${g_window}s window")
            if $hit_count > int($g_max * 0.7);  # only log when >70% of threshold
        if ($hit_count + $cost > $g_max) {
            # A batch that does not fit is queued as individual lines, not a
            # flood incident that silences unrelated channels. A queued retry
            # must likewise wait without creating or extending a silence.
            return 1 if $cost > 1 || $retry;
            $g->{silenced_until} = $now_g + $g_silence;
            $self->{logger}->log(2, "checkAntiFlood() global flood — silencing ${g_silence}s");
            return 1;
        }
        push @{ $g->{hits} }, ($now_g) x $cost if $commit;
        return 0;
    };
    return 1 if $global_check->(0);

    # AF1: in-memory antiflood — zero DB queries per outgoing message.
    # DB params (nbmsg_max, duration, timetowait) are cached for 60s.
    # Flood counters live entirely in $self->{_af}{$sChannel}.

    my $now = $hooks->{clock}->();

    # --- Params cache ---
    # CHANNEL_FLOOD values remain DB-backed, but the refresh TTL is config-backed.
    my $params_ttl = $hooks->{config_int}->($self, 'OUTPUT_PARAMS_CACHE_TTL', 60, 5, 86400);
    my $pc = $self->{_af_params}{$sChannel} // {};
    if (!$pc->{ts} || ($now - $pc->{ts}) >= $params_ttl) {
        my $channel_obj = $self->{channels}{lc $sChannel};
        unless (defined $channel_obj) {
            $self->{logger}->log(1, "checkAntiFlood() unknown channel: $sChannel");
            return $global_check->(1);
        }
        my $id_channel = $channel_obj->get_id;
        require Mediabot::Channel::FloodRules;
        my $result = Mediabot::Channel::FloodRules::read($self->{dbh}, $id_channel);
        if ($result->{status} ne 'error') {
            my $ref = $result->{row};
            if ($ref) {
                $self->{_af_params}{$sChannel} = {
                    ts          => $now,
                    nbmsg_max   => $ref->{nbmsg_max}  // 5,
                    duration    => $ref->{duration}    // 30,
                    timetowait  => $ref->{timetowait}  // 300,
                    id_channel  => $id_channel,
                };
                $pc = $self->{_af_params}{$sChannel};
            } else {
                # mb409-B1: CACHE NÉGATIF. Sans lui, l'absence de ligne
                # CHANNEL_FLOOD (le cas par défaut d'un canal sans antiflood)
                # relançait le SELECT à CHAQUE message sortant — à rebours de
                # l'objectif AF1 « zero DB queries per outgoing message ».
                # L'absence est mémorisée avec le même TTL que les paramètres :
                # activer l'antiflood en base est pris en compte au prochain
                # rafraîchissement (<= OUTPUT_PARAMS_CACHE_TTL).
                $self->{_af_params}{$sChannel} = { ts => $now, unconfigured => 1 };
                return $global_check->(1);
            }
        } else {
            $self->{logger}->log(1, "checkAntiFlood() DB error: $result->{error}");
            return $global_check->(1);
        }
    }

    # mb409-B1: canal sans antiflood (cache négatif frais) -> tout passe,
    # sans requête SQL.
    return $global_check->(1) if $pc->{unconfigured};

    my $nbmsg_max  = $pc->{nbmsg_max}  // 5;
    my $duration   = $pc->{duration}   // 30;
    my $timetowait = $pc->{timetowait} // 300;

    require Mediabot::IRC::OutputBudget;

    # --- In-memory flood state ---
    my $st = $self->{_af}{$sChannel} //= { nbmsg => 0, first => $now, silenced_until => 0 };

    # Silenced? Check expiry
    if ($st->{silenced_until} && $now < $st->{silenced_until}) {
        $self->{logger}->log(3,
            "checkAntiFlood() silenced $sChannel until "
            . ($st->{silenced_until} - $now) . "s remaining");
        return 1;
    }

    # Silence lifted?
    if ($st->{silenced_until} && $now >= $st->{silenced_until}) {
        $self->{logger}->log(1, "checkAntiFlood() silence lifted on $sChannel");
        $st->{nbmsg}          = 0;
        delete $st->{bucket};
        $st->{first}          = $now;
        $st->{silenced_until} = 0;
        # EE5: notify channel that anti-flood silence has been lifted
        eval {
            $hooks->{reply}->($self, $sChannel,
                'Anti-flood silence lifted — bot is responding again.');
        };
    }

    my $bucket = Mediabot::IRC::OutputBudget::refresh($st, $nbmsg_max, $duration);
    # first remains a wall-clock activity marker for legacy cleanup consumers;
    # all credit accrual is driven exclusively by the monotonic bucket clock.
    $st->{first} = $now;
    if ($bucket->{tokens} + 1e-9 < $cost) {
        return 1 if $cost > 1 || $retry;
        $st->{silenced_until} = $now + $timetowait;
        $self->{logger}->log(1,
            "checkAntiFlood() AF1: output budget exhausted on $sChannel — silencing ${timetowait}s");
        $hooks->{console}->($self,
            "Anti-flood activated on $sChannel (output budget exhausted) — silenced for ${timetowait}s");
        $self->{metrics}->inc('mediabot_antiflood_blocks_total') if $self->{metrics};
        return 1;
    }

    # Recheck global admission before spending channel credit. Nested policy
    # notifications may have consumed the connection allowance since the probe.
    return 1 if $global_check->(1);
    $bucket->{tokens} -= $cost;
    $bucket->{tokens} = 0 if $bucket->{tokens} < 0;
    $st->{nbmsg} = $bucket->{capacity} - $bucket->{tokens};

    # A7: periodic cleanup of stale flood state
    {
        my $state_ttl       = $hooks->{config_int}->($self, 'OUTPUT_STATE_TTL', 300, 30, 86400);
        my $params_state_ttl = $hooks->{config_int}->($self, 'OUTPUT_PARAMS_STATE_TTL', 600, 30, 86400);

        if (!$self->{_antiflood_cleanup} || ($now - $self->{_antiflood_cleanup}) >= $state_ttl) {
            for my $chan (keys %{ $self->{_af} // {} }) {
                my $s = $self->{_af}{$chan};
                delete $self->{_af}{$chan}
                    if (!$s->{silenced_until} && ($now - ($s->{first} // 0)) > $state_ttl
                        && (!$s->{bucket} || Mediabot::IRC::OutputBudget::now() - $s->{bucket}{at} >= $s->{bucket}{period}));
            }
            # Also clean params cache
            for my $chan (keys %{ $self->{_af_params} // {} }) {
                delete $self->{_af_params}{$chan}
                    if ($now - ($self->{_af_params}{$chan}{ts} // 0)) > $params_state_ttl;
            }
            $self->{_antiflood_cleanup} = $now;
        }
    }

    return 0;
}

1;
