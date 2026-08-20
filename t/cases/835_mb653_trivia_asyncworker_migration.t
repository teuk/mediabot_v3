# t/cases/835_mb653_trivia_asyncworker_migration.t
# =============================================================================
# MB653 — migrate Trivia's asynchronous fetch wrapper to Mediabot::AsyncWorker
# while preserving the existing Trivia result/error/progress contract.
# =============================================================================

use strict;
use warnings;
use utf8;
use File::Spec;

sub _slurp_835 {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_835 {
    my ($src, $name) = @_;

    my $re = qr/^sub\s+\Q$name\E\s*\{/m;
    return undef unless $src =~ /$re/g;

    my $start = $-[0];
    my $pos   = pos($src);
    my $depth = 1;
    my $quote;
    my $escape  = 0;
    my $comment = 0;

    while ($pos < length($src)) {
        my $ch = substr($src, $pos, 1);

        if ($comment) {
            $comment = 0 if $ch eq "\n";
            $pos++;
            next;
        }

        if (defined $quote) {
            if ($escape) {
                $escape = 0;
            }
            elsif ($ch eq '\\') {
                $escape = 1;
            }
            elsif ($ch eq $quote) {
                undef $quote;
            }
            $pos++;
            next;
        }

        if ($ch eq '#') {
            $comment = 1;
        }
        elsif ($ch eq q{'}) {
            $quote = q{'};
        }
        elsif ($ch eq q{"}) {
            $quote = q{"};
        }
        elsif ($ch eq '{') {
            $depth++;
        }
        elsif ($ch eq '}') {
            $depth--;
            return substr($src, $start, $pos + 1 - $start)
                if $depth == 0;
        }

        $pos++;
    }

    return undef;
}

{
    package MB653::WorkerHandle;
    sub new { bless { pid => $_[1] }, $_[0] }
    sub pid { $_[0]{pid} }
}

{
    package MB653::Bot;
    sub new {
        my ($class) = @_;
        return bless {
            loop   => bless({}, 'MB653::Loop'),
            logger => bless({ rows => [] }, 'MB653::Logger'),
        }, $class;
    }
    sub getLoop { $_[0]{loop} }
}

{
    package MB653::Loop;
    sub add { 1 }
    sub remove { 1 }
    sub watch_process { 1 }
}

{
    package MB653::Logger;
    sub log {
        my ($self, $level, $message) = @_;
        push @{ $self->{rows} }, [$level, $message];
        return 1;
    }
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_835(
        File::Spec->catfile('.', 'Mediabot', 'UserCommands.pm')
    );
    my $async = _extract_sub_835($src, '_trivia_fetch_async');

    $assert->ok(defined($async),
        'mb653-835: trivia async adapter found');
    $assert->like($src, qr/use\s+Mediabot::AsyncWorker;/,
        'mb653-835: UserCommands loads the shared AsyncWorker');
    $assert->like($async // '', qr/Mediabot::AsyncWorker->start\(/,
        'mb653-835: trivia delegates worker launch');
    $assert->like($async // '', qr/on_progress\s*=>\s*\$progress/,
        'mb653-835: trivia registers shared progress handling');
    $assert->like($async // '', qr/timeout\s*=>\s*\$timeout/,
        'mb653-835: existing trivia outer timeout is delegated');
    $assert->like($async // '', qr/term_grace\s*=>\s*0\.5/,
        'mb653-835: existing TERM grace is preserved');
    $assert->like($async // '', qr/force_grace\s*=>\s*1\.5/,
        'mb653-835: existing forced-completion deadline is preserved');
    $assert->like($async // '', qr/max_output\s*=>\s*64\s*\*\s*1024/,
        'mb653-835: shared transport has an explicit total byte bound');
    $assert->like(
        $async // '',
        qr/_trivia_fetch_sync\(\s*\$category_id,\s*\$difficulty,.*?progress_cb\s*=>/s,
        'mb653-835: shared child reuses the synchronous Trivia fetch core',
    );

    my $executable = $async // '';
    $executable =~ s/#.*$//mg;
    $assert->unlike($executable, qr/\bpipe\s*\(/,
        'mb653-835: trivia adapter owns no private pipe');
    $assert->unlike($executable, qr/\bfork\s*\(/,
        'mb653-835: trivia adapter owns no private fork');
    $assert->unlike($executable, qr/\bwatch_process\s*\(/,
        'mb653-835: trivia adapter owns no process watcher');
    $assert->unlike($executable, qr/IO::Async::(?:Stream|Timer::Countdown)->new/,
        'mb653-835: trivia adapter owns no private IO::Async stream/timer');

    my $compiled = eval "package MB653::Probe;\n$async\n1;";
    $assert->ok($compiled,
        'mb653-835: extracted trivia adapter compiles in isolation');

    no warnings 'redefine';

    # Success path with progress: the adapter must preserve the Trivia result
    # shape while adding shared-worker transport metadata.
    {
        my %captured;
        my @callback;
        my $callback_count = 0;
        my $bot = MB653::Bot->new;

        local *MB653::Probe::_trivia_fetch_sync = sub {
            my ($category, $difficulty, %opts) = @_;
            $opts{progress_cb}->({
                stage   => 'http_get_start',
                attempt => 1,
            });
            $opts{progress_cb}->({
                stage         => 'api_parse_ok',
                response_code => 0,
            });
            return {
                ok       => 1,
                attempts => 1,
                status   => 200,
                question => {
                    question => 'Question?',
                    correct  => 'Answer',
                },
            };
        };

        local *Mediabot::AsyncWorker::start = sub {
            my ($class, %args) = @_;
            %captured = %args;
            my $handle = MB653::WorkerHandle->new(65301);
            my $emit = sub {
                my ($event) = @_;
                $args{on_progress}->($event, $handle)
                    if ref($args{on_progress}) eq 'CODE';
                return 1;
            };
            my $value = $args{child}->($emit);
            $args{on_done}->({
                ok             => 1,
                value          => $value,
                pid            => 65301,
                exit           => 0,
                signal         => 0,
                bytes          => 321,
                elapsed_s      => 0.125,
                forced         => 0,
                progress_count => 2,
            });
            return $handle;
        };

        my $started = MB653::Probe::_trivia_fetch_async(
            $bot, 9, 'easy',
            sub {
                @callback = @_;
                $callback_count++;
            },
            timeout     => 7,
            debug_label => 'channel=#test token=42 requested_by=Teuk',
        );

        $assert->ok($started,
            'mb653-835: successful shared-worker request is handled');
        $assert->is($callback_count, 1,
            'mb653-835: success callback fires exactly once');
        $assert->ok($callback[0]{ok},
            'mb653-835: successful Trivia result remains successful');
        $assert->is($callback[0]{question}{correct}, 'Answer',
            'mb653-835: Trivia question payload survives adaptation');
        $assert->is($callback[0]{last_stage}, 'api_parse_ok',
            'mb653-835: last streamed stage survives into final diagnostics');
        $assert->is($callback[0]{worker_output_bytes}, 321,
            'mb653-835: shared byte count maps to historical worker metadata');
        $assert->is($callback[0]{worker_elapsed_ms}, 125,
            'mb653-835: shared elapsed time maps to integer milliseconds');
        $assert->is($captured{timeout}, 7,
            'mb653-835: caller timeout reaches AsyncWorker');
        $assert->is($captured{term_grace}, 0.5,
            'mb653-835: TERM grace reaches AsyncWorker');
        $assert->is($captured{force_grace}, 1.5,
            'mb653-835: force grace reaches AsyncWorker');
        $assert->is($captured{max_output}, 64 * 1024,
            'mb653-835: total transport bound reaches AsyncWorker');

        my $log = join("\n", map { $_->[1] } @{ $bot->{logger}{rows} });
        $assert->like($log, qr/stage=http_get_start/,
            'mb653-835: first progress stage is logged');
        $assert->like($log, qr/stage=api_parse_ok/,
            'mb653-835: second progress stage is logged');
        $assert->like($log, qr/result=ok/,
            'mb653-835: completion remains visible in bounded diagnostics');
    }

    # Shared timeout must retain the old Trivia-facing vocabulary and last
    # progress stage rather than exposing a new user-visible error contract.
    {
        my @callback;
        my $callback_count = 0;
        my $bot = MB653::Bot->new;

        local *Mediabot::AsyncWorker::start = sub {
            my ($class, %args) = @_;
            my $handle = MB653::WorkerHandle->new(65302);
            $args{on_progress}->(
                { stage => 'rate_limit_wait', delay_ms => 5500 },
                $handle,
            );
            $args{on_done}->({
                ok        => 0,
                error     => 'worker_timeout',
                stage     => 'timeout',
                detail    => 'trivia fetch exceeded budget',
                pid       => 65302,
                exit      => 0,
                signal    => 9,
                bytes     => 88,
                elapsed_s => 0.750,
                forced    => 1,
            });
            return $handle;
        };

        my $started = MB653::Probe::_trivia_fetch_async(
            $bot, undef, undef,
            sub {
                @callback = @_;
                $callback_count++;
            },
            timeout => 0.2,
        );

        $assert->ok($started,
            'mb653-835: shared timeout is handled');
        $assert->is($callback_count, 1,
            'mb653-835: timeout callback fires exactly once');
        $assert->is($callback[0]{error}, 'worker_timeout',
            'mb653-835: timeout keeps historical Trivia error code');
        $assert->is($callback[0]{stage}, 'async_timeout',
            'mb653-835: timeout keeps historical Trivia stage');
        $assert->is($callback[0]{last_stage}, 'rate_limit_wait',
            'mb653-835: timeout keeps last streamed child stage');
        $assert->is($callback[0]{worker_signal}, 9,
            'mb653-835: timeout keeps worker signal metadata');
        $assert->is($callback[0]{forced_completion}, 1,
            'mb653-835: timeout keeps forced-completion metadata');
    }

    # Launcher exceptions are data, never a silent stuck per-channel request.
    {
        my @callback;
        my $bot = MB653::Bot->new;

        local *Mediabot::AsyncWorker::start = sub {
            die "synthetic AsyncWorker launcher failure\n";
        };

        my $started = MB653::Probe::_trivia_fetch_async(
            $bot, undef, undef,
            sub { @callback = @_ },
            timeout => 1,
        );

        $assert->ok($started,
            'mb653-835: launcher failure is still a handled request');
        $assert->is($callback[0]{error}, 'worker_setup',
            'mb653-835: launcher failure becomes worker_setup');
        $assert->is($callback[0]{stage}, 'launcher',
            'mb653-835: launcher failure identifies adapter stage');
    }
};
