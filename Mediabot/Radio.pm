package Mediabot::Radio;

# =============================================================================
# Mediabot::Radio
# =============================================================================

use strict;
use warnings;
use POSIX qw(strftime);
use List::Util qw(min);
use Exporter 'import';
use HTML::Entities qw(decode_entities);
use Encode qw(encode);
use Mediabot::Helpers;
use JSON::MaybeXS;
use File::Basename;

our @EXPORT = qw(
    _radio_listeners_format
    _radio_next_format
    _radio_song_format
    displayRadioCurrentSong_ctx
    displayRadioListeners_ctx
    getHarBorId
    getLastRadioPub
    getRadioCurrentListeners
    getRadioCurrentSong
    getRadioHarbor
    getRadioRemainingTime
    isInQueueRadio
    isRadioLive
    nextRadio
    nextRadio_ctx
    playRadio
    playRadio_ctx
    queueCount
    queuePushRadio
    queueRadio
    queueRadio_ctx
    radioMsg
    radioNext_ctx
    radioPub
    radioPub_ctx
    rplayRadio
    rplayRadio_ctx
    setLastRadioPub
    setRadioMetadata
    setRadioMetadata_ctx
);

sub setLastRadioPub(@) {
	my ($self,$iLastRadioPub) = @_;
	$self->{iLastRadioPub} = $iLastRadioPub;
}

sub getLastRadioPub(@) {
	my $self = shift;
	return $self->{iLastRadioPub};
}

sub getRadioCurrentSong(@) {
	my ($self) = @_;
	my $conf = $self->{conf};

	my $RADIO_HOSTNAME = $conf->get('radio.RADIO_HOSTNAME');
	my $RADIO_PORT     = $conf->get('radio.RADIO_PORT');
	my $RADIO_JSON     = $conf->get('radio.RADIO_JSON');
	my $RADIO_SOURCE   = $conf->get('radio.RADIO_SOURCE');

	unless (defined($RADIO_HOSTNAME) && ($RADIO_HOSTNAME ne "")) {
		$self->{logger}->log(0,"getRadioCurrentSong() radio.RADIO_HOSTNAME not set in " . $self->{config_file});
		return undef;
	}
	
	my $JSON_STATUS_URL = "http://$RADIO_HOSTNAME:$RADIO_PORT/$RADIO_JSON";
	if ($RADIO_PORT == 443) {
		$JSON_STATUS_URL = "https://$RADIO_HOSTNAME/$RADIO_JSON";
	}
	
	my $fh_icecast;
	unless (open $fh_icecast, "-|", "curl", "--connect-timeout", "3", "-f", "-s", $JSON_STATUS_URL) {
		return "N/A";
	}
	
	my $line;
	if (defined($line = <$fh_icecast>)) {
		close $fh_icecast;
		chomp($line);
		my $json = eval { decode_json $line };
		return "N/A" unless defined $json;
		my $source_data = $json->{'icestats'}{'source'};
        my @sources = ref($source_data) eq 'ARRAY' ? @$source_data : ($source_data);

		if (defined($sources[0])) {
			my %source = %{$sources[0]};
			if (defined($source{'title'})) {
				my $title = $source{'title'};
				if ($title =~ /&#.*;/) {
					return decode_entities($title);
				} else {
					return $title;
				}
			}
			elsif (defined($source{'server_description'})) {
				return $source{'server_description'};
			}
			elsif (defined($source{'server_name'})) {
				return $source{'server_name'};
			}
			else {
				return "N/A";
			}
		}
		else {
			return undef;
		}
	}
	else {
		return "N/A";
	}
}

sub getRadioCurrentListeners(@) {
	my ($self) = @_;
	my $conf = $self->{conf};

	my $RADIO_HOSTNAME = $conf->get('radio.RADIO_HOSTNAME');
	my $RADIO_PORT     = $conf->get('radio.RADIO_PORT');
	my $RADIO_JSON     = $conf->get('radio.RADIO_JSON');
	my $RADIO_SOURCE   = $conf->get('radio.RADIO_SOURCE');  # optionnel

	unless (defined($RADIO_HOSTNAME) && $RADIO_HOSTNAME ne "") {
		$self->{logger}->log(0, "getRadioCurrentListeners() radio.RADIO_HOSTNAME not set in " . $self->{config_file});
		return undef;
	}

	my $JSON_STATUS_URL = "http://$RADIO_HOSTNAME:$RADIO_PORT/$RADIO_JSON";
	$JSON_STATUS_URL = "https://$RADIO_HOSTNAME/$RADIO_JSON" if $RADIO_PORT == 443;

	my $fh;
	unless (open($fh, "-|", "curl", "--connect-timeout", "3", "-f", "-s", $JSON_STATUS_URL)) {
		return undef;
	}

	my $line = <$fh>;
	close $fh;

	return undef unless defined $line;
	chomp($line);

	my $json;
	eval { $json = decode_json($line); };
	if ($@ or not defined $json->{'icestats'}{'source'}) {
		return undef;
	}

	my $source_data = $json->{'icestats'}{'source'};
	my @sources = ref($source_data) eq 'ARRAY' ? @$source_data : ($source_data);

	if (defined $RADIO_SOURCE && $RADIO_SOURCE ne '') {
		foreach my $s (@sources) {
			if (defined($s->{'mount'}) && $s->{'mount'} eq $RADIO_SOURCE) {
				return int($s->{'listeners'} || 0);
			}
		}
	} else {
		my $s = $sources[0];
		return int($s->{'listeners'} || 0) if defined $s;
	}

	return undef;
}




# Get the harbor name from the LIQUIDSOAP telnet port
sub getRadioHarbor(@) {
	my ($self) = @_;
	my $conf = $self->{conf};

	my $LIQUIDSOAP_TELNET_HOST = $conf->get('radio.LIQUIDSOAP_TELNET_HOST');
	my $LIQUIDSOAP_TELNET_PORT = $conf->get('radio.LIQUIDSOAP_TELNET_PORT');

	if (defined($LIQUIDSOAP_TELNET_HOST) && ($LIQUIDSOAP_TELNET_HOST ne "")) {
		my $fh_lsharbor;
		unless (open $fh_lsharbor, "echo -ne \"help\nquit\n\" | nc $LIQUIDSOAP_TELNET_HOST $LIQUIDSOAP_TELNET_PORT |") {
			$self->{logger}->log( 3, "Unable to connect to LIQUIDSOAP telnet port");
		}

		my $line;
		while (defined($line = <$fh_lsharbor>)) {
			chomp($line);
			if ($line =~ /harbor/) {
				my $sHarbor = $line;
				$sHarbor =~ s/^.*harbor/harbor/;
				$sHarbor =~ s/\..*$//;
				close $fh_lsharbor;
				return $sHarbor;
			}
		}

		close $fh_lsharbor;
		return undef;
	} else {
		return undef;
	}
}

# Check if the radio is live by checking the LIQUIDSOAP harbor status
sub isRadioLive(@) {
	my ($self, $sHarbor) = @_;
	my $conf = $self->{conf};

	my $LIQUIDSOAP_TELNET_HOST = $conf->get('radio.LIQUIDSOAP_TELNET_HOST');
	my $LIQUIDSOAP_TELNET_PORT = $conf->get('radio.LIQUIDSOAP_TELNET_PORT');

	if (defined($LIQUIDSOAP_TELNET_HOST) && ($LIQUIDSOAP_TELNET_HOST ne "")) {
		my $fh_lsharbor;
		unless (open $fh_lsharbor, "echo -ne \"$sHarbor.status\nquit\n\" | nc $LIQUIDSOAP_TELNET_HOST $LIQUIDSOAP_TELNET_PORT |") {
			$self->{logger}->log( 3, "Unable to connect to LIQUIDSOAP telnet port");
		}

		my $line;
		while (defined($line = <$fh_lsharbor>)) {
			chomp($line);
			if ($line =~ /source/) {
				$self->{logger}->log( 3, $line);
				if ($line =~ /no source client connected/) {
					return 0;
				} else {
					return 1;
				}
			}
		}
		close $fh_lsharbor;
		return 0;
	} else {
		return 0;
	}
}

# Get the remaining time of the current song from the LIQUIDSOAP telnet port
sub getRadioRemainingTime(@) {
	my ($self) = @_;
	my $conf = $self->{conf};

	my $LIQUIDSOAP_TELNET_HOST = $conf->get('radio.LIQUIDSOAP_TELNET_HOST');
	my $LIQUIDSOAP_TELNET_PORT = $conf->get('radio.LIQUIDSOAP_TELNET_PORT');
	my $RADIO_URL = $conf->get('radio.RADIO_URL');

	my $LIQUIDSOAP_MOUNPOINT = $RADIO_URL;
	$LIQUIDSOAP_MOUNPOINT =~ s/\./(dot)/;

	if (defined($LIQUIDSOAP_TELNET_HOST) && ($LIQUIDSOAP_TELNET_HOST ne "")) {
		my $fh_ls;
		unless (open $fh_ls, "echo -ne \"help\nquit\n\" | nc $LIQUIDSOAP_TELNET_HOST $LIQUIDSOAP_TELNET_PORT | grep remaining | tr -s \" \" | cut -f2 -d\" \" | tail -n 1 |") {
			$self->{logger}->log( 0, "getRadioRemainingTime() Unable to connect to LIQUIDSOAP telnet port");
		}
		my $line;
		if (defined($line = <$fh_ls>)) {
			chomp($line);
			$self->{logger}->log( 3, $line);
			my $fh_ls2;
			unless (open $fh_ls2, "echo -ne \"$line\nquit\n\" | nc $LIQUIDSOAP_TELNET_HOST $LIQUIDSOAP_TELNET_PORT | head -1 |") {
				$self->{logger}->log( 0, "getRadioRemainingTime() Unable to connect to LIQUIDSOAP telnet port");
			}
			my $line2;
			if (defined($line2 = <$fh_ls2>)) {
				chomp($line2);
				$self->{logger}->log( 3, $line2);
				return $line2;
			}
		}
		return 0;
	} else {
		$self->{logger}->log( 0, "getRadioRemainingTime() radio.LIQUIDSOAP_TELNET_HOST not set in " . $self->{config_file});
	}
}

# Display the current song on the radio
sub displayRadioCurrentSong_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $message = $ctx->message;
    my $nick    = $ctx->nick;
    my $chan    = $ctx->channel; # undef en privé
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    my $conf = $self->{conf};
    my $RADIO_HOSTNAME          = $conf->get('radio.RADIO_HOSTNAME');
    my $RADIO_PORT              = $conf->get('radio.RADIO_PORT');
    my $RADIO_URL               = $conf->get('radio.RADIO_URL');
    my $LIQUIDSOAP_TELNET_HOST  = $conf->get('radio.LIQUIDSOAP_TELNET_HOST');

    # Optional flags:
    #   --safe  => colors without background (readable on dark/light)
    #   --plain => no IRC colors at all
    my $safe  = 0;
    my $plain = 0;
    @args = grep {
        if ($_ eq '--safe')  { $safe = 1; 0 }
        elsif ($_ eq '--plain'){ $plain = 1; 0 }
        else { 1 }
    } @args;

    # Resolve target channel
    my $target_chan = $chan;
    if ((!defined $target_chan || $target_chan eq '') && @args && defined($args[0]) && $args[0] =~ /^#/) {
        $target_chan = shift @args;
    }
    unless (defined($target_chan) && $target_chan =~ /^#/) {
        botNotice($self, $nick, "Syntax: song <#channel> [--safe|--plain]");
        return;
    }

    my $channel_obj = $self->{channels}{$target_chan} || $self->{channels}{lc($target_chan)};
    unless ($channel_obj) {
        botNotice($self, $nick, "Channel $target_chan is not registered");
        return;
    }

    # Fetch song + harbor/live
    my $title   = getRadioCurrentSong($self);
    my $harbor  = getRadioHarbor($self);
    my $is_live = 0;

    if (defined($harbor) && $harbor ne '') {
        $self->{logger}->log(3, $harbor);
        $is_live = isRadioLive($self, $harbor) ? 1 : 0;
    }

    unless (defined($title) && $title ne '') {
        botNotice($self, $nick, "Radio is currently unavailable");
        return;
    }

    # Build URL
    my $url;
    if (defined($RADIO_PORT) && $RADIO_PORT == 443) {
        $url = "https://$RADIO_HOSTNAME/$RADIO_URL";
    } else {
        $url = "http://$RADIO_HOSTNAME:$RADIO_PORT/$RADIO_URL";
    }

    # Remaining time (only if not live and telnet configured)
    my $remaining_txt = '';
    if (!$is_live && defined($LIQUIDSOAP_TELNET_HOST) && $LIQUIDSOAP_TELNET_HOST ne '') {
        my $rem = getRadioRemainingTime($self);
        $rem = 0 unless defined($rem) && $rem =~ /^\d+(\.\d+)?$/;

        my $total = int($rem);
        my $min   = int($total / 60);
        my $sec   = $total % 60;

        my @parts;
        push @parts, sprintf("%d min%s", $min, ($min > 1 ? 's' : '')) if $min > 0;
        push @parts, sprintf("%d sec%s", $sec, ($sec > 1 ? 's' : ''));
        $remaining_txt = join(" and ", @parts) . " remaining";
    }

    # Output formatting (plain / safe / legacy)
    my $out = _radio_song_format(
        url       => $url,
        title     => $title,
        is_live   => $is_live,
        remaining => $remaining_txt,
        safe      => $safe,
        plain     => $plain,
    );

    botPrivmsg($self, $target_chan, $out);
    logBot($self, $message, $target_chan, "song", $nick);
    return 1;
}

