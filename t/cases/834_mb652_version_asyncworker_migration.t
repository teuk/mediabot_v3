# t/cases/834_mb652_version_asyncworker_migration.t
# =============================================================================
# MB652 — migrate the version checker, and only the version checker, onto the
# shared Mediabot::AsyncWorker lifecycle while preserving callback semantics.
# =============================================================================

use strict;
use warnings;
use utf8;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }

sub _slurp_834 {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

sub _extract_834 {
    my ($src, $name) = @_;
    my $re = qr/^sub\s+\Q$name\E\s*\{/m;
    return undef unless $src =~ /$re/g;

    my ($start, $pos, $depth) = ($-[0], pos($src), 1);
    my ($quote, $escape, $comment);
    while ($pos < length($src)) {
        my $ch = substr($src, $pos, 1);
        if ($comment) { $comment = 0 if $ch eq "\n"; $pos++; next; }
        if (defined $quote) {
            if ($escape) { $escape = 0; $pos++; next; }
            if ($ch eq '\\') { $escape = 1; $pos++; next; }
            if ($ch eq $quote) { undef $quote; $pos++; next; }
            $pos++; next;
        }
        if ($ch eq '#') { $comment = 1; $pos++; next; }
        if ($ch eq "'" || $ch eq '"') { $quote = $ch; $pos++; next; }
        $depth++ if $ch eq '{';
        $depth-- if $ch eq '}';
        return substr($src, $start, $pos + 1 - $start) if $depth == 0;
        $pos++;
    }
    return undef;
}

{
    package MB652::Loop;
    sub new { bless {}, shift }
    sub add { 1 }
    sub remove { 1 }
}

{
    package MB652::Logger;
    sub new { bless { messages => [] }, shift }
    sub log { my ($self, @m) = @_; push @{ $self->{messages} }, \@m; 1 }
}

{
    package MB652::Bot;
    sub getLoop { $_[0]{loop} }
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_834('Mediabot/Helpers.pm');
    my $async = _extract_834($src, 'getVersion_async');
    my $reason = _extract_834($src, '_version_asyncworker_reason');

    $assert->ok(defined $async, 'mb652-834: getVersion_async located');
    $assert->ok(defined $reason, 'mb652-834: AsyncWorker reason adapter located');

    $assert->like($src, qr/use\s+Mediabot::AsyncWorker;/,
        'mb652-834: Helpers loads shared AsyncWorker');
    $assert->like($async // '', qr/Mediabot::AsyncWorker->start\(/,
        'mb652-834: version async path delegates to shared worker');

    my $exec = $async // '';
    $exec =~ s/#.*$//mg;
    $assert->unlike($exec, qr/\b(?:pipe|fork|waitpid)\s*\(/,
        'mb652-834: version adapter contains no private pipe/fork/reap lifecycle');
    $assert->unlike($exec, qr/\bwatch_process\s*\(/,
        'mb652-834: version adapter contains no private process watcher');
    $assert->unlike($exec, qr/IO::Async::(?:Stream|Timer::Countdown)->new/,
        'mb652-834: version adapter contains no private lifecycle IO objects');
    $assert->unlike($exec, qr/\bkill\s+['"](?:TERM|KILL)['"]/,
        'mb652-834: version adapter contains no private timeout signals');

    $assert->like($async // '', qr/timeout\s*=>\s*\$timeout/,
        'mb652-834: computed version timeout is passed to AsyncWorker');
    $assert->like($async // '', qr/term_grace\s*=>\s*0\.2/,
        'mb652-834: historical TERM grace preserved');
    $assert->like($async // '', qr/force_grace\s*=>\s*2/,
        'mb652-834: historical liveness grace preserved');
    $assert->like($async // '', qr/max_output\s*=>\s*1024/,
        'mb652-834: historical version payload bound preserved');
    $assert->like($async // '',
        qr/return \[\$local, \$remote, \$why\]/,
        'mb652-834: child returns version-specific structured value');
    $assert->like($async // '',
        qr/local \$self->\{logger\} = bless \{\}, 'Mediabot::Helpers::_SilentLogger'/,
        'mb652-834: child keeps duplicate-log suppression');

    # The original no-loop synchronous compatibility path is intentionally
    # retained for startup/unit callers that do not own a usable IO::Async loop.
    $assert->like($async // '',
        qr/unless\s*\(\$loop\s*&&.*?getVersion\(\$self\).*?return 1;/s,
        'mb652-834: no-loop compatibility path remains synchronous');

    # Terminal mappings are tested functionally below; keep a structural guard
    # that all expected AsyncWorker terminal codes remain represented.
    for my $code (qw(
        worker_timeout worker_signal worker_exit worker_empty worker_decode
        worker_setup worker_liveness worker_cancelled worker_exception
    )) {
        $assert->like($reason // '', qr/\Q$code\E/,
            "mb652-834: terminal mapping mentions $code");
    }

    # Functional adapter test with a fake AsyncWorker launcher: no real fork or
    # network is needed to prove the version-specific policy.
    require Mediabot::Helpers;
    require Mediabot::AsyncWorker;

    my $reason_fn = \&Mediabot::Helpers::_version_asyncworker_reason;
    $assert->is($reason_fn->({ ok => 0, error => 'worker_timeout' }),
        'version check timed out',
        'mb652-834: timeout reason preserved');
    $assert->is($reason_fn->({ ok => 0, error => 'worker_signal', signal => 9 }),
        'version check worker terminated by signal 9',
        'mb652-834: signal reason preserved');
    $assert->is($reason_fn->({ ok => 0, error => 'worker_exit', exit => 7 }),
        'version check worker exited with status 7',
        'mb652-834: exit reason preserved');
    $assert->is($reason_fn->({ ok => 0, error => 'worker_empty' }),
        'version check worker produced no result',
        'mb652-834: empty-result reason preserved');
    $assert->is($reason_fn->({ ok => 0, error => 'worker_decode' }),
        'version check worker returned an invalid result',
        'mb652-834: invalid-result reason preserved');
    $assert->like(
        $reason_fn->({ ok => 0, error => 'worker_setup', stage => 'pipe',
                       detail => 'synthetic pipe failure' }),
        qr/^version check worker pipe failed: synthetic pipe failure$/,
        'mb652-834: pipe setup reason preserved');
    $assert->like(
        $reason_fn->({ ok => 0, error => 'worker_setup', stage => 'fork',
                       detail => 'synthetic fork failure' }),
        qr/^version check worker could not start: synthetic fork failure$/,
        'mb652-834: fork setup reason preserved');
    $assert->is($reason_fn->({ ok => 0, error => 'worker_liveness' }),
        'version check worker finalization timed out',
        'mb652-834: liveness-backstop failure has explicit reason');

    my $loop = MB652::Loop->new;
    my $logger = MB652::Logger->new;
    my $bot = bless {
        loop              => $loop,
        logger            => $logger,
        main_prog_version => '3.4dev-20260817_080225',
    }, 'MB652::Bot';

    my %captured;
    my @callback;
    {
        no warnings 'redefine';
        local *Mediabot::AsyncWorker::start = sub {
            my ($class, %args) = @_;
            %captured = %args;
            return bless {}, 'MB652::FakeWorker';
        };

        my $started = Mediabot::Helpers::getVersion_async(
            $bot,
            sub { @callback = @_ },
            timeout => 7,
        );

        $assert->ok($started, 'mb652-834: adapter reports async request handled');
        $assert->is($captured{loop}, $loop,
            'mb652-834: bot event loop is passed unchanged');
        $assert->is($captured{timeout}, 7,
            'mb652-834: explicit timeout reaches shared worker');
        $assert->is($captured{term_grace}, 0.2,
            'mb652-834: TERM grace reaches shared worker');
        $assert->is($captured{force_grace}, 2,
            'mb652-834: force grace reaches shared worker');
        $assert->is($captured{max_output}, 1024,
            'mb652-834: output budget reaches shared worker');
        $assert->ok(ref($captured{child}) eq 'CODE',
            'mb652-834: child policy callback supplied');
        $assert->ok(ref($captured{on_done}) eq 'CODE',
            'mb652-834: completion adapter supplied');
        $assert->is(scalar(@callback), 0,
            'mb652-834: fake async launch does not fabricate inline result');

        local *Mediabot::Helpers::getVersion = sub {
            $_[0]{_version_fetch_error} = undef;
            return ('3.4dev-20260817_080225', '3.4dev-20260818_010203');
        };
        my $child_value = $captured{child}->();
        $assert->is(ref($child_value), 'ARRAY',
            'mb652-834: child policy returns array payload for shared JSON envelope');
        $assert->is($child_value->[0], '3.4dev-20260817_080225',
            'mb652-834: child returns usable local version');
        $assert->is($child_value->[1], '3.4dev-20260818_010203',
            'mb652-834: child returns usable remote version');
        $assert->ok(!defined $child_value->[2],
            'mb652-834: nominal child result invents no failure reason');

        $captured{on_done}->({
            ok     => 1,
            value  => $child_value,
            exit   => 0,
            signal => 0,
        });
        $assert->is($callback[0], '3.4dev-20260817_080225',
            'mb652-834: parent callback receives local version');
        $assert->is($callback[1], '3.4dev-20260818_010203',
            'mb652-834: parent callback receives remote version');
        $assert->ok(!defined $callback[2],
            'mb652-834: nominal parent callback has no reason');
    }

    # Child exceptions from getVersion are still converted into bounded,
    # version-specific data before AsyncWorker serialises the value.
    {
        no warnings 'redefine';
        my %args;
        local *Mediabot::AsyncWorker::start = sub {
            my ($class, %got) = @_;
            %args = %got;
            return bless {}, 'MB652::FakeWorker';
        };
        local *Mediabot::Helpers::getVersion = sub {
            die "synthetic version explosion at Helpers.pm line 999.\n";
        };

        Mediabot::Helpers::getVersion_async($bot, sub { }, timeout => 7);
        my $value = $args{child}->();

        $assert->is($value->[0], '3.4dev-20260817_080225',
            'mb652-834: child crash retains cached local version');
        $assert->is($value->[1], 'Undefined',
            'mb652-834: child crash leaves remote Undefined');
        $assert->like($value->[2], qr/^version check crashed: synthetic version explosion$/,
            'mb652-834: child crash becomes bounded clean reason');
    }

    # Structured worker failure maps back to the historical 3-argument API.
    {
        no warnings 'redefine';
        my @got;
        local *Mediabot::AsyncWorker::start = sub {
            my ($class, %args) = @_;
            $args{on_done}->({
                ok        => 0,
                error     => 'worker_timeout',
                stage     => 'timeout',
                detail    => 'version check exceeded 7s',
                timed_out => 1,
            });
            return undef;
        };

        my $started = Mediabot::Helpers::getVersion_async(
            $bot, sub { @got = @_ }, timeout => 7,
        );
        $assert->ok($started,
            'mb652-834: synchronous setup/error completion is still handled');
        $assert->is($got[0], '3.4dev-20260817_080225',
            'mb652-834: timeout callback retains cached local version');
        $assert->is($got[1], 'Undefined',
            'mb652-834: timeout callback keeps remote Undefined');
        $assert->is($got[2], 'version check timed out',
            'mb652-834: timeout callback keeps historical reason text');
    }
    # Even an unexpected launcher exception is converted into the historical
    # handled callback contract instead of escaping into the IRC event loop.
    {
        no warnings 'redefine';
        my @got;
        local *Mediabot::AsyncWorker::start = sub {
            die "synthetic launcher failure\n";
        };

        my $started = Mediabot::Helpers::getVersion_async(
            $bot, sub { @got = @_ }, timeout => 7,
        );
        $assert->ok($started,
            'mb652-834: unexpected launcher exception is handled');
        $assert->is($got[0], '3.4dev-20260817_080225',
            'mb652-834: launcher exception retains cached local version');
        $assert->is($got[1], 'Undefined',
            'mb652-834: launcher exception keeps remote Undefined');
        $assert->like($got[2], qr/^version check worker setup failed: synthetic launcher failure/,
            'mb652-834: launcher exception becomes explicit setup reason');
    }

};
