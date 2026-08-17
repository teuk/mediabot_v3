package Mediabot::Achievements;

# =============================================================================
# Mediabot::Achievements — système de succès débloquables
#
# Stockage : MariaDB depuis mb646 (JSON uniquement comme import/fallback legacy)
# Identité durable : profil par canal + alias (nick, user@host, channel).
#
# Hooks intégrés depuis :
#   - mediabot.pl on_message_PRIVMSG   → first_msg, chatterbox, megaphone,
#                                         night_owl, midnight_regular,
#                                         creature_night, early_bird
#   - UserCommands.pm  mbKarma_ctx     → karma_star, karma_legend
#   - UserCommands.pm  mbTrivia (ok)   → trivia_rookie, trivia_champion, trivia_sniper
#   - UserCommands.pm  mbWordCount_ctx → wordsmith
#   - UserCommands.pm  mbStreak_ctx    → streak_week, streak_month, streak_master
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
use File::Basename qw(dirname basename);
use File::Copy qw(copy);
use File::Spec ();
use Scalar::Util qw(reftype);

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
        threshold => 1,
        progress_kind => 'msg_count',
    },
    chatterbox => {
        emoji   => '💬',
        name    => 'Chatterbox',
        desc    => 'Sent 1 000 messages on a channel',
        rarity  => 'uncommon',
        check_on => 'msg',
        threshold => 1000,
        progress_kind => 'msg_count',
    },
    megaphone => {
        emoji   => '📢',
        name    => 'Megaphone',
        desc    => 'Sent 10 000 messages on a channel',
        rarity  => 'rare',
        check_on => 'msg',
        threshold => 10000,
        progress_kind => 'msg_count',
    },
    icon => {
        emoji   => '🗿',
        name    => 'Icon',
        desc    => 'Sent 50 000 messages on a channel',
        rarity  => 'epic',
        check_on => 'msg',
        threshold => 50000,
        progress_kind => 'msg_count',
    },
    legend => {
        emoji   => '⭐',
        name    => 'Legend',
        desc    => 'Sent 150 000 messages on a channel',
        rarity  => 'legendary',
        check_on => 'msg',
        threshold => 150000,
        progress_kind => 'msg_count',
    },
    wordsmith => {
        emoji   => '📚',
        name    => 'Wordsmith',
        desc    => 'Used 1 000 distinct words',
        rarity  => 'uncommon',
        check_on => 'wordcount',
        threshold => 1000,
        progress_kind => 'distinct_words',
    },
    polyglot => {
        emoji   => '🎓',
        name    => 'Polyglot',
        desc    => 'Used 7 500 distinct words',
        rarity  => 'rare',
        check_on => 'wordcount',
        threshold => 7500,
        progress_kind => 'distinct_words',
    },
    karma_star => {
        emoji   => '🌟',
        name    => 'Karma Star',
        desc    => 'Reached +50 karma on a channel',
        rarity  => 'uncommon',
        check_on => 'karma',
        threshold => 50,
        progress_kind => 'karma_score',
    },
    karma_legend => {
        emoji   => '💫',
        name    => 'Karma Legend',
        desc    => 'Reached +250 karma on a channel',
        rarity  => 'epic',
        check_on => 'karma',
        threshold => 250,
        progress_kind => 'karma_score',
    },
    gift_giver => {
        emoji   => '🎁',
        name    => 'Gift Giver',
        desc    => 'Gave 250 positive karma',
        rarity  => 'rare',
        check_on => 'karma',
        threshold => 250,
        progress_kind => 'karma_given',
    },
    # mb657: the historical hour-band scan already knows the exact number of
    # night/morning messages.  Persist that result as progress and turn the
    # original Night Owl into the first rung of a cumulative night ladder.
    night_owl => {
        emoji   => '🌙',
        name    => 'Night Owl',
        desc    => 'Sent 50 messages between 00h and 05h',
        rarity  => 'uncommon',
        check_on => 'msg',
        threshold => 50,
        progress_kind => 'night_messages',
    },
    midnight_regular => {
        emoji   => '🌌',
        name    => 'Midnight Regular',
        desc    => 'Sent 250 messages between 00h and 05h',
        rarity  => 'rare',
        check_on => 'msg',
        threshold => 250,
        progress_kind => 'night_messages',
    },
    creature_night => {
        emoji   => '🦇',
        name    => 'Creature of the Night',
        desc    => 'Sent 1 000 messages between 00h and 05h',
        rarity  => 'epic',
        check_on => 'msg',
        threshold => 1000,
        progress_kind => 'night_messages',
    },
    early_bird => {
        emoji   => '🌅',
        name    => 'Early Bird',
        desc    => 'Sent 50 messages between 06h and 08h',
        rarity  => 'uncommon',
        check_on => 'msg',
        threshold => 50,
        progress_kind => 'morning_messages',
    },
    # mb655: user-facing activity streak milestones.  The expensive day-by-day
    # calculation already exists in !streak; these achievements reuse that result
    # instead of introducing another CHANNEL_LOG scan in the message hot path.
    streak_week => {
        emoji   => '🔥',
        name    => 'On a Roll',
        desc    => 'Stayed active for 7 consecutive days',
        rarity  => 'uncommon',
        check_on => 'activity',
        threshold => 7,
        progress_kind => 'activity_streak_days',
    },
    streak_month => {
        emoji   => '📆',
        name    => 'Habit Formed',
        desc    => 'Stayed active for 30 consecutive days',
        rarity  => 'rare',
        check_on => 'activity',
        threshold => 30,
        progress_kind => 'activity_streak_days',
    },
    streak_master => {
        emoji   => '⚡',
        name    => 'Streak Master',
        desc    => 'Stayed active for 100 consecutive days',
        rarity  => 'epic',
        check_on => 'activity',
        threshold => 100,
        progress_kind => 'activity_streak_days',
    },
    # mb656: comeback milestones. USER_SEEN is sampled on JOIN before the normal
    # upsert overwrites seen_at; the candidate is consumed only after the user
    # speaks and mb646 has resolved the live identity.
    comeback_week => {
        emoji   => '🪃',
        name    => 'Welcome Back',
        desc    => 'Returned after at least 7 days away',
        rarity  => 'uncommon',
        check_on => 'comeback',
        threshold => 7,
        progress_kind => 'comeback_days',
    },
    comeback_month => {
        emoji   => '🕰️',
        name    => 'Long Time No See',
        desc    => 'Returned after at least 30 days away',
        rarity  => 'rare',
        check_on => 'comeback',
        threshold => 30,
        progress_kind => 'comeback_days',
    },
    comeback_legend => {
        emoji   => '🌠',
        name    => 'The Return',
        desc    => 'Returned after at least 90 days away',
        rarity  => 'epic',
        check_on => 'comeback',
        threshold => 90,
        progress_kind => 'comeback_days',
    },
    trivia_rookie => {
        emoji   => '🧠',
        name    => 'Trivia Rookie',
        desc    => 'Answered 10 trivia questions correctly',
        rarity  => 'common',
        check_on => 'trivia',
        threshold => 10,
        progress_kind => 'trivia_correct',
    },
    trivia_champion => {
        emoji   => '🏆',
        name    => 'Trivia Champion',
        desc    => 'Answered 300 trivia questions correctly',
        rarity  => 'rare',
        check_on => 'trivia',
        threshold => 300,
        progress_kind => 'trivia_correct',
    },
    trivia_sniper => {
        emoji   => '🎯',
        name    => 'Trivia Sniper',
        desc    => 'Answered a trivia question in 2 seconds or less',
        rarity  => 'epic',
        check_on => 'trivia',
        threshold => 2,
    },

    # mb116: achievements liés au duel
    duel_warrior => {
        emoji   => '⚔️',
        name    => 'Duel Warrior',
        desc    => 'Won 10 duels on a channel',
        rarity  => 'uncommon',
        check_on => 'duel',
        threshold => 10,
        progress_kind => 'duel_win',
    },
    duel_master => {
        emoji   => '🛡️',
        name    => 'Duel Master',
        desc    => 'Won 150 duels on a channel',
        rarity  => 'rare',
        check_on => 'duel',
        threshold => 150,
        progress_kind => 'duel_win',
    },
    underdog => {
        emoji   => '🐺',
        name    => 'Underdog',
        desc    => 'Won a duel after losing 8 in a row',
        rarity  => 'epic',
        check_on => 'duel',
        threshold => 8,
    },
    star_gazer => {
        emoji   => '🔮',
        name    => 'Star Gazer',
        desc    => 'Consulted the horoscope 30 times',
        rarity  => 'uncommon',
        check_on => 'horoscope',
        threshold => 30,
        progress_kind => 'horoscope',
    },

    # mb117: nouveaux achievements sociaux
    matchmaker => {
        emoji   => '💞',
        name    => 'Matchmaker',
        desc    => 'Calculated 25 compatibility scores',
        rarity  => 'uncommon',
        check_on => 'compat',
        threshold => 25,
        progress_kind => 'compat',
    },
    quote_detective => {
        emoji   => '🕵️',
        name    => 'Quote Detective',
        desc    => 'Solved 20 quotegame questions',
        rarity  => 'uncommon',
        check_on => 'quotegame',
        threshold => 20,
        progress_kind => 'quotegame_solved',
    },
    quote_master => {
        emoji   => '📜',
        name    => 'Quote Master',
        desc    => 'Solved 150 quotegame questions',
        rarity  => 'rare',
        check_on => 'quotegame',
        threshold => 150,
        progress_kind => 'quotegame_solved',
    },
    mood_reader => {
        emoji   => '🌡️',
        name    => 'Mood Reader',
        desc    => 'Took the channel temperature 30 times',
        rarity  => 'uncommon',
        check_on => 'mood',
        threshold => 30,
        progress_kind => 'mood',
    },
    polyphony => {
        emoji   => '🎼',
        name    => 'Polyphony',
        desc    => 'Active on at least 8 channels',
        rarity  => 'rare',
        check_on => 'polyphony',
        threshold => 8,
        progress_kind => 'channels_active',
    },
);

# -- Seuils (mb611) ------------------------------------------------------------
# Le merite exige par chaque achievement vit DANS le catalogue ci-dessus :
# la definition et la verification ne peuvent plus diverger. Chaque seuil est
# reglable sans toucher au code via la conf, section [achievements], clé =
# l'identifiant en MAJUSCULES (ex. TRIVIA_CHAMPION=200). Une valeur invalide
# ou <= 0 est ignoree et le defaut du catalogue s'applique.
sub threshold {
    my ($self, $id) = @_;
    my $default = (ref $ACH{$id || ''} eq 'HASH') ? $ACH{$id}{threshold} : undef;
    return $default unless defined $id;
    my $conf = ref($self) ? eval { $self->{bot}{conf} } : undef;
    if ($conf && eval { $conf->can('get') }) {
        my $raw = eval { $conf->get('achievements.' . uc($id)) };
        if (defined $raw && !ref $raw && $raw =~ /\A\d+\z/ && $raw > 0) {
            return int($raw);
        }
    }
    return $default;
}

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
        storage => 'json',
        # JSON fallback caches (also retained for legacy unit tests).
        data   => {},   # { "$nick\x00$channel" => { id => ts, ... } }
        # mb610-B1: REGISTRE DE PROGRESSION persistant. Les compteurs qui
        # menent aux achievements vivaient en memoire du bot (horoscope,
        # compat, mood, duels) ou dans la partie en cours (trivia,
        # quotegame) : au redemarrage — ou a la partie suivante — le
        # merite acquis repartait de zero, ce qui rendait les paliers
        # eleves inatteignables plutot que difficiles. Le registre est
        # { kind => { "lc(nick)\x00lc(channel)" => n } } dans le fallback
        # JSON historique ; en mode mb646 la DB est la source de verite.
        progress => {},
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

        # mb646: database-backed identity/profile caches. The DB is the source
        # of truth when the migration tables exist; JSON remains a guarded
        # compatibility fallback for installations that have not migrated yet.
        _profiles             => {},
        _identity_exact       => {},
        _nick_channel_profile => {},
        _channel_ids          => {},
        _channel_names        => {},
        _unlocks_by_profile   => {},
        _progress_by_profile  => {},
        _identity_touch_ts     => {},
    }, $class;
    $self->{_worker_timeout} = 75
        unless defined($self->{_worker_timeout})
            && !ref($self->{_worker_timeout})
            && "$self->{_worker_timeout}" =~ /\A\d+(?:\.\d+)?\z/;
    $self->{_worker_timeout} = 10  if $self->{_worker_timeout} < 10;
    $self->{_worker_timeout} = 180 if $self->{_worker_timeout} > 180;
    $self->_initialize_storage;
    $self->_metric('set', 'mediabot_achievement_queue_pending', 0);
    $self->_metric('set', 'mediabot_achievement_worker_inflight', 0);
    return $self;
}