sub _radio_song_format {
    my (%p) = @_;
    my $url       = $p{url} // '';
    my $title     = $p{title} // '';
    my $is_live   = $p{is_live} ? 1 : 0;
    my $remaining = $p{remaining} // '';
    my $safe      = $p{safe} ? 1 : 0;
    my $plain     = $p{plain} ? 1 : 0;

    # Plain text fallback (no colors)
    if ($plain || !eval { String::IRC->can('new') }) {
        my $s = "[ $url ] - [ " . ($is_live ? "Live - " : "") . $title . " ]";
        $s   .= " - [ $remaining ]" if $remaining ne '';
        return $s;
    }

    # SAFE mode: avoid background colors (readable on any theme)
    if ($safe) {
        my $s = String::IRC->new('[ ')->bold;
        $s   .= String::IRC->new($url)->bold->orange;
        $s   .= String::IRC->new(' ] - [ ')->bold;
        $s   .= String::IRC->new('Live - ')->bold->red if $is_live;
        $s   .= String::IRC->new($title)->bold;
        $s   .= String::IRC->new(' ]')->bold;

        if ($remaining ne '') {
            $s .= String::IRC->new(' - [ ')->bold;
            $s .= String::IRC->new($remaining)->grey;
            $s .= String::IRC->new(' ]')->bold;
        }
        return "$s";
    }

    # Legacy mode: keep your exact style (backgrounds)
    my $sMsgSong = String::IRC->new('[ ')->white('black');

    $sMsgSong .= String::IRC->new($url)->orange('black');

    $sMsgSong .= String::IRC->new(' ] ')->white('black');
    $sMsgSong .= String::IRC->new(' - ')->white('black');
    $sMsgSong .= String::IRC->new(' [ ')->orange('black');

    $sMsgSong .= String::IRC->new('Live - ')->white('black') if $is_live;

    $sMsgSong .= String::IRC->new($title)->white('black');
    $sMsgSong .= String::IRC->new(' ]')->orange('black');

    if ($remaining ne '') {
        $sMsgSong .= String::IRC->new(' - ')->white('black');
        $sMsgSong .= String::IRC->new(' [ ')->orange('black');
        $sMsgSong .= String::IRC->new($remaining)->white('black');
        $sMsgSong .= String::IRC->new(' ]')->orange('black');
    }

    return "$sMsgSong";
}

# Display current number of radio listeners
sub displayRadioListeners_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $message = $ctx->message;
    my $nick    = $ctx->nick;
    my $chan    = $ctx->channel; # undef en privé
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    my $conf = $self->{conf};

    my $RADIO_HOSTNAME = $conf->get('radio.RADIO_HOSTNAME');
    my $RADIO_PORT     = $conf->get('radio.RADIO_PORT');
    my $RADIO_URL      = $conf->get('radio.RADIO_URL');

    # Flags optionnels :
    #   --safe  => couleurs sans background (lisible partout)
    #   --plain => aucun code couleur
    my $safe  = 0;
    my $plain = 0;
    @args = grep {
        if ($_ eq '--safe')   { $safe = 1; 0 }
        elsif ($_ eq '--plain'){ $plain = 1; 0 }
        else { 1 }
    } @args;

    # Resolve target channel :
    # - si commande vient d’un chan → ctx->channel
    # - en privé, autoriser listeners #chan
    my $target_chan = $chan;
    if ((!defined $target_chan || $target_chan eq '') && @args && defined($args[0]) && $args[0] =~ /^#/) {
        $target_chan = shift @args;
    }

    unless (defined($target_chan) && $target_chan =~ /^#/) {
        botNotice($self, $nick, "Syntax: listeners <#channel> [--safe|--plain]");
        return;
    }

    my $channel_obj = $self->{channels}{$target_chan} || $self->{channels}{lc($target_chan)};
    unless ($channel_obj) {
        botNotice($self, $nick, "Channel $target_chan is not registered");
        return;
    }

    my $listeners = getRadioCurrentListeners($self);
    unless (defined($listeners) && $listeners ne '') {
        botNotice($self, $nick, "Radio is currently unavailable");
        return;
    }

    $listeners = int($listeners);
    my $msg = _radio_listeners_format(
        listeners => $listeners,
        safe      => $safe,
        plain     => $plain,
    );

    botPrivmsg($self, $target_chan, $msg);
    logBot($self, $message, $target_chan, "listeners", "$listeners listener(s)");
    return 1;
}

sub _radio_listeners_format {
    my (%p) = @_;

    my $n     = $p{listeners} // 0;
    my $safe  = $p{safe}  ? 1 : 0;
    my $plain = $p{plain} ? 1 : 0;

    # Fallback sans couleurs (plain)
    if ($plain || !eval { String::IRC->can('new') }) {
        my $word = ($n == 1) ? "listener" : "listeners";
        return "Currently $n $word on the radio.";
    }

    my $word = ($n == 1) ? "listener" : "listeners";

    # SAFE : pas de background → lisible sur fond clair ou sombre
    if ($safe) {
        my $s = String::IRC->new('[ ')->bold;
        $s   .= String::IRC->new('Radio')->bold->orange;
        $s   .= String::IRC->new(' ] ')->bold;
        $s   .= String::IRC->new('Currently ')->grey;
        $s   .= String::IRC->new($n)->bold->green;
        $s   .= String::IRC->new(" $word")->grey;
        return "$s";
    }

    # Legacy : on garde ton truc psychédélique d’origine
    my $sMsgListeners = String::IRC->new('(')->white('red');
    $sMsgListeners   .= String::IRC->new(')')->maroon('red');
    $sMsgListeners   .= String::IRC->new('(')->red('maroon');
    $sMsgListeners   .= String::IRC->new(')')->black('maroon');
    $sMsgListeners   .= String::IRC->new('( ')->maroon('black');
    $sMsgListeners   .= String::IRC->new('( ')->red('black');
    $sMsgListeners   .= String::IRC->new('Currently ')->silver('black');
    $sMsgListeners   .= String::IRC->new(')-( ')->red('black');
    $sMsgListeners   .= $n;
    $sMsgListeners   .= String::IRC->new(' )-( ')->red('black');
    $sMsgListeners   .= String::IRC->new("$word")->white('black');
    $sMsgListeners   .= String::IRC->new(' ) ')->red('black');
    $sMsgListeners   .= String::IRC->new(')')->maroon('black');
    $sMsgListeners   .= String::IRC->new('(')->black('maroon');
    $sMsgListeners   .= String::IRC->new(')')->red('maroon');
    $sMsgListeners   .= String::IRC->new('(')->maroon('red');
    $sMsgListeners   .= String::IRC->new(')')->white('red');

    return "$sMsgListeners";
}

# Set the radio metadata (current song)
sub setRadioMetadata_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my $message = $ctx->message;
    my @args    = @{ $ctx->args };

    # Authentification
    my $user = $ctx->user;
    unless ($user && $user->is_authenticated) {
        my $msg = $message->prefix . " metadata command attempt (user not logged in)";
        noticeConsoleChan($self, $msg);
        botNotice($self, $nick, "You must be logged in to use this command - /msg "
            . $self->{irc}->nick_folded . " login username password");
        return;
    }

    # Niveau requis : Administrator+
    unless ($user->has_level('Administrator')) {
        my $msg = $message->prefix . " metadata command attempt (level ["
            . $user->level_description . "] insufficient for user " . $user->nickname . ")";
        noticeConsoleChan($self, $msg);
        botNotice($self, $nick, "Your level does not allow you to use this command.");
        return;
    }

    # Si premier arg est un #channel, on l'utilise comme cible
    if (defined($args[0]) && $args[0] =~ /^#/) {
        my $chan_name = shift @args;
        my $chan_obj  = $self->{channels}{$chan_name};
        unless ($chan_obj) {
            botNotice($self, $nick, "Channel $chan_name is undefined");
            return;
        }
        $channel = $chan_name;
    }

    my $sNewMetadata = join(" ", @args);

    # Pas de métadonnée fournie : afficher le titre courant
    unless ($sNewMetadata ne '') {
        displayRadioCurrentSong($self, $message, $nick, $channel)
            if (defined($channel) && $channel ne '');
        return;
    }

    # Config radio
    my $conf            = $self->{conf};
    my $RADIO_HOSTNAME  = $conf->get('radio.RADIO_HOSTNAME');
    my $RADIO_PORT      = $conf->get('radio.RADIO_PORT');
    my $RADIO_URL       = $conf->get('radio.RADIO_URL');
    my $RADIO_ADMINPASS = $conf->get('radio.RADIO_ADMINPASS');

    unless (defined($RADIO_ADMINPASS) && $RADIO_ADMINPASS ne '') {
        $self->{logger}->log(0, "setRadioMetadata_ctx() radio.RADIO_ADMINPASS not set");
        return;
    }

    # Envoi de la métadonnée à Icecast via HTTP::Tiny
    my $encoded_meta = url_encode_utf8($sNewMetadata);
    my $url = "http://$RADIO_HOSTNAME:$RADIO_PORT/admin/metadata"
            . "?mount=/$RADIO_URL&mode=updinfo&song=$encoded_meta";

    my $http = HTTP::Tiny->new(
        timeout => 5,
    );

    # Icecast attend une authentification Basic
    require MIME::Base64;
    my $credentials = MIME::Base64::encode_base64("admin:$RADIO_ADMINPASS", '');

    my $response = $http->request('GET', $url, {
        headers => { 'Authorization' => "Basic $credentials" },
    });

    unless ($response->{success}) {
        $self->{logger}->log(1, "setRadioMetadata_ctx() Icecast HTTP error: "
            . "$response->{status} $response->{reason}");
        botNotice($self, $nick, "Unable to update metadata (HTTP error $response->{status}).");
        return;
    }

    # Confirmer ou afficher le titre mis à jour
    if (defined($channel) && $channel ne '') {
        sleep 3;  # laisser Icecast rafraîchir ses métadonnées
        displayRadioCurrentSong($self, $message, $nick, $channel);
    } else {
        botNotice($self, $nick, "Metadata updated to: $sNewMetadata");
    }
}

# Legacy wrapper
sub setRadioMetadata {
    my ($self, $message, $sNick, $sChannel, @tArgs) = @_;
    my $ctx = Mediabot::Context->new(
        bot     => $self,
        message => $message,
        nick    => $sNick,
        channel => $sChannel,
        command => 'metadata',
        args    => \@tArgs,
    );
    setRadioMetadata_ctx($ctx);
}

