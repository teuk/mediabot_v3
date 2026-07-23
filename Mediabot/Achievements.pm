package Mediabot::Achievements;

# =============================================================================
# Mediabot::Achievements — système de succès débloquables
#
# Stockage : JSON persisté dans var/achievements.json
# Structure : { "$nick\x00$channel" => { ach_id => unlock_ts, ... } }
#
# Hooks intégrés depuis :
#   - mediabot.pl on_message_PRIVMSG   → first_msg, chatterbox, megaphone,
#                                         night_owl, early_bird
#   - UserCommands.pm  mbKarma_ctx     → karma_star, karma_legend
#   - UserCommands.pm  mbTrivia (ok)   → trivia_rookie, trivia_champion, trivia_sniper
#   - UserCommands.pm  mbWordCount_ctx → wordsmith
#   - UserCommands.pm  mbActive_ctx    → streak_master (via _seen_days)
#
# Commande : !achievements [nick]   liste pour soi ou un autre
#            !achievements list     affiche tous les achievements possibles
#            !achievements all      affiche cross-canal pour soi
#            !achievements top      classement par nombre de succès
# =============================================================================

use strict;
use Time::HiRes ();
use warnings;
use utf8;
use Encode    ();
use JSON::PP  ();
use File::Path qw(make_path);
use File::Basename qw(dirname);

# -- Définition des achievements -------------------------------------------------
# id        => clef interne (snake_case)
# emoji     => glyphe Unicode affiché
# name      => nom court (affichage IRC)
# desc      => description condition
# rarity    => common | uncommon | rare | epic | legendary
# check_on  => événement déclencheur ('msg', 'karma', 'trivia', 'wordcount', 'activity')
#
# Couleur IRC associée à la rareté :
#   common    = gris  (15) | uncommon = vert (03) | rare = cyan (11)
#   epic      = magenta (13) | legendary = orange (07)
# -----------------------------------------------------------------------------
my %ACH = (
    first_msg => {
        emoji   => '👋',
        name    => 'First Steps',
        desc    => 'Posted a first message on a channel',
        rarity  => 'common',
        check_on => 'msg',
    },
    chatterbox => {
        emoji   => '💬',
        name    => 'Chatterbox',
        desc    => 'Sent 1 000 messages on a channel',
        rarity  => 'uncommon',
        check_on => 'msg',
    },
    megaphone => {
        emoji   => '📢',
        name    => 'Megaphone',
        desc    => 'Sent 10 000 messages on a channel',
        rarity  => 'rare',
        check_on => 'msg',
    },
    icon => {
        emoji   => '🗿',
        name    => 'Icon',
        desc    => 'Sent 50 000 messages on a channel',
        rarity  => 'epic',
        check_on => 'msg',
    },
    legend => {
        emoji   => '⭐',
        name    => 'Legend',
        desc    => 'Sent 100 000 messages on a channel',
        rarity  => 'legendary',
        check_on => 'msg',
    },
    wordsmith => {
        emoji   => '📚',
        name    => 'Wordsmith',
        desc    => 'Used 1 000 distinct words',
        rarity  => 'uncommon',
        check_on => 'wordcount',
    },
    polyglot => {
        emoji   => '🎓',
        name    => 'Polyglot',
        desc    => 'Used 5 000 distinct words',
        rarity  => 'rare',
        check_on => 'wordcount',
    },
    karma_star => {
        emoji   => '🌟',
        name    => 'Karma Star',
        desc    => 'Reached +50 karma on a channel',
        rarity  => 'uncommon',
        check_on => 'karma',
    },
    karma_legend => {
        emoji   => '💫',
        name    => 'Karma Legend',
        desc    => 'Reached +100 karma on a channel',
        rarity  => 'epic',
        check_on => 'karma',
    },
    gift_giver => {
        emoji   => '🎁',
        name    => 'Gift Giver',
        desc    => 'Gave 100 positive karma',
        rarity  => 'rare',
        check_on => 'karma',
    },
    night_owl => {
        emoji   => '🌙',
        name    => 'Night Owl',
        desc    => 'Active between 00h-05h (50+ msgs)',
        rarity  => 'uncommon',
        check_on => 'msg',
    },
    early_bird => {
        emoji   => '🌅',
        name    => 'Early Bird',
        desc    => 'Active between 06h-08h (50+ msgs)',
        rarity  => 'uncommon',
        check_on => 'msg',
    },
    trivia_rookie => {
        emoji   => '🧠',
        name    => 'Trivia Rookie',
        desc    => 'Answered 10 trivia questions correctly',
        rarity  => 'common',
        check_on => 'trivia',
    },
    trivia_champion => {
        emoji   => '🏆',
        name    => 'Trivia Champion',
        desc    => 'Answered 100 trivia questions correctly',
        rarity  => 'rare',
        check_on => 'trivia',
    },
    trivia_sniper => {
        emoji   => '🎯',
        name    => 'Trivia Sniper',
        desc    => 'Answered a trivia question in under 3 seconds',
        rarity  => 'epic',
        check_on => 'trivia',
    },

    # mb116: achievements liés au duel
    duel_warrior => {
        emoji   => '⚔️',
        name    => 'Duel Warrior',
        desc    => 'Won 10 duels on a channel',
        rarity  => 'uncommon',
        check_on => 'duel',
    },
    duel_master => {
        emoji   => '🛡️',
        name    => 'Duel Master',
        desc    => 'Won 50 duels on a channel',
        rarity  => 'rare',
        check_on => 'duel',
    },
    underdog => {
        emoji   => '🐺',
        name    => 'Underdog',
        desc    => 'Won a duel after losing 5 in a row',
        rarity  => 'epic',
        check_on => 'duel',
    },
    star_gazer => {
        emoji   => '🔮',
        name    => 'Star Gazer',
        desc    => 'Consulted the horoscope 30 times',
        rarity  => 'uncommon',
        check_on => 'horoscope',
    },

    # mb117: nouveaux achievements sociaux
    matchmaker => {
        emoji   => '💞',
        name    => 'Matchmaker',
        desc    => 'Calculated 10 compatibility scores',
        rarity  => 'uncommon',
        check_on => 'compat',
    },
    quote_detective => {
        emoji   => '🕵️',
        name    => 'Quote Detective',
        desc    => 'Solved 10 quotegame questions',
        rarity  => 'uncommon',
        check_on => 'quotegame',
    },
    quote_master => {
        emoji   => '📜',
        name    => 'Quote Master',
        desc    => 'Solved 50 quotegame questions',
        rarity  => 'rare',
        check_on => 'quotegame',
    },
    mood_reader => {
        emoji   => '🌡️',
        name    => 'Mood Reader',
        desc    => 'Took the channel temperature 30 times',
        rarity  => 'uncommon',
        check_on => 'mood',
    },
    polyphony => {
        emoji   => '🎼',
        name    => 'Polyphony',
        desc    => 'Active on at least 5 channels',
        rarity  => 'rare',
        check_on => 'polyphony',
    },
);