# -- mb646: stockage DB + résolution d'identité -------------------------------
#
# The durable identity is a PROFILE scoped to one channel. IRC appearances are
# aliases attached to that profile. This lets one of the visible tuple elements
# change without losing merit:
#
#   nick + user@host + channel
#
# Resolution is deliberately conservative:
#   1. exact triplet
#   2. registered USER id on the same channel
#   3. exact user@host on the same channel (nick may have changed)
#   4. same nick + compatible user@host (same ident OR same host)
#   5. same nick + legacy empty userhost imported from JSON
#
# We never merge on a nick alone when two plausible profiles exist. A known
# registered USER id is the strongest proof and is reused when available.

sub _initialize_storage {
    my ($self) = @_;

    if ($self->_db_schema_available) {
        $self->{storage} = 'db';
        $self->_load_db;

        # On the first DB-backed boot, merge every legacy snapshot we can still
        # find (live JSON + numeric release archives). Repeated historical
        # updates may each have stranded a different piece of merit, so using
        # only the newest file could preserve an already-truncated history.
        my $first_db_boot = !keys %{ $self->{_profiles} || {} };
        $self->_import_legacy_json_if_present(
            include_archives => $first_db_boot,
        );
        $self->_log(3, 'Achievements: database persistence enabled');
        return 1;
    }

    # An installation that has not applied mb646 yet must keep the old JSON
    # behaviour, including recovery from an archive produced by an old updater.
    $self->{storage} = 'json';
    $self->_restore_legacy_from_latest_archive;
    $self->_log(1,
        'Achievements: DB persistence tables are missing; using legacy JSON fallback. '
      . 'Apply install/migrations/20260816_achievements_db.sql.');
    $self->_load;
    return 1;
}

sub _db_schema_available {
    my ($self) = @_;
    my $bot = $self->{bot};
    return 0 unless $bot && (reftype($bot) || '') eq 'HASH';
    my $dbh = $bot->{dbh};
    return 0 unless $dbh && eval { $dbh->can('prepare') };

    my @required = qw(
        ACHIEVEMENT_PROFILE
        ACHIEVEMENT_IDENTITY
        ACHIEVEMENT_UNLOCK
        ACHIEVEMENT_PROGRESS
    );

    my $sth = eval {
        $dbh->prepare(q{
            SELECT COUNT(*) AS n
            FROM information_schema.TABLES
            WHERE TABLE_SCHEMA = DATABASE()
              AND TABLE_NAME IN (
                'ACHIEVEMENT_PROFILE',
                'ACHIEVEMENT_IDENTITY',
                'ACHIEVEMENT_UNLOCK',
                'ACHIEVEMENT_PROGRESS'
              )
        })
    };
    return 0 unless $sth && eval { $sth->execute };

    my ($n) = $sth->fetchrow_array;
    $sth->finish;
    return (defined($n) && $n == @required) ? 1 : 0;
}

sub _legacy_archive_json_sources {
    my ($self, $path) = @_;
    return () unless defined($path) && length($path);
    return () if File::Spec->file_name_is_absolute($path);

    my $cwd = File::Spec->rel2abs('.');
    my $parent = dirname($cwd);
    my $base = basename($cwd);
    return () unless defined($base) && length($base);

    # Scope archive discovery to the CURRENT deployment family. teuk.org has
    # both /home/mediabot/mediabot_v3 (dev) and /home/mediabot/mediabot3
    # (Undernet) under the same Unix home, so a broad mediabot* scan would risk
    # cross-importing achievements from another bot/database.
    #
    # Supported updater archive shapes, scoped by the current root basename:
    #   <root>.NNN
    #   <root>.old.YYYYMMDD_HHMMSS
    my @candidates;
    opendir my $dh, $parent or return ();
    while (defined(my $name = readdir $dh)) {
        next if $name eq '.' || $name eq '..';
        next unless $name =~ /\A\Q$base\E(?:\.\d+|\.old\.\d{8}_\d{6})\z/;

        my $dir = File::Spec->catdir($parent, $name);
        next unless -d $dir && !-l $dir;

        my $candidate = File::Spec->catfile($dir, split m{/+}, $path);
        next unless -f $candidate && !-l $candidate;

        my $mtime = (stat($candidate))[9] // 0;
        push @candidates, [ $mtime, $name, $candidate ];
    }
    closedir $dh;

    # Import merge semantics are order-safe (unlock=min timestamp,
    # progress=max), but newest-first keeps diagnostics deterministic and is
    # essential for the JSON fallback recovery path below.
    return map { $_->[2] }
        sort { $b->[0] <=> $a->[0] || $b->[1] cmp $a->[1] } @candidates;
}

sub _restore_legacy_from_latest_archive {
    my ($self) = @_;
    my $path = $self->{path};
    return 0 unless defined($path) && length($path);
    return 0 if -f $path;
    return 0 if File::Spec->file_name_is_absolute($path);

    my @candidates = $self->_legacy_archive_json_sources($path);
    return 0 unless @candidates;

    my $source = $candidates[0];
    make_path(dirname($path)) unless -d dirname($path);
    if (copy($source, $path)) {
        $self->_log(1,
            "Achievements: recovered legacy state from archived release $source");
        return 1;
    }

    $self->_log(1,
        "Achievements: could not recover legacy state from $source: $!");
    return 0;
}

sub _norm_nick {
    my ($nick) = @_;
    return '' unless defined $nick;
    $nick =~ s/^\s+|\s+$//g;
    return lc $nick;
}

sub _norm_channel {
    my ($channel) = @_;
    return '' unless defined $channel;
    $channel =~ s/^\s+|\s+$//g;
    return lc $channel;
}

sub _norm_userhost {
    my ($userhost) = @_;
    return '' unless defined $userhost;
    $userhost =~ s/^\s+|\s+$//g;
    return lc $userhost;
}

sub _split_userhost {
    my ($userhost) = @_;
    $userhost = _norm_userhost($userhost);
    my ($ident, $host) = split /\@/, $userhost, 2;
    $ident //= '';
    $host  //= '';
    $ident =~ s/^~+//;
    return ($ident, $host);
}

sub _userhost_compatible {
    my ($a, $b) = @_;
    $a = _norm_userhost($a);
    $b = _norm_userhost($b);
    return 1 if $a eq $b && $a ne '';
    return 1 if $a eq '' || $b eq ''; # legacy JSON alias; nick+channel guards it

    my ($ai, $ah) = _split_userhost($a);
    my ($bi, $bh) = _split_userhost($b);

    return 1 if $ai ne '' && $bi ne '' && $ai eq $bi;
    return 1 if $ah ne '' && $bh ne '' && $ah eq $bh;
    return 0;
}

sub _channel_id {
    my ($self, $channel) = @_;
    my $norm = _norm_channel($channel);
    return undef unless $norm ne '';

    return $self->{_channel_ids}{$norm}
        if exists $self->{_channel_ids}{$norm};

    my $dbh = eval { $self->{bot}{dbh} } or return undef;
    my $sth = $dbh->prepare('SELECT id_channel, name FROM CHANNEL WHERE name = ? LIMIT 1');
    return undef unless $sth && $sth->execute($channel);
    my $row = $sth->fetchrow_hashref;
    $sth->finish;
    return undef unless $row && defined $row->{id_channel};

    my $id = 0 + $row->{id_channel};
    my $name = $row->{name} // $channel;
    $self->{_channel_ids}{_norm_channel($name)} = $id;
    $self->{_channel_names}{$id} = $name;
    return $id;
}

