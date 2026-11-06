package Mediabot::Games::QuoteGame;

use strict;
use warnings;
use utf8;
use Exporter 'import';
use Scalar::Util qw(refaddr weaken);
use Mediabot::Helpers ();
use Mediabot::IRC::Timer qw(countdown);

our @EXPORT_OK = qw(
    _quotegame_cancel_timer
    _quotegame_start_timer
    mbQuotegame_ctx
    checkQuotegameAnswer
);

# UserCommands remains the compatibility entry point. Resolve its existing
# transport hooks at call time so local overrides still see the same output.
sub botPrivmsg { goto &Mediabot::UserCommands::botPrivmsg }
sub botNotice  { goto &Mediabot::UserCommands::botNotice }
sub _ach_progress { goto &Mediabot::UserCommands::_ach_progress }

# ---------------------------------------------------------------------------
# _quotegame_cancel_timer / _quotegame_start_timer
# mb122: proactive quotegame timeout. The old lazy timeout still remains as a
# safety net in checkQuotegameAnswer(), but a real IO::Async countdown now
# announces the answer after 60 seconds even if nobody talks.
# ---------------------------------------------------------------------------
sub _quotegame_cancel_timer {
    my ($self, $channel) = @_;
    return unless $self && defined $channel;

    my $qg = $self->{_quotegame}{lc $channel} or return;

    my $timer = delete $qg->{timer};
    delete $qg->{timer_arm};

    return unless $timer;

    my $loop = eval { $timer->loop };
    eval { $timer->stop if $timer->can('stop') };
    eval { $loop->remove($timer) if $loop };
}

