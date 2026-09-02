package Mediabot::Hailo;

# =============================================================================
# Mediabot::Hailo — Hailo AI chatter integration
#
# Provides all Hailo-related commands and helpers:
#   init_hailo, get_hailo, is_hailo_excluded_nick,
#   hailo_ignore_ctx, hailo_unignore_ctx, hailo_status_ctx,
#   hailo_chatter_ctx, get_hailo_channel_ratio, set_hailo_channel_ratio
#
# All subs are called as methods on the Mediabot object ($self).
# External dependencies (botNotice, logBot, etc.) remain in Mediabot.pm
# and are called via $self->method() or as package functions.
# =============================================================================

use strict;
use warnings;

use Exporter 'import';
use Mediabot::Helpers;
use Mediabot::Hailo::BrainRegistry;
use Mediabot::Hailo::Normalizer qw(
    normalize_hailo_input
    rehydrate_hailo_output
);
use Mediabot::Hailo::Policy;
use Mediabot::Hailo::PostEditor;
use Mediabot::Hailo::PostEditRuntime;
use Mediabot::Hailo::ReplyQueue;
use Hailo;

our @EXPORT = qw(
    init_hailo
    get_hailo
    get_hailo_runtime
    save_hailo_brains
    hailo_reply_before_learning
    hailo_channel_policy
    hailo_process_turn
    hailo_post_edit_runtime
    hailo_observe_public_line
    hailo_submit_candidate
    is_hailo_excluded_nick
    hailo_ignore_ctx
    hailo_unignore_ctx
    hailo_status_ctx
    hailo_chatter_ctx
    get_hailo_channel_ratio
    set_hailo_channel_ratio
    check_birthdays_today
    hailo_record_activity
    hailo_should_chatter
);

sub init_hailo {
	my ($self) = shift;
	$self->{logger}->log(1, "Initialize per-channel Hailo brain registry");

    my $conf = $self->{conf};
    my $root = eval { $conf->get('hailo.HAILO_BRAIN_DIR') } || 'var/hailo';
    my $legacy = eval { $conf->get('hailo.HAILO_LEGACY_BRAIN') };
    $legacy = 'mediabot_v3.brn' unless defined($legacy) && $legacy ne '';
    my $max_open = eval { $conf->get('hailo.HAILO_MAX_OPEN_BRAINS') } || 32;
    my $network = eval { $conf->get('connection.CONN_SERVER_NETWORK') }
        || $self->{network_name}
        || 'unknown';

	my $registry = eval {
        Mediabot::Hailo::BrainRegistry->new(
            root         => $root,
            network      => $network,
            legacy_brain => $legacy,
            max_open     => $max_open,
            logger       => $self->{logger},
            factory      => sub {
                my ($path) = @_;
                return Hailo->new(
                    brain        => $path,
                    save_on_exit => 1,
                );
            },
        );
	};
	if ($@ || !$registry) {
        my $error = $@ || 'unknown registry initialization failure';
        $error =~ s/[\r\n]+/ /g;
		$self->{logger}->log(0, " Hailo init failed: $error");
		$self->{hailo_registry} = undef;
		$self->{hailo} = undef;
		return;
	}
	$self->{hailo_registry} = $registry;
    $self->{hailo} = undef; # compatibility alias: last channel brain opened

    my $conf_int = sub {
        my ($key, $default) = @_;
        my $value = eval { $conf->get("hailo.$key") };
        return $default unless defined($value) && !ref($value) && "$value" =~ /^\d+\z/;
        return int($value);
    };

    $self->{hailo_policy} = Mediabot::Hailo::Policy->new(
        learn_interval => $conf_int->('HAILO_LEARN_INTERVAL_SECONDS', 5),
        reply_interval => $conf_int->('HAILO_REPLY_INTERVAL_SECONDS', 5),
        flood_max      => $conf_int->('HAILO_FLOOD_MAX_REPLIES', 4),
        flood_window   => $conf_int->('HAILO_FLOOD_WINDOW_SECONDS', 30),
        min_words      => $conf_int->('HAILO_LEARN_MIN_WORDS', 3),
        max_words      => $conf_int->('HAILO_LEARN_MAX_WORDS', 20),
        key_reply_rate => $conf_int->('HAILO_KEY_REPLY_RATE', 95),
    );
    $self->{hailo_reply_queue} = Mediabot::Hailo::ReplyQueue->new(
        max_total       => $conf_int->('HAILO_REPLY_QUEUE_MAX_TOTAL', 32),
        max_per_channel => $conf_int->('HAILO_REPLY_QUEUE_MAX_PER_CHANNEL', 3),
        ttl_seconds     => $conf_int->('HAILO_REPLY_QUEUE_TTL_SECONDS', 30),
        typing_coeff    => $conf_int->('HAILO_TYPING_DELAY_COEFFICIENT_PERCENT', 35) / 100,
        typing_offset   => $conf_int->('HAILO_TYPING_DELAY_OFFSET_MS', 500) / 1000,
    );
	delete $self->{_hailo_runtime_unavailable_logged};
}

# Get the Hailo object for a channel. Calls without a channel retain the narrow
# compatibility contract used by older internal diagnostics: the last opened
# channel brain is returned, but no global writable brain is created.
sub get_hailo {
	my ($self, $channel) = @_;
    return $self->{hailo} unless defined($channel) && $channel ne '';

    my $registry = $self->{hailo_registry};
    return undef unless $registry;

    my $hailo = eval { $registry->brain_for($channel) };
    if ($@ || !$hailo) {
        my $error = $@ || 'unknown per-channel brain failure';
        $error =~ s/[\r\n]+/ /g;
        $self->{logger}->log(1, "Hailo brain unavailable for channel: $error")
            if $self->{logger};
        return undef;
    }

    $self->{hailo} = $hailo;
    return $hailo;
}

# mb361-B1: runtime paths must tolerate an unavailable Hailo brain. init_hailo()
# already logs the initialization failure; this helper adds at most one concise
# runtime diagnostic and lets message handling continue without dereferencing
# undef or misclassifying the failure as a timeout.
sub get_hailo_runtime {
    my ($self, $channel) = @_;

    my $hailo = get_hailo($self, $channel);
    return $hailo if $hailo;

    unless ($self->{_hailo_runtime_unavailable_logged}) {
        $self->{_hailo_runtime_unavailable_logged} = 1;
        $self->{logger}->log(2,
            "Hailo runtime unavailable; skipping per-channel reply and learning paths")
            if $self->{logger};
    }

    return undef;
}

sub save_hailo_brains {
    my ($self) = @_;
    my $registry = $self->{hailo_registry};
    return 1 unless $registry;
    return eval { $registry->save_all } ? 1 : 0;
}

sub _hailo_optional_chanset {
    my ($self, $channel, $name, $fallback, $fresh) = @_;
    my $now = time();
    my $cache = $self->{_hailo_optional_chanset_ids} ||= {};
    my $id;
    if (!$fresh && exists($cache->{$name}) && ($now - $cache->{$name}{ts}) < 30) {
        $id = $cache->{$name}{id};
    }
    else {
        $id = eval { getIdChansetList($self, $name) };
        $cache->{$name} = { ts => $now, id => $id };
    }
    return $fallback ? 1 : 0 unless defined($id) && $id ne '';
    my $enabled = eval { getIdChannelSet($self, $channel, $id) };
    return $enabled ? 1 : 0;
}