# Skip to the next song in the radio stream (Context version)
sub radioNext_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $message = $ctx->message;
    my $nick    = $ctx->nick;
    my $chan    = $ctx->channel;      # undef en privé
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # Récup utilisateur
    my $user = $ctx->user || eval { $self->get_user_from_message($message) };
    unless ($user && eval { $user->id }) {
        botNotice($self, $nick, "User not found.");
        return;
    }

    unless ($user->is_authenticated) {
        my $msg = ($message && $message->can('prefix'))
            ? $message->prefix . " nextsong command attempt (user " . $user->nickname . " is not logged in)"
            : "nextsong command attempt (unauthenticated)";
        noticeConsoleChan($self, $msg);
        botNotice($self, $nick, "You must be logged in to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
        return;
    }



    # Options d'affichage : --safe / --plain (facultatives)
    my $safe  = 0;
    my $plain = 0;

    @args = grep {
        if    ($_ eq '--safe')   { $safe  = 1; 0 }
        elsif ($_ eq '--plain')  { $plain = 1; 0 }
        else { 1 }
    } @args;

    # Canal cible :
    # - si commande vient du chan → ctx->channel
    # - sinon, autoriser nextsong #chan
    my $target_chan = $chan;
    if ((!defined $target_chan || $target_chan eq '') && @args && $args[0] =~ /^#/) {
        $target_chan = shift @args;
    }

    unless (defined $target_chan && $target_chan =~ /^#/) {
        botNotice($self, $nick, "Syntax: nextsong <#channel> [--safe|--plain]");
        return;
    }

    my $channel_obj = $self->{channels}{$target_chan} || $self->{channels}{lc $target_chan};
    unless ($channel_obj) {
        botNotice($self, $nick, "Channel $target_chan is not registered");
        return;
    }

    # Config radio
    my $conf = $self->{conf};

    my $RADIO_HOSTNAME         = $conf->get('radio.RADIO_HOSTNAME');
    my $RADIO_PORT             = $conf->get('radio.RADIO_PORT');
    my $RADIO_URL              = $conf->get('radio.RADIO_URL');
    my $LIQUIDSOAP_TELNET_HOST = $conf->get('radio.LIQUIDSOAP_TELNET_HOST');
    my $LIQUIDSOAP_TELNET_PORT = $conf->get('radio.LIQUIDSOAP_TELNET_PORT');

    unless ($LIQUIDSOAP_TELNET_HOST && $LIQUIDSOAP_TELNET_PORT) {
        $self->{logger}->log(0,
            "radioNext_ctx(): LIQUIDSOAP_TELNET_HOST/PORT not set in " . ($self->{config_file} // 'config')
        );
        botNotice($self, $nick, "Liquidsoap telnet endpoint is not configured.");
        return;
    }

    # Transform mountpoint (RADIO_URL) pour Liquidsoap
    my $mountpoint = $RADIO_URL // '';
    $mountpoint =~ s/\./(dot)/g;

    # Commande telnet via nc
    my $cmd = qq{echo -ne "$mountpoint.skip\\nquit\\n" | nc $LIQUIDSOAP_TELNET_HOST $LIQUIDSOAP_TELNET_PORT};

    my $lines = 0;
    if (open my $fh, "$cmd |") {
        while (my $line = <$fh>) {
            chomp $line;
            $lines++;
        }
        close $fh;
    } else {
        botNotice($self, $nick, "Unable to connect to LIQUIDSOAP telnet port");
        $self->{logger}->log(1, "radioNext_ctx(): failed to run nc command: $cmd");
        return;
    }

    # Liquidsoap répond en général quelque chose (prompt etc.)
    if ($lines > 0) {
        my $msg = _radio_next_format(
            nick        => $nick,
            hostname    => $RADIO_HOSTNAME,
            port        => $RADIO_PORT,
            mount       => $RADIO_URL,
            safe        => $safe,
            plain       => $plain,
        );
        botPrivmsg($self, $target_chan, $msg);
        logBot($self, $message, $target_chan, "nextsong", "$nick skipped to next track");
    } else {
        botNotice($self, $nick, "No response from Liquidsoap. The command may have failed.");
        $self->{logger}->log(2, "radioNext_ctx(): nc produced no output for cmd: $cmd");
    }

    return 1;
}

sub _radio_next_format {
    my (%p) = @_;

    my $nick     = $p{nick}     // '?';
    my $host     = $p{hostname} // 'radio';
    my $port     = $p{port}     // 80;
    my $mount    = $p{mount}    // '';
    my $safe     = $p{safe}  ? 1 : 0;
    my $plain    = $p{plain} ? 1 : 0;

    my $url = ($port && $port == 443)
        ? "https://$host/$mount"
        : "http://$host:$port/$mount";

    # Mode texte brut (no colors)
    if ($plain || !eval { String::IRC->can('new') }) {
        return "[$url] - [$nick skipped to next track]";
    }

    # Mode safe : couleurs sans background
    if ($safe) {
        my $s = String::IRC->new('[ ')->bold;
        $s   .= String::IRC->new($url)->orange;
        $s   .= String::IRC->new(' ] ')->bold;
        $s   .= String::IRC->new('-')->white;
        $s   .= String::IRC->new(' [ ')->orange;
        $s   .= String::IRC->new("$nick skipped to next track")->grey;
        $s   .= String::IRC->new(' ]')->orange;
        return "$s";
    }

    # Mode legacy avec fond noir, comme ton code original
    my $sMsgSong = String::IRC->new('[ ')->grey('black');
    $sMsgSong   .= String::IRC->new($url)->orange('black');
    $sMsgSong   .= String::IRC->new(' ] ')->grey('black');
    $sMsgSong   .= String::IRC->new(' - ')->white('black');
    $sMsgSong   .= String::IRC->new(' [ ')->orange('black');
    $sMsgSong   .= String::IRC->new("$nick skipped to next track")->grey('black');
    $sMsgSong   .= String::IRC->new(' ]')->orange('black');

    return "$sMsgSong";
}

# Update the bot
sub playRadio_ctx {
    my ($ctx) = @_;
    playRadio($ctx->bot, $ctx->message, $ctx->nick, $ctx->channel, @{ $ctx->args });
}

sub radioPub_ctx {
    my ($ctx) = @_;
    radioPub($ctx->bot, $ctx->message, $ctx->nick, undef, @{ $ctx->args });
}

sub rplayRadio_ctx {
    my ($ctx) = @_;
    rplayRadio($ctx->bot, $ctx->message, $ctx->nick, $ctx->channel, @{ $ctx->args });
}

sub queueRadio_ctx {
    my ($ctx) = @_;
    queueRadio($ctx->bot, $ctx->message, $ctx->nick, $ctx->channel, @{ $ctx->args });
}

sub nextRadio_ctx {
    my ($ctx) = @_;
    nextRadio($ctx->bot, $ctx->message, $ctx->nick, $ctx->channel, @{ $ctx->args });
}

sub playRadio(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my $incomingDir = $self->{conf}->get('radio.YOUTUBEDL_INCOMING');
	my $LIQUIDSOAP_TELNET_HOST = $self->{conf}->get('radio.LIQUIDSOAP_TELNET_HOST');
	my $LIQUIDSOAP_TELNET_PORT = $self->{conf}->get('radio.LIQUIDSOAP_TELNET_PORT');
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"User")) {
				my $sHarbor = getRadioHarbor($self);
				my $bRadioLive = 0;
				if (defined($sHarbor) && ($sHarbor ne "")) {
					$self->{logger}->log(3,$sHarbor);
					$bRadioLive = isRadioLive($self,$sHarbor);
				}
				if ($bRadioLive) {
					unless (defined($sChannel) && ($sChannel ne "")) {
						botPrivmsg($self,$sChannel,"($sNick radio play) Cannot queue requests while radio is live");
					}
					else {
						botNotice($self,$sNick,"($sNick radio play) Cannot queue requests while radio is live");
					}
					return undef;
				}
				my $sYoutubeId;
				unless (defined($tArgs[0]) && ($tArgs[0] ne "")) {
					botNotice($self,$sNick,"Syntax : play id <ID>|ytid <YTID>|<searchstring>");
				}
				else {
					my $sText = $tArgs[0];
					if ( $sText =~ /http.*:\/\/www\.youtube\..*\/watch.*v=/i ) {
						$sYoutubeId = $sText;
						$sYoutubeId =~ s/^.*watch.*v=//;
						$sYoutubeId = substr($sYoutubeId,0,11);
					}
					elsif ( $sText =~ /http.*:\/\/m\.youtube\..*\/watch.*v=/i ) {
						$sYoutubeId = $sText;
						$sYoutubeId =~ s/^.*watch.*v=//;
						$sYoutubeId = substr($sYoutubeId,0,11);
					}
					elsif ( $sText =~ /http.*:\/\/music\.youtube\..*\/watch.*v=/i ) {
						$sYoutubeId = $sText;
						$sYoutubeId =~ s/^.*watch.*v=//;
						$sYoutubeId = substr($sYoutubeId,0,11);
					}
					elsif ( $sText =~ /http.*:\/\/youtu\.be.*/i ) {
						$sYoutubeId = $sText;
						$sYoutubeId =~ s/^.*youtu\.be\///;
						$sYoutubeId = substr($sYoutubeId,0,11);
					}
					if (defined($sYoutubeId) && ( $sYoutubeId ne "" )) {
						my $ytUrl = "https://www.youtube.com/watch?v=$sYoutubeId";
						my ($sDurationSeconds,$sMsgSong) = getYoutubeDetails($self,$ytUrl);
						unless (defined($sMsgSong)) {
							if (defined($sChannel) && ($sChannel ne "")) {
								botPrivmsg($self,$sChannel,"($sNick radio play) Unknown Youtube link");
							}
							else {
								botNotice($self,$sNick,"($sNick radio play) Unknown Youtube link");
							}
							return undef;
						}
						else {
							unless ($sDurationSeconds < (12 * 60)) {
								if (defined($sChannel) && ($sChannel ne "")) {
									botPrivmsg($self,$sChannel,"($sNick radio play) Youtube link duration is too long ($sDurationSeconds seconds), sorry");
								}
								else {
									botNotice($self,$sNick,"($sNick radio play) Youtube link duration is too long ($sDurationSeconds seconds), sorry");
								}
								return undef;
							}
							unless ( -d $incomingDir ) {
								$self->{logger}->log(0,"Incoming YOUTUBEDL directory : $incomingDir does not exist");
								return undef;
							}
							else {
								chdir $incomingDir;
							}
							my $ytDestinationFile;
							my $sQuery = "SELECT id_mp3,folder,filename FROM MP3 WHERE id_youtube=?";
							my $sth = $self->{dbh}->prepare($sQuery);
							my $id_mp3;
							unless ($sth->execute($sYoutubeId)) {
								$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
							}
							else {
								if (my $ref = $sth->fetchrow_hashref()) {
									$id_mp3 = $ref->{'id_mp3'};
									$ytDestinationFile = $ref->{'folder'} . "/" . $ref->{'filename'};
								}
							}
							if (defined($ytDestinationFile) && ($ytDestinationFile ne "")) {
								my $rPush = queuePushRadio($self,$ytDestinationFile);
								if (defined($rPush) && $rPush) {
									if (defined($sChannel) && ($sChannel ne "")) {
										botPrivmsg($self,$sChannel,"($sNick radio play) Library ID : ID : $sYoutubeId (cached) / https://www.youtube.com/watch?v=$sYoutubeId / $sMsgSong / Queued");
									}
									else {
										botNotice($self,$sNick,"($sNick radio play) Library ID : ID : $sYoutubeId (cached) / https://www.youtube.com/watch?v=$sYoutubeId / $sMsgSong / Queued");
									}
									logBot($self,$message,$sChannel,"play",$sText);
								}
								else {
									$self->{logger}->log(3,"playRadio() could not queue queuePushRadio() $ytDestinationFile");
									if (defined($sChannel) && ($sChannel ne "")) {
										botPrivmsg($self,$sChannel,"($sNick radio play could not queue) Already asked ?");
									}
									else {
										botNotice($self,$sNick,"($sNick radio play could not queue) Already asked ?");
									}
									return undef;
								}
							}
							else {
								if (defined($sChannel) && ($sChannel ne "")) {
									botPrivmsg($self,$sChannel,"($sNick radio play) $sMsgSong - Please wait while downloading");
								}
								else {
									botNotice($self,$sNick,"($sNick radio play) $sMsgSong - Please wait while downloading");
								}
								my $timer = IO::Async::Timer::Countdown->new(
							   	delay => 3,
							   	on_expire => sub {
										$self->{logger}->log(4,"Timer start, downloading $ytUrl");
										my $ytdlp_bin1 = $self->{conf}->get('radio.YTDLP_PATH') || '/usr/bin/yt-dlp';
										my $fh_yt1;
										unless ( open $fh_yt1, "-|", $ytdlp_bin1,
										    "-x", "--audio-format", "mp3", "--audio-quality", "0", $ytUrl ) {
				                    		$self->{logger}->log(0,"Could not run yt-dlp for $ytUrl");
				                    		return undef;
				            			}
				            			my $ytdlOuput;
				            
										while (defined($ytdlOuput=<$fh_yt1>)) {
												chomp($ytdlOuput);
												if ( $ytdlOuput =~ /^\[ExtractAudio\] Destination: (.*)$/ ) {
													$ytDestinationFile = $1;
													$self->{logger}->log(0,"Downloaded mp3 : $incomingDir/$ytDestinationFile");
													
												}
												$self->{logger}->log(3,"$ytdlOuput");
										}
										if (defined($ytDestinationFile) && ($ytDestinationFile ne "")) {			
											my $filename = $ytDestinationFile;
											my $folder = $incomingDir;
											my $id_youtube = substr($filename,-15);
											$id_youtube = substr($id_youtube,0,11);

											my ($title, $artist) = ('', '');
											eval {
												if (defined &MP3::Tag::new) {
													my $mp3 = MP3::Tag->new("$incomingDir/$ytDestinationFile");
													$mp3->get_tags;
													my ($t, undef, $a) = $mp3->autoinfo();
													$mp3->close;
													$title  = $t // '';
													$artist = $a // '';
												}
											};
											if ($@) { $self->{logger}->log(1, "MP3::Tag error: $@") }
											my ($track, $album, $comment, $year, $genre) = ('', '', '', '', '');
											if ($title eq $id_youtube) {
												$title = "";
											}
											print 
											my $sQuery = "INSERT INTO MP3 (id_user,id_youtube,folder,filename,artist,title) VALUES (?,?,?,?,?,?)";
											my $sth = $self->{dbh}->prepare($sQuery);
											my $id_mp3 = 0;
											unless ($sth->execute($iMatchingUserId,$id_youtube,$folder,$filename,$artist,$title)) {
												$self->{logger}->log(1,"Error : " . $DBI::errstr . " Query : " . $sQuery);
											}
											else {
												$id_mp3 = $sth->{Database}->last_insert_id(undef, undef, undef, undef);
												$self->{logger}->log(4,"Added : $artist - Title : $title - Youtube ID : $id_youtube");
											}
											$sth->finish;
											my $rPush = queuePushRadio($self,"$incomingDir/$ytDestinationFile");
											if (defined($rPush) && $rPush) {
												if (defined($sChannel) && ($sChannel ne "")) {
													botPrivmsg($self,$sChannel,"($sNick radio play) Library ID : $id_mp3 / Youtube ID : $sYoutubeId (downloaded) / https://www.youtube.com/watch?v=$sYoutubeId / $sMsgSong / Queued");
												}
												else {
													botNotice($self,$sNick,"($sNick radio play) Library ID : $id_mp3 / Youtube ID : $sYoutubeId (downloaded) / https://www.youtube.com/watch?v=$sYoutubeId / $sMsgSong / Queued");
												}
												logBot($self,$message,$sChannel,"play",$sText);
											}
											else {
												$self->{logger}->log(3,"playRadio() could not queue queuePushRadio() $incomingDir/$ytDestinationFile");
												if (defined($sChannel) && ($sChannel ne "")) {
													botPrivmsg($self,$sChannel,"($sNick radio play could not queue) Already asked ?");
												}
												else {
													botNotice($self,$sNick,"($sNick radio play could not queue) Already asked ?");
												}
												return undef;
											}
										}
										},
								);
								$self->{loop}->add( $timer );
								$timer->start;

							}
						}
					}
					else {
						if (defined($tArgs[0]) && ($tArgs[0] =~ /^id$/) && defined($tArgs[1]) && ($tArgs[1] =~ /^[0-9]+$/)) {
							my $sQuery = "SELECT id_youtube,artist,title,folder,filename FROM MP3 WHERE id_mp3=?";
							my $sth = $self->{dbh}->prepare($sQuery);
							unless ($sth->execute($tArgs[1])) {
								$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
							}
							else {
								if (my $ref = $sth->fetchrow_hashref()) {
									my $ytDestinationFile = $ref->{'folder'} . "/" . $ref->{'filename'};
									$self->{logger}->log(4,"playRadio() pushing $ytDestinationFile to queue");
									my $rPush = queuePushRadio($self,$ytDestinationFile);
									if (defined($rPush) && $rPush) {
										my $id_youtube = $ref->{'id_youtube'};
										my $artist = ( defined($ref->{'artist'}) ? $ref->{'artist'} : "Unknown");
										my $title = ( defined($ref->{'title'}) ? $ref->{'title'} : "Unknown");
										my $duration = 0;
										my $sMsgSong = "$artist - $title";
										if (defined($id_youtube) && ($id_youtube ne "")) {
											($duration,$sMsgSong) = getYoutubeDetails($self,"https://www.youtube.com/watch?v=$id_youtube");
											if (defined($sChannel) && ($sChannel ne "")) {
												botPrivmsg($self,$sChannel,"($sNick radio play) Library ID : " . $tArgs[1] . " (cached) / https://www.youtube.com/watch?v=$id_youtube / $sMsgSong / Queued");
											}
											else {
												botNotice($self,$sNick,"($sNick radio play) Library ID : " . $tArgs[1] . " (cached) / https://www.youtube.com/watch?v=$id_youtube / $sMsgSong / Queued");
											}
										}
										else {
											if (defined($sChannel) && ($sChannel ne "")) {
												botPrivmsg($self,$sChannel,"($sNick radio play) Library ID : " . $tArgs[1] . " (cached) / $sMsgSong / Queued");
											}
											else {
												botNotice($self,$sNick,"($sNick radio play) Library ID : " . $tArgs[1] . " (cached) / $sMsgSong / Queued");
											}
										}
										logBot($self,$message,$sChannel,"play",$sText);
										return 1;
									}
									else {
										$self->{logger}->log(3,"playRadio() could not queue queuePushRadio() $ytDestinationFile");
										if (defined($sChannel) && ($sChannel ne "")) {
											botPrivmsg($self,$sChannel,"($sNick radio play could not queue) Already asked ?");
										}
										else {
											botNotice($self,$sNick,"($sNick radio play could not queue) Already asked ?");
										}
										return undef;
									}
								}
								else {
									if (defined($sChannel) && ($sChannel ne "")) {
										botPrivmsg($self,$sChannel,"($sNick radio play / could not find mp3 id in library : $tArgs[1]");
									}
									else {
										botNotice($self,$sNick,"($sNick radio play / could not find mp3 id in library : $tArgs[1]");
									}
									return undef;
								}
							}
						}
						if (defined($tArgs[0]) && ($tArgs[0] =~ /^ytid$/) && defined($tArgs[1]) && ($tArgs[1] ne "")) {
							my $sQuery = "SELECT id_youtube,artist,title,folder,filename FROM MP3 WHERE id_youtube=?";
							my $sth = $self->{dbh}->prepare($sQuery);
							unless ($sth->execute($tArgs[1])) {
								$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
							}
							else {
								if (my $ref = $sth->fetchrow_hashref()) {
									my $ytDestinationFile = $ref->{'folder'} . "/" . $ref->{'filename'};
									my $rPush = queuePushRadio($self,$ytDestinationFile);
									if (defined($rPush) && $rPush) {
										my $id_youtube = $ref->{'id_youtube'};
										my $artist = ( defined($ref->{'artist'}) ? $ref->{'artist'} : "Unknown");
										my $title = ( defined($ref->{'title'}) ? $ref->{'title'} : "Unknown");
										my $duration = 0;
										my $sMsgSong = "$artist - $title";
										if (defined($id_youtube) && ($id_youtube ne "")) {
											($duration,$sMsgSong) = getYoutubeDetails($self,"https://www.youtube.com/watch?v=$id_youtube");
										}
										if (defined($sChannel) && ($sChannel ne "")) {
											botPrivmsg($self,$sChannel,"($sNick radio play) Library ID : " . $tArgs[1] . " Youtube ID : $sText (cached) / https://www.youtube.com/watch?v=$id_youtube / $sMsgSong / Queued");
										}
										else {
											botNotice($self,$sNick,"($sNick radio play) Library ID : " . $tArgs[1] . " Youtube ID : $sText (cached) / https://www.youtube.com/watch?v=$id_youtube / $sMsgSong / Queued");
										}
										logBot($self,$message,$sChannel,"play",$sText);
									}
									else {
										$self->{logger}->log(3,"playRadio() could not queue queuePushRadio() $ytDestinationFile");	
										if (defined($sChannel) && ($sChannel ne "")) {
											botPrivmsg($self,$sChannel,"($sNick radio play could not queue) Already asked ?");
										}
										else {
											botNotice($self,$sNick,"($sNick radio play could not queue) Already asked ?");
										}
										return undef;
									}
								}
								else {
									unless ( -d $incomingDir ) {
										$self->{logger}->log(0,"Incoming YOUTUBEDL directory : $incomingDir does not exist");
										return undef;
									}
									else {
										chdir $incomingDir;
									}
									my $ytUrl = "https://www.youtube.com/watch?v=" . $tArgs[1];
									my ($sDurationSeconds,$sMsgSong) = getYoutubeDetails($self,$ytUrl);
									unless (defined($sMsgSong)) {
										if (defined($sChannel) && ($sChannel ne "")) {
											botPrivmsg($self,$sChannel,"($sNick radio play) Unknown Youtube link");
										}
										else {
											botNotice($self,$sNick,"($sNick radio play) Unknown Youtube link");
										}
										return undef;
									}
									if (defined($sChannel) && ($sChannel ne "")) {
										botPrivmsg($self,$sChannel,"($sNick radio play) $sMsgSong - Please wait while downloading");
									}
									else {
										botNotice($self,$sNick,"($sNick radio play) $sMsgSong - Please wait while downloading");
									}
									my $timer = IO::Async::Timer::Countdown->new(
										delay => 3,
										on_expire => sub {
												$self->{logger}->log(4,"Timer start, downloading $ytUrl");
												my $ytdlp_bin2 = $self->{conf}->get('radio.YTDLP_PATH') || '/usr/bin/yt-dlp';
												my $fh_yt2;
												unless ( open $fh_yt2, "-|", $ytdlp_bin2,
												    "-x", "--audio-format", "mp3", "--audio-quality", "0", $ytUrl ) {
													$self->{logger}->log(0,"Could not run yt-dlp for $ytUrl");
													return undef;
												}
												my $ytdlOuput;
												my $ytDestinationFile;
												while (defined($ytdlOuput=<$fh_yt2>)) {
														chomp($ytdlOuput);
														if ( $ytdlOuput =~ /^\[ExtractAudio\] Destination: (.*)$/ ) {
															$ytDestinationFile = $1;
															$self->{logger}->log(0,"Downloaded mp3 : $incomingDir/$ytDestinationFile");
															
														}
														$self->{logger}->log(3,"$ytdlOuput");
												}
												if (defined($ytDestinationFile) && ($ytDestinationFile ne "")) {			
													my $filename = $ytDestinationFile;
													my $folder = $incomingDir;
													my $id_youtube = substr($filename,-15);
													$id_youtube = substr($id_youtube,0,11);
													$self->{logger}->log(4,"Destination : $incomingDir/$ytDestinationFile");
													my ($title, $artist) = ('', '');
													eval {
														if (defined &MP3::Tag::new) {
															my $t_mp3 = MP3::Tag->new("$incomingDir/$ytDestinationFile");
															$t_mp3->get_tags;
															my ($t, undef, $a) = $t_mp3->autoinfo();
															$t_mp3->close;
															$title  = $t // '';
															$artist = $a // '';
														}
													};
													if ($@) { $self->{logger}->log(1, "MP3::Tag error: $@") }
													my ($track, $album, $comment, $year, $genre) = ('', '', '', '', '');
													if ($title eq $id_youtube) {
														$title = "";
													}
													my $id_mp3;
													my $sQuery = "INSERT INTO MP3 (id_user,id_youtube,folder,filename,artist,title) VALUES (?,?,?,?,?,?)";
													my $sth = $self->{dbh}->prepare($sQuery);
													unless ($sth->execute($iMatchingUserId,$id_youtube,$folder,$filename,$artist,$title)) {
														$self->{logger}->log(1,"Error : " . $DBI::errstr . " Query : " . $sQuery);
													}
													else {
														$id_mp3 = $sth->{Database}->last_insert_id(undef, undef, undef, undef);
														$self->{logger}->log(4,"Added : $artist - Title : $title - Youtube ID : $id_youtube");
													}
													$sth->finish;
													my $rPush = queuePushRadio($self,"$incomingDir/$ytDestinationFile");
													if (defined($rPush) && $rPush) {
														if (defined($sChannel) && ($sChannel ne "")) {
															botPrivmsg($self,$sChannel,"($sNick radio play) Library ID : $id_mp3 / Youtube ID : $id_youtube (downloaded) / https://www.youtube.com/watch?v=$id_youtube / $sMsgSong / Queued");
														}
														else {
															botNotice($self,$sNick,"($sNick radio play) Library ID : $id_mp3 / Youtube ID : $id_youtube (downloaded) / https://www.youtube.com/watch?v=$id_youtube / $sMsgSong / Queued");
														}
														logBot($self,$message,$sChannel,"play",$sText);
													}
													else {
														$self->{logger}->log(3,"playRadio() could not queue queuePushRadio() $incomingDir/$ytDestinationFile");
														if (defined($sChannel) && ($sChannel ne "")) {
															botPrivmsg($self,$sChannel,"($sNick radio play could not queue) Already asked ?");
														}
														else {
															botNotice($self,$sNick,"($sNick radio play could not queue) Already asked ?");
														}
														return undef;
													}
												}
												},
										);
										$self->{loop}->add( $timer );
										$timer->start;
								}
							}
						}
						else {
							# Local library search
							my $sSearch = join (" ",@tArgs);
							my $sQuery = "SELECT id_mp3,id_youtube,artist,title,folder,filename FROM MP3 WHERE (artist LIKE ? OR title LIKE ?) ORDER BY RAND() LIMIT 1";
							$self->{logger}->log(4,"playRadio() Query : $sQuery");
							my $sth = $self->{dbh}->prepare($sQuery);
							unless ($sth->execute($sSearch,$sSearch)) {
								$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
							}
							else {	
								if (my $ref = $sth->fetchrow_hashref()) {
									my $id_mp3 = $ref->{'id_mp3'};
									my $id_youtube = $ref->{'id_youtube'};
									my $ytDestinationFile = $ref->{'folder'} . "/" . $ref->{'filename'};
									my $rPush = queuePushRadio($self,$ytDestinationFile);
									if (defined($rPush) && $rPush) {
										my $id_youtube = $ref->{'id_youtube'};
										my $artist = ( defined($ref->{'artist'}) ? $ref->{'artist'} : "Unknown");
										my $title = ( defined($ref->{'title'}) ? $ref->{'title'} : "Unknown");
										my $duration = 0;
										my $sMsgSong = "$artist - $title";
										if (defined($id_youtube) && ($id_youtube ne "")) {
											($duration,$sMsgSong) = getYoutubeDetails($self,"https://www.youtube.com/watch?v=$id_youtube");
											if (defined($sChannel) && ($sChannel ne "")) {
												botPrivmsg($self,$sChannel,"($sNick radio play " . $sText . ") (Library ID : $id_mp3 YTID : $id_youtube) / $sMsgSong - https://www.youtube.com/watch?v=$id_youtube / Queued");
											}
											else {
												botNotice($self,$sNick,"($sNick radio play " . $sText . ") (Library ID : $id_mp3 YTID : $id_youtube) / $sMsgSong - https://www.youtube.com/watch?v=$id_youtube / Queued");
											}
										}
										else {
											if (defined($sChannel) && ($sChannel ne "")) {
												botPrivmsg($self,$sChannel,"($sNick radio play " . $sText . ") (Library ID : $id_mp3) / $artist - $title / Queued");
											}
											else {
												botNotice($self,$sNick,"($sNick radio play " . $sText . ") (Library ID : $id_mp3) / $artist - $title / Queued");
											}
										}
										logBot($self,$message,$sChannel,"play",@tArgs);
										return 1;
									}
									else {
										$self->{logger}->log(3,"playRadio() could not queue queuePushRadio() $ytDestinationFile");
										if (defined($sChannel) && ($sChannel ne "")) {
											botPrivmsg($self,$sChannel,"($sNick radio rplay / could not queue)");
										}
										else {
											botNotice($self,$sNick,"($sNick radio rplay / could not queue)");
										}
										return undef;
									}
								}
							}
							# Youtube Search
							my $sYoutubeId;
							my $sText = join("%20",@tArgs);
							$self->{logger}->log(4,"radioplay() youtubeSearch() on $sText");
							my $APIKEY = $self->{conf}->get('main.YOUTUBE_APIKEY');
							unless (defined($APIKEY) && ($APIKEY ne "")) {
								$self->{logger}->log(0,"displayYoutubeDetails() API Youtube V3 DEV KEY not set in " . $self->{config_file});
								$self->{logger}->log(0,"displayYoutubeDetails() section [main]");
								$self->{logger}->log(0,"displayYoutubeDetails() YOUTUBE_APIKEY=key");
								return undef;
							}
							unless ( open my $fh_yt_radio, "curl --connect-timeout 5 -G -f -s \"https://www.googleapis.com/youtube/v3/search\" -d part=\"snippet\" -d q=\"$sText\" -d key=\"$APIKEY\" |" ) {
								$self->{logger}->log(3,"displayYoutubeDetails() Could not get YOUTUBE_INFOS from API using $APIKEY");
							}
							else {
								my $line;
								my $i = 0;
								my $json_details;
								while(defined($line=<$fh_yt_radio>)) {
									chomp($line);
									$json_details .= $line;
									$self->{logger}->log(5,"radioplay() youtubeSearch() $line");
									$i++;
								}
								if (defined($json_details) && ($json_details ne "")) {
									$self->{logger}->log(4,"radioplay() youtubeSearch() json_details : $json_details");
									my $sYoutubeInfo = eval { decode_json $json_details };
									if ($@ || !defined $sYoutubeInfo) {
										$self->{logger}->log(3, "radioplay() JSON decode error: $@");
										next;
									}
									my %hYoutubeInfo = %$sYoutubeInfo;
										my @tYoutubeItems = $hYoutubeInfo{'items'};
										my @fTyoutubeItems = @{$tYoutubeItems[0]};
										$self->{logger}->log(4,"radioplay() youtubeSearch() tYoutubeItems length : " . $#fTyoutubeItems);
										# Check items
										if ( $#fTyoutubeItems >= 0 ) {
											my %hYoutubeItems = %{$tYoutubeItems[0][0]};
											$self->{logger}->log(4,"radioplay() youtubeSearch() title=" . ($hYoutubeItems{snippet}{title} // "?"));
											my @tYoutubeId = $hYoutubeItems{'id'};
											my %hYoutubeId = %{$tYoutubeId[0]};
											$sYoutubeId = $hYoutubeId{'videoId'};
											$self->{logger}->log(4,"radioplay() youtubeSearch() sYoutubeId : $sYoutubeId");
										}
										else {
											$self->{logger}->log(3,"radioplay() youtubeSearch() Invalid id : $sYoutubeId");
										}
								}
								else {
									$self->{logger}->log(3,"radioplay() youtubeSearch() curl empty result for : curl --connect-timeout 5 -G -f -s \"https://www.googleapis.com/youtube/v3/search\" -d part=\"snippet\" -d q=\"$sText\" -d key=\"$APIKEY\"");
								}
							}
							if (defined($sYoutubeId) && ($sYoutubeId ne "")) {
								my $ytUrl = "https://www.youtube.com/watch?v=$sYoutubeId";
								my ($sDurationSeconds,$sMsgSong) = getYoutubeDetails($self,$ytUrl);
								unless (defined($sMsgSong)) {
									if (defined($sChannel) && ($sChannel ne "")) {
										botPrivmsg($self,$sChannel,"($sNick radio play) Unknown Youtube link");
									}
									else {
										botNotice($self,$sNick,"($sNick radio play) Unknown Youtube link");
									}
									return undef;
								}
								unless ($sDurationSeconds < (12 * 60)) {
									if (defined($sChannel) && ($sChannel ne "")) {
										botPrivmsg($self,$sChannel,"($sNick radio play) Youtube link duration is too long ($sDurationSeconds seconds), sorry");
									}
									else {
										botNotice($self,$sNick,"($sNick radio play) Youtube link duration is too long ($sDurationSeconds seconds), sorry");
									}
									return undef;
								}
								my $sQuery = "SELECT id_mp3,id_youtube,artist,title,folder,filename FROM MP3 WHERE id_youtube=?";
								my $sth = $self->{dbh}->prepare($sQuery);
								unless ($sth->execute($sYoutubeId)) {
									$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
								}
								else {
									if (my $ref = $sth->fetchrow_hashref()) {
										my $ytDestinationFile = $ref->{'folder'} . "/" . $ref->{'filename'};
										my $rPush = queuePushRadio($self,"$ytDestinationFile");
										if (defined($rPush) && $rPush) {
											my $id_mp3 = $ref->{'id_mp3'};
											my $id_youtube = $ref->{'id_youtube'};
											my $artist = ( defined($ref->{'artist'}) ? $ref->{'artist'} : "Unknown");
											my $title = ( defined($ref->{'title'}) ? $ref->{'title'} : "Unknown");
											my $duration = 0;
											my $sMsgSong = "$artist - $title";
											if (defined($id_youtube) && ($id_youtube ne "")) {
												($duration,$sMsgSong) = getYoutubeDetails($self,"https://www.youtube.com/watch?v=$id_youtube");
											}
											if (defined($sChannel) && ($sChannel ne "")) {
												botPrivmsg($self,$sChannel,"($sNick radio play) Library ID : $id_mp3 / Youtube ID : $id_youtube (cached) / https://www.youtube.com/watch?v=$id_youtube / $sMsgSong / Queued");
											}
											else {
												botNotice($self,$sNick,"($sNick radio play) Library ID : $id_mp3 / Youtube ID : $id_youtube (cached) / https://www.youtube.com/watch?v=$id_youtube / $sMsgSong / Queued");
											}
											logBot($self,$message,$sChannel,"play",$sText);
										}
										else {
											$self->{logger}->log(3,"playRadio() could not queue queuePushRadio() $incomingDir/$ytDestinationFile");
											if (defined($sChannel) && ($sChannel ne "")) {
												botPrivmsg($self,$sChannel,"($sNick radio play could not queue) Already asked ?");
											}
											else {
												botNotice($self,$sNick,"($sNick radio play could not queue) Already asked ?");
											}
											return undef;
										}
									}
									else {
										unless ( -d $incomingDir ) {
											$self->{logger}->log(0,"Incoming YOUTUBEDL directory : $incomingDir does not exist");
											return undef;
										}
										else {
											chdir $incomingDir;
										}
										my $ytUrl = "https://www.youtube.com/watch?v=$sYoutubeId";
										my ($sDurationSeconds,$sMsgSong) = getYoutubeDetails($self,$ytUrl);
										unless (defined($sMsgSong)) {
											if (defined($sChannel) && ($sChannel ne "")) {
												botPrivmsg($self,$sChannel,"($sNick radio play) Unknown Youtube link");
											}
											else {
												botNotice($self,$sNick,"($sNick radio play) Unknown Youtube link");
											}
											return undef;
										}
										if (defined($sChannel) && ($sChannel ne "")) {
											botPrivmsg($self,$sChannel,"($sNick radio play) $sMsgSong - Please wait while downloading");
										}
										else {
											botNotice($self,$sNick,"($sNick radio play) $sMsgSong - Please wait while downloading");
										}
										my $timer = IO::Async::Timer::Countdown->new(
											delay => 3,
											on_expire => sub {
													$self->{logger}->log(4,"Timer start, downloading $ytUrl");
													
													my $ytdlp_bin3 = $self->{conf}->get('radio.YTDLP_PATH') || '/usr/bin/yt-dlp';
													my $fh_yt3;
													unless ( open $fh_yt3, "-|", $ytdlp_bin3,
													    "-x", "--audio-format", "mp3", "--audio-quality", "0", $ytUrl ) {
														$self->{logger}->log(0,"Could not run yt-dlp for $ytUrl");
														return undef;
													}
													my $ytdlOuput;
													my $ytDestinationFile;
													while (defined($ytdlOuput=<$fh_yt3>)) {
															chomp($ytdlOuput);
															if ( $ytdlOuput =~ /^\[ExtractAudio\] Destination: (.*)$/ ) {
																$ytDestinationFile = $1;
																$self->{logger}->log(0,"Downloaded mp3 : $incomingDir/$ytDestinationFile");
																
															}
															$self->{logger}->log(3,"$ytdlOuput");
													}
													if (defined($ytDestinationFile) && ($ytDestinationFile ne "")) {			
														my $filename = $ytDestinationFile;
														my $folder = $incomingDir;
														my $id_youtube = substr($filename,-15);
														$id_youtube = substr($id_youtube,0,11);
														$self->{logger}->log(4,"Destination : $incomingDir/$ytDestinationFile");
														my ($title, $artist) = ('', '');
														eval {
															if (defined &MP3::Tag::new) {
																my $t_mp3 = MP3::Tag->new("$incomingDir/$ytDestinationFile");
																$t_mp3->get_tags;
																my ($t, undef, $a) = $t_mp3->autoinfo();
																$t_mp3->close;
																$title  = $t // '';
																$artist = $a // '';
															}
														};
														if ($@) { $self->{logger}->log(1, "MP3::Tag error: $@") }
														my ($track, $album, $comment, $year, $genre) = ('', '', '', '', '');
														if ($title eq $id_youtube) {
															$title = "";
														}
														my $id_mp3 = 0;
														my $sQuery = "INSERT INTO MP3 (id_user,id_youtube,folder,filename,artist,title) VALUES (?,?,?,?,?,?)";
														my $sth = $self->{dbh}->prepare($sQuery);
														unless ($sth->execute($iMatchingUserId,$id_youtube,$folder,$filename,$artist,$title)) {
															$self->{logger}->log(1,"Error : " . $DBI::errstr . " Query : " . $sQuery);
														}
														else {
															$id_mp3 = $sth->{Database}->last_insert_id(undef, undef, undef, undef);
															$self->{logger}->log(4,"Added : $artist - Title : $title - Youtube ID : $id_youtube");
														}
														$sth->finish;
														my $rPush = queuePushRadio($self,"$incomingDir/$ytDestinationFile");
														if (defined($rPush) && $rPush) {
															if (defined($sChannel) && ($sChannel ne "")) {
																botPrivmsg($self,$sChannel,"($sNick radio play) Library ID : $id_mp3 / Youtube ID : $id_youtube (downloaded) / https://www.youtube.com/watch?v=$sYoutubeId / $sMsgSong / Queued");
															}
															else {
																botNotice($self,$sNick,"($sNick radio play) Library ID : $id_mp3 / Youtube ID : $id_youtube (downloaded) / https://www.youtube.com/watch?v=$sYoutubeId / $sMsgSong / Queued");
															}
															logBot($self,$message,$sChannel,"play",$sText);
														}
														else {
															$self->{logger}->log(3,"playRadio() could not queue queuePushRadio() $incomingDir/$ytDestinationFile");
															if (defined($sChannel) && ($sChannel ne "")) {
																botPrivmsg($self,$sChannel,"($sNick radio play could not queue) Already asked ?");
															}
															else {
																botNotice($self,$sNick,"($sNick radio play could not queue) Already asked ?");
															}
															return undef;
														}
													}
													},
											);
											$self->{loop}->add( $timer );
											$timer->start;
									}
								}
							}
							else {
								if (defined($sChannel) && ($sChannel ne "")) {
									botPrivmsg($self,$sChannel,"($sNick radio play no Youtube ID found for " . join(" ",@tArgs));
								}
								else {
									botNotice($self,$sNick,"($sNick radio play no Youtube ID found for " . join(" ",@tArgs));
								}
							}
						}
					}
				}
			}
			else {
				my $sNoticeMsg = $message->prefix . " play command attempt (command level [User] for user " . $sMatchingUserHandle . "[" . $iMatchingUserLevel ."])";
				noticeConsoleChan($self,$sNoticeMsg);
				botNotice($self,$sNick,"Your level does not allow you to use this command.");
				return undef;
			}
		}
		else {
			my $sNoticeMsg = $message->prefix . " play command attempt (user $sMatchingUserHandle is not logged in)";
			noticeConsoleChan($self,$sNoticeMsg);
			botNotice($self,$sNick,"You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
			return undef;
		}
	}
}

# Check the number of tracks in the queue
sub queueCount(@) {
	my ($self) = @_;
	my $LIQUIDSOAP_TELNET_HOST = $self->{conf}->get('radio.LIQUIDSOAP_TELNET_HOST');
	my $LIQUIDSOAP_TELNET_PORT = $self->{conf}->get('radio.LIQUIDSOAP_TELNET_PORT');
	my $fh_lsts;
	unless (open $fh_lsts, "echo -ne \"queue.queue\nquit\n\" | nc $LIQUIDSOAP_TELNET_HOST $LIQUIDSOAP_TELNET_PORT | head -1 | wc -w |") {
		$self->{logger}->log(0,"queueCount() Unable to connect to LIQUIDSOAP telnet port");
		return undef;
	}
	my $line;
	if (defined($line=<$fh_lsts>)) {
		chomp($line);
		$self->{logger}->log(3,$line);
	}
	return $line;
}

# Check if a track is in the queue
sub isInQueueRadio(@) {
	my ($self,$sAudioFilename) = @_;
	my $LIQUIDSOAP_TELNET_HOST = $self->{conf}->get('radio.LIQUIDSOAP_TELNET_HOST');
	my $LIQUIDSOAP_TELNET_PORT = $self->{conf}->get('radio.LIQUIDSOAP_TELNET_PORT');
	my $iNbTrack = queueCount($self);
	unless ( $iNbTrack == 0 ) {
		my $sNbTrack = ( $iNbTrack > 1 ? "tracks" : "track" );
		my $line;
		if (defined($LIQUIDSOAP_TELNET_HOST) && ($LIQUIDSOAP_TELNET_HOST ne "")) {
			my $fh_lsts;
			unless (open $fh_lsts, "echo -ne \"queue.queue\nquit\n\" | nc $LIQUIDSOAP_TELNET_HOST $LIQUIDSOAP_TELNET_PORT | head -1 |") {
				$self->{logger}->log(0,"queueRadio() Unable to connect to LIQUIDSOAP telnet port");
				return undef;
			}
			if (defined($line=<$fh_lsts>)) {
				chomp($line);
				$line =~ s/\r//;
				$line =~ s/\n//;
				$self->{logger}->log(4,"isInQueueRadio() $line");
			}
			if ($iNbTrack > 0) {
				my @RIDS = split(/ /,$line);
				my $i;
				for ($i=0;$i<=$#RIDS;$i++) {
					my $fh_lsts;
					unless (open $fh_lsts, "echo -ne \"request.trace " . $RIDS[$i] . "\nquit\n\" | nc $LIQUIDSOAP_TELNET_HOST $LIQUIDSOAP_TELNET_PORT | head -1 |") {
						$self->{logger}->log(0,"isInQueueRadio() Unable to connect to LIQUIDSOAP telnet port");
						return undef;
					}
					my $line;
					if (defined($line=<$fh_lsts>)) {
						chomp($line);
						my $sMsgSong = "";
						$line =~ s/\r//;
						$line =~ s/\n//;
						$line =~ s/^.*\[\"//;
						$line =~ s/\".*$//;
						$self->{logger}->log(4,"isInQueueRadio() $line");
						my $sFolder = dirname($line);
						my $sFilename = basename($line);
						my $sBaseFilename = basename($sFilename, ".mp3");
						if ( $line eq $sAudioFilename) {
							return 1;
						}
					}
				}
			}
		}
		else {
			$self->{logger}->log(0,"queueRadio() radio.LIQUIDSOAP_TELNET_HOST not set in " . $self->{config_file});	
		}
	}
	else {
		return 0;
	}
}

# Push a track to the radio queue
sub queueRadio(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my $LIQUIDSOAP_TELNET_HOST = $self->{conf}->get('radio.LIQUIDSOAP_TELNET_HOST');
	my $LIQUIDSOAP_TELNET_PORT = $self->{conf}->get('radio.LIQUIDSOAP_TELNET_PORT');
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"User")) {
				my $iHarborId = getHarBorId($self);
				my $bHarbor = 0;
				if (defined($iHarborId) && ($iHarborId ne "")) {
					$self->{logger}->log(4,"Harbord ID : $iHarborId");
					if (defined($LIQUIDSOAP_TELNET_HOST) && ($LIQUIDSOAP_TELNET_HOST ne "")) {
						my $fh_lsts;
						unless (open $fh_lsts, "echo -ne \"harbor_$iHarborId.status\nquit\n\" | nc $LIQUIDSOAP_TELNET_HOST $LIQUIDSOAP_TELNET_PORT | head -1 |") {
							$self->{logger}->log(0,"queueRadio() Unable to connect to LIQUIDSOAP telnet port");
							return undef;
						}
						my $line;
						if (defined($line=<$fh_lsts>)) {
							chomp($line);
							$line =~ s/\r//;
							$line =~ s/\n//;
							$self->{logger}->log(3,$line);
							unless ($line =~ /^no source client connected/) {
								if (defined($sChannel) && ($sChannel ne "")) {
									botPrivmsg($self,$sChannel,radioMsg($self,"Live - " . getRadioCurrentSong($self)));
								}
								else {
									botNotice($self,$sNick,radioMsg($self,"Live - " . getRadioCurrentSong($self)));
								}
								$bHarbor = 1;
							}
						}
					}
					else {
						$self->{logger}->log(0,"queueRadio() radio.LIQUIDSOAP_TELNET_HOST not set in " . $self->{config_file});
					}
				}
				
				my $iNbTrack = queueCount($self);
				unless ( $iNbTrack == 0 ) {
					my $sNbTrack = ( $iNbTrack > 1 ? "tracks" : "track" );
					my $line;
					if (defined($LIQUIDSOAP_TELNET_HOST) && ($LIQUIDSOAP_TELNET_HOST ne "")) {
						my $fh_lsts;
						unless (open $fh_lsts, "echo -ne \"queue.queue\nquit\n\" | nc $LIQUIDSOAP_TELNET_HOST $LIQUIDSOAP_TELNET_PORT | head -1 |") {
							$self->{logger}->log(0,"queueRadio() Unable to connect to LIQUIDSOAP telnet port");
							return undef;
						}
						if (defined($line=<$fh_lsts>)) {
							chomp($line);
							$line =~ s/\r//;
							$line =~ s/\n//;
							$self->{logger}->log(3,"queueRadio() $line");
						}
						if ($iNbTrack > 0) {
							if (defined($sChannel) && ($sChannel ne "")) {
								botPrivmsg($self,$sChannel,radioMsg($self,"$iNbTrack $sNbTrack in queue, RID : $line"));
							}
							else {
								botNotice($self,$sNick,radioMsg($self,"$iNbTrack $sNbTrack in queue, RID : $line"));
							}
							my @RIDS = split(/ /,$line);
							my $i;
							for ($i=0;($i<3 && $i<=$#RIDS);$i++) {
								my $fh_lsts;
								unless (open $fh_lsts, "echo -ne \"request.trace " . $RIDS[$i] . "\nquit\n\" | nc $LIQUIDSOAP_TELNET_HOST $LIQUIDSOAP_TELNET_PORT | head -1 |") {
									$self->{logger}->log(0,"queueRadio() Unable to connect to LIQUIDSOAP telnet port");
									return undef;
								}
								my $line;
								if (defined($line=<$fh_lsts>)) {
									chomp($line);
									my $sMsgSong = "";
									if (( $i == 0 ) && (!$bHarbor)) {
										#Remaining time
										my $sRemainingTime = getRadioRemainingTime($self);
										$self->{logger}->log(4,"queueRadio() sRemainingTime = $sRemainingTime");
										my $siSecondsRemaining = int($sRemainingTime);
										my $iMinutesRemaining = int($siSecondsRemaining / 60) ;
										my $iSecondsRemaining = int($siSecondsRemaining - ( $iMinutesRemaining * 60 ));
										$sMsgSong .= String::IRC->new(' - ')->white('black');
										my $sTimeRemaining = "";
										if ( $iMinutesRemaining > 0 ) {
											$sTimeRemaining .= $iMinutesRemaining . " mn";
											if ( $iMinutesRemaining > 1 ) {
												$sTimeRemaining .= "s";
											}
											$sTimeRemaining .= " and ";
										}
										$sTimeRemaining .= $iSecondsRemaining . " sec";
										if ( $iSecondsRemaining > 1 ) {
											$sTimeRemaining .= "s";
										}
										$sTimeRemaining .= " remaining";
										$sMsgSong .= String::IRC->new($sTimeRemaining)->white('black');
									}
									$line =~ s/\r//;
									$line =~ s/\n//;
									$line =~ s/^.*\[\"//;
									$line =~ s/\".*$//;
									$self->{logger}->log(3,"queueRadio() $line");
									my $sFolder = dirname($line);
									my $sFilename = basename($line);
									my $sBaseFilename = basename($sFilename, ".mp3");
									my $sQuery = "SELECT artist,title FROM MP3 WHERE folder=? AND filename=?";
									my $sth = $self->{dbh}->prepare($sQuery);
									unless ($sth->execute($sFolder,$sFilename)) {
										$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
									}
									else {
										if (my $ref = $sth->fetchrow_hashref()) {
											my $title = $ref->{'title'};
											my $artist = $ref->{'artist'};
											if ($i == 0) {
												unless ($bHarbor) {
													if (defined($sChannel) && ($sChannel ne "")) {
														botPrivmsg($self,$sChannel,"» $artist - $title" . $sMsgSong);
													}
													else {
														botNotice($self,$sNick,"» $artist - $title" . $sMsgSong);
													}
												}
												else {
													if (defined($sChannel) && ($sChannel ne "")) {
														botPrivmsg($self,$sChannel,"» $artist - $title");
													}
													else {
														botNotice($self,$sNick,"» $artist - $title");
													}
												}
											}
											else {
												if (defined($sChannel) && ($sChannel ne "")) {
													botPrivmsg($self,$sChannel,"└ $artist - $title");
												}
												else {
													botNotice($self,$sNick,"└ $artist - $title");
												}
											}
										}
										else {
											if ($i == 0) {
												unless ($bHarbor) {
													if (defined($sChannel) && ($sChannel ne "")) {
														botPrivmsg($self,$sChannel,"» $sBaseFilename" . $sMsgSong);
													}
													else {
														botNotice($self,$sNick,"» $sBaseFilename" . $sMsgSong);
													}
												}
												else {
													if (defined($sChannel) && ($sChannel ne "")) {
														botPrivmsg($self,$sChannel,"» $sBaseFilename");
													}
													else {
														botNotice($self,$sNick,"» $sBaseFilename");
													}
												}
											}
											else {
												if (defined($sChannel) && ($sChannel ne "")) {
													botPrivmsg($self,$sChannel,"└ $sBaseFilename");
												}
												else {
													botNotice($self,$sNick,"└ $sBaseFilename");
												}
											}
										}
									}
									$sth->finish;
								}
							}
						}
					}
					else {
						$self->{logger}->log(0,"queueRadio() radio.LIQUIDSOAP_TELNET_HOST not set in " . $self->{config_file});	
					}
				}
				else {
					unless ( $bHarbor ) {
						#Remaining time
						my $sRemainingTime = getRadioRemainingTime($self);
						$self->{logger}->log(4,"queueRadio() sRemainingTime = $sRemainingTime");
						my $siSecondsRemaining = int($sRemainingTime);
						my $iMinutesRemaining = int($siSecondsRemaining / 60) ;
						my $iSecondsRemaining = int($siSecondsRemaining - ( $iMinutesRemaining * 60 ));
						my $sMsgSong .= String::IRC->new(' - ')->white('black');
						my $sTimeRemaining = "";
						if ( $iMinutesRemaining > 0 ) {
							$sTimeRemaining .= $iMinutesRemaining . " mn";
							if ( $iMinutesRemaining > 1 ) {
								$sTimeRemaining .= "s";
							}
							$sTimeRemaining .= " and ";
						}
						$sTimeRemaining .= $iSecondsRemaining . " sec";
						if ( $iSecondsRemaining > 1 ) {
							$sTimeRemaining .= "s";
						}
						$sTimeRemaining .= " remaining";
						$sMsgSong .= String::IRC->new($sTimeRemaining)->white('black');
						if (defined($sChannel) && ($sChannel ne "")) {
							botPrivmsg($self,$sChannel,radioMsg($self,"Global playlist - " . getRadioCurrentSong($self) . $sMsgSong));
						}
						else {
							botNotice($self,$sNick,radioMsg($self,"Global playlist - " . getRadioCurrentSong($self) . $sMsgSong));
						}
					}
				}
				logBot($self,$message,$sChannel,"queue",@tArgs);
			}
			else {
				my $sNoticeMsg = $message->prefix . " queue command attempt (command level [User] for user " . $sMatchingUserHandle . "[" . $iMatchingUserLevel ."])";
				noticeConsoleChan($self,$sNoticeMsg);
				botNotice($self,$sNick,"Your level does not allow you to use this command.");
				return undef;
			}
		}
		else {
			my $sNoticeMsg = $message->prefix . " queue command attempt (user $sMatchingUserHandle is not logged in)";
			noticeConsoleChan($self,$sNoticeMsg);
			botNotice($self,$sNick,"You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
			return undef;
		}
	}
}

# Push a track to the radio queue
sub queuePushRadio(@) {
	my ($self,$sAudioFilename) = @_;
	my $LIQUIDSOAP_TELNET_HOST = $self->{conf}->get('radio.LIQUIDSOAP_TELNET_HOST');
	my $LIQUIDSOAP_TELNET_PORT = $self->{conf}->get('radio.LIQUIDSOAP_TELNET_PORT');
	if (defined($sAudioFilename) && ($sAudioFilename ne "")) {
		unless (isInQueueRadio($self,$sAudioFilename)) {
			if (defined($LIQUIDSOAP_TELNET_HOST) && ($LIQUIDSOAP_TELNET_HOST ne "")) {
				$self->{logger}->log(4,"queuePushRadio() pushing $sAudioFilename to queue");
				my $fh_lsts;
				unless (open $fh_lsts, "echo -ne \"queue.push $sAudioFilename\nquit\n\" | nc $LIQUIDSOAP_TELNET_HOST $LIQUIDSOAP_TELNET_PORT |") {
					$self->{logger}->log(0,"queuePushRadio() Unable to connect to LIQUIDSOAP telnet port");
					return undef;
				}
				my $line;
				while (defined($line=<$fh_lsts>)) {
					chomp($line);
					$self->{logger}->log(3,$line);
				}
				return 1;
			}
			else {
				$self->{logger}->log(0,"playRadio() radio.LIQUIDSOAP_TELNET_HOST not set in " . $self->{config_file});
				return 0;
			}
		}
		else {
			$self->{logger}->log(3,"queuePushRadio() $sAudioFilename already in queue");
			return 0;
		}
	}
	else {
		$self->{logger}->log(4,"queuePushRadio() missing audio file parameter");
		return 0;
	}
}

# Send a next command to the radio
sub nextRadio(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my $LIQUIDSOAP_TELNET_HOST = $self->{conf}->get('radio.LIQUIDSOAP_TELNET_HOST');
	my $LIQUIDSOAP_TELNET_PORT = $self->{conf}->get('radio.LIQUIDSOAP_TELNET_PORT');
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Master")) {
				if (defined($LIQUIDSOAP_TELNET_HOST) && ($LIQUIDSOAP_TELNET_HOST ne "")) {
					my $fh_lsts;
					unless (open $fh_lsts, "echo -ne \"radio(dot)mp3.skip\nquit\n\" | nc $LIQUIDSOAP_TELNET_HOST $LIQUIDSOAP_TELNET_PORT |") {
						$self->{logger}->log(0,"queueRadio() Unable to connect to LIQUIDSOAP telnet port");
						return undef;
					}
					my $line;
					while (defined($line=<$fh_lsts>)) {
						chomp($line);
						$self->{logger}->log(3,$line);
					}
					logBot($self,$message,$sChannel,"next",@tArgs);
					sleep(6);
					displayRadioCurrentSong($self,$message,$sNick,$sChannel,@tArgs);
				}
				else {
					$self->{logger}->log(0,"nextRadio() radio.LIQUIDSOAP_TELNET_HOST not set in " . $self->{config_file});
				}
			}
			else {
				my $sNoticeMsg = $message->prefix . " next command attempt (command level [Administrator] for user " . $sMatchingUserHandle . "[" . $iMatchingUserLevel ."])";
				noticeConsoleChan($self,$sNoticeMsg);
				botNotice($self,$sNick,"Your level does not allow you to use this command.");
				return undef;
			}
		}
		else {
			my $sNoticeMsg = $message->prefix . " next command attempt (user $sMatchingUserHandle is not logged in)";
			noticeConsoleChan($self,$sNoticeMsg);
			botNotice($self,$sNick,"You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
			return undef;
		}
	}
}