# -- Couleurs IRC par rareté ----------------------------------------------------
my %RARITY_COLOR = (
    common    => "\x0315",  # gris
    uncommon  => "\x0303",  # vert
    rare      => "\x0311",  # cyan
    epic      => "\x0313",  # magenta
    legendary => "\x0307",  # orange
);

# -- Constructeur ---------------------------------------------------------------
sub new {
    my ($class, %args) = @_;
    my $self = bless {
        path   => $args{path}   // 'var/achievements.json',
        logger => $args{logger},
        bot    => $args{bot},
        data   => {},   # { "$nick\x00$channel" => { id => ts, ... } }
        dirty  => 0,
        last_save => 0,
        # mb559-B1: bounded async queue. An entry remains owned by the parent
        # until a child result is accepted; failures are retried and never
        # acknowledged merely because a worker was started.
        _pending_checks   => {},
        _pending_order    => [],
        _worker_inflight  => undef,
        _worker_process   => undef,
        _worker_seq       => 0,
        _worker_launcher  => $args{worker_launcher},
        _worker_timeout   => $args{worker_timeout},
        _shutting_down    => 0,
    }, $class;
    $self->{_worker_timeout} = 75
        unless defined($self->{_worker_timeout})
            && !ref($self->{_worker_timeout})
            && "$self->{_worker_timeout}" =~ /\A\d+(?:\.\d+)?\z/;
    $self->{_worker_timeout} = 10  if $self->{_worker_timeout} < 10;
    $self->{_worker_timeout} = 180 if $self->{_worker_timeout} > 180;
    $self->_load;
    $self->_metric('set', 'mediabot_achievement_queue_pending', 0);
    $self->_metric('set', 'mediabot_achievement_worker_inflight', 0);
    return $self;
}

# -- Chargement depuis le fichier JSON -----------------------------------------
sub _load {
    my ($self) = @_;
    return unless -f $self->{path};
    open my $fh, '<:utf8', $self->{path} or do {
        $self->_log(1, "Achievements: cannot read $self->{path}: $!");
        return;
    };
    local $/;
    my $json = <$fh>;
    close $fh;
    my $data = eval { JSON::PP->new->utf8(0)->decode($json) };
    if ($@) {
        $self->_log(1, "Achievements: JSON decode error: $@");
        # mb400-B1: préserver le fichier illisible avant qu'un futur save()
        # (qui repartira d'un data vide) ne l'écrase définitivement.
        my $backup = $self->{path} . '.corrupt-' . time();
        if (rename $self->{path}, $backup) {
            $self->_log(1, "Achievements: corrupt data preserved as $backup");
        }
        return;
    }
    $self->{data} = $data if ref $data eq 'HASH';

    # mb430-B1: migration de casse. Les clés sont "lc(nick)\x00<canal>" ; le
    # canal n'était pas replié en lc auparavant, donc un même canal pouvait
    # occuper deux clés selon la casse (#Teuk vs #teuk) -> unlocks dupliqués et
    # récupération manquée. On replie ici toute clé à canal non-lc vers sa
    # forme lc, en fusionnant les achievements (on garde le timestamp le plus
    # ancien en cas de conflit). Aucune donnée perdue.
    {
        my $migrated = 0;
        for my $k (keys %{ $self->{data} }) {
            my ($n, $ch) = split /\x00/, $k, 2;
            $ch = '' unless defined $ch;
            my $lc_ch = lc $ch;
            next if $ch eq $lc_ch;                 # déjà canonique
            my $new_k = $n . "\x00" . $lc_ch;
            my $src = delete $self->{data}{$k};
            for my $id (keys %$src) {
                my $ts = $src->{$id};
                if (!exists $self->{data}{$new_k}{$id}
                    || $ts < $self->{data}{$new_k}{$id}) {
                    $self->{data}{$new_k}{$id} = $ts;   # garde le plus ancien
                }
            }
            $migrated++;
        }
        if ($migrated) {
            $self->{dirty} = 1;
            $self->_log(2, "Achievements: folded $migrated mixed-case channel key(s) to lowercase");
        }
    }

    $self->_log(3, "Achievements: loaded " . scalar(keys %{$self->{data}}) . " profile(s)");
}

# -- Sauvegarde en JSON (avec debounce) -----------------------------------------
sub save {
    my ($self, $force) = @_;
    return unless $force || $self->{dirty};
    # debounce : pas plus d'une sauvegarde toutes les 10s sauf force
    if (!$force && (time() - $self->{last_save}) < 10) {
        return;
    }
    eval {
        make_path(dirname($self->{path})) unless -d dirname($self->{path});
        my $json = JSON::PP->new->utf8(0)->pretty->canonical->encode($self->{data});
        my $tmp  = "$self->{path}.tmp";
        open my $fh, '>:utf8', $tmp or die "open $tmp: $!";
        # mb400-B1: vérifier print ET close avant le rename. Sur disque plein
        # (ENOSPC), print/close échouent silencieusement sinon : le tmp TRONQUÉ
        # était renommé par-dessus le fichier de données -> JSON invalide ->
        # au redémarrage _load() échoue -> data={} -> le save() suivant écrase
        # définitivement tout l'historique achievements. En vérifiant ici, le
        # tmp incomplet n'est jamais promu et le fichier principal reste intact.
        print {$fh} $json or do {
            my $err = $!;
            close $fh;
            unlink $tmp;
            die "write $tmp: $err";
        };
        close $fh or do {
            my $err = $!;
            unlink $tmp;
            die "close $tmp: $err";
        };
        rename $tmp, $self->{path} or die "rename: $!";
    };
    if ($@) {
        $self->_log(1, "Achievements: save error: $@");
        return;
    }
    $self->{dirty}     = 0;
    $self->{last_save} = time();
}