sub hailo_channel_policy {
    my ($self, $channel, %opts) = @_;
    return {
        master  => 0,
        learn   => 0,
        respond => 0,
        chatter => 0,
    } unless defined($channel) && !ref($channel) && $channel =~ /^#/;

    my $master = eval {
        Mediabot::Helpers::chanset_enabled($self, $channel, 'Hailo', default => 0)
    } ? 1 : 0;

    # HailoLearn and HailoRespond are data-only additions. Before their
    # migration exists, both inherit the historical +Hailo switch so an
    # upgrade cannot silently stop an established brain from learning or
    # answering direct mentions.
    my $learn = _hailo_optional_chanset(
        $self, $channel, 'HailoLearn', $master, $opts{fresh}
    );
    my $respond = _hailo_optional_chanset(
        $self, $channel, 'HailoRespond', $master, $opts{fresh}
    );
    my $chatter = eval {
        Mediabot::Helpers::chanset_enabled($self, $channel, 'HailoChatter', default => 0)
    } ? 1 : 0;

    return {
        master  => $master,
        learn   => $master && $learn ? 1 : 0,
        respond => $master && $respond ? 1 : 0,
        chatter => $master && $chatter ? 1 : 0,
    };
}

sub _hailo_channel_nicks {
    my ($self, $channel) = @_;
    return [] unless defined($channel) && !ref($channel);
    my $lists = $self->{hChannelsNicks};
    return [] unless ref($lists) eq 'HASH';

    my $list = $lists->{$channel} || $lists->{lc($channel)};
    return [] unless ref($list) eq 'ARRAY';
    my %seen;
    return [ grep {
        defined($_) && !ref($_) && length($_) && !$seen{lc($_)}++
    } @$list ];
}

sub _hailo_command_prefixes {
    my ($self) = @_;
    my @prefixes = ('!');
    my $configured = eval { $self->{conf}->get('main.MAIN_PROG_CMD_CHAR') };
    push @prefixes, "$configured"
        if defined($configured) && !ref($configured) && length("$configured") == 1;
    my %seen;
    return [ grep { !$seen{$_}++ } @prefixes ];
}

sub _hailo_conf_bool {
    my ($self, $key, $default) = @_;
    my $value = eval { $self->{conf}->get("hailo.$key") };
    return $default ? 1 : 0
        unless defined($value) && !ref($value) && "$value" =~ /^(?:0|1)\z/;
    return $value ? 1 : 0;
}

sub _hailo_safe_log_value {
    my ($value, $default) = @_;
    return $default unless defined($value) && !ref($value);
    my $safe = lc "$value";
    $safe =~ s/[^a-z0-9_.-]+/_/g;
    $safe = substr($safe, 0, 64);
    return length($safe) ? $safe : $default;
}

sub _hailo_schedule_post_edit {
    my ($self, $delay, $callback) = @_;
    return 0 unless ref($callback) eq 'CODE';
    return $callback->() || 1 unless defined($delay) && $delay > 0;

    my $loop = eval { $self->getLoop } || $self->{loop};
    return 0 unless $loop;

    require IO::Async::Timer::Countdown;
    my $id = ++$self->{_hailo_post_edit_timer_id};
    my $timer;
    $timer = IO::Async::Timer::Countdown->new(
        delay     => $delay,
        on_expire => sub {
            delete $self->{_hailo_post_edit_timers}{$id};
            eval { $loop->remove($timer) };
            eval { $callback->() };
        },
    );
    $self->{_hailo_post_edit_timers}{$id} = $timer;
    $loop->add($timer);
    $timer->start;
    return 1;
}