# Display the current song on the radio
sub radioMsg(@) {
	my ($self,$sText) = @_;
	my $sMsgSong = "";
	my $RADIO_HOSTNAME = $self->{conf}->get('radio.RADIO_HOSTNAME');
	my $RADIO_PORT     = $self->{conf}->get('radio.RADIO_PORT');
	my $RADIO_URL      = $self->{conf}->get('radio.RADIO_URL');
	
	$sMsgSong .= String::IRC->new('[ ')->white('black');
	if ( $RADIO_PORT == 443 ) {
		$sMsgSong .= String::IRC->new("https://$RADIO_HOSTNAME/$RADIO_URL")->orange('black');
	}
	else {
		$sMsgSong .= String::IRC->new("http://$RADIO_HOSTNAME:$RADIO_PORT/$RADIO_URL")->orange('black');
	}
	$sMsgSong .= String::IRC->new(' ] ')->white('black');
	$sMsgSong .= String::IRC->new(' - ')->white('black');
	$sMsgSong .= String::IRC->new(' [ ')->orange('black');
	$sMsgSong .= String::IRC->new($sText)->white('black');
	$sMsgSong .= String::IRC->new(' ]')->orange('black');
	return($sMsgSong);
}

# Ransomly play a track from the radio library
sub rplayRadio(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my $incomingDir = $self->{conf}->get('radio.YOUTUBEDL_INCOMING');
	my $LIQUIDSOAP_TELNET_HOST = $self->{conf}->get('radio.LIQUIDSOAP_TELNET_HOST');
	my $LIQUIDSOAP_TELNET_PORT = $self->{conf}->get('radio.LIQUIDSOAP_TELNET_PORT');

	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"User")) {
				my $sHarbor = getRadioHarbor($self);
				my $bRadioLive = 0;
				if (defined($sHarbor) && ($sHarbor ne "")) {
					$self->{logger}->log(3,$sHarbor);
					$bRadioLive = isRadioLive($self,$sHarbor);
				}
				if ($bRadioLive) {
					if (defined($sChannel) && ($sChannel ne "")) {
						botPrivmsg($self,$sChannel,"($sNick radio rplay) Cannot queue requests while radio is live");
					}
					else {
						botNotice($self,$sNick,"($sNick radio rplay) Cannot queue requests while radio is live");
					}
					return undef;
				}
				if (defined($LIQUIDSOAP_TELNET_HOST) && ($LIQUIDSOAP_TELNET_HOST ne "")) {
					if (defined($tArgs[0]) && ($tArgs[0] eq "user") && defined($tArgs[1]) && ($tArgs[1] ne "")) {
						my $id_user = getIdUser($self,$tArgs[1]);
						unless (defined($id_user)) {
							if (defined($sChannel) && ($sChannel ne "")) {
								botPrivmsg($self,$sChannel,"($sNick radio play) Unknown user " . $tArgs[0]);
							}
							else {
								botNotice($self,$sNick,"($sNick radio play) Unknown user " . $tArgs[0]);
							}
							return undef;
						}
						my $sQuery = "SELECT id_mp3,id_youtube,artist,title,folder,filename FROM MP3 WHERE id_user=? ORDER BY RAND() LIMIT 1";
						my $sth = $self->{dbh}->prepare($sQuery);
						unless ($sth->execute($id_user)) {
							$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
						}
						else {	
							if (my $ref = $sth->fetchrow_hashref()) {
								my $id_mp3 = $ref->{'id_mp3'};
								my $id_youtube = $ref->{'id_youtube'};
								my $ytDestinationFile = $ref->{'folder'} . "/" . $ref->{'filename'};
								my $rPush = queuePushRadio($self,$ytDestinationFile);
								if (defined($rPush) && $rPush) {
									my $id_youtube = $ref->{'id_youtube'};
									my $artist = ( defined($ref->{'artist'}) ? $ref->{'artist'} : "Unknown");
									my $title = ( defined($ref->{'title'}) ? $ref->{'title'} : "Unknown");
									my $duration = 0;
									my $sMsgSong = "$artist - $title";
									if (defined($id_youtube) && ($id_youtube ne "")) {
										($duration,$sMsgSong) = getYoutubeDetails($self,"https://www.youtube.com/watch?v=$id_youtube");
										if (defined($sChannel) && ($sChannel ne "")) {
											botPrivmsg($self,$sChannel,"($sNick radio play user " . $tArgs[1] . ") (Library ID : $id_mp3 YTID : $id_youtube) / $sMsgSong - https://www.youtube.com/watch?v=$id_youtube / Queued");
										}
										else {
											botNotice($self,$sNick,"($sNick radio play user " . $tArgs[1] . ") (Library ID : $id_mp3 YTID : $id_youtube) / $sMsgSong - https://www.youtube.com/watch?v=$id_youtube / Queued");
										}
									}
									else {
										if (defined($sChannel) && ($sChannel ne "")) {
											botPrivmsg($self,$sChannel,"($sNick radio play user " . $tArgs[1] . ") (Library ID : $id_mp3) / $artist - $title / Queued");
										}
										else {
											botNotice($self,$sNick,"($sNick radio play user " . $tArgs[1] . ") (Library ID : $id_mp3) / $artist - $title / Queued");
										}
									}
									logBot($self,$message,$sChannel,"rplay",@tArgs);
								}
								else {
									$self->{logger}->log(3,"rplayRadio() user / could not queue queuePushRadio() $ytDestinationFile");	
									if (defined($sChannel) && ($sChannel ne "")) {
										botPrivmsg($self,$sChannel,"($sNick radio rplay / user / could not queue)");
									}
									else {
										botNotice($self,$sNick,"($sNick radio rplay / user / could not queue)");
									}
									return undef;
								}
							}
							else {
								if (defined($sChannel) && ($sChannel ne "")) {
									botPrivmsg($self,$sChannel,"($sNick radio play user " . $tArgs[1] . " / no track found)");
								}
								else {
									botNotice($self,$sNick,"($sNick radio play user " . $tArgs[1] . " / no track found)");
								}
							}
						}
						$sth->finish;
					}
					elsif (defined($tArgs[0]) && ($tArgs[0] eq "artist") && defined($tArgs[1]) && ($tArgs[1] ne "")) {
						shift @tArgs;
						my $sText = join (" ",@tArgs);
						my $sQuery = "SELECT id_mp3,id_youtube,artist,title,folder,filename FROM MP3 WHERE artist like ? ORDER BY RAND() LIMIT 1";
						my $sth = $self->{dbh}->prepare($sQuery);
						unless ($sth->execute($sText)) {
							$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
						}
						else {	
							if (my $ref = $sth->fetchrow_hashref()) {
								my $id_mp3 = $ref->{'id_mp3'};
								my $id_youtube = $ref->{'id_youtube'};
								my $ytDestinationFile = $ref->{'folder'} . "/" . $ref->{'filename'};
								my $rPush = queuePushRadio($self,$ytDestinationFile);
								if (defined($rPush) && $rPush) {
									my $id_youtube = $ref->{'id_youtube'};
									my $artist = ( defined($ref->{'artist'}) ? $ref->{'artist'} : "Unknown");
									my $title = ( defined($ref->{'title'}) ? $ref->{'title'} : "Unknown");
									my $duration = 0;
									my $sMsgSong = "$artist - $title";
									if (defined($id_youtube) && ($id_youtube ne "")) {
										($duration,$sMsgSong) = getYoutubeDetails($self,"https://www.youtube.com/watch?v=$id_youtube");
										if (defined($sChannel) && ($sChannel ne "")) {
											botPrivmsg($self,$sChannel,"($sNick radio play artist " . $sText . ") (Library ID : $id_mp3 YTID : $id_youtube) / $sMsgSong - https://www.youtube.com/watch?v=$id_youtube / Queued");
										}
										else {
											botNotice($self,$sNick,"($sNick radio play artist " . $sText . ") (Library ID : $id_mp3 YTID : $id_youtube) / $sMsgSong - https://www.youtube.com/watch?v=$id_youtube / Queued");
										}
									}
									else {
										if (defined($sChannel) && ($sChannel ne "")) {
											botPrivmsg($self,$sChannel,"($sNick radio play artist " . $sText . ") (Library ID : $id_mp3) / $artist - $title / Queued");
										}
										else {
											botNotice($self,$sNick,"($sNick radio play artist " . $sText . ") (Library ID : $id_mp3) / $artist - $title / Queued");
										}
									}
									logBot($self,$message,$sChannel,"rplay",@tArgs);
								}
								else {
									$self->{logger}->log(3,"rplayRadio() artist / could not queue queuePushRadio() $ytDestinationFile");
									if (defined($sChannel) && ($sChannel ne "")) {
										botPrivmsg($self,$sChannel,"($sNick radio rplay / artist / could not queue)");
									}
									else {
										botNotice($self,$sNick,"($sNick radio rplay / artist / could not queue)");
									}
									
									return undef;
								}
							}
							else {
								if (defined($sChannel) && ($sChannel ne "")) {
									botPrivmsg($self,$sChannel,"($sNick radio play user " . $tArgs[1] . " / no track found)");
								}
								else {
									botNotice($self,$sNick,"($sNick radio play user " . $tArgs[1] . " / no track found)");
								}
							}
						}
						$sth->finish;
					}
					elsif (defined($tArgs[0]) && ($tArgs[0] ne "")) {
						my $sText = join(" ", @tArgs);        # kept for display in IRC messages
						my $sSearch = join("%", @tArgs);
						$sSearch =~ s/\s+/%/g;
						$sSearch =~ s/%+/%/g;
						my $sPattern = "%" . $sSearch . "%"; # parameterized — no SQL injection
						my $sQuery = "SELECT id_mp3, id_youtube, artist, title, folder, filename"
						          . " FROM MP3 WHERE CONCAT(artist, title) LIKE ?"
						          . " ORDER BY RAND() LIMIT 1";
						$self->{logger}->log(4,"rplayRadio() Search: $sPattern");
						my $sth = $self->{dbh}->prepare($sQuery);
						unless ($sth->execute($sPattern)) {
							$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
						}
						else {	
							if (my $ref = $sth->fetchrow_hashref()) {
								my $id_mp3 = $ref->{'id_mp3'};
								my $id_youtube = $ref->{'id_youtube'};
								my $ytDestinationFile = $ref->{'folder'} . "/" . $ref->{'filename'};
								my $rPush = queuePushRadio($self,$ytDestinationFile);
								if (defined($rPush) && $rPush) {
									my $id_youtube = $ref->{'id_youtube'};
									my $artist = ( defined($ref->{'artist'}) ? $ref->{'artist'} : "Unknown");
									my $title = ( defined($ref->{'title'}) ? $ref->{'title'} : "Unknown");
									my $duration = 0;
									my $sMsgSong = "$artist - $title";
									if (defined($id_youtube) && ($id_youtube ne "")) {
										($duration,$sMsgSong) = getYoutubeDetails($self,"https://www.youtube.com/watch?v=$id_youtube");
										if (defined($sChannel) && ($sChannel ne "")) {
											botPrivmsg($self,$sChannel,"($sNick radio play " . $sText . ") (Library ID : $id_mp3 YTID : $id_youtube) / $sMsgSong - https://www.youtube.com/watch?v=$id_youtube / Queued");
										}
										else {
											botNotice($self,$sNick,"($sNick radio play " . $sText . ") (Library ID : $id_mp3 YTID : $id_youtube) / $sMsgSong - https://www.youtube.com/watch?v=$id_youtube / Queued");
										}
									}
									else {
										if (defined($sChannel) && ($sChannel ne "")) {
											botPrivmsg($self,$sChannel,"($sNick radio play " . $sText . ") (Library ID : $id_mp3) / $artist - $title / Queued");
										}
										else {
											botNotice($self,$sNick,"($sNick radio play " . $sText . ") (Library ID : $id_mp3) / $artist - $title / Queued");
										}
									}
									logBot($self,$message,$sChannel,"rplay",@tArgs);
								}
								else {
									$self->{logger}->log(3,"rplayRadio() could not queue queuePushRadio() $ytDestinationFile");
									if (defined($sChannel) && ($sChannel ne "")) {
										botPrivmsg($self,$sChannel,"($sNick radio rplay / could not queue)");
									}
									else {
										botNotice($self,$sNick,"($sNick radio rplay / could not queue)");
									}
									return undef;
								}
							}
							else {
								if (defined($sChannel) && ($sChannel ne "")) {
									botPrivmsg($self,$sChannel,"($sNick radio play $sText / no track found)");
								}
								else {
									botNotice($self,$sNick,"($sNick radio play $sText / no track found)");
								}
							}
						}
						$sth->finish;
					}
					else {
						my $sQuery = "SELECT id_mp3,id_youtube,artist,title,folder,filename FROM MP3 ORDER BY RAND() LIMIT 1";
						my $sth = $self->{dbh}->prepare($sQuery);
						unless ($sth->execute()) {
							$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
						}
						else {	
							if (my $ref = $sth->fetchrow_hashref()) {
								my $id_mp3 = $ref->{'id_mp3'};
								my $id_youtube = $ref->{'id_youtube'};
								my $ytDestinationFile = $ref->{'folder'} . "/" . $ref->{'filename'};
								my $rPush = queuePushRadio($self,$ytDestinationFile);
								if (defined($rPush) && $rPush) {
									my $id_youtube = $ref->{'id_youtube'};
									my $artist = ( defined($ref->{'artist'}) ? $ref->{'artist'} : "Unknown");
									my $title = ( defined($ref->{'title'}) ? $ref->{'title'} : "Unknown");
									my $duration = 0;
									my $sMsgSong = "$artist - $title";
									if (defined($id_youtube) && ($id_youtube ne "")) {
										($duration,$sMsgSong) = getYoutubeDetails($self,"https://www.youtube.com/watch?v=$id_youtube");
										if (defined($sChannel) && ($sChannel ne "")) {
											botPrivmsg($self,$sChannel,"($sNick radio play) (Library ID : $id_mp3 YTID : $id_youtube) / $sMsgSong - https://www.youtube.com/watch?v=$id_youtube / Queued");
										}
										else {
											botNotice($self,$sNick,"($sNick radio play) (Library ID : $id_mp3 YTID : $id_youtube) / $sMsgSong - https://www.youtube.com/watch?v=$id_youtube / Queued");
										}
									}
									else {
										if (defined($sChannel) && ($sChannel ne "")) {
											botPrivmsg($self,$sChannel,"($sNick radio play) (Library ID : $id_mp3) / $artist - $title / Queued");
										}
										else {
											botNotice($self,$sNick,"($sNick radio play) (Library ID : $id_mp3) / $artist - $title / Queued");
										}
									}
									logBot($self,$message,$sChannel,"rplay",@tArgs);
								}
								else {
									$self->{logger}->log(3,"rplayRadio() could not queue queuePushRadio() $ytDestinationFile");	
									if (defined($sChannel) && ($sChannel ne "")) {
										botPrivmsg($self,$sChannel,"($sNick radio rplay / could not queue)");
									}
									else {
										botNotice($self,$sNick,"($sNick radio rplay / could not queue)");
									}
									return undef;
								}
							}
						}
						$sth->finish;
					}
				}
				else {
					$self->{logger}->log(0,"rplayRadio() radio.LIQUIDSOAP_TELNET_HOST not set in " . $self->{config_file});
				}
			}
			else {
				my $sNoticeMsg = $message->prefix . " rplay command attempt (command level [Administrator] for user " . $sMatchingUserHandle . "[" . $iMatchingUserLevel ."])";
				noticeConsoleChan($self,$sNoticeMsg);
				botNotice($self,$sNick,"Your level does not allow you to use this command.");
				return undef;
			}
		}
		else {
			my $sNoticeMsg = $message->prefix . " rplay command attempt (user $sMatchingUserHandle is not logged in)";
			noticeConsoleChan($self,$sNoticeMsg);
			botNotice($self,$sNick,"You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
			return undef;
		}
	}
}

