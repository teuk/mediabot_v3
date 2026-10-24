package Mediabot::IRC::Sender;

use strict;
use warnings;
use utf8;
use Encode qw(encode);

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
                if (checkAntiFlood($self, $sTo)) {
                    # Contextual replies expire with their conversation. Other
                    # callers keep the historical bounded deferred-send queue.
                    return 0 if ref($send_options) eq 'HASH' && $send_options->{no_defer};
                    return _defer_flooded_send($self, 'privmsg', $sTo, $sMsg);
                }
            }
        }

        # Badword filtering — B1/A1: cache per channel (TTL 5 min)
        # Avoids one SQL query per outgoing message on busy channels.
        {
            my $now     = time();
            my $ttl     = 300;   # 5 minutes
            my $cache   = $self->{_badword_cache}{$sTo};

            if (!$cache || ($now - ($cache->{ts} // 0)) > $ttl) {
                my $sth = $self->{dbh}->prepare(
                    "SELECT badword FROM CHANNEL"
                    . " JOIN BADWORDS ON BADWORDS.id_channel = CHANNEL.id_channel"
                    . " WHERE CHANNEL.name = ?"
                );
                my @words;
                if ($sth && $sth->execute($sTo)) {
                    while (my $ref = $sth->fetchrow_hashref) {
                        push @words, lc($ref->{badword}) if defined $ref->{badword};
                    }
                    $sth->finish;
                } else {
                    $self->{logger}->log(1, "botPrivmsg() Badword SQL Error: $DBI::errstr");
                    $self->{metrics}->inc('mediabot_db_query_errors_total') if $self->{metrics};
                    $sth->finish if $sth; # mb135-B10: match botAction cleanup on execute errors
                }
                $self->{_badword_cache}{$sTo} = { ts => $now, words => \@words };
                $cache = $self->{_badword_cache}{$sTo};
            }

            my $msg_lc = lc($sMsg);
            for my $bw (@{ $cache->{words} // [] }) {
                if (index($msg_lc, $bw) != -1) {
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
            $self->{irc}->do_PRIVMSG(target => $sTo, text => $chunk);
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
	my ($self,$sTo,$sMsg) = @_;
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
						if (checkAntiFlood($self,$sTo)) {
							# mb568-B1: differe au lieu de jeter
							return _defer_flooded_send($self,'action',$sTo,$sMsg);
						}
					}
				}
				# mb134-B8: keep botAction aligned with botPrivmsg for outgoing
				# badword checks. The old path queried BADWORDS on every ACTION
				# and did not finish the statement handle on the no-badword path.
				# Reuse the same short-lived per-channel cache used by botPrivmsg.
				{
					my $now     = time();
					my $ttl     = 300;
					my $cache   = $self->{_badword_cache}{$sTo};

					if (!$cache || ($now - ($cache->{ts} // 0)) > $ttl) {
						my $sQuery = "SELECT badword FROM CHANNEL JOIN BADWORDS ON BADWORDS.id_channel = CHANNEL.id_channel WHERE CHANNEL.name = ?";
						my $sth = $self->{dbh}->prepare($sQuery);
						my @words;

						if ($sth && $sth->execute($sTo)) {
							while (my $ref = $sth->fetchrow_hashref()) {
								push @words, lc($ref->{badword}) if defined $ref->{badword};
							}
							$sth->finish;
						}
						else {
							$self->{logger}->log(1,"botAction() Badword SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
							$self->{metrics}->inc('mediabot_db_query_errors_total') if $self->{metrics};
							$sth->finish if $sth;
						}

						$self->{_badword_cache}{$sTo} = { ts => $now, words => \@words };
						$cache = $self->{_badword_cache}{$sTo};
					}

					my $sMsgLc = lc $sMsg;
					for my $bw (@{ $cache->{words} // [] }) {
						if (index($sMsgLc, $bw) != -1) {
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
    my ($self, $target, $text) = @_;

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
        $self->{irc}->do_NOTICE(
            target => $target,
            text   => $encoded_text
        );

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
