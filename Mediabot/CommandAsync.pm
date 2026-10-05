package Mediabot::CommandAsync;

# =============================================================================
# mb583-B1: les commandes CARRIERE quittent la boucle d'evenements.
#
# Terrain (Undernet, 2026-07-27) : « m lb » sur une table vive de 5M lignes a
# tenu la boucle 60 s (SLOW PRIVMSG 60.60s + event loop stalled ~59.52s) avant
# que MariaDB ne tue la requete (« Lost connection to server during query »).
# Pendant ce temps le bot etait fige pour TOUS les canaux. C'etait le point 5
# de la revue pre-commit (« gros calculs synchrones -> worker »), reporte
# deux fois ; le terrain a tranche.
#
# Modele : le moule mb559 (Achievements async) et mb571 (archive worker) —
# fork + connexion DB isolee + pipe JSON + watch_process + TERM/KILL. La
# nouveaute : la sub de commande s'execute INCHANGEE dans l'enfant ; des
# facades locales sur botPrivmsg/botNotice/botAction collectent les messages
# en INTENTS au lieu d'ecrire sur la socket IRC (l'enfant ne touche JAMAIS
# la socket), et le PARENT les rejoue au reap via les vrais helpers — donc
# AntiFlood, NoColors et la file differee mb568 s'appliquent normalement.
# logBot n'est PAS facade : il ecrit via $self->{dbh}, remplace dans
# l'enfant par le handle isole -> le log commande reste vrai.
#
# Fallback : sans loop watch_process ou si fork echoue, la commande s'execute
# en SYNCHRONE (comportement historique) — pour une commande de lecture a la
# demande, degrader vers l'ancien comportement vaut mieux qu'une commande
# morte (contrairement a l'archive mb571, ecriture, qui refuse le sync).
# =============================================================================

use strict;
use warnings;
use utf8;   # mb621-B1: les litteraux de ce fichier sont des CARACTERES.
            # Sans cela ils sont des OCTETS, et interpoler une variable
            # venue d'IRC (mediabot.pl decode les messages entrants) fait
            # basculer toute la chaine : les octets sont relus en latin-1
            # puis re-encodes a l'envoi -> mojibake (« humeur Ã©lectrique »).

use JSON::PP ();
use Time::HiRes ();
use Scalar::Util qw(refaddr weaken);

our $MAX_INTENTS   = 60;
our $MAX_WLOGS     = 40;   # mb585-B1: lignes de log du worker relayees au parent
our $TIMEOUT_S     = 45;
our $KILL_AFTER_S  = 5;
our $MAX_PAYLOAD   = 64 * 1024;
our $DB_MAX_STMT_S = 40;   # SET SESSION max_statement_time (MariaDB, secondes)
our $NEWS_OUTPUT_STEP = 1.5;
our $NEWS_OUTPUT_MAX  = 60;
our $NEWS_OUTPUT_TTL  = 120;