sub hailo_post_edit_runtime {
    my ($self) = @_;
    return $self->{hailo_post_edit_runtime}
        if $self->{hailo_post_edit_runtime};

    my $editor = eval {
        Mediabot::Hailo::PostEditor->new(
            conf       => $self->{conf},
            loop_owner => $self,
        );
    };
    if ($@ || !$editor) {
        my $error = $@ || 'unknown post-editor initialization failure';
        $error =~ s/[\r\n\x00]+/ /g;
        $error = substr($error, 0, 200);
        $self->{logger}->log(1, "Hailo post-editor unavailable: $error")
            if $self->{logger};
        return undef;
    }

    my $runtime = eval {
        Mediabot::Hailo::PostEditRuntime->new(
            post_editor       => $editor,
            queue             => $self->{hailo_reply_queue},
            max_context_lines => _hailo_conf_int(
                $self, 'hailo.HAILO_POST_EDIT_CONTEXT_LINES', 4, 1, 8
            ),
            max_inflight      => _hailo_conf_int(
                $self, 'hailo.HAILO_POST_EDIT_MAX_INFLIGHT', 4, 1, 16
            ),
            typing_enabled    => _hailo_conf_bool(
                $self, 'HAILO_TYPING_DELAY_ENABLED', 1
            ),
            schedule_cb       => sub {
                my ($delay, $callback) = @_;
                return _hailo_schedule_post_edit($self, $delay, $callback);
            },
            metric_cb         => sub {
                my ($summary) = @_;
                return unless $self->{metrics} && ref($summary) eq 'HASH';
                my $result = _hailo_safe_log_value(
                    ($summary->{action} // 'dropped') . '_' . ($summary->{reason} // 'unknown'),
                    'dropped_unknown',
                );
                $self->{metrics}->inc(
                    'mediabot_hailo_post_edit_total', { result => $result }
                );
                my $stats = eval { $self->{hailo_post_edit_runtime}->stats };
                if (ref($stats) eq 'HASH') {
                    $self->{metrics}->set(
                        'mediabot_hailo_post_edit_inflight', $stats->{inflight} || 0
                    );
                    $self->{metrics}->set(
                        'mediabot_hailo_post_edit_queue_depth',
                        ref($stats->{queue}) eq 'HASH' ? ($stats->{queue}{queued} || 0) : 0,
                    );
                }
            },
            log_cb            => sub {
                my ($summary) = @_;
                return unless $self->{logger} && ref($summary) eq 'HASH';
                my $channel = defined($summary->{channel}) && !ref($summary->{channel})
                    && $summary->{channel} =~ /^#/ ? $summary->{channel} : '#?';
                my $action = _hailo_safe_log_value($summary->{action}, 'dropped');
                my $reason = _hailo_safe_log_value($summary->{reason}, 'unknown');
                my $edit = _hailo_safe_log_value($summary->{edit_reason}, 'unknown');
                my $language = _hailo_safe_log_value($summary->{language}, 'en');
                my $provider = _hailo_safe_log_value($summary->{provider}, 'fallback');
                $self->{logger}->log(3, sprintf(
                    '[HAILO_POST_EDIT] channel=%s action=%s reason=%s edit=%s language=%s provider=%s',
                    $channel, $action, $reason, $edit, $language, $provider,
                ));
            },
        );
    };
    if ($@ || !$runtime) {
        my $error = $@ || 'unknown post-edit runtime failure';
        $error =~ s/[\r\n\x00]+/ /g;
        $error = substr($error, 0, 200);
        $self->{logger}->log(1, "Hailo post-edit runtime unavailable: $error")
            if $self->{logger};
        return undef;
    }

    $self->{hailo_post_editor} = $editor;
    $self->{hailo_post_edit_runtime} = $runtime;
    return $runtime;
}

sub hailo_observe_public_line {
    my ($self, %args) = @_;
    my $channel = $args{channel};
    my $policy = hailo_channel_policy($self, $channel);
    return 0 unless $policy->{master};

    my $text = $args{text};
    return 0 unless defined($text) && !ref($text) && length($text);
    my $prefixes = _hailo_command_prefixes($self);
    my $is_command = scalar grep {
        defined($_) && !ref($_) && length($_) == 1 && index($text, $_) == 0
    } @$prefixes;

    my $runtime = hailo_post_edit_runtime($self);
    return 0 unless $runtime;
    return $runtime->observe_public_line(
        channel    => $channel,
        text       => $text,
        from_bot   => $args{from_bot} ? 1 : 0,
        is_command => $is_command ? 1 : 0,
    );
}

sub hailo_submit_candidate {
    my ($self, %args) = @_;
    my $channel = $args{channel};
    my $candidate = $args{candidate};
    my $trigger = $args{trigger};
    my $mode = defined($args{mode}) && !ref($args{mode})
        ? lc "$args{mode}" : 'mention';
    return 0 unless defined($channel) && !ref($channel) && $channel =~ /^#/;
    return 0 unless defined($candidate) && !ref($candidate) && length($candidate);
    return 0 unless defined($trigger) && !ref($trigger) && length($trigger);

    my $runtime = hailo_post_edit_runtime($self);
    return 0 unless $runtime;
    my $generation = eval {
        $self->{wit_runtime_state}->capture_generation($channel)
    };
    unless (defined($generation) && $generation =~ /^[1-9]\d*\z/) {
        $self->{metrics}->inc(
            'mediabot_hailo_post_edit_total', { result => 'dropped_runtime_unready' }
        ) if $self->{metrics};
        return 0;
    }

    my $state_cb = sub {
        my $policy = hailo_channel_policy($self, $channel, fresh => 1);
        my $enabled = $policy->{master}
            && ($mode eq 'chatter' ? $policy->{chatter} : $policy->{respond});
        my $state = eval { $self->{wit_runtime_state}->snapshot($channel) };
        $state = {} unless ref($state) eq 'HASH';
        return {
            enabled            => $enabled ? 1 : 0,
            runtime_active     => $state->{runtime_active} ? 1 : 0,
            irc_connected      => $state->{irc_connected} ? 1 : 0,
            channel_joined     => $state->{channel_joined} ? 1 : 0,
            current_generation => $state->{current_generation} || 0,
        };
    };

    my $provider = eval {
        $self->{conf}->get('hailo.HAILO_POST_EDIT_PROVIDER')
    };
    $provider = 'auto' unless defined($provider) && !ref($provider)
        && $provider =~ /^(?:auto|anthropic|openai|gemini)\z/i;

    my $queued = $runtime->submit(
        channel            => $channel,
        trigger            => $trigger,
        candidate          => $candidate,
        channel_language   => Mediabot::Helpers::channel_lang($self, $channel),
        provider           => lc "$provider",
        mode               => $mode,
        post_edit_enabled  => _hailo_conf_bool(
            $self, 'HAILO_POST_EDIT_ENABLED', 1
        ),
        request_generation => $generation,
        command_prefixes   => _hailo_command_prefixes($self),
        state_cb           => $state_cb,
        send_cb            => sub {
            my ($target, $line) = @_;
            return Mediabot::Helpers::botPrivmsg($self, $target, $line) ? 1 : 0;
        },
    );
    return ref($queued) eq 'HASH' && $queued->{accepted} ? 1 : 0;
}

sub hailo_process_turn {
    my ($self, %args) = @_;
    my $channel = $args{channel};
    my $speaker = $args{speaker};
    my $raw = $args{text};
    return { ok => 0, reason => 'invalid_turn' }
        unless defined($channel) && !ref($channel) && defined($speaker)
            && !ref($speaker) && defined($raw) && !ref($raw);

    my $policy_state = hailo_channel_policy($self, $channel);
    my $nicks = _hailo_channel_nicks($self, $channel);
    my $bot_nick = eval { $self->{irc}->nick_folded } || '';
    my $prefixes = _hailo_command_prefixes($self);
    my $max_input = eval { $self->{conf}->get('hailo.HAILO_MAX_INPUT_CHARS') };

    my $normalized = normalize_hailo_input(
        channel          => $channel,
        speaker          => $speaker,
        bot_nick         => $bot_nick,
        nicks            => $nicks,
        text             => $raw,
        command_prefixes => $prefixes,
        max_chars        => $max_input,
    );
    return { ok => 0, reason => $normalized->{reason} || 'normalization_failed' }
        unless $normalized->{ok};

    my $policy = $self->{hailo_policy};
    return { ok => 0, reason => 'policy_unavailable' }
        unless $policy && eval { $policy->can('decide') };

    my $excluded = exists($args{excluded}) ? ($args{excluded} ? 1 : 0)
        : is_hailo_excluded_nick($self, $speaker);
    my $decision = $policy->decide(
        channel          => $channel,
        speaker          => $speaker,
        text             => $normalized->{text},
        mode             => $args{mode} || 'ambient',
        master_enabled   => $policy_state->{master},
        learn_enabled    => $policy_state->{learn},
        respond_enabled  => $policy_state->{respond},
        chatter_enabled  => $policy_state->{chatter},
        excluded         => $excluded,
        is_command       => $normalized->{is_command},
        force_authorized => $args{force_authorized} ? 1 : 0,
    );

    return {
        ok         => 1,
        reason     => 'policy_denied',
        decision   => $decision,
        normalized => $normalized,
        policy     => $policy_state,
    } unless $decision->{reply} || $decision->{learn};

    my $result = hailo_reply_before_learning(
        $self,
        channel => $channel,
        text    => $decision->{text},
        reply   => $decision->{reply},
        learn   => $decision->{learn},
        (defined($args{brain}) ? (brain => $args{brain}) : ()),
    );
    return { ok => 0, reason => 'brain_unavailable', decision => $decision }
        unless ref($result) eq 'HASH';

    $policy->record_learn(channel => $channel, speaker => $speaker)
        if $result->{learned};

    my $candidate;
    my $output_reason = 'no_candidate';
    if (defined($result->{candidate}) && !ref($result->{candidate})
        && length($result->{candidate})) {
        my $max_output = eval { $self->{conf}->get('hailo.HAILO_MAX_OUTPUT_CHARS') };
        my $output = rehydrate_hailo_output(
            channel          => $channel,
            speaker          => $speaker,
            bot_nick         => $bot_nick,
            nicks            => $nicks,
            bucket_nicks     => $normalized->{bucket_nicks},
            command_prefixes => $prefixes,
            max_chars        => $max_output,
            text             => $result->{candidate},
        );
        $output_reason = $output->{reason} || 'output_rejected';
        if ($output->{ok}
            && $output->{line} !~ /^\Q$decision->{text}\E\s*[.]?\s*\z/i) {
            $candidate = $output->{line};
            $output_reason = 'accepted';
            $policy->record_reply(channel => $channel, speaker => $speaker);
        }
        elsif ($output->{ok}) {
            $output_reason = 'echo_rejected';
        }
    }

    return {
        ok            => 1,
        reason        => defined($candidate) ? 'candidate' : $output_reason,
        candidate     => $candidate,
        learned       => $result->{learned} ? 1 : 0,
        decision      => $decision,
        normalized    => $normalized,
        policy        => $policy_state,
        output_reason => $output_reason,
    };
}

# Generate before learning. This deliberately does not use learn_reply(): the
# triggering line must not become eligible material for its own answer.
sub hailo_reply_before_learning {
    my ($self, %args) = @_;
    my $channel = $args{channel};
    my $text = $args{text};
    return undef unless defined($channel) && $channel ne '';
    return undef unless defined($text) && !ref($text) && $text ne '';

    my $hailo = $args{brain} || get_hailo_runtime($self, $channel);
    return undef unless $hailo;

    my $timeout = eval { $self->{conf}->get('hailo.HAILO_OPERATION_TIMEOUT') };
    $timeout = 5 unless defined($timeout) && !ref($timeout)
        && "$timeout" =~ /^\d+\z/ && $timeout >= 1 && $timeout <= 10;

    my $candidate;
    my $reply_error;
    if ($args{reply}) {
        my $ok = eval {
            local $SIG{ALRM} = sub { die "Hailo reply timeout\n" };
            alarm($timeout);
            $candidate = $hailo->reply($text);
            alarm(0);
            1;
        };
        alarm(0);
        if (!$ok) {
            my $error = $@ || 'unknown Hailo reply failure';
            $error =~ s/[\r\n]+/ /g;
            $self->{logger}->log(1, "Hailo per-channel reply failed: $error")
                if $self->{logger};
            $self->{metrics}->inc('mediabot_hailo_timeout_total')
                if $self->{metrics} && $error =~ /timeout/i;
            $reply_error = $error;
            $candidate = undef;
        }
    }

    my $learned = 0;
    my $learn_error;
    if ($args{learn}) {
        my $ok = eval {
            local $SIG{ALRM} = sub { die "Hailo learn timeout\n" };
            alarm($timeout);
            $hailo->learn($text);
            alarm(0);
            1;
        };
        alarm(0);
        if ($ok) {
            $learned = 1;
        }
        else {
            my $error = $@ || 'unknown Hailo learn failure';
            $error =~ s/[\r\n]+/ /g;
            $self->{logger}->log(1, "Hailo per-channel learn failed: $error")
                if $self->{logger};
            $self->{metrics}->inc('mediabot_hailo_timeout_total')
                if $self->{metrics} && $error =~ /timeout/i;
            $learn_error = $error;
        }
    }

    return {
        candidate => $candidate,
        learned   => $learned,
        (defined($reply_error) ? (reply_error => $reply_error) : ()),
        (defined($learn_error) ? (learn_error => $learn_error) : ()),
    };
}

# Return one RFC1459-casemapped key for a plain IRC nickname. Configuration
# lists share this representation so []\\^ and {}|~ variants cannot bypass an
# explicit HAILO_IGNORE_NICKS or known-bot decision.
sub _hailo_irc_nick_key {
    my ($nick) = @_;

    return undef unless defined($nick) && !ref($nick);
    $nick = "$nick";
    $nick =~ s/^\s+|\s+$//g;
    return undef unless length($nick) >= 1
        && length($nick) <= 100
        && $nick !~ /[\s,:\x00-\x1f\x7f]/;

    my $key = lc($nick);
    $key =~ tr/[]\\^/{}|~/;
    return $key;
}

# Configuration exclusions are evaluated before the SQL cache on every call.
# A SIGHUP/.reloadconf therefore applies HAILO_IGNORE_NICKS immediately and
# removing a nick from the list cannot leave a stale positive cache entry.
sub _hailo_config_ignores_nick {
    my ($self, $wanted) = @_;
    return 0 unless defined($wanted) && $self;

    my %ignored;
    my $live_nick = eval { $self->{irc}->nick_folded };
    my $live_key = _hailo_irc_nick_key($live_nick);
    $ignored{$live_key} = 1 if defined $live_key;

    my $configured_nick = eval {
        $self->{conf}->get('connection.CONN_NICK')
    };
    my $configured_key = _hailo_irc_nick_key($configured_nick);
    $ignored{$configured_key} = 1 if defined $configured_key;

    for my $config_key ('main.BOT_NICKS', 'hailo.HAILO_IGNORE_NICKS') {
        my $list = eval { $self->{conf}->get($config_key) };
        next unless defined($list) && !ref($list);
        for my $raw (split /,/, "$list") {
            my $key = _hailo_irc_nick_key($raw);
            $ignored{$key} = 1 if defined $key;
        }
    }

    return $ignored{$wanted} ? 1 : 0;
}

# Keep the historical SQL cache aligned with the database collation. The SQL
# table does not store an RFC1459 canonical column, so bracket variants must
# not share a negative cache entry with a different literal database value.
sub _hailo_sql_cache_key {
    my ($nick) = @_;
    return undef unless defined($nick) && !ref($nick);
    $nick = "$nick";
    $nick =~ s/^\s+|\s+$//g;
    return length($nick) ? lc($nick) : undef;
}

# Clean up and exit the program (with proper Net::Async::IRC QUIT)
# Check whether Hailo should ignore a nick. The live bot identity, BOT_NICKS
# and HAILO_IGNORE_NICKS are authoritative even if the database is unavailable.
sub is_hailo_excluded_nick {
    my ($self, $nick) = @_;

    my $identity_key = _hailo_irc_nick_key($nick);
    return 0 unless defined $identity_key;
    return 1 if _hailo_config_ignores_nick($self, $identity_key);
    return 0 unless $self->{dbh};

    # mb122-B1: cache TTL 30s. La table HAILO_EXCLUSION_NICK utilise
    # utf8mb4_unicode_ci, so its cache remains lowercase and literal.
    my $cache_key = _hailo_sql_cache_key($nick);
    return 0 unless defined $cache_key;
    my $now       = time();
    my $ttl       = 30;
    if (exists $self->{_hailo_excl_cache}{$cache_key}) {
        my $entry = $self->{_hailo_excl_cache}{$cache_key};
        if (($now - $entry->{ts}) < $ttl) {
            return $entry->{val};
        }
    }

    my $sQuery = "SELECT 1 FROM HAILO_EXCLUSION_NICK WHERE nick = ?";
    my $sth = $self->{dbh}->prepare($sQuery);

    unless ($sth) {
        $self->{logger}->log(1, "is_hailo_excluded_nick() SQL prepare error: $DBI::errstr Query: $sQuery")
            if $self->{logger};
        return 0;
    }

    unless ($sth && $sth->execute($nick)) {
        $self->{logger}->log(1, "is_hailo_excluded_nick() SQL execute error: $DBI::errstr Query: $sQuery")
            if $self->{logger};
        $sth->finish;
        return 0;
    }

    my $excluded = $sth->fetchrow_hashref() ? 1 : 0;
    $sth->finish;

    $self->{_hailo_excl_cache}{$cache_key} = { val => $excluded, ts => $now };

    return $excluded;
}


# hailo_ignore <nick>
# Add a nick to HAILO_EXCLUSION_NICK so Hailo will ignore it
# Requires: authenticated + Master
# hailo_ignore <nick>
# Add a nick to HAILO_EXCLUSION_NICK so Hailo will ignore it
# Requires: authenticated + Master
sub hailo_ignore_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $caller  = $ctx->nick;
    my $message = $ctx->message;

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    my $user = $ctx->user // eval { $self->get_user_from_message($message) };

    unless ($user && $user->is_authenticated) {
        my $who = eval { $user->nickname } // $caller // "unknown";
        my $pfx = eval { $message->prefix } // $who;
        my $msg = "$pfx hailo_ignore command attempt (user $who is not logged in)";
        noticeConsoleChan($self, $msg);
        botNotice(
            $self,
            $caller,
            "You must be logged to use this command - /msg "
              . $self->{irc}->nick_folded
              . " login username password"
        );
        return;
    }

    unless (eval { $user->has_level('Master') }) {
        my $lvl = eval { $user->level_description } || eval { $user->level } || 'undef';
        my $who = eval { $user->nickname } // $caller;
        my $pfx = eval { $message->prefix } // $who;
        my $msg = "$pfx hailo_ignore command attempt (command level [Master] for user $who [$lvl])";
        noticeConsoleChan($self, $msg);
        botNotice($self, $caller, "Your level does not allow you to use this command.");
        return;
    }

    unless (defined $args[0] && $args[0] ne '') {
        botNotice($self, $caller, "Syntax: hailo_ignore <nick>");
        return;
    }

    my $target_nick = $args[0];

    my $sql = "SELECT id_hailo_exclusion_nick FROM HAILO_EXCLUSION_NICK WHERE nick = ?";
    my $sth = $self->{dbh}->prepare($sql);

    unless ($sth) {
        $self->{logger}->log(1, "hailo_ignore_ctx() SQL prepare error (SELECT): $DBI::errstr | Query: $sql")
            if $self->{logger};
        botNotice($self, $caller, "Database error while checking Hailo ignore for $target_nick.");
        return;
    }

    unless ($sth && $sth->execute($target_nick)) {
        $self->{logger}->log(1, "hailo_ignore_ctx() SQL execute error (SELECT): $DBI::errstr | Query: $sql")
            if $self->{logger};
        $sth->finish;
        botNotice($self, $caller, "Database error while checking Hailo ignore for $target_nick.");
        return;
    }

    if (my $ref = $sth->fetchrow_hashref) {
        $sth->finish;
        botNotice($self, $caller, "Nick $target_nick is already ignored by Hailo (id $ref->{id_hailo_exclusion_nick}).");
        return;
    }

    $sth->finish;

    $sql = "INSERT INTO HAILO_EXCLUSION_NICK (nick) VALUES (?)";
    $sth = $self->{dbh}->prepare($sql);

    unless ($sth) {
        $self->{logger}->log(1, "hailo_ignore_ctx() SQL prepare error (INSERT): $DBI::errstr | Query: $sql")
            if $self->{logger};
        botNotice($self, $caller, "Database error while adding Hailo ignore for $target_nick.");
        return;
    }

    unless ($sth && $sth->execute($target_nick)) {
        $self->{logger}->log(1, "hailo_ignore_ctx() SQL execute error (INSERT): $DBI::errstr | Query: $sql")
            if $self->{logger};
        $sth->finish;
        botNotice($self, $caller, "Database error while adding Hailo ignore for $target_nick.");
        return;
    }

    $sth->finish;

    # mb122-B1: invalidate cache after INSERT
    my $cache_key = _hailo_sql_cache_key($target_nick);
    delete $self->{_hailo_excl_cache}{$cache_key} if defined $cache_key;

    botNotice($self, $caller, "Hailo will now ignore nick $target_nick.");
    logBot($self, $message, $ctx->channel, "hailo_ignore", $target_nick);

    return 1;
}