sub _identity_cache_key {
    my ($channel_id, $nick, $userhost) = @_;
    return join("\x00", $channel_id // 0, _norm_nick($nick), _norm_userhost($userhost));
}

sub _nick_channel_cache_key {
    my ($channel_id, $nick) = @_;
    return join("\x00", $channel_id // 0, _norm_nick($nick));
}

sub _load_db {
    my ($self) = @_;
    my $dbh = $self->{bot}{dbh};

    $self->{_profiles}             = {};
    $self->{_identity_exact}       = {};
    $self->{_nick_channel_profile} = {};
    $self->{_channel_ids}          = {};
    $self->{_channel_names}        = {};
    $self->{_unlocks_by_profile}   = {};
    $self->{_progress_by_profile}  = {};

    my $sth_p = $dbh->prepare(q{
        SELECT p.id_achievement_profile, p.id_channel, p.id_user,
               p.display_nick, p.created_at, p.last_seen_at,
               c.name AS channel_name
        FROM ACHIEVEMENT_PROFILE p
        JOIN CHANNEL c ON c.id_channel = p.id_channel
        ORDER BY p.id_achievement_profile
    });
    if ($sth_p && $sth_p->execute) {
        while (my $r = $sth_p->fetchrow_hashref) {
            my $pid = 0 + $r->{id_achievement_profile};
            my $cid = 0 + $r->{id_channel};
            $self->{_profiles}{$pid} = {
                id_channel   => $cid,
                id_user      => $r->{id_user},
                display_nick => $r->{display_nick} // '',
                channel      => $r->{channel_name} // '',
                last_seen_at => $r->{last_seen_at},
            };
            $self->{_channel_ids}{_norm_channel($r->{channel_name})} = $cid;
            $self->{_channel_names}{$cid} = $r->{channel_name};
            my $nk = _nick_channel_cache_key($cid, $r->{display_nick});
            $self->{_nick_channel_profile}{$nk} = $pid;
        }
        $sth_p->finish;
    }

    my $sth_i = $dbh->prepare(q{
        SELECT id_achievement_profile, id_channel, nick, userhost
        FROM ACHIEVEMENT_IDENTITY
        ORDER BY last_seen_at, id_achievement_identity
    });
    if ($sth_i && $sth_i->execute) {
        while (my $r = $sth_i->fetchrow_hashref) {
            my $pid = 0 + $r->{id_achievement_profile};
            my $cid = 0 + $r->{id_channel};
            $self->{_identity_exact}{
                _identity_cache_key($cid, $r->{nick}, $r->{userhost})
            } = $pid;
            $self->{_nick_channel_profile}{
                _nick_channel_cache_key($cid, $r->{nick})
            } = $pid;
        }
        $sth_i->finish;
    }

    my $sth_u = $dbh->prepare(q{
        SELECT id_achievement_profile, achievement_id,
               UNIX_TIMESTAMP(unlocked_at) AS unlock_ts
        FROM ACHIEVEMENT_UNLOCK
    });
    if ($sth_u && $sth_u->execute) {
        while (my $r = $sth_u->fetchrow_hashref) {
            my $pid = 0 + $r->{id_achievement_profile};
            $self->{_unlocks_by_profile}{$pid}{ $r->{achievement_id} } =
                0 + ($r->{unlock_ts} // 0);
        }
        $sth_u->finish;
    }

    my $sth_g = $dbh->prepare(q{
        SELECT id_achievement_profile, progress_kind, progress_value
        FROM ACHIEVEMENT_PROGRESS
    });
    if ($sth_g && $sth_g->execute) {
        while (my $r = $sth_g->fetchrow_hashref) {
            my $pid = 0 + $r->{id_achievement_profile};
            $self->{_progress_by_profile}{ $r->{progress_kind} }{$pid} =
                0 + ($r->{progress_value} // 0);
        }
        $sth_g->finish;
    }

    my $tracked = 0;
    $tracked += scalar keys %{ $self->{_progress_by_profile}{$_} || {} }
        for keys %{ $self->{_progress_by_profile} || {} };
    $self->_log(3, 'Achievements: loaded '
        . scalar(keys %{ $self->{_profiles} }) . " DB profile(s), "
        . "$tracked progress counter(s)");
}

sub _user_object_id {
    my ($user) = @_;
    return undef unless $user;
    my $id = eval { $user->can('id') ? $user->id : $user->{id_user} };
    return (defined($id) && "$id" =~ /\A\d+\z/) ? 0 + $id : undef;
}

sub _message_user_id {
    my ($self, $message, %opts) = @_;
    return undef unless $message && $self->{bot};

    # Reuse Helpers.pm's hostmask cache first. This is intentionally usable
    # even after its short command-auth TTL: attaching a previously proven
    # USER.id_user to an achievement profile is identity bookkeeping, not an
    # authorization decision.
    my $fullmask = eval { $message->prefix } // '';
    if ($fullmask ne '' && ref($self->{bot}{_user_cache}) eq 'HASH') {
        my $cached = $self->{bot}{_user_cache}{$fullmask};
        my $id = _user_object_id($cached);
        return $id if defined $id;
    }
    return undef if $opts{cached_only};

    my $user = eval { $self->{bot}->get_user_from_message($message) };
    return _user_object_id($user);
}

sub _create_profile {
    my ($self, $channel_id, $nick, $userhost, $id_user) = @_;
    my $dbh = $self->{bot}{dbh};
    my $display = defined($nick) ? $nick : '';

    my $sth = $dbh->prepare(q{
        INSERT INTO ACHIEVEMENT_PROFILE
            (id_channel, id_user, display_nick, created_at, last_seen_at)
        VALUES (?, ?, ?, NOW(), NOW())
    });
    return undef unless $sth && $sth->execute($channel_id, $id_user, $display);
    my $pid = $dbh->last_insert_id(undef, undef, undef, undef);
    $pid //= $dbh->{mysql_insertid};
    return undef unless defined($pid) && "$pid" =~ /\A\d+\z/;
    $pid = 0 + $pid;

    $self->{_profiles}{$pid} = {
        id_channel   => $channel_id,
        id_user      => $id_user,
        display_nick => $display,
        channel      => $self->{_channel_names}{$channel_id} // '',
    };
    $self->_attach_identity($pid, $channel_id, $nick, $userhost);
    return $pid;
}

sub _attach_identity {
    my ($self, $pid, $channel_id, $nick, $userhost) = @_;
    return 0 unless $pid && $channel_id && defined($nick) && length($nick);
    my $dbh = $self->{bot}{dbh};
    $userhost = '' unless defined $userhost;

    my $sth = $dbh->prepare(q{
        INSERT INTO ACHIEVEMENT_IDENTITY
            (id_achievement_profile, id_channel, nick, userhost, first_seen_at, last_seen_at)
        VALUES (?, ?, ?, ?, NOW(), NOW())
        ON DUPLICATE KEY UPDATE
            id_achievement_profile = VALUES(id_achievement_profile),
            last_seen_at = NOW()
    });
    return 0 unless $sth && $sth->execute($pid, $channel_id, $nick, $userhost);

    $self->{_identity_exact}{
        _identity_cache_key($channel_id, $nick, $userhost)
    } = $pid;
    $self->{_nick_channel_profile}{
        _nick_channel_cache_key($channel_id, $nick)
    } = $pid;
    return 1;
}

sub _touch_seen_alias {
    my ($self, $pid, $channel_id, $nick, $userhost) = @_;
    my $key = _identity_cache_key($channel_id, $nick, $userhost);
    my $now = time();
    my $last = $self->{_identity_touch_ts}{$key} // 0;
    return 1 if ($now - $last) < 3600;

    my $dbh = $self->{bot}{dbh};
    my $sth_i = $dbh->prepare(q{
        UPDATE ACHIEVEMENT_IDENTITY
        SET last_seen_at = NOW()
        WHERE id_channel = ? AND nick = ? AND userhost = ?
    });
    eval { $sth_i->execute($channel_id, $nick, $userhost) } if $sth_i;

    my $sth_p = $dbh->prepare(q{
        UPDATE ACHIEVEMENT_PROFILE
        SET display_nick = ?, last_seen_at = NOW()
        WHERE id_achievement_profile = ?
    });
    eval { $sth_p->execute($nick, $pid) } if $sth_p;

    $self->{_profiles}{$pid}{display_nick} = $nick
        if $self->{_profiles}{$pid};
    $self->{_identity_touch_ts}{$key} = $now;
    return 1;
}

sub _touch_profile {
    my ($self, $pid, $nick, $id_user) = @_;
    return 0 unless $pid && $self->{_profiles}{$pid};
    my $dbh = $self->{bot}{dbh};

    my $current_uid = $self->{_profiles}{$pid}{id_user};
    my $new_uid = defined($current_uid) ? $current_uid : $id_user;

    my $sth = $dbh->prepare(q{
        UPDATE ACHIEVEMENT_PROFILE
        SET display_nick = ?,
            id_user = COALESCE(id_user, ?),
            last_seen_at = NOW()
        WHERE id_achievement_profile = ?
    });
    return 0 unless $sth && $sth->execute($nick, $id_user, $pid);

    $self->{_profiles}{$pid}{display_nick} = $nick;
    $self->{_profiles}{$pid}{id_user} = $new_uid;
    my $cid = $self->{_profiles}{$pid}{id_channel};
    $self->{_nick_channel_profile}{
        _nick_channel_cache_key($cid, $nick)
    } = $pid;
    return 1;
}

sub _profile_for_registered_user {
    my ($self, $channel_id, $id_user) = @_;
    return undef unless $channel_id && defined($id_user);
    my $dbh = $self->{bot}{dbh};
    my $sth = $dbh->prepare(q{
        SELECT id_achievement_profile
        FROM ACHIEVEMENT_PROFILE
        WHERE id_channel = ? AND id_user = ?
        ORDER BY id_achievement_profile
        LIMIT 1
    });
    return undef unless $sth && $sth->execute($channel_id, $id_user);
    my ($pid) = $sth->fetchrow_array;
    $sth->finish;
    return (defined($pid) && "$pid" =~ /\A\d+\z/) ? 0 + $pid : undef;
}

sub _merge_profiles {
    my ($self, $keep, $drop) = @_;
    return $keep unless $keep && $drop && $keep != $drop;
    my $dbh = $self->{bot}{dbh};

    my $ok = eval {
        local $dbh->{AutoCommit} = 0;

        # Merit is merged losslessly: oldest unlock time, highest progress.
        my $u = $dbh->prepare(q{
            INSERT INTO ACHIEVEMENT_UNLOCK
                (id_achievement_profile, achievement_id, unlocked_at)
            SELECT ?, achievement_id, unlocked_at
            FROM ACHIEVEMENT_UNLOCK
            WHERE id_achievement_profile = ?
            ON DUPLICATE KEY UPDATE
                unlocked_at = LEAST(unlocked_at, VALUES(unlocked_at))
        });
        $u->execute($keep, $drop);

        my $g = $dbh->prepare(q{
            INSERT INTO ACHIEVEMENT_PROGRESS
                (id_achievement_profile, progress_kind, progress_value, updated_at)
            SELECT ?, progress_kind, progress_value, updated_at
            FROM ACHIEVEMENT_PROGRESS
            WHERE id_achievement_profile = ?
            ON DUPLICATE KEY UPDATE
                progress_value = GREATEST(progress_value, VALUES(progress_value)),
                updated_at = GREATEST(updated_at, VALUES(updated_at))
        });
        $g->execute($keep, $drop);

        # Copy aliases instead of UPDATEing them in place: an exact triplet may
        # already exist on the kept profile and the unique key must never make a
        # legitimate merge fail.
        my $i = $dbh->prepare(q{
            INSERT INTO ACHIEVEMENT_IDENTITY
                (id_achievement_profile, id_channel, nick, userhost,
                 first_seen_at, last_seen_at)
            SELECT ?, id_channel, nick, userhost, first_seen_at, last_seen_at
            FROM ACHIEVEMENT_IDENTITY
            WHERE id_achievement_profile = ?
            ON DUPLICATE KEY UPDATE
                first_seen_at = LEAST(first_seen_at, VALUES(first_seen_at)),
                last_seen_at  = GREATEST(last_seen_at, VALUES(last_seen_at))
        });
        $i->execute($keep, $drop);

        $dbh->do(
            'DELETE FROM ACHIEVEMENT_IDENTITY WHERE id_achievement_profile = ?',
            undef, $drop
        );
        $dbh->do(
            'DELETE FROM ACHIEVEMENT_UNLOCK WHERE id_achievement_profile = ?',
            undef, $drop
        );
        $dbh->do(
            'DELETE FROM ACHIEVEMENT_PROGRESS WHERE id_achievement_profile = ?',
            undef, $drop
        );
        $dbh->do(
            'DELETE FROM ACHIEVEMENT_PROFILE WHERE id_achievement_profile = ?',
            undef, $drop
        );
        $dbh->commit;
        1;
    };

    if (!$ok) {
        my $error = $@;
        eval { $dbh->rollback };
        eval { $self->_load_db };
        $self->_log(1,
            "Achievements: profile merge failed ($drop -> $keep): $error");
        return $drop;
    }

    $self->_load_db;
    $self->_log(2, "Achievements: merged identity profile $drop into $keep");
    return $keep;
}

sub observe_identity {
    my ($self, $nick, $channel, $userhost, $message) = @_;
    return undef unless defined($nick) && length($nick)
        && defined($channel) && $channel =~ /^#/;

    # JSON fallback keeps the historical semantics.
    return lc($nick) . "\x00" . lc($channel)
        unless ($self->{storage} // '') eq 'db';

    my $cid = $self->_channel_id($channel);
    return undef unless $cid;

    $userhost = '' unless defined $userhost;
    my $exact_key = _identity_cache_key($cid, $nick, $userhost);
    if (my $pid = $self->{_identity_exact}{$exact_key}) {
        $self->_touch_seen_alias($pid, $cid, $nick, $userhost);

        # A user may authenticate/register AFTER this IRC alias was first
        # observed. If Helpers has since proved that full hostmask, enrich the
        # durable profile without forcing a USER_HOSTMASK scan on every PRIVMSG.
        if ($self->{_profiles}{$pid}
            && !defined($self->{_profiles}{$pid}{id_user})) {
            my $cached_uid = $self->_message_user_id(
                $message, cached_only => 1
            );
            if (defined $cached_uid) {
                my $registered = $self->_profile_for_registered_user(
                    $cid, $cached_uid
                );
                if ($registered && $registered != $pid) {
                    $pid = $self->_merge_profiles($registered, $pid);
                }
                $self->_touch_profile($pid, $nick, $cached_uid);
            }
        }
        return $pid;
    }

    my $dbh = $self->{bot}{dbh};
    my $id_user = $self->_message_user_id($message);

    # Registered account is authoritative within one channel.
    if (defined $id_user) {
        my $pid = $self->_profile_for_registered_user($cid, $id_user);
        if ($pid) {
            $self->_attach_identity($pid, $cid, $nick, $userhost);
            $self->_touch_profile($pid, $nick, $id_user);
            return $pid;
        }
    }

    # Same user@host on the same channel: a nick change is safe to follow.
    if (_norm_userhost($userhost) ne '') {
        my $sth = $dbh->prepare(q{
            SELECT DISTINCT id_achievement_profile
            FROM ACHIEVEMENT_IDENTITY
            WHERE id_channel = ? AND userhost = ?
            ORDER BY id_achievement_profile
        });
        if ($sth && $sth->execute($cid, $userhost)) {
            my @pids;
            while (my ($pid) = $sth->fetchrow_array) { push @pids, 0 + $pid }
            $sth->finish;
            if (@pids == 1) {
                my $pid = $pids[0];
                $self->_attach_identity($pid, $cid, $nick, $userhost);
                $self->_touch_profile($pid, $nick, $id_user);
                return $pid;
            }
        }
    }

    # Same nick on the same channel: accept only a compatible user@host and
    # only when that evidence points to one profile.
    my $sth_n = $dbh->prepare(q{
        SELECT id_achievement_profile, userhost
        FROM ACHIEVEMENT_IDENTITY
        WHERE id_channel = ? AND nick = ?
        ORDER BY last_seen_at DESC, id_achievement_identity DESC
    });
    if ($sth_n && $sth_n->execute($cid, $nick)) {
        my %candidate;
        while (my $r = $sth_n->fetchrow_hashref) {
            if (_userhost_compatible($r->{userhost}, $userhost)) {
                $candidate{ 0 + $r->{id_achievement_profile} } = 1;
            }
        }
        $sth_n->finish;
        if (keys(%candidate) == 1) {
            my ($pid) = keys %candidate;
            $self->_attach_identity($pid, $cid, $nick, $userhost);
            $self->_touch_profile($pid, $nick, $id_user);
            return 0 + $pid;
        }
    }

    my $pid = $self->_create_profile($cid, $nick, $userhost, $id_user);
    return $pid;
}

sub _profile_id_for {
    my ($self, $nick, $channel, %opts) = @_;
    return undef unless ($self->{storage} // '') eq 'db';

    my $cid = $self->_channel_id($channel);
    return undef unless $cid;

    my $nk = _nick_channel_cache_key($cid, $nick);
    return $self->{_nick_channel_profile}{$nk}
        if exists $self->{_nick_channel_profile}{$nk};

    my $dbh = $self->{bot}{dbh};
    my $sth = $dbh->prepare(q{
        SELECT i.id_achievement_profile
        FROM ACHIEVEMENT_IDENTITY i
        JOIN ACHIEVEMENT_PROFILE p
          ON p.id_achievement_profile = i.id_achievement_profile
        WHERE i.id_channel = ? AND i.nick = ?
        ORDER BY i.last_seen_at DESC, i.id_achievement_identity DESC
        LIMIT 2
    });
    if ($sth && $sth->execute($cid, $nick)) {
        my @pids;
        while (my ($pid) = $sth->fetchrow_array) { push @pids, 0 + $pid }
        $sth->finish;
        if (@pids) {
            # For a display/query by nick, the most recently observed identity
            # is the least surprising answer. Live callers are pinned more
            # precisely by observe_identity().
            $self->{_nick_channel_profile}{$nk} = $pids[0];
            return $pids[0];
        }
    }

    return $self->_create_profile($cid, $nick, '', undef) if $opts{create};
    return undef;
}

sub _db_get_unlocks {
    my ($self, $pid) = @_;
    return {} unless $pid;
    return $self->{_unlocks_by_profile}{$pid} // {};
}

sub _db_progress {
    my ($self, $pid, $kind) = @_;
    return 0 unless $pid && defined $kind;
    return $self->{_progress_by_profile}{$kind}{$pid} // 0;
}

sub _db_set_progress {
    my ($self, $pid, $kind, $value) = @_;
    return 0 unless $pid && defined($kind) && length($kind);
    return 0 unless defined($value) && "$value" =~ /\A\d+\z/;

    my $dbh = $self->{bot}{dbh};
    my $sth = $dbh->prepare(q{
        INSERT INTO ACHIEVEMENT_PROGRESS
            (id_achievement_profile, progress_kind, progress_value, updated_at)
        VALUES (?, ?, ?, NOW())
        ON DUPLICATE KEY UPDATE
            progress_value = GREATEST(progress_value, VALUES(progress_value)),
            updated_at = NOW()
    });
    return 0 unless $sth && $sth->execute($pid, $kind, $value);

    my $cur = $self->{_progress_by_profile}{$kind}{$pid} // 0;
    $self->{_progress_by_profile}{$kind}{$pid} = int($value) if $value > $cur;
    return $self->{_progress_by_profile}{$kind}{$pid} // $cur;
}

sub _read_legacy_json {
    my ($self, $path) = @_;
    return undef unless defined($path) && -f $path;
    open my $fh, '<:utf8', $path or return undef;
    local $/;
    my $raw = <$fh>;
    close $fh;
    my $decoded = eval { JSON::PP->new->utf8(0)->decode($raw) };
    return undef if $@ || ref($decoded) ne 'HASH';

    if (ref($decoded->{profiles}) eq 'HASH'
        && defined($decoded->{version}) && $decoded->{version} eq '2') {
        return {
            profiles => $decoded->{profiles},
            progress => ref($decoded->{progress}) eq 'HASH' ? $decoded->{progress} : {},
        };
    }
    return { profiles => $decoded, progress => {} };
}

sub _legacy_json_sources {
    my ($self, %opts) = @_;
    my @sources;

    my $path = $self->{path};
    push @sources, $path if defined($path) && -f $path;

    if ($opts{include_archives}) {
        push @sources, $self->_legacy_archive_json_sources($path);
    }

    my %seen;
    return grep { defined($_) && !$seen{$_}++ } @sources;
}

sub _import_legacy_json_if_present {
    my ($self, %opts) = @_;
    return 0 unless ($self->{storage} // '') eq 'db';

    my @sources = $self->_legacy_json_sources(%opts);
    return 0 unless @sources;

    # Merge legacy snapshots before touching SQL. Repeated old-style updates
    # could have left different merit in different release archives.
    my (%legacy_profiles, %legacy_progress);
    my @decoded_sources;
    for my $source (@sources) {
        my $legacy = $self->_read_legacy_json($source);
        if (!$legacy) {
            $self->_log(1,
                "Achievements: legacy JSON exists but cannot be decoded: $source");
            next;
        }
        push @decoded_sources, $source;

        for my $key (keys %{ $legacy->{profiles} || {} }) {
            for my $id (keys %{ $legacy->{profiles}{$key} || {} }) {
                next unless exists $ACH{$id};
                my $ts = $legacy->{profiles}{$key}{$id};
                $ts = time() unless defined($ts) && "$ts" =~ /\A\d+\z/;
                if (!exists($legacy_profiles{$key}{$id})
                    || $ts < $legacy_profiles{$key}{$id}) {
                    $legacy_profiles{$key}{$id} = $ts;
                }
            }
        }

        for my $kind (keys %{ $legacy->{progress} || {} }) {
            for my $key (keys %{ $legacy->{progress}{$kind} || {} }) {
                my $value = $legacy->{progress}{$kind}{$key};
                next unless defined($value) && "$value" =~ /\A\d+\z/;
                if (!exists($legacy_progress{$kind}{$key})
                    || $value > $legacy_progress{$kind}{$key}) {
                    $legacy_progress{$kind}{$key} = 0 + $value;
                }
            }
        }
    }
    return 0 unless @decoded_sources;

    my $legacy = {
        profiles => \%legacy_profiles,
        progress => \%legacy_progress,
    };

    my $dbh = $self->{bot}{dbh};
    my ($profiles, $unlocks, $progress) = (0, 0, 0);
    my $ok = eval {
        local $dbh->{AutoCommit} = 0;

        my %pid_for;
        for my $key (sort keys %{ $legacy->{profiles} || {} }) {
            my ($nick, $channel) = split /\x00/, $key, 2;
            next unless defined($nick) && length($nick)
                && defined($channel) && $channel =~ /^#/;
            my $cid = $self->_channel_id($channel) or next;

            my $pid = $self->_profile_id_for($nick, $channel);
            $pid ||= $self->_create_profile($cid, $nick, '', undef);
            next unless $pid;
            $pid_for{$key} = $pid;
            $profiles++;

            for my $id (keys %{ $legacy->{profiles}{$key} || {} }) {
                my $ts = $legacy->{profiles}{$key}{$id};
                my $sth = $dbh->prepare(q{
                    INSERT INTO ACHIEVEMENT_UNLOCK
                        (id_achievement_profile, achievement_id, unlocked_at)
                    VALUES (?, ?, FROM_UNIXTIME(?))
                    ON DUPLICATE KEY UPDATE
                        unlocked_at = LEAST(unlocked_at, VALUES(unlocked_at))
                });
                $sth->execute($pid, $id, $ts);
                $unlocks++;
            }
        }

        for my $kind (keys %{ $legacy->{progress} || {} }) {
            for my $key (keys %{ $legacy->{progress}{$kind} || {} }) {
                my $value = $legacy->{progress}{$kind}{$key};
                my $pid = $pid_for{$key};
                if (!$pid) {
                    my ($nick, $channel) = split /\x00/, $key, 2;
                    next unless defined($nick) && defined($channel) && $channel =~ /^#/;
                    my $cid = $self->_channel_id($channel) or next;
                    $pid = $self->_profile_id_for($nick, $channel)
                        || $self->_create_profile($cid, $nick, '', undef);
                    $pid_for{$key} = $pid if $pid;
                }
                next unless $pid;
                my $sth = $dbh->prepare(q{
                    INSERT INTO ACHIEVEMENT_PROGRESS
                        (id_achievement_profile, progress_kind, progress_value, updated_at)
                    VALUES (?, ?, ?, NOW())
                    ON DUPLICATE KEY UPDATE
                        progress_value = GREATEST(progress_value, VALUES(progress_value)),
                        updated_at = NOW()
                });
                $sth->execute($pid, $kind, $value);
                $progress++;
            }
        }

        $dbh->commit;
        1;
    };

    if (!$ok) {
        my $error = $@;
        eval { $dbh->rollback };
        # Transactional writes may already have touched the in-memory caches.
        # Reload from committed DB state so a failed import cannot leave ghost
        # profiles visible until the next restart.
        eval { $self->_load_db };
        $self->_log(1, "Achievements: legacy JSON DB import failed: $error");
        return 0;
    }

    # Only the live file is mutable. Archived releases are historical evidence
    # and are deliberately left untouched.
    my $path = $self->{path};
    if (defined($path) && -f $path) {
        my $backup = $path . '.migrated-' . time();
        if (!rename($path, $backup)) {
            $self->_log(1,
                "Achievements: DB import succeeded but cannot archive legacy JSON $path: $!");
        }
        else {
            $self->_log(1,
                "Achievements: archived live legacy JSON as $backup");
        }
    }

    $self->_log(1,
        "Achievements: processed legacy state from "
      . scalar(@decoded_sources) . " source(s) into DB "
      . "($profiles profile record(s) processed, "
      . "$unlocks unlock record(s) processed, "
      . "$progress progress record(s) processed)");

    $self->_load_db;
    return 1;
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
    # mb610-B1: deux formats acceptes. v2 = enveloppe { version, profiles,
    # progress } ; heritage = table de profils a plat. Un fichier hérité se
    # charge tel quel (aucune perte) et repartira en v2 au prochain save.
    if (ref $data eq 'HASH'
        && ref $data->{profiles} eq 'HASH'
        && defined $data->{version} && $data->{version} eq '2') {
        $self->{data}     = $data->{profiles};
        $self->{progress} = (ref $data->{progress} eq 'HASH') ? $data->{progress} : {};
    }
    elsif (ref $data eq 'HASH') {
        $self->{data} = $data;
        $self->_log(2, 'Achievements: legacy flat file loaded, will be saved as v2');
    }

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

    my $tracked = 0;
    $tracked += scalar keys %{ $self->{progress}{$_} || {} }
        for keys %{ $self->{progress} || {} };
    $self->_log(3, "Achievements: loaded " . scalar(keys %{$self->{data}})
        . " profile(s), $tracked progress counter(s)");
}

# -- Sauvegarde en JSON (avec debounce) -----------------------------------------
sub save {
    my ($self, $force) = @_;
    # mb646: DB writes are synchronous write-through operations. There is no
    # buffered state to flush; keep save() as a compatibility no-op.
    return 1 if ($self->{storage} // '') eq 'db';
    return unless $force || $self->{dirty};
    # debounce : pas plus d'une sauvegarde toutes les 10s sauf force
    if (!$force && (time() - $self->{last_save}) < 10) {
        return;
    }
    eval {
        make_path(dirname($self->{path})) unless -d dirname($self->{path});
        my $json = JSON::PP->new->utf8(0)->pretty->canonical->encode({
            version  => '2',
            profiles => $self->{data},
            progress => $self->{progress},
        });
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

# -- Registre de progression (mb610) -------------------------------------------
# Cle canonique : lc(nick) + \x00 + lc(channel), comme les profils. Un
# achievement se debloque PAR CANAL, donc le merite se compte par canal.
our $MAX_PROGRESS_ENTRIES = 5000;

sub _progress_key {
    my ($nick, $channel) = @_;
    return undef unless defined $nick && length $nick;
    return lc($nick) . "\x00" . lc($channel // '');
}

# Lecture seule : la valeur courante, 0 si inconnue.
sub progress {
    my ($self, $kind, $nick, $channel) = @_;
    if (($self->{storage} // '') eq 'db') {
        my $pid = $self->_profile_id_for($nick, $channel);
        return $self->_db_progress($pid, $kind);
    }
    my $key = _progress_key($nick, $channel);
    return 0 unless defined $kind && defined $key;
    return $self->{progress}{$kind}{$key} // 0;
}

# Incremente et rend la NOUVELLE valeur. Marque le fichier a sauver ; la
# sauvegarde reelle passe par le debounce de save() — un compteur n'a pas
# besoin de la meme urgence qu'un unlock, qui force l'ecriture.
sub bump_progress {
    my ($self, $kind, $nick, $channel, $by) = @_;
    if (($self->{storage} // '') eq 'db') {
        return 0 unless defined($kind) && length($kind);
        $by = 1 unless defined $by && "$by" =~ /\A-?\d+\z/;
        my $pid = $self->_profile_id_for($nick, $channel, create => 1);
        return 0 unless $pid;
        my $value = $self->_db_progress($pid, $kind) + $by;
        $value = 0 if $value < 0;
        return $self->_db_set_progress($pid, $kind, $value);
    }

    my $key = _progress_key($nick, $channel);
    return 0 unless defined $kind && length $kind && defined $key;
    $by = 1 unless defined $by && $by =~ /\A-?\d+\z/;
    my $value = ($self->{progress}{$kind}{$key} // 0) + $by;
    $value = 0 if $value < 0;
    $self->{progress}{$kind}{$key} = $value;
    $self->{dirty} = 1;
    # Le compteur qu'on vient de toucher est protege : sans cela, une
    # nouvelle entree (valeur 1) pouvait etre elaguee dans la foulee de sa
    # creation et ne jamais decoller.
    $self->_prune_progress($kind, $key);
    $self->save;
    return $self->{progress}{$kind}{$key} // $value;
}

# Un canal tres frequente ne doit pas faire enfler le fichier sans fin :
# au-dela du plafond, on laisse tomber les compteurs les PLUS FAIBLES —
# ceux qui sont le plus loin d'un palier, donc les moins interessants.
sub _prune_progress {
    my ($self, $kind, $keep_key) = @_;
    my $table = $self->{progress}{$kind} or return;
    my $count = scalar keys %$table;
    return if $count <= $MAX_PROGRESS_ENTRIES;
    my @by_value = grep { !defined $keep_key || $_ ne $keep_key }
                   sort { $table->{$a} <=> $table->{$b} || $a cmp $b } keys %$table;
    my $drop = $count - $MAX_PROGRESS_ENTRIES;
    $drop = scalar @by_value if $drop > scalar @by_value;
    delete $table->{ $by_value[$_] } for 0 .. ($drop - 1);
    $self->_log(2, "Achievements: pruned $drop low '$kind' progress counter(s)");
}

# mb612-B1: valeur d'ETAT (et non incrementale). Certains compteurs sont des
# cumuls que le bot incremente (duels, trivia, horoscope) ; d'autres sont
# deja connus au moment de la verification parce qu'ils viennent de la base
# (nombre de messages, karma, mots distincts, canaux frequentes). Ces
# derniers sont ENREGISTRES tels quels — aucune requete supplementaire — pour
# que l'affichage de progression connaisse TOUTE la grille et pas la moitie.
# La valeur ne redescend pas : un etat lu plus bas (fenetre glissante, purge)
# ne doit pas effacer un merite deja constate.
sub set_progress {
    my ($self, $kind, $nick, $channel, $value) = @_;
    if (($self->{storage} // '') eq 'db') {
        return 0 unless defined($kind) && length($kind);
        return 0 unless defined($value) && !ref($value) && "$value" =~ /\A\d+\z/;
        my $pid = $self->_profile_id_for($nick, $channel, create => 1);
        return 0 unless $pid;
        my $current = $self->_db_progress($pid, $kind);
        return $current if $value <= $current;
        return $self->_db_set_progress($pid, $kind, int($value));
    }

    my $key = _progress_key($nick, $channel);
    return 0 unless defined $kind && length $kind && defined $key;
    return 0 unless defined $value && !ref $value && $value =~ /\A\d+\z/;
    my $current = $self->{progress}{$kind}{$key} // 0;
    return $current if $value <= $current;
    $self->{progress}{$kind}{$key} = int($value);
    $self->{dirty} = 1;
    $self->_prune_progress($kind, $key);
    $self->save;
    return $self->{progress}{$kind}{$key} // int($value);
}

# mb612-B1: photographie complete de la grille pour un nick sur un canal.
# Rend, par achievement : debloque ou non, valeur courante, seuil, pourcentage.
# Un achievement sans progress_kind (sniper, underdog, tranches horaires) est
# rendu SANS mesure — on ne fabrique pas une progression qu'on ne sait pas
# mesurer.
sub progress_snapshot {
    my ($self, $nick, $channel) = @_;
    my $unlocked = $self->get_for_nick($nick, $channel);
    my %out;
    for my $id (keys %ACH) {
        my $kind = $ACH{$id}{progress_kind};
        my $goal = $self->threshold($id);
        my $entry = {
            unlocked  => (exists $unlocked->{$id} ? 1 : 0),
            threshold => $goal,
            rarity    => $ACH{$id}{rarity},
            measurable => ($kind && $goal ? 1 : 0),
        };
        if ($entry->{measurable}) {
            my $cur = $self->progress($kind, $nick, $channel);
            $cur = $goal if $entry->{unlocked} && $cur < $goal;   # deja gagne
            $entry->{current} = $cur;
            $entry->{pct} = $goal > 0 ? int(100 * $cur / $goal) : 0;
            $entry->{pct} = 100 if $entry->{pct} > 100;
        }
        $out{$id} = $entry;
    }
    return \%out;
}

# mb612-B1: les N achievements VERROUILLES dont on est le plus pres, du plus
# proche au plus lointain. Un achievement jamais commence (0 %) n'est propose
# qu'a defaut de mieux : viser ce qu'on a deja entame est plus motivant.
sub next_goals {
    my ($self, $nick, $channel, $limit) = @_;
    $limit = 3 unless defined $limit && $limit =~ /\A\d+\z/ && $limit > 0;
    my $snap = $self->progress_snapshot($nick, $channel);
    # Un palier deja atteint mais pas encore enregistre (la verification
    # l'ouvrira au prochain evenement) n'est PAS un objectif : le proposer
    # afficherait « 137/10 (100%) » dans la liste des choses a faire.
    my @candidates =
        grep { !$snap->{$_}{unlocked} && $snap->{$_}{measurable}
               && $snap->{$_}{current} < $snap->{$_}{threshold} }
        keys %$snap;
    my @sorted = sort {
        ($snap->{$b}{pct} <=> $snap->{$a}{pct})
        || ($snap->{$a}{threshold} <=> $snap->{$b}{threshold})
        || ($a cmp $b)
    } @candidates;
    @sorted = @sorted[0 .. $limit - 1] if @sorted > $limit;
    return [ map { { id => $_, %{ $snap->{$_} } } } @sorted ];
}

# Compteurs d'un nick sur un canal, tous types confondus (pour .achievements
# et le futur affichage de progression).
sub progress_for_nick {
    my ($self, $nick, $channel) = @_;
    if (($self->{storage} // '') eq 'db') {
        my $pid = $self->_profile_id_for($nick, $channel);
        return {} unless $pid;
        my %out;
        for my $kind (sort keys %{ $self->{_progress_by_profile} || {} }) {
            my $v = $self->{_progress_by_profile}{$kind}{$pid};
            $out{$kind} = $v if defined($v) && $v > 0;
        }
        return \%out;
    }

    my $key = _progress_key($nick, $channel);
    return {} unless defined $key;
    my %out;
    for my $kind (sort keys %{ $self->{progress} || {} }) {
        my $v = $self->{progress}{$kind}{$key};
        $out{$kind} = $v if defined $v && $v > 0;
    }
    return \%out;
}

# -- Récupère les achievements d'un nick sur un canal ---------------------------
sub get_for_nick {
    my ($self, $nick, $channel) = @_;
    return {} unless defined $nick;
    if (($self->{storage} // '') eq 'db') {
        my $pid = $self->_profile_id_for($nick, $channel);
        return $self->_db_get_unlocks($pid);
    }
    my $key = lc($nick) . "\x00" . (defined $channel ? lc($channel) : "");  # mb430-B1: canal en lc (IRC insensible a la casse)
    return $self->{data}{$key} // {};
}

# -- Récupère tous les achievements d'un nick (cross-canal) ---------------------
sub get_for_nick_all {
    my ($self, $nick) = @_;
    return {} unless defined $nick;

    if (($self->{storage} // '') eq 'db') {
        my $dbh = $self->{bot}{dbh};
        my $sth = $dbh->prepare(q{
            SELECT DISTINCT p.id_achievement_profile, c.name AS channel_name
            FROM ACHIEVEMENT_PROFILE p
            JOIN CHANNEL c ON c.id_channel = p.id_channel
            LEFT JOIN ACHIEVEMENT_IDENTITY i
              ON i.id_achievement_profile = p.id_achievement_profile
            WHERE p.display_nick = ? OR i.nick = ?
            ORDER BY p.last_seen_at DESC, p.id_achievement_profile
        });
        my %merged;
        if ($sth && $sth->execute($nick, $nick)) {
            while (my $r = $sth->fetchrow_hashref) {
                my $pid = 0 + $r->{id_achievement_profile};
                my $ch  = $r->{channel_name} // '';
                for my $id (keys %{ $self->_db_get_unlocks($pid) }) {
                    my $ts = $self->{_unlocks_by_profile}{$pid}{$id};
                    if (!exists($merged{$id}) || $ts < $merged{$id}{ts}) {
                        $merged{$id} = { ts => $ts, channel => $ch };
                    }
                }
            }
            $sth->finish;
        }
        return \%merged;
    }

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
    if (($self->{storage} // '') eq 'db') {
        my %counts;
        for my $pid (keys %{ $self->{_profiles} || {} }) {
            my $nick = $self->{_profiles}{$pid}{display_nick} // '';
            next unless length $nick;
            $counts{lc $nick} += scalar keys %{ $self->_db_get_unlocks($pid) };
        }
        return \%counts;
    }

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


# -- Agrégats pour dashboard / leaderboard ------------------------------------
# Keep presentation code out of the internal storage representation.

# -- mb654: read-only durable identity diagnostic ----------------------------
#
# This deliberately does NOT call observe_identity(), _profile_id_for() or any
# other helper that can create/touch/merge profiles.  The diagnostic reports
# the durable evidence that exists now; it cannot reconstruct the historical
# reason why an alias was originally attached because mb646 does not persist a
# merge audit trail.
sub identity_profile_diagnostic {
    my ($self, $nick, $channel) = @_;

    my $result = {
        backend => ($self->{storage} // 'unknown'),
        nick    => defined($nick)    ? $nick    : '',
        channel => defined($channel) ? $channel : '',
        status  => 'invalid',
    };

    return $result unless defined($nick) && $nick =~ /\S/
        && defined($channel) && $channel =~ /^#\S+$/;

    # Legacy installations have no durable alias/profile graph to explain.
    # Still report the old nick+channel key and merit counts without writing.
    if (($self->{storage} // '') ne 'db') {
        my $key = lc($nick) . "\x00" . lc($channel);
        my $unlocks = scalar keys %{ $self->{data}{$key} || {} };
        my $progress = 0;
        for my $kind (keys %{ $self->{progress} || {} }) {
            $progress++ if exists $self->{progress}{$kind}{$key};
        }
        return {
            %$result,
            status            => 'legacy_json',
            storage_label     => 'legacy JSON',
            legacy_key        => $key,
            unlock_count      => $unlocks,
            progress_counters => $progress,
            historical_reason => 'not_available',
        };
    }

    my $dbh = eval { $self->{bot}{dbh} };
    unless ($dbh && eval { $dbh->can('prepare') }) {
        return { %$result, status => 'db_unavailable', storage_label => 'MariaDB' };
    }

    # Resolve the channel with a SELECT only.  Do not use _channel_id(): that
    # helper intentionally fills runtime caches and is therefore not a pure
    # diagnostic source.
    my $sth_c = eval {
        $dbh->prepare(q{
            SELECT id_channel, name
            FROM CHANNEL
            WHERE name = ?
            LIMIT 1
        })
    };
    unless ($sth_c && eval { $sth_c->execute($channel) }) {
        return { %$result, status => 'query_error', storage_label => 'MariaDB' };
    }
    my $crow = $sth_c->fetchrow_hashref;
    $sth_c->finish;
    unless ($crow && defined($crow->{id_channel})) {
        return { %$result, status => 'channel_not_found', storage_label => 'MariaDB' };
    }

    my $cid = 0 + $crow->{id_channel};
    my $canonical_channel = $crow->{name} // $channel;

    # A nick-only diagnostic must never silently pick one of two plausible
    # profiles.  Return every candidate so the operator can see the ambiguity.
    my $sth_p = eval {
        $dbh->prepare(q{
            SELECT DISTINCT
                   p.id_achievement_profile,
                   p.id_user,
                   p.display_nick,
                   p.created_at,
                   p.last_seen_at,
                   u.nickname AS registered_nick,
                   (SELECT COUNT(*)
                      FROM ACHIEVEMENT_IDENTITY ai
                     WHERE ai.id_achievement_profile = p.id_achievement_profile)
                       AS alias_count,
                   (SELECT COUNT(*)
                      FROM ACHIEVEMENT_UNLOCK au
                     WHERE au.id_achievement_profile = p.id_achievement_profile)
                       AS unlock_count,
                   (SELECT COUNT(*)
                      FROM ACHIEVEMENT_PROGRESS ap
                     WHERE ap.id_achievement_profile = p.id_achievement_profile)
                       AS progress_counters
            FROM ACHIEVEMENT_PROFILE p
            LEFT JOIN ACHIEVEMENT_IDENTITY i
              ON i.id_achievement_profile = p.id_achievement_profile
            LEFT JOIN USER u
              ON u.id_user = p.id_user
            WHERE p.id_channel = ?
              AND (p.display_nick = ? OR i.nick = ?)
            ORDER BY p.last_seen_at DESC, p.id_achievement_profile DESC
            LIMIT 21
        })
    };
    unless ($sth_p && eval { $sth_p->execute($cid, $nick, $nick) }) {
        return {
            %$result,
            status        => 'query_error',
            storage_label => 'MariaDB',
            id_channel    => $cid,
            channel       => $canonical_channel,
        };
    }

    my @profiles;
    while (my $row = $sth_p->fetchrow_hashref) {
        next unless defined($row->{id_achievement_profile});
        push @profiles, {
            id_achievement_profile => 0 + $row->{id_achievement_profile},
            id_user                => defined($row->{id_user}) ? 0 + $row->{id_user} : undef,
            registered_nick        => $row->{registered_nick},
            display_nick           => $row->{display_nick} // '',
            created_at             => $row->{created_at},
            last_seen_at           => $row->{last_seen_at},
            alias_count            => 0 + ($row->{alias_count} // 0),
            unlock_count           => 0 + ($row->{unlock_count} // 0),
            progress_counters      => 0 + ($row->{progress_counters} // 0),
        };
    }
    $sth_p->finish;

    my $base = {
        %$result,
        storage_label     => 'MariaDB',
        id_channel        => $cid,
        channel           => $canonical_channel,
        historical_reason => 'not_persisted',
    };

    return { %$base, status => 'not_found', candidates => [] }
        unless @profiles;

    if (@profiles > 1) {
        my $truncated = @profiles > 20 ? 1 : 0;
        pop @profiles while @profiles > 20;
        return {
            %$base,
            status               => 'ambiguous',
            candidates           => \@profiles,
            candidates_truncated => $truncated,
        };
    }

    my $profile = $profiles[0];
    my $pid = $profile->{id_achievement_profile};

    my $sth_i = eval {
        $dbh->prepare(q{
            SELECT nick, userhost, first_seen_at, last_seen_at
            FROM ACHIEVEMENT_IDENTITY
            WHERE id_achievement_profile = ?
            ORDER BY last_seen_at DESC, id_achievement_identity DESC
            LIMIT 20
        })
    };
    unless ($sth_i && eval { $sth_i->execute($pid) }) {
        return {
            %$base,
            status  => 'query_error',
            profile => $profile,
        };
    }

    my @aliases;
    while (my $row = $sth_i->fetchrow_hashref) {
        push @aliases, {
            nick          => $row->{nick} // '',
            userhost      => $row->{userhost} // '',
            first_seen_at => $row->{first_seen_at},
            last_seen_at  => $row->{last_seen_at},
        };
    }
    $sth_i->finish;

    return {
        %$base,
        status             => 'ok',
        profile            => $profile,
        aliases            => \@aliases,
        aliases_shown      => scalar(@aliases),
        aliases_truncated  => ($profile->{alias_count} > scalar(@aliases)) ? 1 : 0,
        resolution_evidence => {
            nick_query_unique => 1,
            registered_user   => defined($profile->{id_user}) ? 1 : 0,
            durable_aliases   => scalar(@aliases),
        },
    };
}

sub storage_stats {
    my ($self) = @_;

    if (($self->{storage} // '') eq 'db') {
        my $profiles = scalar keys %{ $self->{_profiles} || {} };
        my $counters = 0;
        $counters += scalar keys %{ $self->{_progress_by_profile}{$_} || {} }
            for keys %{ $self->{_progress_by_profile} || {} };
        return {
            backend  => 'db',
            profiles => $profiles,
            counters => $counters,
            dirty    => 0,
        };
    }

    my $profiles = scalar keys %{ $self->{data} || {} };
    my $counters = 0;
    $counters += scalar keys %{ $self->{progress}{$_} || {} }
        for keys %{ $self->{progress} || {} };
    return {
        backend  => 'json',
        profiles => $profiles,
        counters => $counters,
        dirty    => $self->{dirty} ? 1 : 0,
    };
}

sub channel_unlock_count {
    my ($self, $channel) = @_;

    if (($self->{storage} // '') eq 'db') {
        my $cid = $self->_channel_id($channel);
        return 0 unless $cid;
        my $count = 0;
        for my $pid (keys %{ $self->{_profiles} || {} }) {
            next unless ($self->{_profiles}{$pid}{id_channel} // 0) == $cid;
            $count += scalar keys %{ $self->_db_get_unlocks($pid) };
        }
        return $count;
    }

    my $count = 0;
    for my $key (keys %{ $self->{data} || {} }) {
        my (undef, $ch) = split /\x00/, $key, 2;
        next unless defined($ch) && $ch eq lc($channel // '');
        $count += scalar keys %{ $self->{data}{$key} || {} };
    }
    return $count;
}

sub top_on_channel {
    my ($self, $channel, $limit) = @_;
    $limit = 3 unless defined($limit) && "$limit" =~ /\A\d+\z/ && $limit > 0;

    if (($self->{storage} // '') eq 'db') {
        my $cid = $self->_channel_id($channel);
        return [] unless $cid;

        my @rows;
        for my $pid (keys %{ $self->{_profiles} || {} }) {
            next unless ($self->{_profiles}{$pid}{id_channel} // 0) == $cid;
            my $count = scalar keys %{ $self->_db_get_unlocks($pid) };
            next unless $count > 0;
            push @rows, {
                nick  => $self->{_profiles}{$pid}{display_nick} // '',
                count => $count,
            };
        }
        @rows = sort {
            $b->{count} <=> $a->{count}
                || lc($a->{nick}) cmp lc($b->{nick})
        } @rows;
        splice(@rows, $limit) if @rows > $limit;
        return \@rows;
    }

    my %counts;
    for my $key (keys %{ $self->{data} || {} }) {
        my ($nick, $ch) = split /\x00/, $key, 2;
        next unless defined($ch) && $ch eq lc($channel // '');
        $counts{$nick} = scalar keys %{ $self->{data}{$key} || {} };
    }
    my @nicks = sort { $counts{$b} <=> $counts{$a} || $a cmp $b } keys %counts;
    splice(@nicks, $limit) if @nicks > $limit;
    return [ map { { nick => $_, count => $counts{$_} } } @nicks ];
}

# -- Déblocage d'un achievement (avec notification IRC) -------------------------
# Retourne 1 si nouvellement débloqué, 0 si déjà obtenu.
sub unlock {
    my ($self, $nick, $channel, $id) = @_;
    return 0 unless defined $nick && defined $id;
    return 0 unless exists $ACH{$id};

    if (($self->{storage} // '') eq 'db') {
        my $pid = $self->_profile_id_for($nick, $channel, create => 1);
        return 0 unless $pid;
        return 0 if exists $self->{_unlocks_by_profile}{$pid}{$id};

        my $dbh = $self->{bot}{dbh};
        my $sth = $dbh->prepare(q{
            INSERT IGNORE INTO ACHIEVEMENT_UNLOCK
                (id_achievement_profile, achievement_id, unlocked_at)
            VALUES (?, ?, NOW())
        });
        return 0 unless $sth && $sth->execute($pid, $id);
        return 0 unless $sth->rows > 0;

        $self->{_unlocks_by_profile}{$pid}{$id} = time();
    }
    else {
        my $key = lc($nick) . "\x00" . (defined $channel ? lc($channel) : "");  # mb430-B1: canal en lc (IRC insensible a la casse)
        return 0 if exists $self->{data}{$key}{$id};

        $self->{data}{$key}{$id} = time();
        $self->{dirty} = 1;
        # mb118: unlocks are rare enough to persist immediately; do not risk
        # losing a freshly unlocked achievement during the debounce window.
        $self->save(1);
    }

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

    my $profile_id;
    if (($self->{storage} // '') eq 'db') {
        # observe_identity() normally pinned the live alias before queue_check().
        # Carry that durable profile into the fork so historical CHANNEL_LOG
        # scans can include every known alias of the same IRC identity.
        $profile_id = $self->_profile_id_for($nick, $channel);
    }

    $self->{_pending_checks}{$key} = {
        nick       => $nick,
        channel    => $channel,
        profile_id => $profile_id,
        attempts   => 0,
        retry_at   => 0,
        queued_at  => Time::HiRes::time(),
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
        key        => $key,
        nick       => $entry->{nick},
        channel    => $entry->{channel},
        profile_id => $entry->{profile_id},
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

        # mb613-B1: check_msg normally runs in the forked SQL worker.
        # set_progress() there only changes child memory, so explicitly import
        # the two DB-derived state counters into the parent after validating
        # their bounded result shape.
        if (ref($result->{progress}) eq 'HASH') {
            for my $kind (qw(msg_count channels_active night_messages morning_messages)) {
                next unless exists $result->{progress}{$kind};
                my $value = $result->{progress}{$kind};
                next unless defined($value) && !ref($value)
                    && "$value" =~ /\A\d+\z/;
                $self->set_progress($kind, $entry->{nick}, $entry->{channel}, $value);
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
                # mb613-B1: the SQL worker runs with a deliberately reduced
                # bot object. Snapshot the EFFECTIVE thresholds first so
                # [achievements] overrides are honoured in the child too.
                my %worker_thresholds = map {
                    $_ => $self->threshold($_)
                } keys %ACH;

                my %worker = %$self;
                $worker{bot} = { dbh => $dbh };
                $worker{logger} = undef;
                $worker{_worker_unlocks} = [];
                $worker{_worker_checks} = {};
                $worker{_worker_timings} = {};
                $worker{_worker_progress} = {};
                $worker{_worker_thresholds} = \%worker_thresholds;
                $worker{_worker_profile_id} = $job->{profile_id};
                my $child = bless \%worker, 'Mediabot::Achievements::Worker';

                my $run_ok = eval {
                    $child->check_msg($job->{nick}, $job->{channel});
                    1;
                };
                if ($run_ok) {
                    $result = {
                        ok       => 1,
                        unlocks  => $child->{_worker_unlocks},
                        checks   => [ sort keys %{ $child->{_worker_checks} || {} } ],
                        timings  => $child->{_worker_timings},
                        # mb613-B1: state values calculated in the fork must
                        # return to the parent; child memory is copy-on-write.
                        progress => $child->{_worker_progress},
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

# mb646: build a bounded SQL predicate for every IRC alias attached to the
# durable achievement profile.  This lets message-derived merit follow a nick
# change or a small user@host variation instead of waiting for the new nick to
# rebuild its counters from zero.
sub _worker_identity_aliases {
    my ($self, $nick) = @_;

    my @aliases = ({ nick => $nick, userhost => undef });
    my $pid = $self->{_worker_profile_id};
    my $dbh = eval { $self->{bot}{dbh} };
    return \@aliases unless ($self->{storage} // '') eq 'db'
        && $pid && $dbh && eval { $dbh->can('prepare') };

    my $sth = eval {
        $dbh->prepare(q{
            SELECT nick, userhost
            FROM ACHIEVEMENT_IDENTITY
            WHERE id_achievement_profile = ?
            ORDER BY last_seen_at DESC, id_achievement_identity DESC
            LIMIT 32
        })
    };
    return \@aliases unless $sth && eval { $sth->execute($pid) };

    my (%seen, @db_aliases);
    while (my $r = $sth->fetchrow_hashref) {
        next unless defined($r->{nick}) && length($r->{nick});
        my $uh = defined($r->{userhost}) ? $r->{userhost} : '';
        my $key = _norm_nick($r->{nick}) . "\x00" . _norm_userhost($uh);
        next if $seen{$key}++;
        push @db_aliases, { nick => $r->{nick}, userhost => $uh };
    }
    $sth->finish;

    return @db_aliases ? \@db_aliases : \@aliases;
}

sub _worker_identity_sql {
    my ($self, $column_prefix, $nick) = @_;
    $column_prefix = 'cl' unless defined($column_prefix)
        && $column_prefix =~ /\A[A-Za-z_][A-Za-z0-9_]*\z/;

    my $aliases = $self->_worker_identity_aliases($nick);
    my (@where, @bind);
    for my $a (@$aliases) {
        next unless ref($a) eq 'HASH' && defined($a->{nick}) && length($a->{nick});
        my $uh = defined($a->{userhost}) ? $a->{userhost} : '';

        # Empty userhost is the legacy JSON identity.  It deliberately falls
        # back to nick-only matching for historical rows that predate mb646.
        if ($uh eq '') {
            push @where, "$column_prefix.nick = ?";
            push @bind, $a->{nick};
        }
        else {
            push @where, "($column_prefix.nick = ? AND $column_prefix.userhost = ?)";
            push @bind, $a->{nick}, $uh;
        }
    }

    if (!@where) {
        push @where, "$column_prefix.nick = ?";
        push @bind, $nick;
    }
    return ('(' . join(' OR ', @where) . ')', @bind);
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
    my ($identity_sql, @identity_bind) =
        $self->_worker_identity_sql('cl', $nick);

    my ($n) = $self->_timed_check('msg_count', $nick, $channel, sub {
        my $sql = qq{
            SELECT COUNT(*) AS c
            FROM CHANNEL_LOG cl
            JOIN CHANNEL    c  ON c.id_channel = cl.id_channel
            WHERE c.name = ?
              AND $identity_sql
              AND cl.event_type IN ('public','action')
        };
        my $sth = eval { $dbh->prepare($sql) };
        return (undef) unless $sth
            && $sth->execute($channel, @identity_bind);
        my $row = $sth->fetchrow_hashref; $sth->finish;
        return ($row ? ($row->{c} // 0) : 0);
    });
    return unless defined $n;

    # First message — déclenché systématiquement pour tout nouveau nick avec ≥1 msg
    # mb611-B1: les seuils viennent du catalogue (et de la conf).
    # mb612-B1: le compte est deja calcule ici — on l'enregistre pour
    # l'affichage de progression, sans requete supplementaire.
    $self->set_progress('msg_count', $nick, $channel, $n);
    $self->unlock($nick, $channel, $_)
        for grep { $n >= $self->threshold($_) }
            qw(first_msg chatterbox megaphone icon legend);

    # Night Owl / Early Bird : compte par tranche horaire.
    #
    # mb657: the same historical scan now feeds measurable progress plus two
    # extra Night Owl milestones.  Do NOT add a second query: one conditional
    # aggregate returns both bands.  This also removes the old GROUP BY HOUR()
    # temporary/filesort path.
    #
    # mb450-B1 remains the governing performance contract.
    # The mathematical short-circuit now follows the lowest still-locked
    # configurable threshold.  This preserves mb450's "do not scan when an
    # unlock is impossible" rule while finally honouring [achievements]
    # overrides below the old hard-coded value of 50.
    my $hour_unlocked = $self->get_for_nick($nick, $channel);
    my @hour_pending = grep { !exists $hour_unlocked->{$_} }
        qw(night_owl midnight_regular creature_night early_bird);
    if (@hour_pending) {
        my $hour_floor;
        for my $id (@hour_pending) {
            my $threshold = $self->threshold($id);
            next unless defined($threshold) && $threshold > 0;
            $hour_floor = $threshold
                if !defined($hour_floor) || $threshold < $hour_floor;
        }

        if (defined($hour_floor) && $n >= $hour_floor) {
            my $hb_key  = lc($nick) . "\x00" . lc($channel // "");
            my $hb_last = $self->{_hourband_check_ts}{$hb_key} // 0;
            if ((time() - $hb_last) >= 3600) {
                $self->{_hourband_check_ts}{$hb_key} = time();
                my ($night, $morn) = $self->_timed_check('hour_band', $nick, $channel, sub {
                    my $sql_h = qq{
                        SELECT
                            COALESCE(SUM(CASE
                                WHEN HOUR(cl.ts) BETWEEN 0 AND 5 THEN 1 ELSE 0
                            END), 0) AS night_count,
                            COALESCE(SUM(CASE
                                WHEN HOUR(cl.ts) BETWEEN 6 AND 8 THEN 1 ELSE 0
                            END), 0) AS morning_count
                        FROM CHANNEL_LOG cl
                        JOIN CHANNEL c ON c.id_channel = cl.id_channel
                        WHERE c.name = ?
                          AND $identity_sql
                          AND cl.event_type IN ('public','action')   -- mb347-B1
                    };
                    my $sth_h = eval { $dbh->prepare($sql_h) };
                    return (undef, undef) unless $sth_h
                        && $sth_h->execute($channel, @identity_bind);
                    my $row_h = $sth_h->fetchrow_hashref;
                    $sth_h->finish;
                    return (undef, undef) unless $row_h;
                    return (
                        0 + ($row_h->{night_count} // 0),
                        0 + ($row_h->{morning_count} // 0),
                    );
                });
                if (defined $night) {
                    # mb657: the worker already paid for these exact values.
                    # Persist them through the generic monotonic progress path;
                    # the async parent imports both kinds from the child result.
                    $self->set_progress('night_messages', $nick, $channel, $night);
                    $self->set_progress('morning_messages', $nick, $channel, $morn);

                    for my $id (qw(night_owl midnight_regular creature_night)) {
                        $self->unlock($nick, $channel, $id)
                            if $night >= $self->threshold($id);
                    }
                    $self->unlock($nick, $channel, 'early_bird')
                        if $morn >= $self->threshold('early_bird');
                }
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
                my $sql_p = qq{
                    SELECT COUNT(DISTINCT c.name) AS n
                    FROM CHANNEL_LOG cl
                    JOIN CHANNEL c ON c.id_channel = cl.id_channel
                    WHERE $identity_sql
                      AND cl.event_type IN ('public','action')   -- mb347-B1
                      AND c.name LIKE '#%'
                };
                my $sth_p = eval { $dbh->prepare($sql_p) };
                return (undef) unless $sth_p && $sth_p->execute(@identity_bind);
                my $r = $sth_p->fetchrow_hashref; $sth_p->finish;
                return ($r ? ($r->{n} // 0) : 0);
            });
            # mb613-B1: the value is already known; return/persist it just
            # like msg_count instead of throwing it away after the unlock check.
            $self->set_progress('channels_active', $nick, $channel, $nchan)
                if defined $nchan && $nchan =~ /\A\d+\z/;
            $self->unlock($nick, $channel, 'polyphony')
                if defined $nchan && $nchan >= $self->threshold('polyphony');
        }
    }
}

# -- Hook : vérifie les achievements 'karma' après un vote ---------------------
sub check_karma {
    my ($self, $nick, $channel, $score, $giver, $given_total) = @_;
    return unless defined $nick && defined $channel && $channel =~ /^#/;
    $self->set_progress('karma_score', $nick, $channel, $score)
        if defined $score && $score =~ /\A\d+\z/;
    $self->unlock($nick, $channel, 'karma_star')
        if defined $score && $score >= $self->threshold('karma_star');
    $self->unlock($nick, $channel, 'karma_legend')
        if defined $score && $score >= $self->threshold('karma_legend');
    # Gift giver : karma positifs donnés (cross-canal somme)
    $self->set_progress('karma_given', $giver, $channel, $given_total)
        if defined $giver && defined $given_total && $given_total =~ /\A\d+\z/;
    if (defined $giver && defined $given_total
        && $given_total >= $self->threshold('gift_giver')) {
        $self->unlock($giver, $channel, 'gift_giver');
    }
}

# -- Hook : vérifie les achievements 'trivia' ----------------------------------
sub check_trivia {
    my ($self, $nick, $channel, $correct_count, $response_seconds) = @_;
    return unless defined $nick && defined $channel && $channel =~ /^#/;
    $self->unlock($nick, $channel, 'trivia_rookie')
        if defined $correct_count && $correct_count >= $self->threshold('trivia_rookie');
    $self->unlock($nick, $channel, 'trivia_champion')
        if defined $correct_count && $correct_count >= $self->threshold('trivia_champion');
    # Seuil INVERSE : le sniper doit repondre en MOINS de N secondes.
    $self->unlock($nick, $channel, 'trivia_sniper')
        if defined $response_seconds && $response_seconds <= $self->threshold('trivia_sniper');
}

# -- mb655: activity streak achievements --------------------------------------
# The caller already paid for the !streak history scan.  Persist only the best
# run ever observed; set_progress() is monotonic, so a broken current streak does
# not erase previously earned merit.
sub check_streak {
    my ($self, $nick, $channel, $current, $best) = @_;
    return 0 unless defined($nick) && length($nick)
                 && defined($channel) && $channel =~ /^#/;

    $best = $current unless defined $best;
    return 0 unless defined($best) && !ref($best) && "$best" =~ /\A\d+\z/;
    $best = int($best);
    return 0 if $best < 1;

    my $saved = $self->set_progress('activity_streak_days', $nick, $channel, $best);
    for my $id (qw(streak_week streak_month streak_master)) {
        $self->unlock($nick, $channel, $id)
            if $best >= $self->threshold($id);
    }
    return $saved;
}

# -- Hook : mb656 comeback achievements ---------------------------------------
# USER_SEEN is one row per nick and is updated on JOIN before the user can speak.
# Capture its PRE-JOIN age in memory, then consume it on the first public message
# only after observe_identity() has pinned the live nick/user@host/channel tuple.
#
# This deliberately does not unlock on JOIN: merely entering a channel must not
# create an Achievement profile for a nick that never interacts with Mediabot.
my $COMEBACK_PENDING_TTL = 24 * 60 * 60;
my $COMEBACK_PENDING_MAX = 200;

sub note_comeback_candidate {
    my ($self, $nick, $current_userhost) = @_;
    return 0 unless defined($nick) && length($nick);
    return 0 unless $self->{bot} && $self->{bot}{dbh};

    my $key = lc($nick);
    $self->{_comeback_pending} ||= {};

    # Keep a still-valid earlier candidate. This matters when one IRC identity
    # joins several shared channels: the first JOIN sees the real long absence;
    # later JOINs see USER_SEEN already refreshed by the first one.
    if (my $pending = $self->{_comeback_pending}{$key}) {
        if (time() - ($pending->{captured_at} // 0) <= $COMEBACK_PENDING_TTL) {
            return 1;
        }
        delete $self->{_comeback_pending}{$key};
    }

    my $dbh = $self->{bot}{dbh};
    my $sth = $dbh->prepare(q{
        SELECT userhost, event_type, seen_at,
               TIMESTAMPDIFF(SECOND, seen_at, NOW()) AS away_seconds
        FROM USER_SEEN
        WHERE nick = ?
        LIMIT 1
    });
    return 0 unless $sth && $sth->execute(lc($nick));

    my $row = $sth->fetchrow_hashref;
    $sth->finish;
    return 0 unless $row && defined($row->{away_seconds})
        && !ref($row->{away_seconds})
        && "$row->{away_seconds}" =~ /\A\d+\z/;

    my $away_seconds = int($row->{away_seconds});
    my $minimum_days = $self->threshold('comeback_week') // 7;
    return 0 if $away_seconds < int($minimum_days) * 86400;

    # USER_SEEN is nick-based. Refuse to transfer an old nick's absence to a
    # clearly different current hostmask. The normal mb646 identity resolver
    # may still follow legitimate ident/host changes when one side matches.
    my $previous_userhost = $row->{userhost} // '';
    $current_userhost = '' unless defined $current_userhost;
    return 0 unless _userhost_compatible($previous_userhost, $current_userhost);

    # Bound the transient map. Drop the oldest captured candidate if needed.
    if (scalar(keys %{ $self->{_comeback_pending} }) >= $COMEBACK_PENDING_MAX) {
        my ($oldest) = sort {
            ($self->{_comeback_pending}{$a}{captured_at} // 0)
                <=>
            ($self->{_comeback_pending}{$b}{captured_at} // 0)
        } keys %{ $self->{_comeback_pending} };
        delete $self->{_comeback_pending}{$oldest} if defined $oldest;
    }

    $self->{_comeback_pending}{$key} = {
        away_seconds => $away_seconds,
        seen_at      => $row->{seen_at},
        event_type   => $row->{event_type},
        userhost     => $previous_userhost,
        captured_at  => time(),
    };
    return 1;
}

sub consume_comeback_candidate {
    my ($self, $nick, $channel) = @_;
    return 0 unless defined($nick) && length($nick)
                 && defined($channel) && $channel =~ /^#/;

    my $key = lc($nick);
    my $pending = delete(($self->{_comeback_pending} ||= {})->{$key});
    return 0 unless $pending;

    return 0 if time() - ($pending->{captured_at} // 0) > $COMEBACK_PENDING_TTL;
    return $self->check_comeback(
        $nick, $channel, $pending->{away_seconds}
    );
}

sub check_comeback {
    my ($self, $nick, $channel, $away_seconds) = @_;
    return 0 unless defined($nick) && length($nick)
                 && defined($channel) && $channel =~ /^#/;
    return 0 unless defined($away_seconds) && !ref($away_seconds)
                 && "$away_seconds" =~ /\A\d+\z/;

    my $days = int($away_seconds / 86400);
    return 0 if $days < 1;

    my $saved = $self->set_progress('comeback_days', $nick, $channel, $days);
    for my $id (qw(comeback_week comeback_month comeback_legend)) {
        $self->unlock($nick, $channel, $id)
            if $days >= $self->threshold($id);
    }
    return $saved;
}

# -- Hook : vérifie les achievements 'wordcount' -------------------------------
sub check_wordcount {
    my ($self, $nick, $channel, $distinct) = @_;
    return unless defined $nick && defined $channel && $channel =~ /^#/;
    $self->set_progress('distinct_words', $nick, $channel, $distinct)
        if defined $distinct && $distinct =~ /\A\d+\z/;
    $self->unlock($nick, $channel, 'wordsmith')
        if defined $distinct && $distinct >= $self->threshold('wordsmith');
    $self->unlock($nick, $channel, 'polyglot')
        if defined $distinct && $distinct >= $self->threshold('polyglot');
}

# -- Hook : vérifie les achievements 'duel' (mb116) ---------------------------
# $wins = nombre total de duels gagnés sur le canal
# $streak_loss = streak de pertes consécutives avant la victoire (pour underdog)
sub check_duel {
    my ($self, $nick, $channel, $wins, $streak_loss) = @_;
    return unless defined $nick && defined $channel && $channel =~ /^#/;
    $self->unlock($nick, $channel, 'duel_warrior')
        if defined $wins && $wins >= $self->threshold('duel_warrior');
    $self->unlock($nick, $channel, 'duel_master')
        if defined $wins && $wins >= $self->threshold('duel_master');
    $self->unlock($nick, $channel, 'underdog')
        if defined $streak_loss && $streak_loss >= $self->threshold('underdog');
}

# -- Hook : vérifie les achievements 'horoscope' (mb116) -----------------------
sub check_horoscope {
    my ($self, $nick, $channel, $consultations) = @_;
    return unless defined $nick && defined $channel && $channel =~ /^#/;
    $self->unlock($nick, $channel, 'star_gazer')
        if defined $consultations && $consultations >= $self->threshold('star_gazer');
}

# -- Hook : vérifie les achievements 'compat' (mb117) --------------------------
sub check_compat {
    my ($self, $nick, $channel, $count) = @_;
    return unless defined $nick && defined $channel && $channel =~ /^#/;
    $self->unlock($nick, $channel, 'matchmaker')
        if defined $count && $count >= $self->threshold('matchmaker');
}

# -- Hook : vérifie les achievements 'quotegame' (mb117) -----------------------
sub check_quotegame {
    my ($self, $nick, $channel, $solved) = @_;
    return unless defined $nick && defined $channel && $channel =~ /^#/;
    $self->unlock($nick, $channel, 'quote_detective')
        if defined $solved && $solved >= $self->threshold('quote_detective');
    $self->unlock($nick, $channel, 'quote_master')
        if defined $solved && $solved >= $self->threshold('quote_master');
}

# -- Hook : vérifie les achievements 'mood' (mb117) ----------------------------
sub check_mood {
    my ($self, $nick, $channel, $reads) = @_;
    return unless defined $nick && defined $channel && $channel =~ /^#/;
    $self->unlock($nick, $channel, 'mood_reader')
        if defined $reads && $reads >= $self->threshold('mood_reader');
}

# -- Hook : vérifie l'achievement 'polyphony' (mb117) --------------------------
# Appelé après un check sur le nombre de canaux où le nick a posté.
sub check_polyphony {
    my ($self, $nick, $current_channel, $n_channels) = @_;
    return unless defined $nick && defined $current_channel && $current_channel =~ /^#/;
    $self->set_progress('channels_active', $nick, $current_channel, $n_channels)
        if defined $n_channels && $n_channels =~ /\A\d+\z/;
    $self->unlock($nick, $current_channel, 'polyphony')
        if defined $n_channels && $n_channels >= $self->threshold('polyphony');
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

# mb613-B1: the worker's bot object intentionally contains only its isolated
# DB handle. Effective thresholds are snapshotted by the parent before fork.
sub threshold {
    my ($self, $id) = @_;
    if (ref($self->{_worker_thresholds}) eq 'HASH'
        && exists $self->{_worker_thresholds}{$id}) {
        return $self->{_worker_thresholds}{$id};
    }
    return $self->SUPER::threshold($id);
}

# State progress must cross the process boundary just like unlock intents.
# Keep only the highest value observed for each kind in this one job.
sub set_progress {
    my ($self, $kind, $nick, $channel, $value) = @_;
    return 0 unless defined($kind) && length($kind)
        && defined($value) && !ref($value) && "$value" =~ /\A\d+\z/;
    $self->{_worker_progress} ||= {};
    my $current = $self->{_worker_progress}{$kind} // 0;
    $self->{_worker_progress}{$kind} = int($value)
        if $value > $current;
    return $self->{_worker_progress}{$kind} // $current;
}

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