# ---------------------------------------------------------------------------
# mb585-B1: le logger de l'enfant ecrivait dans le filehandle herite, mais
# POSIX::_exit(0) sort sans vider les buffers : les logs du worker (dont le
# precieux « channel_log_gather: ARCHIVE query failed ») etaient PERDUS —
# l'incident #quebec (40.30s, 2 lignes) a ete diagnostique a l'aveugle.
# Desormais l'enfant collecte ses logs et le parent les rejoue au reap,
# prefixes [worker <label>], via son propre logger. logBot n'est pas
# concerne : il ecrit en DB via le dbh isole de l'enfant, ce qui fonctionne.
# ---------------------------------------------------------------------------
{
    package Mediabot::CommandAsync::_WorkerLogger;
    sub new { bless { q => [], dropped => 0 }, $_[0] }
    sub log {
        my ($self2, $level, $text) = @_;
        if (@{ $self2->{q} } >= $Mediabot::CommandAsync::MAX_WLOGS) {
            $self2->{dropped}++;
            return 1;
        }
        push @{ $self2->{q} }, [ int($level // 0), defined $text ? "$text" : '' ];
        return 1;
    }
}

# ---------------------------------------------------------------------------
# Partie ENFANT testable sans fork : pose les facades, execute le code,
# retourne les intents collectes. [ [ 'privmsg'|'notice'|'action', target,
# text ], ... ] — borne a $MAX_INTENTS, drapeau truncated au-dela.
# ---------------------------------------------------------------------------
sub _collect_intents_run {
    my ($code) = @_;
    my (@intents, $truncated);
    my $push = sub {
        my ($kind, $target, $text) = @_;
        if (@intents >= $MAX_INTENTS) { $truncated = 1; return }
        push @intents, [ $kind, "$target", defined $text ? "$text" : '' ];
    };
    no warnings qw(redefine once);
    # mb615-B1: la facade doit couvrir les DEUX chemins d'appel.
    #
    # Terrain (#test, 2026-08-08) : « m actualités » demarrait bien son
    # worker mais ne repondait JAMAIS. Les facades n'existaient que sur les
    # alias IMPORTES par Mediabot::UserCommands ; or un module appele depuis
    # un worker peut tres bien appeler la forme QUALIFIEE
    # Mediabot::Helpers::botPrivmsg (c'est le cas de External::News, et de
    # tout module hors UserCommands). Ces appels-la partaient alors vers la
    # vraie socket depuis l'ENFANT — qui ne doit jamais y toucher — et le
    # POSIX::_exit final jetait le tampon : silence complet, sans la moindre
    # erreur. Toutes les commandes asynchrones existantes vivant dans
    # UserCommands, le trou n'avait jamais mordu jusqu'ici.
    #
    # On pose donc la facade sur le glob SOURCE (Helpers) *et* sur l'alias
    # importe (UserCommands) : un alias importe est un glob distinct, poser
    # l'un ne suffit pas a couvrir l'autre.
    local *Mediabot::Helpers::botPrivmsg      = sub { $push->('privmsg', $_[1], $_[2]); 1 };
    local *Mediabot::Helpers::botNotice       = sub { $push->('notice',  $_[1], $_[2]); 1 };
    local *Mediabot::Helpers::botAction       = sub { $push->('action',  $_[1], $_[2]); 1 };
    local *Mediabot::UserCommands::botPrivmsg = sub { $push->('privmsg', $_[1], $_[2]); 1 };
    local *Mediabot::UserCommands::botNotice  = sub { $push->('notice',  $_[1], $_[2]); 1 };
    local *Mediabot::UserCommands::botAction  = sub { $push->('action',  $_[1], $_[2]); 1 };
    # Context->reply()/reply_private() call the helpers as methods on the bot
    # object. Capture that third path too; otherwise a worker can complete
    # successfully with zero replayable intents (mb692 live RSS probe).
    local *Mediabot::botPrivmsg               = sub { $push->('privmsg', $_[1], $_[2]); 1 };
    local *Mediabot::botNotice                = sub { $push->('notice',  $_[1], $_[2]); 1 };
    local *Mediabot::botAction                = sub { $push->('action',  $_[1], $_[2]); 1 };
    my $ok = eval { $code->(); 1 };
    my $err = $ok ? undef : ($@ || 'command exception');
    return (\@intents, $truncated, $ok, $err);
}

# Rejeu cote PARENT via les vrais helpers (AntiFlood/NoColors/file mb568).
sub _replay_intents {
    my ($self, $intents, $label, $expected_irc) = @_;
    return _queue_news_intents($self, $intents, $expected_irc)
        if defined($label) && $label eq 'actualites';
    for my $it (@{ $intents || [] }) {
        my ($kind, $target, $text) = @$it;
        next unless defined $target && length $target;
        if    ($kind eq 'privmsg') { eval { Mediabot::Helpers::botPrivmsg($self, $target, $text) } }
        elsif ($kind eq 'notice')  { eval { Mediabot::Helpers::botNotice($self, $target, $text) } }
        elsif ($kind eq 'action')  { eval { Mediabot::Helpers::botAction($self, $target, $text) } }
    }
    return 1;
}

# News workers collect lines without touching IRC. Pace their PARENT replay,
# including synchronous worker fallbacks, with one timer for the whole bot.
# Timers are armed after each delivery: a late event loop never catches up by
# releasing several expired timers in the same turn. All deliveries still go
# through the normal AntiFlood/NoColors/badword/logging helpers above.
sub _news_output_now {
    return Time::HiRes::clock_gettime(Time::HiRes::CLOCK_MONOTONIC());
}

sub _news_output_log {
    my ($self, $reason) = @_;
    eval { $self->{logger}->log(2, "CommandAsync: news output $reason") };
    return;
}

sub _clear_news_output {
    my ($self, $q, $reason) = @_;
    if (my $timer = delete $q->{timer}) {
        eval { $timer->stop };
        eval { $q->{loop}->remove($timer) };
    }
    $q->{items} = [];
    delete $self->{_news_output_q}
        if $self->{_news_output_q} && refaddr($self->{_news_output_q}) == refaddr($q);
    _news_output_log($self, $reason);
    return 0;
}

sub _arm_news_output {
    my ($self, $q, $delay) = @_;
    return 1 if $q->{timer};
    my $weak_self = $self;
    weaken($weak_self);
    my $timer;
    my $ok = eval {
        require IO::Async::Timer::Countdown;
        $timer = IO::Async::Timer::Countdown->new(
            delay => $delay,
            on_expire => sub {
                my ($expired_timer) = @_;
                eval { $q->{loop}->remove($expired_timer) };
                delete $q->{timer};
                my $bot = $weak_self or return;
                return unless $bot->{_news_output_q}
                    && refaddr($bot->{_news_output_q}) == refaddr($q);
                _drain_news_output($bot, $q);
            },
        );
        $q->{timer} = $timer;
        $q->{loop}->add($timer);
        $timer->start;
        1;
    };
    return $ok ? 1 : _clear_news_output($self, $q, 'timer_unavailable');
}

sub _drain_news_output {
    my ($self, $q) = @_;
    return _clear_news_output($self, $q, 'connection_changed')
        unless $self->{irc} && refaddr($self->{irc}) == refaddr($q->{irc})
            && eval { $self->{irc}->is_connected }
            && !eval { $self->getQuit };
    my $now = _news_output_now();
    my $expired = 0;
    while (@{$q->{items}} && $q->{items}[0]{expires} <= $now) {
        shift @{$q->{items}}; $expired++;
    }
    _news_output_log($self, 'expired') if $expired;
    return 1 unless @{$q->{items}};
    my $wait = defined($q->{last_at}) ? $NEWS_OUTPUT_STEP - ($now - $q->{last_at}) : 0;
    return _arm_news_output($self, $q, $wait) if $wait > 0;
    my $item = shift @{$q->{items}};
    _replay_intents($self, [$item->{intent}]);
    $q->{last_at} = _news_output_now();
    return @{$q->{items}} ? _arm_news_output($self, $q, $NEWS_OUTPUT_STEP) : 1;
}

sub _queue_news_intents {
    my ($self, $intents, $expected_irc) = @_;
    my $irc = $self->{irc};
    unless ($irc && eval { $irc->is_connected }
        && (!$expected_irc || refaddr($expected_irc) == refaddr($irc))) {
        _news_output_log($self, 'connection_changed');
        return 0;
    }
    my $loop = $self->{loop} || eval { $self->getLoop };
    unless ($loop && $loop->can('add') && $loop->can('remove')) {
        # Never replace a missing scheduler with a public burst or a sleep.
        _news_output_log($self, 'loop_unavailable');
        return 0;
    }
    my @batch = map { [@$_] } grep {
        ref($_) eq 'ARRAY' && @$_ == 3 && defined($_->[0]) && !ref($_->[0])
            && $_->[0] =~ /\A(?:privmsg|notice|action)\z/
            && defined($_->[1]) && !ref($_->[1]) && length($_->[1])
            && defined($_->[2]) && !ref($_->[2])
    } @{ $intents || [] };
    return 1 unless @batch;
    my $q = $self->{_news_output_q};
    if ($q && (refaddr($q->{irc}) != refaddr($irc) || refaddr($q->{loop}) != refaddr($loop))) {
        _clear_news_output($self, $q, 'connection_changed');
        $q = undef;
    }
    $q ||= $self->{_news_output_q} = {items => [], irc => $irc, loop => $loop};
    if (@{$q->{items}} + @batch > $NEWS_OUTPUT_MAX) {
        _news_output_log($self, 'queue_full');
        return 0; # Reject the whole new batch, preserving the pending order.
    }
    my $expires = _news_output_now() + $NEWS_OUTPUT_TTL;
    push @{$q->{items}}, map { {intent => $_, expires => $expires} } @batch;
    return $q->{timer} ? 1 : _drain_news_output($self, $q);
}

sub _run_sync {
    my ($self, $label, $code) = @_;
    return $code->() unless $label eq 'actualites';
    my $irc = $self->{irc};
    my ($intents, $truncated, $ok, $err) = _collect_intents_run($code);
    die $err unless $ok;
    return _replay_intents($self, $intents, $label, $irc);
}

# mb595-B1: instantanes de LECTURE pour l'operateur (.status) — memoire
# seule, contrat mb573 : jamais une requete, jamais un kill, jamais un
# waitpid ici. Les jobs actifs sont rendus tries par anciennete avec leur
# duree ecoulee ; les stats sont une copie a plat des compteurs cumules
# depuis le demarrage (spawned/completed/timeouts/fallback_sync/
# lock_refused — absents = 0). Le compteur fallback_sync couvre les quatre
# replis : loop, pipe, fork et echec d'enregistrement watch_process.
sub async_jobs_snapshot {
    my ($self) = @_;
    my $jobs = $self->{_cmd_async_jobs} || {};
    my $now  = Time::HiRes::time();
    my @out;
    for my $lockkey (sort keys %$jobs) {
        my $j = $jobs->{$lockkey} or next;
        push @out, {
            lockkey => $lockkey,
            channel => $j->{channel} // $lockkey,
            label   => $j->{label}   // '?',
            pid     => $j->{pid}     // 0,
            elapsed => sprintf('%.1f', $now - ($j->{started} || $now)),
        };
    }
    @out = sort { $b->{elapsed} <=> $a->{elapsed} } @out;
    return \@out;
}

sub async_stats_snapshot {
    my ($self) = @_;
    my $st = $self->{_cmd_async_stats} || {};
    return { map { $_ => $st->{$_} || 0 }
        qw(spawned completed timeouts fallback_sync lock_refused) };
}

# mb770-R6: a worker can be reaped before IO::Async has delivered the final
# bytes from its result pipe.  Finalizing on watch_process alone therefore
# turned a valid JSON result into an intermittent "no result"/Database error.
# Keep the ordering rule in one tiny pure helper so both possible event orders
# are testable: process exit first or pipe EOF first.  IO::Async guarantees
# that on_read_eof runs only after pending on_read data has been presented.
sub _worker_completion_barrier {
    my ($state, $finalize) = @_;
    return 0 unless ref($state) eq 'HASH' && ref($finalize) eq 'CODE';
    return 0 if $state->{finalized};
    return 0 unless $state->{process_done} && $state->{pipe_eof};
    $finalize->();
    return 1;
}

sub run_ctx_async {
    my ($self, $ctx, $label, $code) = @_;
    return 0 unless $self && $ctx && ref($code) eq 'CODE';
    $label = 'career' unless defined $label && length $label;

    my $nick    = eval { $ctx->nick }    // '';
    my $channel = eval { $ctx->channel } // '';
    my $lockkey = lc($channel || $nick || 'global');
    my $news_irc = $label eq 'actualites' ? $self->{irc} : undef;

    # Un seul gros job par canal : proteger MariaDB et l'ordre des reponses.
    $self->{_cmd_async_jobs} ||= {};
    $self->{_cmd_async_stats} ||= {};
    if ($self->{_cmd_async_jobs}{$lockkey}) {
        $self->{_cmd_async_stats}{lock_refused}++;
        eval { Mediabot::Helpers::botNotice($self, $nick,
            "Another heavy analysis is already running for $channel — try again in a moment.") };
        return 1;
    }

    my $loop = eval { $self->{loop} } || eval { $self->getLoop };
    my $can_async = $loop && eval { $loop->can('add') && $loop->can('remove')
        && $loop->can('watch_process') };

    unless ($can_async) {
        # mb583-B1: fallback SYNCHRONE documente (comportement historique).
        $self->{_cmd_async_stats}{fallback_sync}++;
        eval { $self->{logger}->log(3,
            "CommandAsync: no async loop, running '$label' synchronously") };
        return _run_sync($self, $label, $code);
    }

    require IO::Async::Stream;
    require IO::Async::Timer::Countdown;
    require POSIX;

    my ($pipe, $child_write);
    unless (pipe($pipe, $child_write)) {
        $self->{_cmd_async_stats}{fallback_sync}++;
        eval { $self->{logger}->log(1, "CommandAsync: pipe failed: $!") };
        return _run_sync($self, $label, $code);
    }
    my $pid = fork();
    unless (defined $pid) {
        $self->{_cmd_async_stats}{fallback_sync}++;
        eval { close $pipe }; eval { close $child_write };
        eval { $self->{logger}->log(1, "CommandAsync: fork failed: $!") };
        return _run_sync($self, $label, $code);
    }

    if ($pid == 0) {
        # ----------------------------- ENFANT ------------------------------
        eval { close $pipe };
        binmode($child_write, ':raw');
        local $SIG{PIPE} = 'IGNORE';
        local $SIG{TERM} = 'DEFAULT';
        local $SIG{INT}  = 'DEFAULT';

        # Ne jamais laisser la destruction DBI fermer la socket du parent.
        eval { $self->{dbh}{InactiveDestroy} = 1 if $self->{dbh} };
        eval { $self->{db}{dbh}{InactiveDestroy} = 1 if $self->{db} && $self->{db}{dbh} };

        my $result;
        my $db_obj = $self->{db};
        if (!$db_obj || !eval { $db_obj->can('connect_isolated_handle') }) {
            $result = { ok => 0, stage => 'isolated_db',
                detail => 'database wrapper has no isolated connector' };
        }
        else {
            my ($dbh, $db_error) = $db_obj->connect_isolated_handle;
            if (!$dbh) {
                $db_error //= 'isolated DB connection failed';
                $db_error =~ s/[\r\n\0]+/ /g;
                $result = { ok => 0, stage => 'isolated_db',
                    detail => substr($db_error, 0, 240) };
            }
            else {
                # Borne dure cote serveur : jamais plus de $DB_MAX_STMT_S par
                # requete, meme si un index manque encore. Best-effort.
                eval { $dbh->do("SET SESSION max_statement_time = $DB_MAX_STMT_S") };
                $self->{dbh} = $dbh;   # $ctx->bot EST $self : les subs le voient
                my $wlog = Mediabot::CommandAsync::_WorkerLogger->new;
                $self->{logger} = $wlog;   # process jetable : pas besoin de local
                my ($intents, $truncated, $ok, $err) = _collect_intents_run($code);
                my @wlogs = @{ $wlog->{q} };
                push @wlogs, [ 1, "(worker) $wlog->{dropped} further log line(s) dropped" ]
                    if $wlog->{dropped};
                $result = $ok
                    ? { ok => 1, intents => $intents, wlogs => \@wlogs,
                        ($truncated ? (truncated => 1) : ()) }
                    : do { (my $e = $err) =~ s/[\r\n\0]+/ /g;
                        { ok => 0, stage => 'command', wlogs => \@wlogs,
                          detail => substr($e, 0, 240) } };
                eval { $dbh->disconnect };
            }
        }

        my $payload = eval { JSON::PP::encode_json($result) };
        if (!defined($payload) || length($payload) > $MAX_PAYLOAD) {
            # Trop gros : tronquer les intents plutot que perdre la reponse.
            my $r2 = { ok => $result->{ok} ? 1 : 0, truncated => 1,
                       intents => [ @{ $result->{intents} || [] }[0 .. 9] ] };
            $payload = eval { JSON::PP::encode_json($r2) }
                // '{"ok":0,"stage":"encode","detail":"payload"}';
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

    # ------------------------------- PARENT --------------------------------
    eval { close $child_write };
    $self->{_cmd_async_jobs}{$lockkey} = { pid => $pid, label => $label,
        channel => $channel, started => Time::HiRes::time() };
    $self->{_cmd_async_stats}{spawned}++;
    eval { $self->{logger}->log(3,
        "CommandAsync: '$label' worker started pid=$pid chan=$channel") };

    my $state = {
        buffer => '', finalized => 0, timed_out => 0,
        process_done => 0, pipe_eof => 0,
    };
    my ($stream, $t_term, $t_kill);
    my $cleanup = sub {
        for my $obj ($stream, $t_term, $t_kill) {
            next unless $obj;
            eval { $obj->stop };
            eval { $loop->remove($obj) };
        }
        delete $self->{_cmd_async_jobs}{$lockkey};
    };
    my $job_started = Time::HiRes::time();
    my $finalize = sub {
        return if $state->{finalized};
        $state->{finalized} = 1;
        $cleanup->();
        my $elapsed = sprintf('%.2f', Time::HiRes::time() - $job_started);
        if ($state->{timed_out}) {
            $self->{_cmd_async_stats}{timeouts}++;
            eval { $self->{logger}->log(1,
                "CommandAsync: '$label' timed out after ${TIMEOUT_S}s (killed)") };
            eval { Mediabot::Helpers::botNotice($self, $nick,
                "$label: analysis timed out — the database may be missing indexes"
                . " (see tools/normalize_channel_log_indexes.pl).") };
            return;
        }
        my $res = eval { JSON::PP::decode_json($state->{buffer}) };
        if (ref($res) eq 'HASH') {
            for my $wl (@{ $res->{wlogs} || [] }) {
                eval { $self->{logger}->log($wl->[0],
                    "[worker $label] $wl->[1]") };
            }
        }
        if (ref($res) eq 'HASH' && $res->{ok}) {
            $self->{_cmd_async_stats}{completed}++;
            _replay_intents($self, $res->{intents}, $label, $news_irc);
            eval { Mediabot::Helpers::botNotice($self, $nick,
                "$label: output truncated (too many lines for one run).") }
                if $res->{truncated};
            eval { $self->{logger}->log(3,
                "CommandAsync: '$label' completed in ${elapsed}s ("
                . scalar(@{ $res->{intents} || [] }) . " line(s))") };
        }
        else {
            my $detail = ref($res) eq 'HASH'
                ? ($res->{detail} // $res->{stage} // 'unknown') : 'no result';
            eval { $self->{logger}->log(1,
                "CommandAsync: '$label' failed: $detail") };
            eval { Mediabot::Helpers::botNotice($self, $nick, 'Database error.') };
        }
    };
    my $completion_barrier = sub {
        return _worker_completion_barrier($state, $finalize);
    };

    $stream = IO::Async::Stream->new(
        read_handle => $pipe,
        on_read => sub {
            my (undef, $buffref) = @_;
            $state->{buffer} .= $$buffref;
            $$buffref = '';
            $state->{buffer} = substr($state->{buffer}, 0, $MAX_PAYLOAD + 1024)
                if length($state->{buffer}) > $MAX_PAYLOAD + 1024;
            return 0;
        },
        on_read_eof => sub {
            $state->{pipe_eof} = 1;
            $completion_barrier->();
        },
    );
    $t_term = IO::Async::Timer::Countdown->new(
        delay => $TIMEOUT_S,
        on_expire => sub {
            $state->{timed_out} = 1;
            kill 'TERM', $pid;
            $t_kill = IO::Async::Timer::Countdown->new(
                delay => $KILL_AFTER_S,
                on_expire => sub { kill 'KILL', $pid },
            );
            $loop->add($t_kill); $t_kill->start;
        },
    );

    my $watch_ok = eval {
        $loop->add($stream);
        $loop->add($t_term); $t_term->start;
        $loop->watch_process($pid, sub {
            $state->{process_done} = 1;
            $completion_barrier->();
        });
        1;
    };
    unless ($watch_ok) {
        $self->{_cmd_async_stats}{fallback_sync}++;
        kill 'KILL', $pid;
        waitpid($pid, 0);
        $cleanup->();
        eval { $self->{logger}->log(1,
            "CommandAsync: could not watch worker; running '$label' synchronously") };
        return _run_sync($self, $label, $code);
    }
    return 1;
}

1;