# hailo_unignore <nick>
# Remove a nick from HAILO_EXCLUSION_NICK so Hailo will reply again
# Requires: authenticated + Master
# hailo_unignore <nick>
# Remove a nick from HAILO_EXCLUSION_NICK so Hailo will reply again
# Requires: authenticated + Master
sub hailo_unignore_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $caller  = $ctx->nick;
    my $chan    = $ctx->channel;
    my $message = $ctx->message;

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    my $user = $ctx->user // eval { $self->get_user_from_message($message) };

    unless ($user && $user->is_authenticated) {
        my $who = eval { $user->nickname } // $caller // "unknown";
        my $pfx = eval { $message->prefix } // $who;
        my $msg = "$pfx hailo_unignore command attempt (user $who is not logged in)";
        noticeConsoleChan($self, $msg);
        botNotice(
            $self,
            $caller,
            "You must be logged to use this command - /msg "
              . $self->{irc}->nick_folded
              . " login username password"
        );
        return;
    }

    unless (eval { $user->has_level('Master') }) {
        my $lvl = eval { $user->level_description } || eval { $user->level } || 'undef';
        my $who = eval { $user->nickname } // $caller;
        my $pfx = eval { $message->prefix } // $who;
        my $msg = "$pfx hailo_unignore command attempt (command level [Master] for user $who [$lvl])";
        noticeConsoleChan($self, $msg);
        botNotice($self, $caller, "Your level does not allow you to use this command.");
        return;
    }

    unless (defined $args[0] && $args[0] ne '') {
        botNotice($self, $caller, "Syntax: hailo_unignore <nick>");
        return;
    }

    my $target_nick = $args[0];

    my $sql = "SELECT id_hailo_exclusion_nick FROM HAILO_EXCLUSION_NICK WHERE nick = ?";
    my $sth = $self->{dbh}->prepare($sql);

    unless ($sth) {
        $self->{logger}->log(1, "hailo_unignore_ctx() SQL prepare error (SELECT): $DBI::errstr | Query: $sql")
            if $self->{logger};
        botNotice($self, $caller, "Database error while checking Hailo ignore for $target_nick.");
        return;
    }

    unless ($sth && $sth->execute($target_nick)) {
        $self->{logger}->log(1, "hailo_unignore_ctx() SQL execute error (SELECT): $DBI::errstr | Query: $sql")
            if $self->{logger};
        $sth->finish;
        botNotice($self, $caller, "Database error while checking Hailo ignore for $target_nick.");
        return;
    }

    my $row = $sth->fetchrow_hashref;
    $sth->finish;

    unless ($row) {
        botNotice($self, $caller, "Nick $target_nick is not ignored by Hailo.");
        return;
    }

    my $id_excl = $row->{id_hailo_exclusion_nick};

    $sql = "DELETE FROM HAILO_EXCLUSION_NICK WHERE id_hailo_exclusion_nick = ?";
    $sth = $self->{dbh}->prepare($sql);

    unless ($sth) {
        $self->{logger}->log(1, "hailo_unignore_ctx() SQL prepare error (DELETE): $DBI::errstr | Query: $sql")
            if $self->{logger};
        botNotice($self, $caller, "Database error while removing Hailo ignore for $target_nick.");
        return;
    }

    unless ($sth && $sth->execute($id_excl)) {
        $self->{logger}->log(1, "hailo_unignore_ctx() SQL execute error (DELETE): $DBI::errstr | Query: $sql")
            if $self->{logger};
        $sth->finish;
        botNotice($self, $caller, "Database error while removing Hailo ignore for $target_nick.");
        return;
    }

    $sth->finish;

    # mb122-B1: invalidate cache after DELETE
    my $cache_key = _hailo_sql_cache_key($target_nick);
    delete $self->{_hailo_excl_cache}{$cache_key} if defined $cache_key;

    botNotice($self, $caller, "Hailo will no longer ignore nick $target_nick.");
    logBot($self, $message, $chan, "hailo_unignore", $target_nick);

    return 1;
}


