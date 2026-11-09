package Mediabot::IRC::Sender;

use strict;
use warnings;
use utf8;
use Encode qw(encode);
use Time::HiRes ();
use Scalar::Util qw(refaddr);

# Internal implementation reached by Helpers. Callers use IRC::Output or the
# legacy Helpers facade; these bodies are not exported. Resolve the existing
# policy/integration hooks dynamically so overrides remain effective.
sub _sanitize_irc_text { return Mediabot::Helpers::_sanitize_irc_text(@_); }
sub _is_irc_channel_target { return Mediabot::Helpers::_is_irc_channel_target(@_); }
sub _redact_irc_service_secret_for_log { return Mediabot::Helpers::_redact_irc_service_secret_for_log(@_); }
sub _split_text_for_irc { return Mediabot::Helpers::_split_text_for_irc(@_); }
sub getIdChansetList { return Mediabot::Helpers::getIdChansetList(@_); }
sub getIdChannelSet { return Mediabot::Helpers::getIdChannelSet(@_); }
sub checkAntiFlood { return Mediabot::Helpers::checkAntiFlood(@_); }
sub noticeConsoleChan { return Mediabot::Helpers::noticeConsoleChan(@_); }
sub logBotAction { return Mediabot::Helpers::logBotAction(@_); }
sub _defer_flooded_send { return Mediabot::Helpers::_defer_flooded_send(@_); }

