package Mediabot::Games::Trivia;

use strict;
use warnings;
use utf8;
use Exporter 'import';
use Mediabot::Helpers ();
use Time::HiRes ();
use Mediabot::AsyncWorker;

our @EXPORT_OK = qw(
    _trivia_fetch_async
    mbTrivia_ctx
    checkTriviaAnswer
    mbTriviaTop_ctx
    mbTriviaReset_ctx
    mbTriviaStop_ctx
    mbTriviaScore_ctx
);

# UserCommands remains the compatibility entry point. Resolve its existing
# transport hooks at call time so local overrides still see the same output.
sub botPrivmsg { goto &Mediabot::UserCommands::botPrivmsg }
sub botNotice  { goto &Mediabot::UserCommands::botNotice }
sub _ach_progress { goto &Mediabot::UserCommands::_ach_progress }
sub logBot { goto &Mediabot::UserCommands::logBot }
sub _trivia_fetch_sync { goto &Mediabot::UserCommands::_trivia_fetch_sync }

# MB319: Open Trivia DB HTTP and DNS work must not run in the IRC event loop.
# Execute the synchronous request in a forked child and consume its bounded JSON
# result through IO::Async. MB394 extends the child budget for one rate-limit
# retry. MB395 registers the worker with watch_process(), because IO::Async owns
# SIGCHLD collection; manual waitpid polling can race the loop and discard a
# successful child as a detail-free fetch failure.
sub _trivia_fetch_async {
    my ($self, $category_id, $difficulty, $callback, %opts) = @_;

    return 0 unless ref($callback) eq 'CODE';

    require Time::HiRes;
    require JSON::PP;

    my $timeout = $opts{timeout};
    # The child has a seven-second hard wall around each HTTP attempt and may
    # wait once for the Open Trivia DB IP window. Keep the outer worker budget
    # larger, while still guaranteeing a callback when child notification fails.
    $timeout = 24
        unless defined($timeout)
            && !ref($timeout)
            && $timeout =~ /\A\d+(?:\.\d+)?\z/;
    $timeout = 0.1 if $timeout < 0.1;
    $timeout = 30  if $timeout > 30;

    my $debug_label = defined($opts{debug_label})
        && !ref($opts{debug_label})
            ? $opts{debug_label}
            : '';
    $debug_label =~ s/[\r\n\0]+/ /g;
    $debug_label =~ s/\s{2,}/ /g;
    $debug_label = substr($debug_label, 0, 240);

    my $debug_log = sub {
        my ($level, $message) = @_;
        return unless $self && ref($self) && $self->{logger};
        $message = '' unless defined($message) && !ref($message);
        $message =~ s/[\r\n\0]+/ /g;
        $message =~ s/\s{2,}/ /g;
        $message = substr($message, 0, 1000);
        $self->{logger}->log($level, "trivia worker $message");
    };

    my $clean_trace_value = sub {
        my ($value, $limit) = @_;
        $limit ||= 120;
        return '' unless defined($value) && !ref($value);
        $value =~ s/[\r\n\0]+/ /g;
        $value =~ s/\s{2,}/ /g;
        $value =~ s/^\s+|\s+$//g;
        return substr($value, 0, $limit);
    };

    my $loop = eval { $self->getLoop };
    $loop ||= $self->{loop} if ref($self);

    my $fallback = {
        ok    => 0,
        error => 'fetch',
        stage => 'async_fallback',
    };

    # Compatibility path for lightweight tests or emergency callers without a
    # usable event loop. Normal runtime uses the shared forked AsyncWorker.
    unless ($loop && $loop->can('add') && $loop->can('remove')) {
        $debug_log->(2, "sync fallback label=$debug_label reason=no_event_loop");
        my $result = eval {
            _trivia_fetch_sync($category_id, $difficulty);
        };
        if ($@) {
            my $error = $@;
            $error =~ s/[\r\n\0]+/ /g;
            $error =~ s/\s{2,}/ /g;
            $result = {
                ok     => 0,
                error  => 'worker_exception',
                stage  => 'sync_fallback',
                detail => substr($error, 0, 240),
            };
        }
        $result = $fallback unless ref($result) eq 'HASH';
        eval { $callback->($result); 1; };
        return 1;
    }

    # MB653: AsyncWorker now owns pipe/fork, watch_process, bounded transport,
    # timeout TERM/KILL escalation and callback-once semantics. Trivia retains
    # only its fetch protocol, stage diagnostics and IRC-specific error shape.
    my $worker_started = Time::HiRes::time();
    my $last_stage = 'worker_started';
    my $adapter_done = 0;
    my $worker;

    $debug_log->(
        3,
        sprintf(
            'start label=%s category=%s difficulty=%s timeout=%.1fs',
            ($debug_label ne '' ? $debug_label : '-'),
            (defined($category_id) ? $category_id : 'any'),
            (defined($difficulty) ? $difficulty : 'any'),
            $timeout,
        ),
    );

    my $progress = sub {
        my ($event, $worker_handle) = @_;
        return unless ref($event) eq 'HASH';

        my $stage = $clean_trace_value->($event->{stage}, 64);
        return unless $stage =~ /\A[a-z_]+\z/;
        $last_stage = $stage;

        my $pid = eval { $worker_handle->pid };
        $pid = eval { $worker->pid } unless defined $pid;
        $pid = '-' unless defined $pid;

        my @trace = (
            'progress',
            'label=' . ($debug_label ne '' ? $debug_label : '-'),
            "pid=$pid",
            "stage=$stage",
        );
        for my $field (qw(attempt elapsed_ms attempt_elapsed_ms status success content_bytes response_code parse_error delay_ms)) {
            next unless exists($event->{$field})
                && defined($event->{$field})
                && !ref($event->{$field});
            my $value = $clean_trace_value->($event->{$field}, 80);
            push @trace, "$field=$value" if $value ne '';
        }
        $debug_log->(4, join(' ', @trace));
    };

    my $done = sub {
        my ($shared) = @_;
        return if $adapter_done;
        $adapter_done = 1;

        my $elapsed = int(
            (Time::HiRes::time() - $worker_started) * 1000 + 0.5
        );

        my $pid = ref($shared) eq 'HASH' ? $shared->{pid} : undef;
        $pid = eval { $worker->pid } unless defined $pid;
        $pid = '-' unless defined $pid;

        my $result;
        if (ref($shared) eq 'HASH' && $shared->{ok}) {
            if (ref($shared->{value}) eq 'HASH') {
                $result = { %{ $shared->{value} } };
            }
            else {
                $result = {
                    ok     => 0,
                    error  => 'worker_decode',
                    stage  => 'missing_result',
                    detail => 'worker returned no trivia result hash',
                };
            }
        }
        else {
            my $error = ref($shared) eq 'HASH'
                && defined($shared->{error})
                && !ref($shared->{error})
                    ? $shared->{error}
                    : 'worker_failed';
            my $stage = ref($shared) eq 'HASH'
                && defined($shared->{stage})
                && !ref($shared->{stage})
                    ? $shared->{stage}
                    : 'process_exit';
            my $detail = ref($shared) eq 'HASH'
                && defined($shared->{detail})
                && !ref($shared->{detail})
                    ? $shared->{detail}
                    : undef;

            if ($error eq 'worker_timeout') {
                $stage = 'async_timeout';
            }
            elsif ($error eq 'worker_signal' || $error eq 'worker_exit') {
                $error = 'worker_failed';
                $stage = 'process_exit';
            }
            elsif ($error eq 'worker_output_limit') {
                $error = 'worker_payload';
                $stage = 'payload_limit';
            }
            elsif ($error eq 'worker_empty') {
                $error = 'worker_decode';
                $stage = 'missing_result';
            }

            $result = {
                ok    => 0,
                error => $error,
                stage => $stage,
            };
            $result->{detail} = substr($detail, 0, 240)
                if defined($detail) && length($detail);
        }

        if (ref($shared) eq 'HASH') {
            $result->{worker_exit} = defined($shared->{exit})
                ? int($shared->{exit}) : 0;
            $result->{worker_signal} = defined($shared->{signal})
                ? int($shared->{signal}) : 0;
            $result->{worker_output_bytes} = int($shared->{bytes} // 0);
            $result->{worker_elapsed_ms} = int(
                1000 * ($shared->{elapsed_s} // 0) + 0.5
            );
            $result->{forced_completion} = $shared->{forced} ? 1 : 0;
        }
        else {
            $result->{worker_exit} = 0;
            $result->{worker_signal} = 0;
            $result->{worker_output_bytes} = 0;
            $result->{worker_elapsed_ms} = $elapsed;
            $result->{forced_completion} = 0;
        }

        $result->{last_stage} = $last_stage
            unless exists $result->{last_stage};

        my @trace = (
            'complete',
            'label=' . ($debug_label ne '' ? $debug_label : '-'),
            "pid=$pid",
            'result=' . ($result->{ok} ? 'ok' : ($result->{error} // 'unknown')),
            'stage=' . ($result->{stage} // '-'),
            'last_stage=' . ($result->{last_stage} // '-'),
            'elapsed_ms=' . ($result->{worker_elapsed_ms} // $elapsed),
            'output_bytes=' . ($result->{worker_output_bytes} // 0),
            'exit=' . ($result->{worker_exit} // 0),
            'signal=' . ($result->{worker_signal} // 0),
            'forced=' . ($result->{forced_completion} ? 1 : 0),
        );
        for my $field (qw(attempts status response_code parse_error content_type content_bytes elapsed_ms)) {
            next unless exists($result->{$field})
                && defined($result->{$field})
                && !ref($result->{$field});
            my $value = $clean_trace_value->($result->{$field}, 120);
            push @trace, "$field=$value" if $value ne '';
        }
        $debug_log->($result->{ok} ? 3 : 2, join(' ', @trace));

        my $callback_ok = eval { $callback->($result); 1; };
        if (!$callback_ok && $self && ref($self) && $self->{logger}) {
            my $error = $@ || 'unknown callback failure';
            $error =~ s/\s+/ /g;
            $self->{logger}->log(1, "trivia async callback failed: $error");
        }
    };

    my $launch_ok = eval {
        $worker = Mediabot::AsyncWorker->start(
            loop        => $loop,
            label       => 'trivia fetch',
            timeout     => $timeout,
            term_grace  => 0.5,
            force_grace => 1.5,
            max_output  => 64 * 1024,
            on_progress => $progress,
            child       => sub {
                my ($emit_progress) = @_;

                my $result = eval {
                    _trivia_fetch_sync(
                        $category_id,
                        $difficulty,
                        progress_cb => sub {
                            my ($event) = @_;
                            return unless ref($event) eq 'HASH';
                            return unless ref($emit_progress) eq 'CODE';

                            # Preserve MB396's per-record 20 KiB safety bound
                            # before handing the event to the shared transport.
                            my $probe = eval { JSON::PP::encode_json($event) };
                            return if !defined($probe) || ref($probe);
                            return if length($probe) > 20 * 1024;
                            $emit_progress->($event);
                        },
                    );
                };

                if ($@) {
                    my $error = $@;
                    $error =~ s/[\r\n\0]+/ /g;
                    $error =~ s/\s{2,}/ /g;
                    $result = {
                        ok     => 0,
                        error  => 'worker_exception',
                        stage  => 'sync_worker',
                        detail => substr($error, 0, 240),
                    };
                }

                $result = $fallback unless ref($result) eq 'HASH';

                # Preserve the old 20 KiB bound for the terminal Trivia result.
                my $probe = eval { JSON::PP::encode_json($result) };
                if (!defined($probe) || ref($probe)) {
                    $result = {
                        ok     => 0,
                        error  => 'worker_encode',
                        stage  => 'json_encode',
                        detail => 'could not encode final worker record',
                    };
                }
                elsif (length($probe) > 20 * 1024) {
                    $result = {
                        ok            => 0,
                        error         => 'worker_payload',
                        stage         => 'payload_limit',
                        payload_bytes => length($probe),
                    };
                }

                return $result;
            },
            on_done => $done,
        );
        1;
    };

    # AsyncWorker normally reports setup failures through on_done. Keep a final
    # adapter guard so a launcher exception can never make Trivia silently hang.
    if (!$launch_ok && !$adapter_done) {
        my $error = $@ || 'unknown AsyncWorker launch failure';
        $done->({
            ok     => 0,
            error  => 'worker_setup',
            stage  => 'launcher',
            detail => $error,
        });
    }
    elsif (!$worker && !$adapter_done) {
        $done->({
            ok     => 0,
            error  => 'worker_setup',
            stage  => 'launcher',
            detail => 'AsyncWorker refused launch without a completion result',
        });
    }

    return 1;
}

# ---------------------------------------------------------------------------
# mbTrivia_ctx --- !trivia
# mbTriviaAnswer_ctx --- !answer <text> (or just speak in channel)
# Simple trivia from Open Trivia DB (opentdb.com).
# ---------------------------------------------------------------------------
sub mbTrivia_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
    # mb104-IMP1: !trivia reset [nick] — réinitialiser score
    # Sans nick : reset all (Owner only). Avec nick : délègue à mbTriviaReset_ctx (Master)
    if (@args && lc($args[0]) eq 'reset') {
        if (@args > 1) {
            # Reset un nick spécifique — niveau Master suffit (mbTriviaReset_ctx)
            my @new_args = @args[1..$#args];
            $ctx->{args} = \@new_args;
            return Mediabot::UserCommands::mbTriviaReset_ctx($ctx);
        }
        # Reset all — Owner only
        return unless $ctx->require_level('Owner');
        # mb413-R1: id canal via le helper central (cache d'abord, mb411).
        my $cid_tda = Mediabot::Helpers::channel_id_cached($self, $channel);
        unless (defined $cid_tda) { botNotice($self, $nick, 'Channel not found.'); return; }
        my $rc = { id_channel => $cid_tda };
        my $sth = $self->{dbh}->prepare('DELETE FROM TRIVIA_SCORES WHERE id_channel = ?');
        unless ($sth && $sth->execute($rc->{id_channel})) {
            botNotice($self, $nick, 'DB error.'); $sth->finish if $sth; return;
        }
        my $rows = $sth->rows; $sth->finish;
        botPrivmsg($self, $channel, "All trivia scores reset on $channel ($rows row(s) deleted).");
        return 1;
    }


    if (@args && lc($args[0]) eq 'myscore') {
        my $target = @args > 1 ? lc($args[1]) : lc($nick);
        my $sth_ms = $self->{dbh}->prepare(q{
            SELECT ts.score, ts.last_correct,
                   (SELECT COUNT(*)+1 FROM TRIVIA_SCORES ts2
                    JOIN CHANNEL c2 ON c2.id_channel = ts2.id_channel
                    WHERE c2.name = ? AND ts2.score > ts.score) AS rank
            FROM TRIVIA_SCORES ts
            JOIN CHANNEL c ON c.id_channel = ts.id_channel
            WHERE c.name = ? AND ts.nick = ?
        });
        unless ($sth_ms && $sth_ms->execute($channel, $channel, $target)) {
            botNotice($self, $nick, 'DB error.'); return;
        }
        my $r = $sth_ms->fetchrow_hashref; $sth_ms->finish;
        unless ($r) {
            botPrivmsg($self, $channel, "$target has no trivia score on $channel yet."); return 1;
        }
        botPrivmsg($self, $channel, sprintf(
            "Trivia score for %s on %s: %d correct answer(s)  |  rank #%d  |  last: %s",
            $target, $channel, $r->{score}, $r->{rank}, $r->{last_correct} // '?'));
        return 1;
    }


    if (@args && lc($args[0]) eq 'leaderboard') {
        my $limit = (defined $args[1] && $args[1] =~ /^\d+$/) ? int($args[1]) : 5;
        $limit = 1  if $limit < 1;
        $limit = 10 if $limit > 10;
        my $sth_lb = $self->{dbh}->prepare(q{
            SELECT ts.nick, ts.score, ts.last_correct
            FROM TRIVIA_SCORES ts
            JOIN CHANNEL c ON c.id_channel = ts.id_channel
            WHERE c.name = ?
            ORDER BY ts.score DESC, ts.last_correct DESC
            LIMIT ?
        });
        unless ($sth_lb && $sth_lb->execute($channel, $limit)) {
            botNotice($self, $nick, 'DB error fetching leaderboard.'); return;
        }
        my @lb;
        while (my $r = $sth_lb->fetchrow_hashref) { push @lb, $r; }
        $sth_lb->finish;
        unless (@lb) {
            botPrivmsg($self, $channel, "No trivia scores yet on $channel."); return 1;
        }
        botPrivmsg($self, $channel, "Trivia leaderboard on $channel (top $limit):");
        my $rank = 1;
        for my $r (@lb) {
            botPrivmsg($self, $channel, sprintf("  %d. %-20s %d correct answer(s)  (last: %s)",
                $rank++, $r->{nick}, $r->{score}, $r->{last_correct} // '?'));
        }
        return 1;
    }

    # CC4: named category map — !trivia <name> maps to Open Trivia DB category ID
    my %trivia_cats = (
        general    => 9,  science    => 17, computers  => 18,
        maths      => 19, math       => 19, sports     => 21,
        geography  => 22, history    => 23, politics   => 24,
        art        => 25, celebrities=> 26, animals    => 27,
        vehicles   => 28, comics     => 29, gadgets    => 30,
        anime      => 31, manga      => 31, cartoons   => 32,
        tv         => 14, television => 14, music      => 12,
        film       => 11, movies     => 11, books      => 10,
        mythology  => 20, nature     => 27,
    );

    # !trivia categories remains available even while a question is active.
    if (@args && lc($args[0]) eq 'categories') {
        botPrivmsg($self, $channel,
            'Trivia categories: ' . join(', ', sort keys %trivia_cats));
        return 1;
    }

    if ($self->{_trivia}{$channel} && $self->{_trivia}{$channel}{active}) {
        botNotice($self, $nick, 'A trivia question is already active. Answer it or wait.');
        return;
    }

    if ($self->{_trivia_fetch}{$channel}) {
        botNotice($self, $nick, 'A trivia question request is already in progress.');
        return 1;
    }

    # V1/MB319: start a multi-round game only after active and pending guards.
    # The previous order reset the multi-round state even when another question
    # was still active.
    if (@args && lc($args[0]) eq 'start' && $args[1] && $args[1] =~ /^(\d+)$/) {
        my $rounds = int($args[1]);
        $rounds = 1  if $rounds < 1;
        $rounds = 20 if $rounds > 20;

        $self->{_trivia}{$channel}{multi_total}   = $rounds;
        $self->{_trivia}{$channel}{multi_current} = 0;
        $self->{_trivia}{$channel}{scores}        = {};

        botPrivmsg($self, $channel,
            "Trivia: starting $rounds-round game! Scores reset.");

        @args = ();
    }

    # Optional named category filter.
    my $trivia_cat = (
        @args
        && $args[0] !~ /^\d/
        && $args[0] !~ /^(?:easy|medium|hard)$/i
    ) ? lc(shift @args) : undef;

    my $trivia_cat_id = defined($trivia_cat)
        ? $trivia_cats{$trivia_cat}
        : undef;

    if (defined($trivia_cat) && !defined($trivia_cat_id)) {
        botNotice(
            $self,
            $nick,
            "Unknown trivia category '$trivia_cat'. Use !trivia categories.",
        );
        return 1;
    }

    # Optional difficulty filter.
    my $trivia_diff;
    if (@args && $args[0] =~ /^(?:easy|medium|hard)$/i) {
        $trivia_diff = lc(shift @args);
    }

    my $request_token = join(
        ':',
        $$,
        time(),
        ++$self->{_trivia_fetch_sequence},
    );

    $self->{_trivia_fetch}{$channel} = {
        token        => $request_token,
        requested_by => $nick,
        started      => time(),
    };

    my $log_message = $ctx->message;

    if ($self->{logger}) {
        my $cat_log = defined($trivia_cat_id) ? $trivia_cat_id : 'any';
        my $diff_log = defined($trivia_diff) ? $trivia_diff : 'any';
        $self->{logger}->log(
            3,
            "trivia request queued channel=$channel nick=$nick "
            . "token=$request_token category=$cat_log difficulty=$diff_log",
        );
    }

    return Mediabot::UserCommands::_trivia_fetch_async(
        $self,
        $trivia_cat_id,
        $trivia_diff,
        sub {
            my ($result) = @_;

            my $pending = $self->{_trivia_fetch}{$channel};
            return unless $pending
                && defined($pending->{token})
                && $pending->{token} eq $request_token;

            delete $self->{_trivia_fetch}{$channel};
            delete $self->{_trivia_fetch}
                unless keys %{ $self->{_trivia_fetch} // {} };

            unless (ref($result) eq 'HASH'
                    && $result->{ok}
                    && ref($result->{question}) eq 'HASH') {
                my $error = ref($result) eq 'HASH'
                    && defined($result->{error})
                    && !ref($result->{error})
                        ? $result->{error}
                        : 'unknown';

                my @details = ("error=$error");
                if (ref($result) eq 'HASH') {
                    my %numeric = (
                        attempts            => 'attempts',
                        status              => 'http_status',
                        response_code       => 'api_code',
                        content_bytes       => 'content_bytes',
                        attempt_elapsed_ms  => 'attempt_ms',
                        elapsed_ms          => 'fetch_ms',
                        worker_exit         => 'worker_exit',
                        worker_signal       => 'worker_signal',
                        worker_output_bytes => 'worker_output_bytes',
                        worker_elapsed_ms   => 'worker_ms',
                        forced_completion    => 'forced',
                    );

                    for my $field (sort keys %numeric) {
                        next unless defined($result->{$field})
                            && !ref($result->{$field})
                            && $result->{$field} =~ /\A\d+\z/;
                        push @details, $numeric{$field} . '=' . int($result->{$field});
                    }

                    for my $spec (
                        [stage        => 'stage',        qr/\A[a-z_]+\z/, 64],
                        [last_stage   => 'last_stage',   qr/\A[a-z_]+\z/, 64],
                        [parse_error  => 'parse',        qr/\A[a-z_]+\z/, 64],
                        [content_type => 'content_type', undef,              120],
                        [reason       => 'reason',       undef,              160],
                        [detail       => 'detail',       undef,              240],
                    ) {
                        my ($field, $label, $pattern, $limit) = @$spec;
                        next unless defined($result->{$field})
                            && !ref($result->{$field});
                        my $value = $result->{$field};
                        $value =~ s/[\r\n\0]+/ /g;
                        $value =~ s/\s{2,}/ /g;
                        $value =~ s/^\s+|\s+$//g;
                        next if $pattern && $value !~ $pattern;
                        $value = substr($value, 0, $limit);
                        push @details, "$label=$value" if $value ne '';
                    }
                }

                $self->{logger}->log(
                    1,
                    "trivia fetch failed for $channel token=$request_token: "
                    . join(' ', @details),
                ) if $self->{logger};

                my $message = $error eq 'rate_limit'
                    ? 'Trivia: the question service is rate-limiting this server. Please retry in a few seconds.'
                    : $error eq 'http_timeout'
                        ? 'Trivia: the question service request timed out. Details were logged.'
                        : $error =~ /\A(?:http|http_exception|http_setup)\z/
                            ? 'Trivia: the question service is temporarily unreachable.'
                            : $error eq 'worker_timeout'
                            ? 'Trivia: the question request timed out. Details were logged.'
                            : $error =~ /\Aworker_/
                                ? 'Trivia: the question worker failed. Details were logged.'
                                : $error eq 'response'
                                    ? 'Trivia: the question service returned an unusable response. Details were logged.'
                                    : 'Trivia: could not fetch question. Details were logged.';

                botPrivmsg($self, $channel, $message);
                return;
            }

            if (defined($result->{attempts})
                    && !ref($result->{attempts})
                    && $result->{attempts} =~ /\A\d+\z/
                    && $result->{attempts} > 1
                    && $self->{logger}) {
                $self->{logger}->log(
                    3,
                    "trivia fetch recovered after rate-limit retry for $channel",
                );
            }

            # A different internal path may have activated a question while the
            # fetch was in flight. Never overwrite live game state.
            if ($self->{_trivia}{$channel}
                    && $self->{_trivia}{$channel}{active}) {
                $self->{logger}->log(
                    1,
                    "Discarding stale trivia result for $channel: "
                    . 'a question became active while fetching',
                ) if $self->{logger};
                return;
            }

            my $q = $result->{question};

            require HTML::Entities;

            my $question = HTML::Entities::decode_entities(
                $q->{question} // '',
            );
            my $answer = HTML::Entities::decode_entities(
                $q->{correct_answer} // '',
            );

            my @wrong = map {
                HTML::Entities::decode_entities($_)
            } @{ $q->{incorrect_answers} // [] };

            for ($question, $answer, @wrong) {
                $_ = '' unless defined($_) && !ref($_);
                s/[\r\n\t]+/ /g;
                s/\s{2,}/ /g;
                s/^\s+|\s+$//g;
            }

            unless ($question ne '' && $answer ne '' && @wrong) {
                botPrivmsg($self, $channel,
                    'Trivia: no usable question in response.');
                return;
            }

            my @choices = (@wrong, $answer);

            # Shuffle choices.
            for my $i (reverse 1 .. $#choices) {
                my $j = int(rand($i + 1));
                @choices[$i, $j] = @choices[$j, $i];
            }

            my $_prev = $self->{_trivia}{$channel} // {};
            my $multi_total   = $_prev->{multi_total};
            my $multi_current = $_prev->{multi_current} // 0;

            # MB319: increment and announce the round only after a usable
            # question has been fetched. Failed HTTP/API requests no longer
            # consume a round.
            if ($multi_total) {
                $multi_current++;
                botPrivmsg(
                    $self,
                    $channel,
                    "Round $multi_current/$multi_total:",
                );
            }

            my $trivia_timeout = eval {
                int($self->{conf}->get('main.TRIVIA_TIMEOUT') // 30)
            } // 30;
            $trivia_timeout = 30
                unless $trivia_timeout > 0 && $trivia_timeout <= 120;

            my $category = $q->{category};
            $category = 'Unknown'
                unless defined($category)
                    && !ref($category)
                    && $category ne '';

            my $difficulty = $q->{difficulty};
            $difficulty = ''
                unless defined($difficulty)
                    && !ref($difficulty)
                    && $difficulty =~ /\A(?:easy|medium|hard)\z/i;
            $difficulty = lc($difficulty);

            $self->{_trivia}{$channel} = {
                active         => 1,
                answer         => lc($answer),
                answer_display => $answer,
                started        => Time::HiRes::time(),
                hint_given     => 0,
                category       => $category,
                difficulty     => $difficulty,
                scores         => ($_prev->{scores} // {}),
                multi_total    => $multi_total,
                multi_current  => $multi_current,
                timeout        => $trivia_timeout,
                deadline       => time() + $trivia_timeout,
            };

            my $opts = join('  ', map { "[$_]" } @choices);

            my $diff_tag = '';
            if ($difficulty ne '') {
                my %diff_colors = (
                    easy   => "\x0303",
                    medium => "\x0308",
                    hard   => "\x0304",
                );
                my $color = $diff_colors{$difficulty} // '';
                $diff_tag = $color
                    ? " ${color}[" . uc($difficulty) . "]\x0f"
                    : " [" . uc($difficulty) . "]";
            }

            botPrivmsg(
                $self,
                $channel,
                "Trivia$diff_tag ($category): $question",
            );
            botPrivmsg(
                $self,
                $channel,
                "Choices: $opts -- reply with !answer <choice> "
                . "or just say it (${trivia_timeout}s)",
            );

            $self->{metrics}->inc('mediabot_trivia_questions_total')
                if $self->{metrics};

            logBot(
                $self,
                $log_message,
                $channel,
                'trivia',
                $category,
            );

            return 1;
        },
        debug_label => "channel=$channel token=$request_token requested_by=$nick",
    );
}

# Called from on_message_PRIVMSG hook and !answer command
sub checkTriviaAnswer {
    my ($self, $nick, $channel, $text) = @_;
    my $trivia = $self->{_trivia}{$channel};
    return unless $trivia && $trivia->{active};
    if (time() > $trivia->{deadline}) {
        $trivia->{active} = 0;
        # DD6: enriched timeout message with category + mb108-IMP1: difficulty
        my $cat_str  = $trivia->{category}   ? " ($trivia->{category})"  : '';
        my $diff_str = '';
        if (defined $trivia->{difficulty} && $trivia->{difficulty} ne '') {
            my %dc = ( easy => "\x0303", medium => "\x0308", hard => "\x0304" );
            my $dl = lc($trivia->{difficulty});
            my $c  = $dc{$dl} // '';
            $diff_str = $c ? " ${c}[" . uc($dl) . "]\x0f" : " [" . uc($dl) . "]";
        }
        Mediabot::Helpers::botPrivmsg($self, $channel,
            "Time's up!$diff_str The answer was: $trivia->{answer_display}${cat_str}");
        $self->{metrics}->inc('mediabot_trivia_timeout_total') if $self->{metrics};
        return;
    }
    # Y5: hint at half-time — reveal first letter(s)
    if (!$trivia->{hint_given} && defined $trivia->{deadline}
            && $trivia->{deadline} - time() < ($trivia->{timeout} // 30) / 2) {
        $trivia->{hint_given} = 1;
        my $ans = $trivia->{answer} // '';
        # mb402-R1: préserver la STRUCTURE de la réponse dans l'indice. Avant,
        # tout sauf la première lettre devenait '_', espaces compris :
        # "emile zola" -> "e_________" (le joueur ignorait qu'il y a 2 mots).
        # On ne masque que les caractères de mot ; espaces, tirets et
        # apostrophes restent visibles : "e____ ____", "r___ '_' ____".
        my $hint = '';
        if (length $ans) {
            my $rest = substr($ans, 1);
            $rest =~ s/[^\s'\-]/_/g;
            $hint = substr($ans, 0, 1) . $rest;
        }
        Mediabot::Helpers::botPrivmsg($self, $channel, "Hint: $hint");
    }
    # B3/fix: guard against undef answer + wrap regex in eval
    return unless defined $trivia->{answer};
    # mb339-B1: la branche "contient la réponse" faisait un match SOUS-CHAÎNE brut
    # (lc($text) =~ /\Qanswer\E/), donc un mot plus long contenant la réponse
    # validait à tort (réponse "war" gagnée par "warsaw"), et une mention
    # incidente terminait la manche. On borne désormais la réponse par des
    # frontières alphanumériques, comme le fait déjà checkQuotegameAnswer pour
    # l'auteur (mb121-B2) : "the answer is paris" / "paris!" gagnent toujours,
    # mais "warsaw" ne valide plus "war".
    my $answer = $trivia->{answer};
    # mb443-B1: keep legacy high bytes inside words. MB920 also treats decoded
    # Unicode letters, numbers and combining marks as word material. Public
    # IRC text is decoded at the application boundary; a wider letter must not
    # turn an embedded answer into a complete word. Existing punctuation rules remain.
    my $matched = eval {
        lc($text) eq $answer
        || lc($text) =~ /(?<![A-Za-z0-9\x80-\xFF\p{L}\p{N}\p{M}])\Q$answer\E(?![A-Za-z0-9\x80-\xFF\p{L}\p{N}\p{M}])/
    };
    return unless $matched;
    $trivia->{active} = 0;
    $trivia->{scores}{$nick} = ($trivia->{scores}{$nick} // 0) + 1;
    # X10: Prometheus counter for correct trivia answers
    # AA1: persist trivia score in DB (TRIVIA_SCORES table)
    eval {
        # mb413-R1: id canal via le helper central (cache d'abord, mb411).
        my $cid_tsi = Mediabot::Helpers::channel_id_cached($self, $channel);
        {
            my $rc = defined($cid_tsi) ? { id_channel => $cid_tsi } : undef;
            if ($rc) {
                my $sth_u = $self->{dbh}->prepare(q{
                    INSERT INTO TRIVIA_SCORES (id_channel, nick, score, last_correct)
                    VALUES (?, ?, 1, NOW())
                    ON DUPLICATE KEY UPDATE score = score + 1, last_correct = NOW()
                });
                if ($sth_u) {
                    unless ($sth_u->execute($rc->{id_channel}, lc($nick))) {
                        $self->{logger}->log(1, "TRIVIA_SCORES persist execute failed: $DBI::errstr")
                            if $self->{logger};
                    }
                    $sth_u->finish;
                }
            }
        }
    };
    if ($@) {
        $self->{logger}->log(1, "AA1: TRIVIA_SCORES persist failed: $@");
    } else {
        $self->{metrics}->inc('mediabot_trivia_db_saves_total') if $self->{metrics};
    }
    $self->{metrics}->inc('mediabot_trivia_correct_total') if $self->{metrics};
    my $score = $trivia->{scores}{$nick};
    my $diff_str = '';
    if (defined $trivia->{difficulty} && $trivia->{difficulty} ne '') {
        my %diff_colors = ( easy => "\x0303", medium => "\x0308", hard => "\x0304" );
        my $dl  = lc($trivia->{difficulty});
        my $col = $diff_colors{$dl} // '';
        $diff_str = $col ? " ${col}[" . uc($dl) . "]\x0f" : " [" . uc($dl) . "]";
    }
    Mediabot::Helpers::botPrivmsg($self, $channel,
        "Correct, $nick!$diff_str The answer was: $trivia->{answer_display}  (score: $score)");

    # mb115: hook achievements trivia (score atteint, sniper si réponse <= 2s)
    if ($self->{achievements}) {
        my $response_time = Time::HiRes::time()
            - ($trivia->{started} // Time::HiRes::time());
        $response_time = 0 if $response_time < 0;
        # mb610-B1: $score est le score de la PARTIE en cours. Un palier
        # « 100 bonnes reponses » exigeait donc 100 reponses dans une seule
        # session — inatteignable. Le hook recoit desormais le total
        # cumule persistant ; l'affichage du jeu, lui, ne bouge pas.
        my $total = _ach_progress($self, 'trivia_correct', $nick, $channel) // $score;
        eval {
            $self->{achievements}->check_trivia($nick, $channel, $total, $response_time);
        };
        if ($@) { $self->{logger}->log(1, "achievements check_trivia error: $@"); }
    }
    # W1: show intermediate scores in multi-round mode
    if ($trivia->{multi_total}) {
        my $cur = $trivia->{multi_current} // 0;
        my $tot = $trivia->{multi_total};
        my %sc  = %{ $trivia->{scores} // {} };
        my @sboard = map { "$_:$sc{$_}" }
                     sort { $sc{$b} <=> $sc{$a} } keys %sc;
        Mediabot::Helpers::botPrivmsg($self, $channel,
            "Scores after round $cur/$tot: " . join('  ', @sboard[0..($#sboard > 4 ? 4 : $#sboard)]));
        if ($cur >= $tot) {
            Mediabot::Helpers::botPrivmsg($self, $channel,
                "Game over! Final scores: " . join('  ', @sboard));
            delete $trivia->{multi_total};
            delete $trivia->{multi_current};
        }
    }
}

# ---------------------------------------------------------------------------
# mbTriviaTop_ctx --- !triviatop [n]  (AA1)
# Show top trivia scores from DB (persistent across sessions).
# ---------------------------------------------------------------------------
sub mbTriviaTop_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
    my $limit   = (@args && $args[0] =~ /^(\d+)$/) ? int($args[0]) : 5;
    $limit = 1 if $limit < 1; $limit = 15 if $limit > 15;
    # mb411-R1: id canal via le helper central (cache d'abord).
    my $cid_tt = Mediabot::Helpers::channel_id_cached($self, $channel);
    unless (defined $cid_tt) { botPrivmsg($self, $channel, 'Channel not found.'); return; }
    my $rc = { id_channel => $cid_tt };
    my $sth = $self->{dbh}->prepare(q{
        SELECT nick, score, last_correct
        FROM TRIVIA_SCORES
        WHERE id_channel = ?
        ORDER BY score DESC LIMIT ?
    });
    unless ($sth && $sth->execute($rc->{id_channel}, $limit)) {
        botPrivmsg($self, $channel, 'DB error.'); $sth->finish if $sth; return;
    }
    my @ranked; my $i = 1;
    my @raw;  # JJ2: collect all rows first to compute total
    while (my $r = $sth->fetchrow_hashref) {
        push @raw, { nick => $r->{nick}, score => $r->{score}//0 };
    }
    $sth->finish;
    my $t_tot = 0; $t_tot += $_->{score} for @raw;
    for my $r (@raw) {
        my $pct = $t_tot > 0 ? sprintf(' (%.0f%%)', 100*$r->{score}/$t_tot) : '';
        push @ranked, "#${i}. $r->{nick}: $r->{score}$pct";
        $i++;
    }
    unless (@ranked) {
        botPrivmsg($self, $channel, 'No trivia scores in DB yet.'); return 1;
    }
    botPrivmsg($self, $channel, "Trivia hall of fame ($channel): " . join('  ', @ranked));
    return 1;
}

# ---------------------------------------------------------------------------
# mbTriviaReset_ctx --- !triviareset <nick>  (BB10)
# Reset a nick's trivia score in DB. Requires Master.
# ---------------------------------------------------------------------------
sub mbTriviaReset_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
    return unless $ctx->require_level('Master');
    my $target = lc($args[0] // '');
    unless ($target) {
        botNotice($self, $nick, 'Syntax: triviareset <nick>'); return;
    }
    # mb411-R1: id canal via le helper central (cache d'abord).
    my $cid_ts = Mediabot::Helpers::channel_id_cached($self, $channel);
    unless (defined $cid_ts) { botNotice($self, $nick, 'Channel not found.'); return; }
    my $rc = { id_channel => $cid_ts };
    my $sth = $self->{dbh}->prepare(
        'DELETE FROM TRIVIA_SCORES WHERE id_channel = ? AND nick = ?'
    );
    unless ($sth && $sth->execute($rc->{id_channel}, $target)) {
        botNotice($self, $nick, 'DB error.'); $sth->finish if $sth; return;
    }
    my $rows = $sth->rows; $sth->finish;
    if ($rows > 0) {
        Mediabot::Helpers::botPrivmsg($self, $channel,
            "$nick reset trivia score for $target.");
    } else {
        botNotice($self, $nick, "No trivia score found for '$target' on $channel.");
    }
    return 1;
}

sub mbTriviaStop_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;

    return unless $ctx->require_level('Master');

    my $pending = delete $self->{_trivia_fetch}{$channel};
    delete $self->{_trivia_fetch}
        if $self->{_trivia_fetch}
            && !keys %{ $self->{_trivia_fetch} };

    my $trivia = $self->{_trivia}{$channel};
    my $active = $trivia && $trivia->{active};

    # MB983: a series also exists while fetching or between questions. Merely
    # cancelling its request token would let the next command resume that series.
    unless ($active || $pending || ($trivia && $trivia->{multi_total})) {
        botNotice($self, $nick, 'No active trivia on this channel.');
        return 1;
    }

    if ($trivia) {
        $trivia->{active} = 0;
        delete $trivia->{multi_total};
        delete $trivia->{multi_current};

        # B-68-2/fix: clear scores and hint so next game starts clean.
        delete $trivia->{scores};
        $trivia->{hint_given} = 0;
    }

    unless ($active) {
        botNotice($self, $nick, $pending
            ? 'Pending trivia question request cancelled.'
            : 'Trivia game stopped.');
        return 1;
    }

    Mediabot::Helpers::botPrivmsg(
        $self,
        $channel,
        "Trivia stopped by $nick. Answer: $trivia->{answer_display}",
    );

    return 1;
}

sub mbTriviaScore_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my $scores  = $self->{_trivia}{$channel}{scores} // {};
    unless (%$scores) {
        botPrivmsg($self, $channel, 'No trivia scores yet.'); return 1;
    }
    my @sorted = sort { $scores->{$b} <=> $scores->{$a} } keys %$scores;
    # IMP17: also show total correct answers this session
    my $total_correct = 0; $total_correct += $scores->{$_} for keys %$scores;
    my $top = join(', ', map {
        my $pct = $total_correct > 0
            ? sprintf(' (%.0f%%)', 100*$scores->{$_}/$total_correct) : '';
        "$_: $scores->{$_}$pct"
    } @sorted[0..($#sorted > 4 ? 4 : $#sorted)]);
    botPrivmsg($self, $channel,
        "Trivia scores on $channel ($total_correct total): $top");
    logBot($self, $ctx->message, $channel, 'triviascore', '');  # Q1
    return 1;
}

1;
