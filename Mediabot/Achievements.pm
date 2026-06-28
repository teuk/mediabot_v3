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
    }, $class;
    $self->_load;
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
        return;
    }
    $self->{data} = $data if ref $data eq 'HASH';
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
        print $fh $json;
        close $fh;
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
    my $key = lc($nick) . "\x00" . (defined $channel ? $channel : '');
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

    my $key = lc($nick) . "\x00" . (defined $channel ? $channel : '');
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
# Cette méthode est appelée depuis on_message_PRIVMSG. Elle limite ses
# requêtes SQL via un cache mémoire pour ne pas exploser la charge.
sub check_msg {
    my ($self, $nick, $channel) = @_;
    return unless defined $nick && defined $channel && $channel =~ /^#/;
    my $bot = $self->{bot} or return;

    # Cache : on ne refait le check msg que toutes les 5 minutes par (nick, chan)
    my $cache_key = lc($nick) . "\x00" . $channel;
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
    my $sth = eval {
        $dbh->prepare(q{
            SELECT COUNT(*) AS c
            FROM CHANNEL_LOG cl
            JOIN CHANNEL    c  ON c.id_channel = cl.id_channel
            WHERE c.name = ? AND cl.nick = ?
              AND cl.event_type IN ('public','action')
        })
    };
    return unless $sth && $sth->execute($channel, $nick);
    my $row = $sth->fetchrow_hashref; $sth->finish;
    my $n   = $row ? ($row->{c} // 0) : 0;

    # First message — déclenché systématiquement pour tout nouveau nick avec ≥1 msg
    $self->unlock($nick, $channel, 'first_msg')         if $n >= 1;
    $self->unlock($nick, $channel, 'chatterbox')        if $n >= 1_000;
    $self->unlock($nick, $channel, 'megaphone')         if $n >= 10_000;
    $self->unlock($nick, $channel, 'icon')              if $n >= 50_000;
    $self->unlock($nick, $channel, 'legend')            if $n >= 100_000;

    # Night Owl / Early Bird : compte par tranche horaire
    if (!exists $self->get_for_nick($nick, $channel)->{night_owl} ||
        !exists $self->get_for_nick($nick, $channel)->{early_bird}) {
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
        if ($sth_h && $sth_h->execute($channel, $nick)) {
            my (%by_h);
            while (my $r = $sth_h->fetchrow_hashref) { $by_h{$r->{h}} = $r->{c}; }
            $sth_h->finish;
            my $night = 0; $night += ($by_h{$_} // 0) for (0..5);
            my $morn  = 0; $morn  += ($by_h{$_} // 0) for (6..8);
            $self->unlock($nick, $channel, 'night_owl')  if $night >= 50;
            $self->unlock($nick, $channel, 'early_bird') if $morn  >= 50;
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
            if ($sth_p && $sth_p->execute($nick)) {
                my $r = $sth_p->fetchrow_hashref; $sth_p->finish;
                $self->unlock($nick, $channel, 'polyphony')
                    if $r && ($r->{n} // 0) >= 5;
            }
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

1;
