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
use Hailo;

our @EXPORT = qw(
    init_hailo
    get_hailo
    get_hailo_runtime
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
	$self->{logger}->log(1, "Initialize Hailo");
	my $hailo = eval {
		Hailo->new(
			brain        => 'mediabot_v3.brn',
			save_on_exit => 1,
		);
	};
	if ($@) {
		$self->{logger}->log(0, " Hailo init failed: $@");
		$self->{hailo} = undef;
		return;
	}
	$self->{hailo} = $hailo;
	delete $self->{_hailo_runtime_unavailable_logged};
}

# Get the Hailo object
sub get_hailo {
	my ($self) = shift;
	return $self->{hailo};
}

# mb361-B1: runtime paths must tolerate an unavailable Hailo brain. init_hailo()
# already logs the initialization failure; this helper adds at most one concise
# runtime diagnostic and lets message handling continue without dereferencing
# undef or misclassifying the failure as a timeout.
sub get_hailo_runtime {
    my ($self) = @_;

    my $hailo = get_hailo($self);
    return $hailo if $hailo;

    unless ($self->{_hailo_runtime_unavailable_logged}) {
        $self->{_hailo_runtime_unavailable_logged} = 1;
        $self->{logger}->log(2,
            "Hailo runtime unavailable; skipping reply and learning paths")
            if $self->{logger};
    }

    return undef;
}

# Clean up and exit the program (with proper Net::Async::IRC QUIT)
# Check whether Hailo should ignore a nick
sub is_hailo_excluded_nick {
    my ($self, $nick) = @_;

    return 0 unless defined($nick) && $nick ne '';
    return 0 unless $self->{dbh};

    # mb122-B1: cache TTL 30s. La table HAILO_EXCLUSION_NICK utilise
    # utf8mb4_unicode_ci (case-insensitive cote DB), donc on peut cacher
    # par lc($nick) sans craindre les ratages de casse.
    my $cache_key = lc($nick);
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
    delete $self->{_hailo_excl_cache}{ lc($target_nick) };

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
    delete $self->{_hailo_excl_cache}{ lc($target_nick) };

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
    my $hailo = eval { get_hailo($self) };
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