# Publish only a complete successful read. Message and ACTION output share
# the same cache and fallback policy, so a refresh cannot erase known rules.
sub _badwords_for_channel {
    my ($self, $target) = @_;
    my $now = time();
    # Match the channel registry's identity without changing the wire target
    # or SQL bind. Different display spellings must share confirmed rules.
    my $key = lc($target);
    my $cache = $self->{_badword_cache}{$key};
    return $cache->{words} // []
        if $cache && ($now - ($cache->{ts} // 0)) <= 300;

    my ($sth, @words);
    my $complete = eval {
        $sth = $self->{dbh}->prepare(
            "SELECT badword FROM CHANNEL"
            . " JOIN BADWORDS ON BADWORDS.id_channel = CHANNEL.id_channel"
            . " WHERE CHANNEL.name = ?"
        ) or die "badword_prepare\n";
        $sth->execute($target) or die "badword_execute\n";
        while (my $row = $sth->fetchrow_hashref) {
            die "badword_row\n" unless ref($row) eq 'HASH';
            next unless defined $row->{badword};
            die "badword_value\n" if ref($row->{badword});
            push @words, lc($row->{badword});
        }
        die "badword_fetch\n" if $sth->err;
        1;
    };
    # Capture success before finish(), which may clear a driver's error flag.
    eval { $sth->finish } if $sth;
    if ($complete) {
        $self->{_badword_cache}{$key} = { ts => $now, words => \@words };
        return \@words;
    }

    eval { $self->{logger}->log(1, 'Outgoing badword lookup failed; last confirmed rules retained')
        if $self->{logger} };
    eval { $self->{metrics}->inc('mediabot_db_query_errors_total') if $self->{metrics} };
    # Preserve the historical diagnostic-and-send behavior if no rules have
    # ever been loaded. Never cache that failure or a partial list as success;
    # the next send retries, while an existing cache keeps its original age.
    return $cache ? ($cache->{words} // []) : [];
}

# A timed ping is a fixed ASCII reply, never a caller-supplied callback.
# Render after AntiFlood and the badword read, before filtering/history/wire.
sub _timed_ping_text {
    my ($text, $options) = @_;
    return $text unless $text eq 'POng ! [0.000s]' && ref($options) eq 'HASH';
    my $started = $options->{ping_started_at};
    return $text unless defined($started) && !ref($started) && length($started) <= 32
        && $started =~ /\A[0-9]+(?:\.[0-9]+)?\z/;
    my $elapsed = Time::HiRes::clock_gettime(Time::HiRes::CLOCK_MONOTONIC()) - $started;
    $elapsed = 0 if $elapsed < 0;
    return sprintf('POng ! [%.3fs]', $elapsed);
}

# Only callers that need to acknowledge durable work request write Futures.
# Leave the ordinary send in void context: the IRC stream then allocates none.
sub _write_irc_chunk {
    my ($irc, $method, $target, $text, $options) = @_;
    if (ref($options) eq 'HASH' && ref($options->{write_futures}) eq 'ARRAY') {
        push @{ $options->{write_futures} }, scalar $irc->$method(target => $target, text => $text);
    }
    else {
        $irc->$method(target => $target, text => $text);
    }
    return;
}

sub _flood_filter_source {
    my ($self, $target, $options) = @_;
    return '' unless ref($options) eq 'HASH' && defined($options->{flood_source_text})
        && !ref($options->{flood_source_text});
    my $source = _sanitize_irc_text($options->{flood_source_text});
    my $id = getIdChansetList($self, 'NoColors');
    if (defined($id) && length($id)) {
        my $enabled = getIdChannelSet($self, $target, $id);
        $source =~ s/\cC\d{1,2}(?:,\d{1,2})?|[\cC\cB\cI\cU\cR\cO]//g
            if defined($enabled) && length($enabled);
    }
    return lc $source;
}

sub _has_older_flood_output {
    my ($self, $target) = @_;
    my $queues = $self->{_flood_outq} or return 0;
    my $q = $queues->{$target} or return 0;
    return @{$q->{items}} && (refaddr($self->{_flood_draining}) // 0) != refaddr($q);
}

sub botPrivmsg {
    my ($self, $sTo, $sMsg, $send_options) = @_;

    return unless defined($sTo);

    # Guard before any formatting/chanset/badword work. Some callers may fail
    # upstream and pass an empty payload; do not let that create noisy
    # uninitialized warnings in NoColors/badword/log paths.
    unless (defined($sMsg) && $sMsg ne '') {
        $self->{logger}->log(0, "botPrivmsg() ERROR no message specified to send to target");
        return;
    }

    # mb386-B1: sanitise before logs, badword filtering, CHANNEL_LOG history
    # and wire splitting so every representation is identical and log-line
    # injection through CR/LF/NUL is impossible.
    $sMsg = _sanitize_irc_text($sMsg);

    my $eventtype = "public";

    if (_is_irc_channel_target($sTo)) {
        # Channel mode

        # NoColors chanset check
        my $id_chanset_list = getIdChansetList($self, "NoColors");
        if (defined($id_chanset_list) && $id_chanset_list ne "") {
            $self->{logger}->log(4, "botPrivmsg() check chanset NoColors, id_chanset_list = $id_chanset_list");
            my $id_channel_set = getIdChannelSet($self, $sTo, $id_chanset_list);
            if (defined($id_channel_set) && $id_channel_set ne "") {
                $self->{logger}->log(4, "botPrivmsg() channel $sTo has chanset +NoColors");
                $sMsg =~ s/\cC\d{1,2}(?:,\d{1,2})?|[\cC\cB\cI\cU\cR\cO]//g;
            }
        }

        # AntiFlood chanset check
        $id_chanset_list = getIdChansetList($self, "AntiFlood");
        if (defined($id_chanset_list) && $id_chanset_list ne "") {
            $self->{logger}->log(4, "botPrivmsg() check chanset AntiFlood, id_chanset_list = $id_chanset_list");
            my $id_channel_set = getIdChannelSet($self, $sTo, $id_chanset_list);
            if (defined($id_channel_set) && $id_channel_set ne "") {
                $self->{logger}->log(4, "botPrivmsg() channel $sTo has chanset +AntiFlood");
                # mb568-B1: differe au lieu de jeter
                my @af_chunks = _split_text_for_irc($sMsg, 400);
                my $af_cost = @af_chunks || 1;
                if (_has_older_flood_output($self, $sTo) || checkAntiFlood($self, $sTo, $af_cost)) {
                    # Contextual replies expire with their conversation. Other
                    # callers keep the historical bounded deferred-send queue.
                    return 0 if ref($send_options) eq 'HASH' && $send_options->{no_defer};
                    return _defer_flooded_send($self, 'privmsg', $sTo, $sMsg, $send_options);
                }
            }
        }

        # Badword filtering — B1/A1: cache per channel (TTL 5 min)
        # Avoids one SQL query per outgoing message on busy channels.
        {
            my $words = _badwords_for_channel($self, $sTo);
            $sMsg = _timed_ping_text($sMsg, $send_options);

            my $msg_lc = lc($sMsg);
            my $source_lc = _flood_filter_source($self, $sTo, $send_options);
            for my $bw (@$words) {
                if (index($msg_lc, $bw) != -1 || index($source_lc, $bw) != -1) {
                    # mb387-B1: a rejected payload was never sent, therefore it
                    # must not appear as a normal LIVE line or CHANNEL_LOG event.
                    # Keep the explicit operational diagnostic only.
                    noticeConsoleChan($self, "Badword : $bw blocked on channel $sTo ($sMsg)");
                    $self->{logger}->log(3, "Badword : $bw blocked on channel $sTo ($sMsg)");
                    return;
                }
            }
            logBotAction($self, undef, $eventtype, $self->{irc}->nick_folded, $sTo, $sMsg);
        }

        # mb387-B1: LIVE means accepted for wire delivery. Log it only after
        # AntiFlood and badword checks have both allowed the message.
        $self->{logger}->log(0, "[LIVE] $sTo:<" . $self->{irc}->nick_folded . "> $sMsg");
    } else {
        # Private message
        $eventtype = "private";
        # mb130-B2: redact password in log for NickServ-like service commands.
        # Avant ce fix, on_login() faisait botPrivmsg("NickServ", "identify
        # mypass") ou botPrivmsg("X", "login user pass") qui etait loggue
        # textuellement au niveau 0 (toujours actif) -> password Undernet/
        # Libera/etc. en clair dans le log file. Tout admin avec acces
        # lecture au log pouvait recuperer les credentials.
        my $log_msg = _redact_irc_service_secret_for_log($sMsg);
        $self->{logger}->log(0, "-> *$sTo* $log_msg");
        # A5: encoding, sanitisation and truncation applied uniformly below
    }

    # Send actual message — shared path for channel and private (A5)
    if (defined($sMsg) && $sMsg ne "") {
        # Split while the string is still a Perl character string so
        # substr() never cuts a multi-byte character in half.
        # IRC hard limit is ~512 bytes. mb325-B1: split on a byte budget (not a
        # character count) so accented text and emojis can never push a chunk
        # past the wire limit; the encode happens per chunk below. 400 bytes
        # keeps the historical headroom for prefix/target overhead.
        my @chunks = _split_text_for_irc($sMsg, 400);
        @chunks = ($sMsg) unless @chunks;

        # AA14: log when message was split for debug
        if (scalar(@chunks) > 1) {
            $self->{logger}->log(4, 'botPrivmsg: split into '
                . scalar(@chunks) . ' chunks for ' . ($sTo // '?'));
        }
        for my $chunk (@chunks) {
            next unless defined($chunk) && $chunk ne '';
            $chunk = encode("UTF-8", $chunk) if utf8::is_utf8($chunk);
            $self->{metrics}->inc('mediabot_privmsg_out_total') if $self->{metrics};
            _write_irc_chunk($self->{irc}, 'do_PRIVMSG', $sTo, $chunk, $send_options);
        }
    } else {
        $self->{logger}->log(0, "botAction() ERROR no message specified to send to target");
        return;
    }

    # mb693: callers that need durable acknowledgement (RSS auto-polling) may
    # mark work complete only after the normal output path accepted the message
    # for immediate or AntiFlood-queued delivery. Rejected badword/invalid paths
    # return earlier and therefore stay unacknowledged.
    if (_is_irc_channel_target($sTo) && $self->{wit_dryrun}) {
        eval { $self->{wit_dryrun}->note_bot_pressure($sTo); };
    }
    if (_is_irc_channel_target($sTo) && $self->{spark_observer}) {
        eval { $self->{spark_observer}->note_bot_pressure($sTo); };
    }
    return 1;
}

sub botAction {
	my ($self,$sTo,$sMsg,$send_options) = @_;
	if (defined($sTo)) {
		unless (defined($sMsg) && $sMsg ne "") {
			$self->{logger}->log(0,"botAction() ERROR no message specified to send to target");
			return;
		}

		# mb386-B1: keep logs, CHANNEL_LOG history and the wire payload on the
		# same sanitised text. This runs before channel/private classification.
		$sMsg = _sanitize_irc_text($sMsg);

		my $eventtype = "public";
		if (_is_irc_channel_target($sTo)) {
				my $id_chanset_list = getIdChansetList($self,"NoColors");
				if (defined($id_chanset_list) && ($id_chanset_list ne "")) {
					$self->{logger}->log(4,"botAction() check chanset NoColors, id_chanset_list = $id_chanset_list");
					my $id_channel_set = getIdChannelSet($self,$sTo,$id_chanset_list);
					if (defined($id_channel_set) && ($id_channel_set ne "")) {
						$self->{logger}->log(4,"botAction() channel $sTo has chanset +NoColors");
						$sMsg =~ s/\cC\d{1,2}(?:,\d{1,2})?|[\cC\cB\cI\cU\cR\cO]//g;
					}
				}
				$id_chanset_list = getIdChansetList($self,"AntiFlood");
				if (defined($id_chanset_list) && ($id_chanset_list ne "")) {
					$self->{logger}->log(4,"botAction() check chanset AntiFlood, id_chanset_list = $id_chanset_list");
					my $id_channel_set = getIdChannelSet($self,$sTo,$id_chanset_list);
					if (defined($id_channel_set) && ($id_channel_set ne "")) {
						$self->{logger}->log(4,"botAction() channel $sTo has chanset +AntiFlood");
						my @af_chunks = _split_text_for_irc($sMsg, 391);
                        my $af_cost = @af_chunks || 1;
                        if (_has_older_flood_output($self, $sTo) || checkAntiFlood($self,$sTo,$af_cost)) {
							# mb568-B1: differe au lieu de jeter
							return _defer_flooded_send($self,'action',$sTo,$sMsg,$send_options);
						}
					}
				}
                # Use the same confirmed rules as PRIVMSG output.
                {
                    my $words = _badwords_for_channel($self, $sTo);

					my $sMsgLc = lc $sMsg;
                    my $source_lc = _flood_filter_source($self, $sTo, $send_options);
					for my $bw (@$words) {
						if (index($sMsgLc, $bw) != -1 || index($source_lc, $bw) != -1) {
							# mb387-B1: rejected ACTIONs are diagnostics, not sent
							# conversation events. Do not forge LIVE/history entries.
							noticeConsoleChan($self,"Badword : $bw blocked on channel $sTo ($sMsg)");
							$self->{logger}->log(3,"Badword : $bw blocked on channel $sTo ($sMsg)");
							return;
						}
					}

					logBotAction($self,undef,$eventtype,$self->{irc}->nick_folded,$sTo,$sMsg);
				}

				# mb387-B1: only accepted ACTIONs are represented as LIVE output.
				$self->{logger}->log(0,"[LIVE] $sTo:<" . $self->{irc}->nick_folded . "> $sMsg");
		}
		else {
			$eventtype = "private";
			my $log_msg = _redact_irc_service_secret_for_log($sMsg);
			$self->{logger}->log(0,"-> *$sTo* $log_msg");
		}
		if (defined($sMsg) && ($sMsg ne "")) {
			# mb386-B1 performs CR/LF/NUL normalisation before every log/history
			# path; only byte-aware ACTION splitting remains here.

			# mb327-B1: découpe les ACTIONs longues sur le même budget d'octets que
			# botPrivmsg/botNotice (helper partagé _split_text_for_irc). Sans ça, un
			# /me accentué/emoji dépassait ~512 octets : le serveur tronquait la ligne
			# ET perdait le \1 final, corrompant le CTCP ACTION. Le budget texte est
			# réduit de l'overhead du wrapper "\1ACTION \1" (9 octets) pour que la
			# ligne émise reste dans la même enveloppe qu'un PRIVMSG. Chaque chunk est
			# ré-emballé en ACTION distinct. Le découpage se fait avant l'encodage
			# UTF-8 (sur la chaîne de caractères) pour ne jamais couper un multi-octets.
			my $action_overhead = length("\1ACTION \1");   # 9
			my @chunks = _split_text_for_irc($sMsg, 400 - $action_overhead);
			@chunks = ($sMsg) unless @chunks;
			for my $chunk (@chunks) {
				next unless defined($chunk) && $chunk ne "";
				my $payload = utf8::is_utf8($chunk) ? encode("UTF-8", $chunk) : $chunk;
				$self->{irc}->do_PRIVMSG( target => $sTo, text => "\1ACTION $payload\1" );
			}
			if (_is_irc_channel_target($sTo) && $self->{spark_observer}) {
				eval { $self->{spark_observer}->note_bot_pressure($sTo); };
			}
			if (_is_irc_channel_target($sTo) && $self->{wit_dryrun}) {
				eval { $self->{wit_dryrun}->note_bot_pressure($sTo); };
			}
		}
		else {
			$self->{logger}->log(0,"botPrivmsg() ERROR no message specified to send to target");
		}
	}
	else {
		$self->{logger}->log(0,"botAction() ERROR no target specified to send $sMsg");
	}
}

sub botNotice {
    my ($self, $target, $text, $send_options) = @_;

    # Sanity check: both target and message must be defined and non-empty
    unless (defined $target && $target ne '') {
        $self->{logger}->log(4, "[DEBUG] botNotice() aborted: target is undefined or empty");
        return;
    }
    unless (defined $text && $text ne '') {
        $self->{logger}->log(4, "[DEBUG] botNotice() aborted: text is undefined or empty");
        return;
    }

    # Keep NOTICE behavior aligned with botPrivmsg:
    # - sanitize newlines;
    # - split long messages instead of truncating them;
    # - split before UTF-8 encoding so accents, emojis and IRC bar chars are
    #   never cut in the middle of a multi-byte sequence.
    # mb325-B1: byte-aware split shared with botPrivmsg. Splitting on a 400-byte
    # budget (instead of 400 characters) keeps accents/emojis/IRC bar chars from
    # pushing a NOTICE past the ~512-byte wire limit; the per-chunk encode below
    # is unchanged. Char-boundary safety is preserved by the helper.
    $text = _sanitize_irc_text($text);

    my $is_channel_target = _is_irc_channel_target($target);

    # mb385-B1: private NOTICEs were redacted in the normal level-0 log, but the
    # earlier level-4 diagnostic still printed the original text verbatim.
    # Redact the complete private message before both debug logging and splitting
    # its log copy. Redacting each wire chunk independently is unsafe because a
    # long service command can put the secret in a later chunk that no longer
    # starts with "identify", "login", etc.
    my $safe_log_text = $is_channel_target
        ? $text
        : _redact_irc_service_secret_for_log($text);

    $self->{logger}->log(
        4,
        "[DEBUG] botNotice() called with target='$target', text='$safe_log_text'"
    );

    my @chunks = _split_text_for_irc($text, 400);
    @chunks = ($text) unless @chunks;

    my @private_log_chunks;
    unless ($is_channel_target) {
        @private_log_chunks = _split_text_for_irc($safe_log_text, 400);
        @private_log_chunks = ($safe_log_text) unless @private_log_chunks;
    }

    for my $chunk (@chunks) {
        next unless defined($chunk) && $chunk ne '';

        my $encoded_text = utf8::is_utf8($chunk) ? encode('UTF-8', $chunk) : $chunk;

        $self->{logger}->log(4, "[DEBUG] botNotice() sending encoded text length=" . length($encoded_text));

        # Envoi du NOTICE
        $self->{metrics}->inc('mediabot_notice_out_total') if $self->{metrics};
        _write_irc_chunk($self->{irc}, 'do_NOTICE', $target, $encoded_text, $send_options);

        if ($is_channel_target) {
            # Channel logs and action history retain the original visible text.
            $self->{logger}->log(0, "-> -$target- $chunk");
            $self->{logger}->log(4, "[DEBUG] botNotice() target is a channel, logging to action log");
            logBotAction($self, undef, "notice", $self->{irc}->nick_folded, $target, $chunk);
        }
    }

    # Private logs use the already-redacted complete-message copy. This keeps
    # credentials masked even when the wire message required several chunks.
    unless ($is_channel_target) {
        for my $log_chunk (@private_log_chunks) {
            next unless defined($log_chunk) && $log_chunk ne '';
            $self->{logger}->log(0, "-> -$target- $log_chunk");
        }
    }
}

1;