# hailo_status
# Show Hailo brain statistics (tokens, expressions, links, etc.)
# Requires: authenticated + Master
sub hailo_status_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my $message = $ctx->message;

    my $user = $ctx->user // eval { $self->get_user_from_message($message) };

    # --- Auth check ---
    unless ($user && $user->is_authenticated) {
        my $who = eval { $user->nickname } // $nick // "unknown";
        my $pfx = eval { $message->prefix } // $who;
        my $msg = "$pfx hailo_status command attempt (user $who is not logged in)";
        noticeConsoleChan($self, $msg);
        botNotice(
            $self,
            $nick,
            "You must be logged to use this command - /msg "
              . $self->{irc}->nick_folded
              . " login username password"
        );
        return;
    }

    # --- Permission check: Master+ ---
    unless (eval { $user->has_level('Master') }) {
        my $lvl = eval { $user->level_description } || eval { $user->level } || 'undef';
        my $who = eval { $user->nickname } // $nick;
        my $pfx = eval { $message->prefix } // $who;
        my $msg = "$pfx hailo_status command attempt (command level [Master] for user $who [$lvl])";
        noticeConsoleChan($self, $msg);
        botNotice($self, $nick, "Your level does not allow you to use this command.");
        return;
    }

    # --- Get Hailo object ---
    my $hailo = eval { get_hailo($self, $channel) };
    if ($@ || !$hailo) {
        $self->{logger}->log(1, "hailo_status_ctx(): failed to get Hailo object: $@");
        botNotice($self, $nick, "Internal error: could not access Hailo brain.");
        return;
    }

    # --- Get stats from Hailo ---
    my $stats_raw = eval { $hailo->stats };
    if ($@) {
        $self->{logger}->log(1, "hailo_status_ctx(): Hailo->stats died: $@");
        botNotice($self, $nick, "Internal error: Hailo stats() failed.");
        return;
    }
    unless (defined $stats_raw) {
        botNotice($self, $nick, "Hailo did not return any stats.");
        return;
    }

    my $summary;
    my $extra = "";

    if (ref $stats_raw eq 'HASH') {
        my $href = $stats_raw;

        # Generic listing of all available keys
        my @pairs;
        for my $k (sort keys %$href) {
            next unless defined $href->{$k};
            push @pairs, "$k=$href->{$k}";
        }
        $summary = join(", ", @pairs) || "No stats available";

        # Try to compute some useful derived metrics if we recognize keys
        my $tokens = $href->{tokens};
        my $prev   = $href->{previous_token_links} // $href->{previous_links};
        my $next   = $href->{next_token_links}     // $href->{next_links};

        if (defined $tokens && $tokens > 0 && defined $prev && defined $next) {
            my $total_links = $prev + $next;
            my $avg_links   = sprintf("%.2f", $total_links / $tokens);
            # Y3: human-readable format for Hailo brain stats
            my $size_k = int($tokens / 1000);
            $extra = $size_k > 0
                ? sprintf(' | ~%dk tokens, %.1f links/token', $size_k, $avg_links)
                : sprintf(' | %d tokens, %.1f links/token', $tokens, $avg_links);
        }
    }
    else {
        # Old behaviour: stats() returns a simple string like
        # "X tokens, Y expressions, Z previous links and W next links"
        $summary = $stats_raw;
    }

    my $msg_out = "Hailo stats: $summary$extra";

    if (defined $channel && $channel ne '') {
        botPrivmsg($self, $channel, $msg_out);
        logBot($self, $message, $channel, "hailo_status", undef);
    } else {
        botNotice($self, $nick, $msg_out);
        logBot($self, $message, undef, "hailo_status", undef);
    }

    return 1;
}