# -- Récupère les achievements d'un nick sur un canal ---------------------------
sub get_for_nick {
    my ($self, $nick, $channel) = @_;
    return {} unless defined $nick;
    my $key = lc($nick) . "\x00" . (defined $channel ? lc($channel) : "");  # mb430-B1: canal en lc (IRC insensible a la casse)
    return $self->{data}{$key} // {};
}

# -- Récupère tous les achievements d'un nick (cross-canal) ---------------------
sub get_for_nick_all {
    my ($self, $nick) = @_;
    return {} unless defined $nick;
    my %merged;
    my $lc_nick = lc($nick);
    for my $k (keys %{$self->{data}}) {
        my ($n, $ch) = split /\x00/, $k, 2;
        next unless $n eq $lc_nick;
        for my $id (keys %{$self->{data}{$k}}) {
            $merged{$id} //= { ts => $self->{data}{$k}{$id}, channel => $ch };
        }
    }
    return \%merged;
}

# -- Compte d'achievements par nick (cross-canal) - pour le top -----------------
sub count_all_nicks {
    my ($self) = @_;
    my %counts;
    for my $k (keys %{$self->{data}}) {
        my ($n) = split /\x00/, $k, 2;
        my %ids;
        $ids{$_} = 1 for keys %{$self->{data}{$k}};
        $counts{$n} //= 0;
        $counts{$n} += scalar keys %ids;
    }
    return \%counts;
}