# Context-based MP3 command.
# Features:
#   - mp3 count        : show total number of MP3s in local library
#   - mp3 id <id>      : show info for a specific library ID
#   - mp3 <search...>  : search by artist/title, show first match + up to 10 IDs
sub getHarBorId(@) {
	my ($self) = @_;
	my $LIQUIDSOAP_TELNET_HOST = $self->{conf}->get('radio.LIQUIDSOAP_TELNET_HOST');
	my $LIQUIDSOAP_TELNET_PORT = $self->{conf}->get('radio.LIQUIDSOAP_TELNET_PORT');
	if (defined($LIQUIDSOAP_TELNET_HOST) && ($LIQUIDSOAP_TELNET_HOST ne "")) {
		my $fh_lsts;
		unless (open $fh_lsts, "echo -ne \"help\nquit\n\" | nc $LIQUIDSOAP_TELNET_HOST $LIQUIDSOAP_TELNET_PORT | grep harbor | grep status | awk '{print \$2}' | awk -F'.' {'print \$1}' | awk -F'_' '{print \$2}' |") {
			$self->{logger}->log(0,"getHarBorId() Unable to connect to LIQUIDSOAP telnet port");
			return undef;
		}
		my $line;
		if (defined($line=<$fh_lsts>)) {
			chomp($line);
			$self->{logger}->log(3,$line);
			return $line;
		}
		else {
			$self->{logger}->log(3,"getHarBorId() No output");
		}
	}
	else {
		$self->{logger}->log(0,"getHarBorId() radio.LIQUIDSOAP_TELNET_HOST not set in " . $self->{config_file});
	}
	return undef;
}