# Get the Hailo chatter ratio for a specific channel
# Get the Hailo chatter ratio for a specific channel
sub get_hailo_channel_ratio {
    my ($self, $sChannel) = @_;

    return -1 unless defined($sChannel) && $sChannel ne '';
    return -1 unless $self->{dbh};

    # mb432-R1: cache avec TTL. hailo_should_chatter() est appelé à CHAQUE
    # message public d'un canal ; sans cache, get_hailo_channel_ratio faisait
    # un SELECT+JOIN par message. Le ratio ne change que par commande
    # (set_hailo_channel_ratio, qui invalide ce cache) -> on peut le mémoriser.
    # Clé lc (mb407). TTL 60 s : une modif externe de la table est prise en
    # compte au prochain rafraîchissement.
    my $ckey = lc $sChannel;
    my $now  = time();
    my $cached = $self->{_hailo_ratio_cache}{$ckey};
    if ($cached && ($now - $cached->{ts}) < 60) {
        return $cached->{ratio};
    }

    my $sQuery = "SELECT HAILO_CHANNEL.ratio FROM HAILO_CHANNEL JOIN CHANNEL ON CHANNEL.id_channel = HAILO_CHANNEL.id_channel WHERE CHANNEL.name = ?";
    my $sth = $self->{dbh}->prepare($sQuery);

    unless ($sth) {
        $self->{logger}->log(1, "get_hailo_channel_ratio() SQL prepare error: $DBI::errstr Query: $sQuery")
            if $self->{logger};
        return -1;
    }

    unless ($sth && $sth->execute($sChannel)) {
        $self->{logger}->log(1, "get_hailo_channel_ratio() SQL execute error: $DBI::errstr Query: $sQuery")
            if $self->{logger};
        $sth->finish;
        return -1;
    }

    my $ratio = -1;
    if (my $ref = $sth->fetchrow_hashref()) {
        $ratio = $ref->{ratio};
    }

    $sth->finish;
    # mb432-R1: mémoriser (y compris -1 = non configuré, pour éviter de
    # re-SELECT à chaque message sur un canal sans ratio).
    $self->{_hailo_ratio_cache}{$ckey} = { ts => $now, ratio => $ratio };
    return $ratio;
}