sub _quotegame_start_timer {
    my ($self, $channel, $token, $delay) = @_;
    return unless $self && defined $channel && defined $token;
    my $key = lc $channel;
    my $round = $self->{_quotegame}{$key} or return;
    return unless $round->{active};

    $delay ||= 60;

    my $loop = eval { $self->getLoop } || $self->{loop};
    unless ($loop) {
        eval {
            $self->{logger}->log(2, "Quotegame: no IO::Async loop available, keeping lazy timeout only");
        };
        return;
    }

    Mediabot::UserCommands::_quotegame_cancel_timer($self, $channel);

    # Each arm has its own identity, even when the round token is unchanged.
    my $arm = $round->{timer_arm} = {};
    my $bot = $self;
    weaken($bot);
    my $owned_round = sub {
        return unless $bot;
        my $qg = $bot->{_quotegame}{$key} or return;
        return $qg if (refaddr($qg->{timer_arm}) // 0) == refaddr($arm);
        return;
    };
    my $timer = eval {
        countdown(
            loop => $loop,
            delay => $delay,
            on_expire => sub {
                my $qg = $owned_round->() or return;
                delete $qg->{timer};
                delete $qg->{timer_arm};
                return unless $qg->{active};
                $qg->{active} = 0;
                my $author = defined($qg->{author}) ? $qg->{author} : 'unknown';
                Mediabot::Helpers::botPrivmsg(
                    $bot,
                    $channel,
                    "\x{23F0} Time's up! The answer was: \x02$author\x02"
                );
            },
        );
    };
    my $current = $owned_round->();
    if (!$current) {
        eval { $timer->stop } if $timer;
        eval { $loop->remove($timer) } if $timer;
        return;
    }
    unless ($timer) {
        delete $current->{timer_arm};
        eval { $self->{logger}->log(2, "Quotegame: timer setup failed, keeping lazy timeout only") };
        return;
    }
    $current->{timer} = $timer;
    return $timer;
}


# ---------------------------------------------------------------------------
# mbQuotegame_ctx --- !quotegame [stop|top]
# Devine qui a dit la quote. État partagé en mémoire par canal.
# Réponses validées via checkQuotegameAnswer() appelé depuis on_message_PRIVMSG.
# ---------------------------------------------------------------------------
sub mbQuotegame_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    unless ($channel && $channel =~ /^#/) {
        botNotice($self, $nick, 'Syntax: !quotegame  (must be in a channel)'); return;
    }

    # mb118-IMP2: gate par chanset +Games (sauf stop/top: lecture toujours OK)
    if (!(@args && lc($args[0] // '') =~ /^(stop|top)$/)) {
        unless (Mediabot::Helpers::chanset_enabled($self, $channel, 'Games', default => 1)) {
            botNotice($self, $nick, "Games are disabled on $channel (chanset -Games)");
            return;
        }
    }

    # Share the channel cache's lowercase identity. The original target
    # spelling still belongs to SQL binds and outbound messages.
    my $key = lc $channel;
    my $qg = $self->{_quotegame}{$key};

    # !quotegame stop
    if (@args && lc($args[0]) eq 'stop') {
        if ($qg && $qg->{active}) {
            Mediabot::UserCommands::_quotegame_cancel_timer($self, $channel);
            $qg->{active} = 0;
            botPrivmsg($self, $channel,
                "\x{1F6D1} Quotegame stopped. Answer was: \x02$qg->{author}\x02");
        } else {
            botPrivmsg($self, $channel, 'No active quotegame.');
        }
        return 1;
    }

    # !quotegame top
    if (@args && lc($args[0]) eq 'top') {
        my $scores = $qg && $qg->{scores} ? $qg->{scores} : {};
        unless (%$scores) {
            botPrivmsg($self, $channel, 'No quotegame scores yet on this channel.'); return 1;
        }
        my @sorted = sort { $scores->{$b} <=> $scores->{$a} || $a cmp $b } keys %$scores;
        my $top = scalar @sorted > 5 ? 5 : scalar @sorted;
        my @parts = map { "$_:" . $scores->{$_} } @sorted[0..$top-1];
        botPrivmsg($self, $channel, "\x{1F4DC} Quote detectives: " . join('  |  ', @parts));
        return 1;
    }

    # Vérifier qu'il n'y a pas déjà une question active
    if ($qg && $qg->{active}) {
        botPrivmsg($self, $channel,
            "\x{23F3} Quotegame already in progress (use \x02!quotegame stop\x02 to abort).");
        return 1;
    }

    # Read one eligible quote before changing the round or announcing it.
    my $dbh = $self->{dbh};
    my ($sth, $row);
    my $read_ok = eval {
        $sth = $dbh && $dbh->prepare(q{
            SELECT q.id_quotes, q.quotetext, u.nickname AS author
            FROM QUOTES q
            JOIN CHANNEL c ON c.id_channel = q.id_channel
            JOIN USER    u ON u.id_user    = q.id_user
            WHERE c.name = ? AND LENGTH(q.quotetext) >= 20
            ORDER BY RAND()
            LIMIT 1
        }) or die "quotegame_prepare\n";
        $sth->execute($channel) or die "quotegame_execute\n";
        $row = $sth->fetchrow_hashref;
        die "quotegame_fetch\n" if $sth->err;
        1;
    };
    eval { $sth->finish } if $sth;
    unless ($read_ok) {
        botNotice($self, $nick, 'Database error.');
        return;
    }
    unless ($row && $row->{quotetext}) {
        botPrivmsg($self, $channel, 'No quotes long enough for the game on this channel.');
        return 1;
    }

    # Préserver les scores cumulés
    my $prev_scores = ($qg && $qg->{scores}) ? $qg->{scores} : {};
    $self->{_quotegame}{$key} = {
        active     => 1,
        id_quote   => $row->{id_quotes},
        author     => $row->{author},
        author_lc  => lc($row->{author}),
        started    => time(),
        deadline   => time() + 60,
        token      => join(':', $channel, ($row->{id_quotes} // 0), time(), int(rand(1_000_000))),
        scores     => $prev_scores,
    };

    # Masquer toute occurrence du nom de l'auteur dans la quote
    # mb121-B2: les nicks IRC peuvent contenir [ ] \ ^ _ ` { } | -
    # qui ne sont pas word chars Perl -> \b ne borde pas correctement
    # les nicks type [teuk], __user__, etc. On utilise des assertions
    # personnalisees basees sur le character class IRC (RFC 2812).
    my $masked = $row->{quotetext};
    my $author_lc = lc($row->{author});
    # nick chars IRC: lettres, chiffres, et certains specials. Les borders sont
    # "tout ce qui n'est PAS un nick char" (ou debut/fin de string).
    my $nick_char = qr/[A-Za-z0-9\[\]\\^_`{}|\-\x80-\xFF\p{L}\p{N}\p{M}]/;  # mb445-B1 / MB920: legacy bytes and decoded Unicode word material
    $masked =~ s/(?<!$nick_char)\Q$row->{author}\E(?!$nick_char)/???/gi;
    # 2e passe sur la version lowercase au cas ou \Q...\E ne matche pas
    # case-insensitively pour des caracteres non-ASCII (defensif).
    $masked =~ s/(?<!$nick_char)\Q$author_lc\E(?!$nick_char)/???/gi;

    botPrivmsg($self, $channel,
        "\x{1F4DC} \x02Quotegame!\x02 Who said: \"\x02$masked\x02\"  \x{2014}  60s to answer with the nick");

    Mediabot::UserCommands::_quotegame_start_timer($self, $channel, $self->{_quotegame}{$key}{token}, 60);

    return 1;
}

# ---------------------------------------------------------------------------
# checkQuotegameAnswer --- appelé depuis on_message_PRIVMSG (canal public)
# Validation déclenchée par tout message contenant un nick — peu coûteux.
# ---------------------------------------------------------------------------
sub checkQuotegameAnswer {
    my ($self, $sNick, $sChannel, $sMsg) = @_;
    return unless defined $sChannel && $sChannel =~ /^#/;
    my $qg = $self->{_quotegame}{lc $sChannel} or return;
    return unless $qg->{active};

    # Timeout passé
    if (time() > $qg->{deadline}) {
        Mediabot::UserCommands::_quotegame_cancel_timer($self, $sChannel);
        $qg->{active} = 0;
        Mediabot::Helpers::botPrivmsg($self, $sChannel,
            "\x{23F0} Time's up! The answer was: \x02$qg->{author}\x02");
        return;
    }

    return unless defined $sMsg && $sMsg ne '';

    # Le message contient-il le nick de l'auteur ?
    # On évite que l'auteur lui-même réponde "moi"
    return if lc($sNick) eq $qg->{author_lc};

    # mb121-B2: meme correction qu'a la creation de la quote -- les nicks IRC
    # contenant [ ] _ \ ^ { } | ne sont pas bornes correctement par \b.
    my $nick_char = qr/[A-Za-z0-9\[\]\\^_`{}|\-\x80-\xFF\p{L}\p{N}\p{M}]/;  # mb445-B1 / MB920: legacy bytes and decoded Unicode word material
    my $msg_lc = lc($sMsg);
    if ($msg_lc =~ /(?<!$nick_char)\Q$qg->{author_lc}\E(?!$nick_char)/) {
        Mediabot::UserCommands::_quotegame_cancel_timer($self, $sChannel);
        $qg->{active} = 0;
        $qg->{scores}{$sNick}++;
        my $score = $qg->{scores}{$sNick};
        my $elapsed = time() - $qg->{started};
        Mediabot::Helpers::botPrivmsg($self, $sChannel,
            sprintf("\x{1F3AF} Correct, \x02%s\x02! It was \x02%s\x02 (in %ds, score: %d)",
                $sNick, $qg->{author}, $elapsed, $score));

        # Hook achievement (mb610-B1: total cumule, pas le score de la partie)
        if ($self->{achievements}) {
            my $qg_total = _ach_progress($self, 'quotegame_solved', $sNick, $sChannel)
                        // $score;
            eval { $self->{achievements}->check_quotegame($sNick, $sChannel, $qg_total) };
        }
        $self->{metrics}->inc('mediabot_quotegame_correct_total') if $self->{metrics};
    }
}

1;