# qlog: search CHANNEL_LOG for a pattern, grep-style
# Syntax:
#   qlog [-n nick] [#channel] <word1> <word2> ...
# - If -n nick is given, restrict search to that nick.
# - If #channel is given, search that channel (defaults to current channel).
# - Shows up to 5 most recent matches, first one displayed first.
sub radioPub(@) {
	my ($self,$message,$sNick,undef,@tArgs) = @_;
	
	# Check channels with chanset +RadioPub
	if (defined($self->{conf}->get('radio.RADIO_HOSTNAME'))) {	
		my $sQuery = "SELECT CHANNEL.name FROM CHANNEL JOIN CHANNEL_SET ON CHANNEL_SET.id_channel = CHANNEL.id_channel JOIN CHANSET_LIST ON CHANSET_LIST.id_chanset_list = CHANNEL_SET.id_chanset_list WHERE CHANSET_LIST.chanset = 'RadioPub'";
		my $sth = $self->{dbh}->prepare($sQuery);
		unless ($sth->execute()) {
			$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
		}
		else {
			while (my $ref = $sth->fetchrow_hashref()) {
				my $curChannel = $ref->{'name'};
				$self->{logger}->log(4,"RadioPub on $curChannel");
				my $currentTitle = getRadioCurrentSong($self);
				if ( $currentTitle ne "Unknown" ) {
					displayRadioCurrentSong($self,undef,undef,$curChannel,undef);
				}
				else {
					$self->{logger}->log(4,"RadioPub skipped for $curChannel, title is $currentTitle");
				}
			}
		}
		$sth->finish;
	}
}

# Context-based: Delete a user from the database (Master only)

1;