# -- Déblocage d'un achievement (avec notification IRC) -------------------------
# Retourne 1 si nouvellement débloqué, 0 si déjà obtenu.
sub unlock {
    my ($self, $nick, $channel, $id) = @_;
    return 0 unless defined $nick && defined $id;
    return 0 unless exists $ACH{$id};

    my $key = lc($nick) . "\x00" . (defined $channel ? lc($channel) : "");  # mb430-B1: canal en lc (IRC insensible a la casse)
    return 0 if exists $self->{data}{$key}{$id};

    $self->{data}{$key}{$id} = time();
    $self->{dirty} = 1;
    # mb118: unlocks are rare enough to persist immediately; do not risk
    # losing a freshly unlocked achievement during the debounce window.
    $self->save(1);

    # Notification IRC
    #
    # mb119: public achievement announcements are intentionally gated by
    # +AchievementAnnounce. Achievements themselves are still unlocked and
    # persisted even when the channel does not announce them publicly.
    #
    # Backward compatibility: if the chanset is not present in CHANSET_LIST yet,
    # keep the historical behavior and announce. Once the migration below adds
    # the chanset, channels must explicitly opt in with:
    #   chanset #channel +AchievementAnnounce
    if ($self->{bot} && defined $channel && $channel =~ /^#/) {
        require Mediabot::Helpers;
        # mb118: utilise le helper chanset_enabled (default=1 pour backward compat)
        my $announce = eval {
            Mediabot::Helpers::chanset_enabled(
                $self->{bot}, $channel, 'AchievementAnnounce',
                default => 1,
            );
        } // 1;

        if ($announce) {
            my $a = $ACH{$id};
            my $col = $RARITY_COLOR{$a->{rarity}} // '';
            my $rst = $col ? "\x0f" : '';
            # Affiche : 🏆 Achievement Unlocked! teuk → 🌟 Karma Star (uncommon)
            eval {
                Mediabot::Helpers::botPrivmsg(
                    $self->{bot}, $channel,
                    "\x02🏆 Achievement Unlocked!\x02 $nick → "
                  . $a->{emoji} . " ${col}" . $a->{name} . "${rst} (" . $a->{rarity} . ")"
                );
            };
        }
    }

    if ($self->{bot} && $self->{bot}{metrics}) {
        $self->{bot}{metrics}->inc('mediabot_achievements_unlocked_total',
            { achievement => $id });
    }

    $self->_log(3, "Achievements: unlocked '$id' for $nick on " . ($channel // '?'));
    return 1;
}

# -- Liste de tous les achievements définis (pour affichage) --------------------
sub list_definitions {
    return \%ACH;
}

# -- Couleur IRC associée à une rareté ------------------------------------------
sub rarity_color {
    my (undef, $rarity) = @_;
    return $RARITY_COLOR{$rarity // ''} // '';
}

# -- Hook : vérifie les achievements 'msg' après chaque PRIVMSG ----------------
# mb558 created the bounded queue; mb559 makes its consumer genuinely
# asynchronous. The IRC/event-loop parent only queues work, starts one child at
# a time and applies validated unlock results. CHANNEL_LOG scans run on a fresh
# child-only DB connection and can no longer freeze PRIVMSG, PING/PONG or the
# Scheduler itself.
sub _metric {
    my ($self, $method, @args) = @_;
    my $metrics = $self->{bot} ? $self->{bot}{metrics} : undef;
    return 0 unless $metrics && eval { $metrics->can($method) };
    return eval { $metrics->$method(@args); 1 } ? 1 : 0;
}

sub _sync_queue_metric {
    my ($self) = @_;
    $self->_metric('set', 'mediabot_achievement_queue_pending',
        scalar(keys %{ $self->{_pending_checks} || {} }));
}

sub queue_check {
    my ($self, $nick, $channel) = @_;
    return 0 if $self->{_shutting_down};
    return 0 unless defined $nick && defined $channel && $channel =~ /^#/;

    my $key = lc($nick) . "\x00" . lc($channel);
    my $last = $self->{_msg_check_ts}{$key} // 0;
    return 0 if (time() - $last) < 300;
    return 0 if exists $self->{_pending_checks}{$key};

    if (scalar(keys %{ $self->{_pending_checks} || {} }) >= 200) {
        $self->_metric('inc', 'mediabot_achievement_queue_dropped_total',
            { reason => 'full' });
        $self->_log(2, "Achievements: async queue full, dropping check for $nick/$channel");
        return 0;
    }

    $self->{_pending_checks}{$key} = {
        nick      => $nick,
        channel   => $channel,
        attempts  => 0,
        retry_at  => 0,
        queued_at => Time::HiRes::time(),
    };
    push @{ $self->{_pending_order} }, $key;
    $self->_sync_queue_metric;
    return 1;
}

sub pending_check_count {
    my ($self) = @_;
    return scalar(keys %{ $self->{_pending_checks} || {} });
}

sub worker_inflight {
    my ($self) = @_;
    return $self->{_worker_inflight} ? 1 : 0;
}

sub _next_ready_check {
    my ($self) = @_;
    my $order = $self->{_pending_order} || [];
    my $count = scalar @$order;
    my $now = Time::HiRes::time();

    for (1 .. $count) {
        my $key = shift @$order;
        my $entry = $self->{_pending_checks}{$key};
        next unless ref($entry) eq 'HASH';
        push @$order, $key;
        next if ($entry->{retry_at} // 0) > $now;
        return ($key, $entry);
    }
    return;
}

sub start_next_check_async {
    my ($self) = @_;
    return 0 if $self->{_shutting_down} || $self->{_worker_inflight};

    my ($key, $entry) = $self->_next_ready_check;
    return 0 unless defined $key && ref($entry) eq 'HASH';

    my $token = ++$self->{_worker_seq};
    my $job = {
        key     => $key,
        nick    => $entry->{nick},
        channel => $entry->{channel},
    };
    $self->{_worker_inflight} = {
        token      => $token,
        key        => $key,
        started_at => Time::HiRes::time(),
    };
    $self->_metric('set', 'mediabot_achievement_worker_inflight', 1);

    my $done = sub {
        my ($result) = @_;
        $self->_finish_async_check($token, $result);
    };
    my $launcher = $self->{_worker_launcher};
    my $started;
    if (ref($launcher) eq 'CODE') {
        $started = eval { $launcher->($job, $done, $self) };
    }
    else {
        $started = eval { $self->_spawn_check_worker($job, $done) };
    }

    unless ($started) {
        my $error = $@ || 'worker launcher refused the job';
        $error =~ s/[\r\n\0]+/ /g;
        $done->({
            ok     => 0,
            error  => 'worker_setup',
            stage  => 'launcher',
            detail => substr($error, 0, 240),
        });
    }
    return 1;
}

# Compatibility name retained for private callers from the short-lived mb558
# queue implementation. It now STARTS an async worker and never performs SQL.
sub drain_one_check {
    my ($self) = @_;
    return $self->start_next_check_async;
}

sub _finish_async_check {
    my ($self, $token, $result) = @_;
    my $active = $self->{_worker_inflight};
    return 0 unless ref($active) eq 'HASH' && ($active->{token} // -1) == $token;

    my $key = $active->{key};
    my $entry = $self->{_pending_checks}{$key};
    $self->{_worker_inflight} = undef;
    $self->_metric('set', 'mediabot_achievement_worker_inflight', 0);
    return 0 unless ref($entry) eq 'HASH';

    $result = {} unless ref($result) eq 'HASH';
    my $ok = $result->{ok} ? 1 : 0;
    my $result_label = $ok ? 'ok' : ($result->{error} // 'failed');
    # mb560-B1: keep successful completions labelled as "ok". Without
    # this value in the bounded whitelist, every healthy worker was rewritten
    # to "failed", making the Grafana failure panel count successes.
    $result_label = 'failed'
        unless defined($result_label) && !ref($result_label)
            && $result_label =~ /\A(?:ok|failed|worker_setup|worker_timeout|worker_failed|worker_decode|worker_exception)\z/;
    $self->_metric('inc', 'mediabot_achievement_worker_total',
        { result => $result_label });
    $self->_metric('inc', 'mediabot_achievement_worker_timeouts_total')
        if $result_label eq 'worker_timeout';

    if ($ok) {
        my %checks;
        if (ref($result->{checks}) eq 'ARRAY') {
            $checks{$_} = 1 for grep {
                defined($_) && !ref($_)
                    && /\A(?:msg_count|hour_band|polyphony)\z/
            } @{ $result->{checks} };
        }

        if (ref($result->{timings}) eq 'HASH') {
            for my $check (qw(msg_count hour_band polyphony)) {
                next unless exists $result->{timings}{$check};
                my $elapsed = $result->{timings}{$check};
                next unless defined($elapsed) && !ref($elapsed)
                    && "$elapsed" =~ /\A(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?\z/
                    && $elapsed >= 0;
                $self->_metric('observe', 'mediabot_achievement_check_seconds',
                    0 + $elapsed, { check => $check });
                if ($elapsed > 1.0) {
                    $self->_log(3, sprintf(
                        'SLOW ACHIEVEMENT: %s for %s/%s took %.2fs',
                        $check, $entry->{nick}, $entry->{channel}, $elapsed));
                }
            }
        }

        if (ref($result->{unlocks}) eq 'ARRAY') {
            my $seen = 0;
            for my $unlock (@{ $result->{unlocks} }) {
                last if ++$seen > 32;
                next unless ref($unlock) eq 'HASH';
                next unless defined($unlock->{nick}) && !ref($unlock->{nick})
                    && defined($unlock->{channel}) && !ref($unlock->{channel})
                    && defined($unlock->{id}) && !ref($unlock->{id});
                next unless lc($unlock->{nick}) eq lc($entry->{nick})
                    && lc($unlock->{channel}) eq lc($entry->{channel});
                $self->unlock($entry->{nick}, $entry->{channel}, $unlock->{id});
            }
        }

        my $now = time();
        $self->{_msg_check_ts}{$key} = $now if $checks{msg_count};
        $self->{_hourband_check_ts}{$key} = $now if $checks{hour_band};
        $self->{_polyphony_check_ts}{lc($entry->{nick})} = $now
            if $checks{polyphony};

        delete $self->{_pending_checks}{$key};
        @{ $self->{_pending_order} } = grep { $_ ne $key }
            @{ $self->{_pending_order} || [] };
        $self->_sync_queue_metric;
        $self->_log(3, "Achievements: async check completed for $entry->{nick}/$entry->{channel}");
        return 1;
    }

    $entry->{attempts} = int($entry->{attempts} // 0) + 1;
    my $error = $result->{detail} // $result->{error} // 'worker failure';
    $error = 'worker failure' if ref($error);
    $error =~ s/[\r\n\0]+/ /g;
    $error = substr($error, 0, 240);

    if ($entry->{attempts} >= 3) {
        delete $self->{_pending_checks}{$key};
        @{ $self->{_pending_order} } = grep { $_ ne $key }
            @{ $self->{_pending_order} || [] };
        $self->_metric('inc', 'mediabot_achievement_queue_dropped_total',
            { reason => 'retry_exhausted' });
        $self->_sync_queue_metric;
        $self->_log(1, "Achievements: async check dropped after 3 attempts for $entry->{nick}/$entry->{channel}: $error");
        return 0;
    }

    my @backoff = (0, 15, 60);
    $entry->{retry_at} = Time::HiRes::time() + $backoff[$entry->{attempts}];
    $self->_log(2, "Achievements: async check retry $entry->{attempts}/3 for $entry->{nick}/$entry->{channel}: $error");
    return 0;
}

sub _spawn_check_worker {
    my ($self, $job, $done) = @_;
    return 0 unless ref($job) eq 'HASH' && ref($done) eq 'CODE';

    my $bot = $self->{bot};
    my $loop = eval { $bot->getLoop } if $bot;
    $loop ||= $bot->{loop} if $bot && ref($bot);
    unless ($loop && $loop->can('add') && $loop->can('remove')
        && $loop->can('watch_process')) {
        $done->({ ok => 0, error => 'worker_setup', stage => 'event_loop',
            detail => 'IO::Async loop with watch_process is required' });
        return 1;
    }

    require IO::Async::Stream;
    require IO::Async::Timer::Countdown;
    require POSIX;

    my ($pipe, $child_write);
    unless (pipe($pipe, $child_write)) {
        $done->({ ok => 0, error => 'worker_setup', stage => 'pipe',
            detail => substr("$!", 0, 240) });
        return 1;
    }

    my $pid = fork();
    unless (defined $pid) {
        eval { close $pipe };
        eval { close $child_write };
        $done->({ ok => 0, error => 'worker_setup', stage => 'fork',
            detail => substr("$!", 0, 240) });
        return 1;
    }

    if ($pid == 0) {
        eval { close $pipe };
        binmode($child_write, ':raw');
        local $SIG{PIPE} = 'IGNORE';
        local $SIG{TERM} = 'DEFAULT';
        local $SIG{INT}  = 'DEFAULT';
        local $SIG{HUP}  = 'DEFAULT';

        # Never let DBI destruction in the child disconnect the parent's
        # inherited socket. All worker SQL uses a separately opened handle.
        my $parent_dbh = $bot ? $bot->{dbh} : undef;
        eval { $parent_dbh->{InactiveDestroy} = 1 if $parent_dbh };
        my $db_obj = $bot ? $bot->{db} : undef;
        eval { $db_obj->{dbh}{InactiveDestroy} = 1 if $db_obj && $db_obj->{dbh} };

        my $result;
        if (!$db_obj || !eval { $db_obj->can('connect_isolated_handle') }) {
            $result = { ok => 0, error => 'worker_setup', stage => 'isolated_db',
                detail => 'database wrapper has no isolated connector' };
        }
        else {
            my ($dbh, $db_error) = $db_obj->connect_isolated_handle;
            if (!$dbh) {
                $db_error = 'isolated DB connection failed' unless defined $db_error;
                $db_error =~ s/[\r\n\0]+/ /g;
                $result = { ok => 0, error => 'worker_failed', stage => 'isolated_db',
                    detail => substr($db_error, 0, 240) };
            }
            else {
                my %worker = %$self;
                $worker{bot} = { dbh => $dbh };
                $worker{logger} = undef;
                $worker{_worker_unlocks} = [];
                $worker{_worker_checks} = {};
                $worker{_worker_timings} = {};
                my $child = bless \%worker, 'Mediabot::Achievements::Worker';

                my $run_ok = eval {
                    $child->check_msg($job->{nick}, $job->{channel});
                    1;
                };
                if ($run_ok) {
                    $result = {
                        ok      => 1,
                        unlocks => $child->{_worker_unlocks},
                        checks  => [ sort keys %{ $child->{_worker_checks} || {} } ],
                        timings => $child->{_worker_timings},
                    };
                }
                else {
                    my $err = $@ || 'achievement worker exception';
                    $err =~ s/[\r\n\0]+/ /g;
                    $result = { ok => 0, error => 'worker_exception',
                        stage => 'check_msg', detail => substr($err, 0, 240) };
                }
                eval { $dbh->disconnect };
            }
        }

        my $payload = eval { JSON::PP::encode_json($result) };
        if (!defined($payload) || ref($payload) || length($payload) > 64 * 1024) {
            $payload = JSON::PP::encode_json({ ok => 0, error => 'worker_decode',
                stage => 'encode', detail => 'invalid worker result payload' });
        }
        my $offset = 0;
        while ($offset < length($payload)) {
            my $written = syswrite($child_write, $payload,
                length($payload) - $offset, $offset);
            next if !defined($written) && $!{EINTR};
            last unless defined($written) && $written > 0;
            $offset += $written;
        }
        eval { close $child_write };
        POSIX::_exit(0);
    }

    eval { close $child_write };
    my $started = Time::HiRes::time();
    my $state = {
        buffer     => '',
        bytes      => 0,
        eof        => 0,
        child_done => 0,
        wait_status => undef,
        timed_out  => 0,
        finalized  => 0,
        force      => 0,
    };
    my ($stream, $timeout_timer, $kill_timer, $force_timer);
    my $finish;

    my $remove = sub {
        my ($obj) = @_;
        return unless $obj;
        eval { $obj->stop };
        eval { $loop->remove($obj) };
    };

    $finish = sub {
        return if $state->{finalized};
        return unless $state->{force}
            || ($state->{child_done} && ($state->{eof} || $state->{timed_out}));
        $state->{finalized} = 1;
        $remove->($timeout_timer);
        $remove->($kill_timer);
        $remove->($force_timer);
        eval { $loop->remove($stream) } if $stream;
        eval { close $pipe };
        delete $self->{_worker_process};

        my $status = $state->{wait_status} // 0;
        my $signal = $status & 127;
        my $exit = ($status >> 8) & 255;
        my $result;
        if ($state->{timed_out}) {
            $result = { ok => 0, error => 'worker_timeout', stage => 'timeout',
                detail => sprintf('worker exceeded %.1fs', $self->{_worker_timeout}) };
        }
        elsif ($signal || $exit != 0) {
            $result = { ok => 0, error => 'worker_failed', stage => 'process_exit',
                detail => "worker exit=$exit signal=$signal" };
        }
        elsif ($state->{bytes} > 64 * 1024) {
            $result = { ok => 0, error => 'worker_decode', stage => 'payload_limit',
                detail => 'worker output exceeded 64 KiB' };
        }
        else {
            $result = eval { JSON::PP::decode_json($state->{buffer}) };
            if ($@ || ref($result) ne 'HASH') {
                $result = { ok => 0, error => 'worker_decode', stage => 'json',
                    detail => 'worker returned invalid JSON' };
            }
        }
        $result->{worker_elapsed_s} = Time::HiRes::time() - $started;
        eval { $done->($result); 1 } or do {
            my $err = $@ || 'unknown callback error';
            $err =~ s/\s+/ /g;
            $self->_log(1, "Achievements: async completion callback failed: $err");
        };
        $finish = undef;
    };

    my $watch_ok = eval {
        $loop->watch_process($pid, sub {
            my ($seen_pid, $status) = @_;
            return unless defined($seen_pid) && $seen_pid == $pid;
            $state->{wait_status} = $status;
            $state->{child_done} = 1;
            $finish->() if $finish;
        });
        1;
    };
    unless ($watch_ok) {
        kill 'KILL', $pid;
        eval { close $pipe };
        $done->({ ok => 0, error => 'worker_setup', stage => 'watch_process',
            detail => 'could not register child process watcher' });
        return 1;
    }

    $stream = IO::Async::Stream->new(
        read_handle => $pipe,
        on_read => sub {
            my ($io, $buffref, $eof) = @_;
            if (length $$buffref) {
                $state->{bytes} += length($$buffref);
                $state->{buffer} .= $$buffref if $state->{bytes} <= 64 * 1024;
                $$buffref = '';
            }
            if ($eof && !$state->{eof}++) {
                eval { $loop->remove($io) };
                $finish->() if $finish;
            }
            return 0;
        },
    );
    $loop->add($stream);

    $timeout_timer = IO::Async::Timer::Countdown->new(
        delay => $self->{_worker_timeout},
        on_expire => sub {
            return if $state->{finalized} || $state->{child_done};
            $state->{timed_out} = 1;
            kill 'TERM', $pid;
            $kill_timer = IO::Async::Timer::Countdown->new(
                delay => 0.5,
                on_expire => sub {
                    return if $state->{finalized} || $state->{child_done};
                    kill 'KILL', $pid;
                },
            );
            $force_timer = IO::Async::Timer::Countdown->new(
                delay => 2,
                on_expire => sub {
                    return if $state->{finalized};
                    $state->{force} = 1;
                    $finish->() if $finish;
                },
            );
            $loop->add($kill_timer); $kill_timer->start;
            $loop->add($force_timer); $force_timer->start;
        },
    );
    $loop->add($timeout_timer);
    $timeout_timer->start;

    $self->{_worker_process} = { pid => $pid };
    return 1;
}

sub shutdown_worker {
    my ($self) = @_;
    $self->{_shutting_down} = 1;
    my $proc = delete $self->{_worker_process};
    if (ref($proc) eq 'HASH' && $proc->{pid}) {
        kill 'TERM', $proc->{pid};
    }
    return 1;
}

# mb558-B1: per-query stopwatch. Every aggregation names itself when slow
# (level 3) and feeds mediabot_achievement_check_seconds{check} — the
# instrument that would have pointed at these queries on day one.
sub _timed_check {
    my ($self, $check, $nick, $channel, $code) = @_;

    my $t0 = [ Time::HiRes::gettimeofday() ];
    my @ret = $code->();
    my $elapsed = Time::HiRes::tv_interval($t0);

    my $metrics = $self->{bot} ? $self->{bot}{metrics} : undef;
    if ($metrics && eval { $metrics->can('observe') }) {
        eval { $metrics->observe('mediabot_achievement_check_seconds',
            $elapsed, { check => $check }); 1 };
    }
    if ($elapsed > 1.0 && $self->{logger}) {
        $self->{logger}->log(3, sprintf(
            "SLOW ACHIEVEMENT: %s for %s/%s took %.2fs",
            $check, $nick, $channel, $elapsed));
    }
    return @ret;
}

sub check_msg {
    my ($self, $nick, $channel) = @_;
    return unless defined $nick && defined $channel && $channel =~ /^#/;
    my $bot = $self->{bot} or return;

    # Cache : on ne refait le check msg que toutes les 5 minutes par (nick, chan)
    my $cache_key = lc($nick) . "\x00" . lc($channel // "");  # mb430-B1
    my $now = time();
    my $last = $self->{_msg_check_ts}{$cache_key} // 0;
    return if ($now - $last) < 300;
    $self->{_msg_check_ts}{$cache_key} = $now;

    # Compte les messages du nick sur le canal
    # mb347-B1: ne compter que les VRAIS messages. publictext IS NOT NULL est un
    # faux filtre : logBotAction stocke publictext verbatim, donc join/part (''),
    # kick/mode/topic/notice (texte) ont tous un publictext NON-NULL et étaient
    # comptés comme des messages -> chatterbox/megaphone/night_owl/polyphony
    # gonflés (on débloquait "chatterbox" en rejoignant 1000×). On s'aligne sur
    # la convention "a parlé" = event_type IN ('public','action').
    my $dbh = $bot->{dbh} or return;
    my ($n) = $self->_timed_check('msg_count', $nick, $channel, sub {
        my $sth = eval {
            $dbh->prepare(q{
                SELECT COUNT(*) AS c
                FROM CHANNEL_LOG cl
                JOIN CHANNEL    c  ON c.id_channel = cl.id_channel
                WHERE c.name = ? AND cl.nick = ?
                  AND cl.event_type IN ('public','action')
            })
        };
        return (undef) unless $sth && $sth->execute($channel, $nick);
        my $row = $sth->fetchrow_hashref; $sth->finish;
        return ($row ? ($row->{c} // 0) : 0);
    });
    return unless defined $n;

    # First message — déclenché systématiquement pour tout nouveau nick avec ≥1 msg
    $self->unlock($nick, $channel, 'first_msg')         if $n >= 1;
    $self->unlock($nick, $channel, 'chatterbox')        if $n >= 1_000;
    $self->unlock($nick, $channel, 'megaphone')         if $n >= 10_000;
    $self->unlock($nick, $channel, 'icon')              if $n >= 50_000;
    $self->unlock($nick, $channel, 'legend')            if $n >= 100_000;

    # Night Owl / Early Bird : compte par tranche horaire
    #
    # mb450-B1 (perf): ce GROUP BY HOUR(ts) sur CHANNEL_LOG est la requete la
    # plus chere de ce hook (Using temporary + filesort). Deux gardes, sans rien
    # changer a la logique de deblocage :
    #   1. Court-circuit mathematique : night_owl et early_bird exigent chacun
    #      >= 50 messages dans une tranche horaire. C'est impossible si le total
    #      du nick sur le canal ($n) est < 50 -> on saute le scan pour l'immense
    #      majorite des nicks (le cas courant sur un canal charge).
    #   2. Throttle horaire : pour les gros nicks qui franchissent 50, on ne
    #      relance le scan qu'une fois par heure et par (nick,canal), au lieu de
    #      chaque fois que le cache 5 min de check_msg laisse passer.
    # Les seuils (>= 50) et les unlock sont identiques a l'avant-mb450.
    if ($n >= 50 &&
        (!exists $self->get_for_nick($nick, $channel)->{night_owl} ||
         !exists $self->get_for_nick($nick, $channel)->{early_bird})) {
        my $hb_key  = lc($nick) . "\x00" . lc($channel // "");
        my $hb_last = $self->{_hourband_check_ts}{$hb_key} // 0;
        if ((time() - $hb_last) >= 3600) {
            $self->{_hourband_check_ts}{$hb_key} = time();
            my ($night, $morn) = $self->_timed_check('hour_band', $nick, $channel, sub {
                my $sth_h = eval {
                    $dbh->prepare(q{
                        SELECT HOUR(cl.ts) AS h, COUNT(*) AS c
                        FROM CHANNEL_LOG cl
                        JOIN CHANNEL c ON c.id_channel = cl.id_channel
                        WHERE c.name = ? AND cl.nick = ?
                          AND cl.event_type IN ('public','action')   -- mb347-B1
                        GROUP BY HOUR(cl.ts)
                    })
                };
                return (undef, undef) unless $sth_h && $sth_h->execute($channel, $nick);
                my (%by_h);
                while (my $r = $sth_h->fetchrow_hashref) { $by_h{$r->{h}} = $r->{c}; }
                $sth_h->finish;
                my ($ni, $mo) = (0, 0);
                $ni += ($by_h{$_} // 0) for (0..5);
                $mo += ($by_h{$_} // 0) for (6..8);
                return ($ni, $mo);
            });
            if (defined $night) {
                $self->unlock($nick, $channel, 'night_owl')  if $night >= 50;
                $self->unlock($nick, $channel, 'early_bird') if $morn  >= 50;
            }
        }
    }

    # mb118-IMP4: hook polyphony — check 1× / heure / nick. Compte les canaux
    # publics où le nick a parlé. Déplacé ici depuis mbMood_ctx pour ne plus
    # dépendre d'un trigger explicite.
    if (!exists $self->get_for_nick($nick, $channel)->{polyphony}) {
        my $now_p = time();
        my $last_p = $self->{_polyphony_check_ts}{lc($nick)} // 0;
        if (($now_p - $last_p) >= 3600) {
            $self->{_polyphony_check_ts}{lc($nick)} = $now_p;
            my ($nchan) = $self->_timed_check('polyphony', $nick, $channel, sub {
                my $sth_p = eval {
                    $dbh->prepare(q{
                        SELECT COUNT(DISTINCT c.name) AS n
                        FROM CHANNEL_LOG cl
                        JOIN CHANNEL c ON c.id_channel = cl.id_channel
                        WHERE cl.nick = ?
                          AND cl.event_type IN ('public','action')   -- mb347-B1
                          AND c.name LIKE '#%'
                    })
                };
                return (undef) unless $sth_p && $sth_p->execute($nick);
                my $r = $sth_p->fetchrow_hashref; $sth_p->finish;
                return ($r ? ($r->{n} // 0) : 0);
            });
            $self->unlock($nick, $channel, 'polyphony')
                if defined $nchan && $nchan >= 5;
        }
    }
}

# -- Hook : vérifie les achievements 'karma' après un vote ---------------------
sub check_karma {
    my ($self, $nick, $channel, $score, $giver, $given_total) = @_;
    return unless defined $nick && defined $channel && $channel =~ /^#/;
    $self->unlock($nick, $channel, 'karma_star')   if defined $score && $score >=  50;
    $self->unlock($nick, $channel, 'karma_legend') if defined $score && $score >= 100;
    # Gift giver : 100+ karma positifs donnés (cross-canal somme)
    if (defined $giver && defined $given_total && $given_total >= 100) {
        $self->unlock($giver, $channel, 'gift_giver');
    }
}

# -- Hook : vérifie les achievements 'trivia' ----------------------------------
sub check_trivia {
    my ($self, $nick, $channel, $correct_count, $response_seconds) = @_;
    return unless defined $nick && defined $channel && $channel =~ /^#/;
    $self->unlock($nick, $channel, 'trivia_rookie')    if defined $correct_count && $correct_count >=  10;
    $self->unlock($nick, $channel, 'trivia_champion')  if defined $correct_count && $correct_count >= 100;
    $self->unlock($nick, $channel, 'trivia_sniper')    if defined $response_seconds && $response_seconds <= 3;
}

# -- Hook : vérifie les achievements 'wordcount' -------------------------------
sub check_wordcount {
    my ($self, $nick, $channel, $distinct) = @_;
    return unless defined $nick && defined $channel && $channel =~ /^#/;
    $self->unlock($nick, $channel, 'wordsmith') if defined $distinct && $distinct >= 1_000;
    $self->unlock($nick, $channel, 'polyglot')  if defined $distinct && $distinct >= 5_000;
}

# -- Hook : vérifie les achievements 'duel' (mb116) ---------------------------
# $wins = nombre total de duels gagnés sur le canal
# $streak_loss = streak de pertes consécutives avant la victoire (pour underdog)
sub check_duel {
    my ($self, $nick, $channel, $wins, $streak_loss) = @_;
    return unless defined $nick && defined $channel && $channel =~ /^#/;
    $self->unlock($nick, $channel, 'duel_warrior') if defined $wins && $wins >= 10;
    $self->unlock($nick, $channel, 'duel_master')  if defined $wins && $wins >= 50;
    $self->unlock($nick, $channel, 'underdog')     if defined $streak_loss && $streak_loss >= 5;
}

# -- Hook : vérifie les achievements 'horoscope' (mb116) -----------------------
sub check_horoscope {
    my ($self, $nick, $channel, $consultations) = @_;
    return unless defined $nick && defined $channel && $channel =~ /^#/;
    $self->unlock($nick, $channel, 'star_gazer') if defined $consultations && $consultations >= 30;
}

# -- Hook : vérifie les achievements 'compat' (mb117) --------------------------
sub check_compat {
    my ($self, $nick, $channel, $count) = @_;
    return unless defined $nick && defined $channel && $channel =~ /^#/;
    $self->unlock($nick, $channel, 'matchmaker') if defined $count && $count >= 10;
}

# -- Hook : vérifie les achievements 'quotegame' (mb117) -----------------------
sub check_quotegame {
    my ($self, $nick, $channel, $solved) = @_;
    return unless defined $nick && defined $channel && $channel =~ /^#/;
    $self->unlock($nick, $channel, 'quote_detective') if defined $solved && $solved >= 10;
    $self->unlock($nick, $channel, 'quote_master')    if defined $solved && $solved >= 50;
}

# -- Hook : vérifie les achievements 'mood' (mb117) ----------------------------
sub check_mood {
    my ($self, $nick, $channel, $reads) = @_;
    return unless defined $nick && defined $channel && $channel =~ /^#/;
    $self->unlock($nick, $channel, 'mood_reader') if defined $reads && $reads >= 30;
}

# -- Hook : vérifie l'achievement 'polyphony' (mb117) --------------------------
# Appelé après un check sur le nombre de canaux où le nick a posté.
sub check_polyphony {
    my ($self, $nick, $current_channel, $n_channels) = @_;
    return unless defined $nick && defined $current_channel && $current_channel =~ /^#/;
    $self->unlock($nick, $current_channel, 'polyphony') if defined $n_channels && $n_channels >= 5;
}

# -- Logger interne -------------------------------------------------------------
sub _log {
    my ($self, $level, $msg) = @_;
    return unless $self->{logger};
    $self->{logger}->log($level, $msg);
}


# Child-only facade used after fork. It runs the historical check_msg logic on
# an isolated DB handle, but records unlock intents and timings instead of
# touching parent state, JSON storage, IRC or Prometheus directly.
package Mediabot::Achievements::Worker;
our @ISA = ('Mediabot::Achievements');

sub unlock {
    my ($self, $nick, $channel, $id) = @_;
    return 0 unless defined $nick && defined $id && exists $ACH{$id};
    my $key = lc($nick) . "\x00" . (defined($channel) ? lc($channel) : '');
    return 0 if exists $self->{data}{$key}{$id};
    $self->{data}{$key}{$id} = time();
    push @{ $self->{_worker_unlocks} }, {
        nick => $nick, channel => $channel, id => $id,
    };
    return 1;
}

sub _timed_check {
    my ($self, $check, $nick, $channel, $code) = @_;
    my $t0 = [ Time::HiRes::gettimeofday() ];
    my (@ret, $ok, $error);
    $ok = eval { @ret = $code->(); 1 };
    $error = $@ unless $ok;
    my $elapsed = Time::HiRes::tv_interval($t0);
    $self->{_worker_checks}{$check} = 1;
    $self->{_worker_timings}{$check} = $elapsed;

    if (!$ok) {
        $error ||= "$check query failed";
        die $error;
    }
    if (($check eq 'msg_count' || $check eq 'polyphony') && !defined $ret[0]) {
        die "$check query returned no value";
    }
    if ($check eq 'hour_band' && (!defined($ret[0]) || !defined($ret[1]))) {
        die "$check query returned incomplete values";
    }
    return @ret;
}

sub save { return 1 }

package Mediabot::Achievements;

1;
