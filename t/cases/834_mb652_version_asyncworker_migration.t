# t/cases/834_mb652_version_asyncworker_migration.t
# =============================================================================
# MB652 — migrate the version checker, and only the version checker, onto the
# shared Mediabot::AsyncWorker lifecycle while preserving callback semantics.
# =============================================================================

use strict;
use warnings;
use utf8;
use IPC::Open3 qw(open3);
use Symbol qw(gensym);
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

{
    package MB898::VersionBot;
    sub getDetailedVersion { Mediabot::Helpers::getDetailedVersion(@_) }
}

{
    package MB898::VersionHTTP;
    sub get { push @{$_[0]{asked}}, $_[1]; return {success=>1, content=>'accepted-by-hook'} }
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_834('Mediabot/Version/Remote.pm');
    my $async = _extract_834($src, 'getVersion_async');
    my $reason = _extract_834($src, '_version_asyncworker_reason');

    $assert->ok(defined $async, 'mb652-834: getVersion_async located');
    $assert->ok(defined $reason, 'mb652-834: AsyncWorker reason adapter located');

    $assert->like($src, qr/use\s+Mediabot::AsyncWorker;/,
        'mb652-834: Version::Remote loads shared AsyncWorker');
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

    # Exercise the canonical owner as well as the historical Helpers entry
    # points above. A fresh interpreter catches load-order and startup I/O.
    require Mediabot::Version::Remote;
    for my $order (
        [qw(Version::Remote)],
        [qw(Version::Remote Helpers)],
        [qw(Helpers Version::Remote)],
    ) {
        my $code = q{
            use strict; use warnings;
            require HTTP::Tiny;
            no warnings qw(redefine once);
            local *HTTP::Tiny::get = sub { die 'unexpected startup HTTP' };
        };
        $code .= join('', map { "require Mediabot::$_;\n" } @$order);
        $code .= q{
            my $cold = !exists $INC{'Mediabot/Helpers.pm'};
            die 'unexpected cold dependency' if $cold && (
                exists $INC{'Mediabot/External.pm'} || exists $INC{'DBI.pm'});
            die 'unexpected default import' if defined &main::getVersion;
            Mediabot::Version::Remote->import(qw(_remote_version_urls
                _remote_version_timeout _remote_version_worker_timeout
                fetch_remote_version getVersion _version_asyncworker_reason getVersion_async));
            { package MB898ColdConf; sub get { undef } }
            my $bot = {conf=>bless({}, 'MB898ColdConf')};
            my @urls = _remote_version_urls($bot);
            die 'default routes/budget' unless @urls == 2
                && $urls[0] eq 'https://raw.githubusercontent.com/teuk/mediabot_v3/master/VERSION'
                && _remote_version_timeout($bot) == 8
                && _remote_version_worker_timeout($bot) == 17;
            die 'cold call loaded facade' if $cold && exists $INC{'Mediabot/Helpers.pm'};
            require Mediabot::Helpers;
            {
                no warnings 'once';
                local @Mediabot::Helpers::VERSION_URLS = ('http://one/V', 'http://two/V', 'http://three/V');
                my @custom = _remote_version_urls($bot);
                die 'legacy mutable routes' unless @custom == 3
                    && $custom[2] eq 'http://three/V' && _remote_version_worker_timeout($bot) == 25;
                local @Mediabot::Helpers::VERSION_URLS = ();
                die 'empty legacy routes' unless scalar(_remote_version_urls($bot)) == 0
                    && _remote_version_worker_timeout($bot) == 9;
            }
            print 'loaded';
        };
        my $err = gensym;
        my $pid = open3(undef, my $out, $err, $^X, '-I.', '-It/lib', '-we', $code);
        my $stdout = do { local $/; <$out> } // '';
        my $stderr = do { local $/; <$err> } // '';
        waitpid($pid, 0);
        my $exit = $?;
        (my $diagnostic = $stderr) =~ s/\s+/ /g;
        $assert->ok($exit == 0 && $stdout eq 'loaded' && $stderr eq '',
            'remote version contracts and historical URL list survive load order: ' . join('/', @$order)
                . ($exit || length($stderr) ? " (exit=$exit; $diagnostic)" : ''));
    }
    {
        no warnings 'redefine';
        require Mediabot::External;
        my (@asked, @parsed, %options);
        local *Mediabot::Helpers::_remote_version_urls = sub { 'https://late.example/V' };
        local *Mediabot::Helpers::_remote_version_timeout = sub { 13 };
        local *Mediabot::Helpers::_version_parts = sub { push @parsed, $_[0]; return {major=>3,minor=>7} };
        local *HTTP::Tiny::can_ssl = sub { 1 };
        local *Mediabot::External::_make_http = sub {
            %options = @_;
            return bless {asked=>\@asked}, 'MB898::VersionHTTP';
        };
        my ($remote, $reason) = Mediabot::Version::Remote::fetch_remote_version({});
        $assert->ok($remote eq 'accepted-by-hook' && !defined($reason)
                && join('|', @asked) eq 'https://late.example/V'
                && join('|', @parsed) eq 'accepted-by-hook'
                && $options{timeout} == 13 && $options{max_size} == 65536
                && $options{agent} eq 'mediabot-version-check/1.0 '
                && !exists($options{verify_SSL}),
            'canonical fetch keeps late URL/timeout/parser hooks and the common HTTP factory');
    }
    {
        no warnings 'redefine';
        my @seen;
        local *Mediabot::Helpers::getLocalVersion = sub { push @seen, 'local'; '3.6' };
        local *Mediabot::Helpers::fetch_remote_version = sub { push @seen, 'fetch'; ('3.7', undef) };
        local *Mediabot::Helpers::_compare_mediabot_versions = sub { push @seen, join('/', @_); 0 };
        my $logger = MB652::Logger->new;
        my $bot = bless {logger=>$logger, _version_fetch_error=>'old'}, 'MB898::VersionBot';
        my @versions = Mediabot::Version::Remote::getVersion($bot);
        $assert->ok(join('|', @versions) eq '3.6|3.7'
                && join('|', @seen) eq 'local|fetch|3.6/3.7'
                && $bot->{main_prog_version} eq '3.6' && !defined($bot->{_version_fetch_error})
                && grep({$_->[1] eq 'Mediabot is up to date.'} @{$logger->{messages}}),
            'canonical synchronous check keeps local identity, fetch/comparison hooks and bot state');
    }
    {
        no warnings 'redefine';
        my (%launch, @calls);
        local *Mediabot::Helpers::_cached_local_version = sub { '3.6dev-42' };
        local *Mediabot::Helpers::_remote_version_worker_timeout = sub { 12.5 };
        local *Mediabot::Helpers::_version_asyncworker_reason = sub { 'legacy terminal reason' };
        local *Mediabot::Helpers::getVersion = sub {
            $_[0]{logger}->log(1, 'silent child');
            $_[0]{_version_fetch_error} = undef;
            return ('3.6', '3.7');
        };
        local *Mediabot::AsyncWorker::start = sub {
            my ($class, %args) = @_;
            %launch = %args;
            return bless {}, 'MB652::FakeWorker';
        };
        my $bot = bless {loop=>MB652::Loop->new, logger=>MB652::Logger->new}, 'MB652::Bot';
        my $started = Mediabot::Version::Remote::getVersion_async($bot, sub {push @calls, [@_]});
        my $child = $launch{child}->();
        $launch{on_done}->({ok=>0, error=>'worker_timeout'});
        $launch{on_done}->({ok=>1, value=>['9.9','9.9']});
        $assert->ok($started == 1 && $launch{timeout} == 12.5
                && join('|', map {defined($_) ? $_ : ''} @$child) eq '3.6|3.7|'
                && @calls == 1 && join('|', @{$calls[0]}) eq '3.6dev-42|Undefined|legacy terminal reason'
                && @{$bot->{logger}{messages}} == 0,
            'canonical async check keeps legacy child/timeout/reason hooks, silent logging and callback once');
    }
};