# Set the Hailo chatter ratio for a specific channel
# Set the Hailo chatter ratio for a specific channel
sub set_hailo_channel_ratio {
    my ($self, $sChannel, $ratio) = @_;

    return undef unless defined($sChannel) && $sChannel ne '';
    return undef unless defined($ratio);

    # A4: validate ratio is an integer in [0, 100]
    unless ($ratio =~ /^\d+$/ && $ratio >= 0 && $ratio <= 100) {
        $self->{logger}->log(1, "set_hailo_channel_ratio() invalid ratio '$ratio' -- must be 0-100");
        return undef;
    }
    $ratio = int($ratio);

    my $channel_obj = $self->{channels}{lc $sChannel} || $self->{channels}{lc($sChannel)};

    unless (defined $channel_obj) {
        $self->{logger}->log(1, "set_hailo_channel_ratio() unknown channel: $sChannel")
            if $self->{logger};
        return undef;
    }

    my $id_channel = $channel_obj->get_id;

    unless (defined $id_channel) {
        $self->{logger}->log(1, "set_hailo_channel_ratio() cannot resolve id_channel for $sChannel")
            if $self->{logger};
        return undef;
    }

    my $sQuery = "SELECT ratio FROM HAILO_CHANNEL WHERE id_channel = ?";
    my $sth = $self->{dbh}->prepare($sQuery);

    unless ($sth) {
        $self->{logger}->log(1, "set_hailo_channel_ratio() SQL prepare error (SELECT): $DBI::errstr | Query: $sQuery")
            if $self->{logger};
        return undef;
    }

    unless ($sth && $sth->execute($id_channel)) {
        $self->{logger}->log(1, "set_hailo_channel_ratio() SQL execute error (SELECT): $DBI::errstr | Query: $sQuery")
            if $self->{logger};
        $sth->finish;
        return undef;
    }

    my $ref_check = $sth->fetchrow_hashref();
    $sth->finish;

    if ($ref_check) {
        $sQuery = "UPDATE HAILO_CHANNEL SET ratio = ? WHERE id_channel = ?";
        $sth = $self->{dbh}->prepare($sQuery);

        unless ($sth) {
            $self->{logger}->log(1, "set_hailo_channel_ratio() SQL prepare error (UPDATE): $DBI::errstr | Query: $sQuery")
                if $self->{logger};
            return undef;
        }

        unless ($sth && $sth->execute($ratio, $id_channel)) {
            $self->{logger}->log(1, "set_hailo_channel_ratio() SQL execute error (UPDATE): $DBI::errstr | Query: $sQuery")
                if $self->{logger};
            $sth->finish;
            return undef;
        }

        $sth->finish;
        # mb435-B2: mb432 invalidated the cache only after INSERT. The common
        # UPDATE path returned first, leaving the old ratio active for up to
        # 60 seconds. Invalidate here too so an existing channel changes now.
        delete $self->{_hailo_ratio_cache}{lc $sChannel};
        $self->{logger}->log(3, "set_hailo_channel_ratio updated hailo chatter ratio to $ratio for $sChannel")
            if $self->{logger};
        return 0;
    }

    $sQuery = "INSERT INTO HAILO_CHANNEL (id_channel, ratio) VALUES (?, ?)";
    $sth = $self->{dbh}->prepare($sQuery);

    unless ($sth) {
        $self->{logger}->log(1, "set_hailo_channel_ratio() SQL prepare error (INSERT): $DBI::errstr | Query: $sQuery")
            if $self->{logger};
        return undef;
    }

    unless ($sth && $sth->execute($id_channel, $ratio)) {
        $self->{logger}->log(1, "set_hailo_channel_ratio() SQL execute error (INSERT): $DBI::errstr | Query: $sQuery")
            if $self->{logger};
        $sth->finish;
        return undef;
    }

    $sth->finish;
    # mb432-R1: invalider le cache de ratio pour ce canal afin qu'un changement
    # prenne effet immédiatement (sinon le TTL pouvait retarder l'application).
    delete $self->{_hailo_ratio_cache}{lc $sChannel};
    $self->{logger}->log(3, "set_hailo_channel_ratio set hailo chatter ratio to $ratio for $sChannel")
        if $self->{logger};
    return 0;
}


# =============================================================================
# mb370-B1 — Décision de chatter HailoChatter : taux ADAPTATIF au débit du canal.
#
# Avant, la décision (dans mediabot.pl) était `rand(100) >= ratio`, ce qui était :
#   (a) INVERSÉ — ratio=97 donnait ~3 % de réponses au lieu de 97 % ;
#   (b) AVEUGLE AU DÉBIT — une probabilité par-message fixe inonde un canal très
#       actif et reste muette sur un canal calme.
#
# Désormais le `ratio` (0-100, stocké en base, INCHANGÉ) reste la cible, et la
# probabilité EFFECTIVE est modulée par le débit récent du canal :
#   - canal au rythme de référence ou plus calme  -> proba effective = ratio ;
#   - canal plus rapide que la référence           -> proba réduite
#     proportionnellement (ref/count), avec un plancher -> anti-flood.
#
# Tout l'état de débit est EN MÉMOIRE (aucune table, aucune colonne ajoutée).
# Paramètres réglables via [hailo] (get_int, défauts = comportement de référence) :
#   HAILO_CHATTER_RATE_WINDOW     fenêtre de mesure du débit, en secondes (60)
#   HAILO_CHATTER_REFERENCE_MSGS  nb de messages/fenêtre au-delà duquel on bride (10)
#   HAILO_CHATTER_MIN_FACTOR_PCT  plancher du facteur, en % (10) -> proba mini = ratio*10%
# =============================================================================

# Enregistre un message de conversation sur un canal (pour le calcul de débit).
# À appeler pour CHAQUE message public conversationnel.
sub hailo_record_activity {
    my ($self, $channel) = @_;
    return unless defined($channel) && $channel ne '';
    my $now = time();
    my $buf = ($self->{_hailo_activity}{$channel} //= []);
    push @$buf, $now;
    # Bornage mémoire : on ne conserve que la dernière heure, et au plus 600 entrées.
    my $cutoff = $now - 3600;
    shift @$buf while @$buf && $buf->[0] < $cutoff;
    splice(@$buf, 0, scalar(@$buf) - 600) if @$buf > 600;
    return;
}

# Nombre de messages enregistrés dans la fenêtre des $window dernières secondes.
sub _hailo_recent_count {
    my ($self, $channel, $window) = @_;
    my $buf = $self->{_hailo_activity}{$channel} or return 0;
    my $cutoff = time() - $window;
    my $n = 0;
    for my $ts (@$buf) { $n++ if $ts >= $cutoff; }
    return $n;
}

# Lecture entière de config avec repli (utilise get_int si dispo).
sub _hailo_conf_int {
    my ($self, $key, $default, $min, $max) = @_;
    my $conf = $self->{conf};
    return $default unless $conf && $conf->can('get_int');
    return $conf->get_int($key, default => $default, min => $min, max => $max);
}

# Probabilité effective (0-100) modulée par le débit récent du canal.
sub _hailo_effective_pct {
    my ($self, $channel, $base) = @_;
    return 0 if !defined($base) || $base <= 0;
    $base = 100 if $base > 100;

    my $window = _hailo_conf_int($self, 'hailo.HAILO_CHATTER_RATE_WINDOW',    60,  5, 3600);
    my $ref    = _hailo_conf_int($self, 'hailo.HAILO_CHATTER_REFERENCE_MSGS', 10,  1, 10000);
    my $minpct = _hailo_conf_int($self, 'hailo.HAILO_CHATTER_MIN_FACTOR_PCT', 10,  1, 100);

    my $count  = _hailo_recent_count($self, $channel, $window);
    # Facteur de débit : 1.0 jusqu'à la référence, puis décroît en ref/count.
    my $factor = ($count <= $ref) ? 1.0 : ($ref / $count);
    my $floor  = $minpct / 100;
    $factor = $floor if $factor < $floor;

    my $eff = $base * $factor;
    $eff = 100 if $eff > 100;
    $eff = 0   if $eff < 0;
    return $eff;
}

# Décision finale : le bot doit-il chatter (HailoChatter) sur ce canal maintenant ?
# Renvoie 0 si le canal n'a pas de ratio configuré (-1) -> on retombe sur la
# branche d'apprentissage, comme avant.
sub hailo_should_chatter {
    my ($self, $channel) = @_;
    my $ratio = $self->get_hailo_channel_ratio($channel);
    return 0 unless defined($ratio) && $ratio >= 0;   # -1 = non configuré
    my $eff = _hailo_effective_pct($self, $channel, $ratio);
    return (rand(100) < $eff) ? 1 : 0;
}



# hailo_chatter
# Get or set Hailo chatter ratio for a given channel.
# - Query: hailo_chatter [#channel]
# - Set:   hailo_chatter [#channel] <ratio 0-100>
#
# mb371-B1: since mb370 the value stored in HAILO_CHANNEL.ratio is the direct
# user-facing reply percentage.  The command must therefore read and write the
# same value.  Keeping the former `100 - ratio` conversion here would undo the
# mb370 runtime fix (for example, asking for 97% would store 3 and chatter at
# roughly 3% on a calm channel).
sub hailo_chatter_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my $message = $ctx->message;

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # --- Auth / permission checks (Master+) ---
    my $user = $ctx->user // eval { $self->get_user_from_message($message) };

    unless ($user && $user->is_authenticated) {
        my $who = eval { $user->nickname } // $nick // "unknown";
        my $pfx = eval { $message->prefix } // $who;
        my $msg = "$pfx hailo_chatter command attempt (user $who is not logged in)";
        noticeConsoleChan($self, $msg);
        botNotice(
            $self,
            $nick,
            "You must be logged to use this command - /msg "
              . $self->{irc}->nick_folded
              . " login username password"
        );
        return;
    }

    unless (eval { $user->has_level('Master') }) {
        my $lvl = eval { $user->level_description } || eval { $user->level } || 'undef';
        my $who = eval { $user->nickname } // $nick;
        my $pfx = eval { $message->prefix } // $who;
        my $msg = "$pfx hailo_chatter command attempt (command level [Master] for user $who [$lvl])";
        noticeConsoleChan($self, $msg);
        botNotice($self, $nick, "Your level does not allow you to use this command.");
        return;
    }

    # --- Resolve target channel ---
    my $target_chan = undef;

    # First arg can be a channel name
    if (@args && defined $args[0] && $args[0] =~ /^#/) {
        $target_chan = shift @args;
    } else {
        $target_chan = $channel if defined $channel && $channel =~ /^#/;
    }

    unless (defined $target_chan && $target_chan =~ /^#/) {
        botNotice($self, $nick, "Syntax: hailo_chatter [#channel] <ratio 0-100>");
        return;
    }

    # --- If no numeric arg: just display current ratio ---
    my $is_query_only = 1;
    if (@args && defined $args[0] && $args[0] =~ /^\d+$/) {
        $is_query_only = 0;
    }

    if ($is_query_only) {
        my $stored_ratio = eval { get_hailo_channel_ratio($self, $target_chan) };
        if (!defined $stored_ratio || $stored_ratio == -1) {
            botNotice($self, $nick, "No Hailo chatter ratio set for $target_chan (using default behaviour).");
        } else {
            botNotice(
                $self,
                $nick,
                "Hailo chatter reply chance on $target_chan is currently ${stored_ratio}%."
            );
        }
        logBot($self, $message, $target_chan, "hailo_chatter", "show $target_chan");
        return 1;
    }

    # --- Set mode: hailo_chatter [#channel] <ratio> ---
    my $ratio = $args[0];

    unless (defined $ratio && $ratio =~ /^\d+$/) {
        botNotice($self, $nick, "Syntax: hailo_chatter [#channel] <ratio 0-100>");
        return;
    }
    if ($ratio > 100) {
        botNotice($self, $nick, "Syntax: hailo_chatter [#channel] <ratio 0-100>");
        botNotice($self, $nick, "ratio must be between 0 and 100");
        return;
    }

    # Check that chanset +HailoChatter is enabled
    my $id_chanset_list = eval { getIdChansetList($self, "HailoChatter") };
    unless ($id_chanset_list) {
        botNotice($self, $nick, "Chanset list HailoChatter is not defined.");
        return;
    }

    my $id_channel_set = eval { getIdChannelSet($self, $target_chan, $id_chanset_list) };
    unless ($id_channel_set) {
        botNotice($self, $nick, "Chanset +HailoChatter is not set on $target_chan (use: chanset $target_chan +HailoChatter).");
        return;
    }

    # mb371-B1: store the direct user-facing percentage.  The adaptive runtime
    # consumes this same value as its base probability.
    my $ret = eval { set_hailo_channel_ratio($self, $target_chan, $ratio) };
    if ($@) {
        $self->{logger}->log(1, "hailo_chatter_ctx(): set_hailo_channel_ratio died: $@");
        botNotice($self, $nick, "Internal error while setting Hailo chatter ratio.");
        return;
    }

    # set_hailo_channel_ratio returns 0 on success and undef on error
    if (defined $ret) {
        botNotice($self, $nick, "HailoChatter's ratio is now set to ${ratio}% on $target_chan");
        logBot($self, $message, $target_chan, "hailo_chatter", "set $target_chan $ratio");
        return 1;
    } else {
        botNotice($self, $nick, "Failed to update HailoChatter ratio on $target_chan.");
        return;
    }
}

# whereis <hostname|IP>


# ---------------------------------------------------------------------------
# check_birthdays_today()
# Called daily by the Scheduler. Posts birthday greetings on all auto-join
# channels where the setting birthday_greetings = 1.
# ---------------------------------------------------------------------------
sub check_birthdays_today {
    my ($self) = @_;

    my $dbh = $self->{db} ? $self->{db}->ensure_connected() : $self->{dbh};
    return unless $dbh;

    my @t   = localtime;
    my $mmdd = sprintf("%02d-%02d", $t[4]+1, $t[3]);  # MM-DD today

    # mb433-B1: les personnes nées un 29 février n'ont pas de date le
    # 3 années sur 4. Sans traitement, elles ne sont JAMAIS fêtées hors année
    # bissextile (le MM-DD du jour ne vaut jamais "02-29"). Convention (cohérente
    # avec le "prochain 29 février valide" de mb399) : on observe leur
    # anniversaire le 28 février des années NON bissextiles. On construit donc
    # la liste des MM-DD à faire matcher aujourd'hui.
    my $year    = $t[5] + 1900;
    my $is_leap = ($year % 4 == 0 && ($year % 100 != 0 || $year % 400 == 0)) ? 1 : 0;
    my @match_mmdd = ($mmdd);
    push @match_mmdd, '02-29' if !$is_leap && $mmdd eq '02-28';

    # Match both MM-DD and YYYY-MM-DD formats, pour chaque MM-DD observé.
    my $where = join(' OR ', ('birthday = ? OR birthday LIKE ?') x scalar(@match_mmdd));
    my @binds = map { ($_, "%-$_") } @match_mmdd;
    my $sth = $dbh->prepare(qq{
        SELECT nickname, birthday
        FROM USER
        WHERE birthday IS NOT NULL
          AND ($where)
    });
    unless ($sth && $sth->execute(@binds)) {
        $self->{logger}->log(1, "check_birthdays_today() SQL error: $DBI::errstr");
        $sth->finish if $sth;
        return;
    }

    my @bdays;
    while (my $row = $sth->fetchrow_hashref) {
        push @bdays, $row->{nickname};
    }
    $sth->finish;

    return unless @bdays;

    # Announce on all auto-join channels
    for my $chan_name (keys %{ $self->{channels} || {} }) {
        my $chan = $self->{channels}{lc $chan_name};
        next unless $chan && $chan->auto_join;

        for my $nick (@bdays) {
            $self->{logger}->log(2, "Birthday: $nick on $chan_name");
            Mediabot::Helpers::botPrivmsg($self, $chan_name,
                "Happy Birthday, $nick! 4<3");
        }
    }
}


1;
