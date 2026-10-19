# MB850 — Unicode failure recording across actual API v3 runtime boundaries.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

use JSON::PP ();
use Encode qw(encode);
use Digest::SHA qw(sha256_hex);
use Mediabot::Plugin::FailureLedgerV3;

{
    package MB850T::Log;
    sub new { bless {}, shift }
    sub log { 1 }
}

{
    package MB850T::Loop;
    sub new { bless { later => [] }, shift }
    sub later { push @{ $_[0]{later} }, $_[1]; 1 }
    sub run_all {
        my ($self) = @_;
        while (my $cb = shift @{ $self->{later} }) { $cb->() }
    }
}

{
    package MB850T::Scheduler;
    sub new { bless { tasks => {} }, shift }
    sub add {
        my ($self, %args) = @_;
        $self->{tasks}{ $args{name} } = { %args, started => 0 };
        return $self;
    }
    sub start { $_[0]{tasks}{ $_[1] }{started} = 1; 1 }
    sub stop { $_[0]{tasks}{ $_[1] }{started} = 0; 1 }
    sub remove { delete($_[0]{tasks}{ $_[1] }); 1 }
    sub fire {
        my ($self, $name) = @_;
        my $task = $self->{tasks}{$name} or return 0;
        return 0 unless $task->{started};
        $task->{cb}->();
        return 1;
    }
}

{
    package MB850T::HTTP;
    sub new { bless { callbacks => [] }, shift }
    sub fetch {
        my ($self, $plugin, $request, $callback) = @_;
        push @{ $self->{callbacks} }, $callback;
        return { accepted => 1, request_id => scalar @{ $self->{callbacks} } };
    }
    sub complete { (shift @{ $_[0]{callbacks} })->({ ok => 1 }) }
    sub cancel_plugin { 1 }
}

{
    package MB850T::Bot;
    sub new {
        require Mediabot::CommandRegistry;
        require Mediabot::EventBus;
        return bless {
            registry => Mediabot::CommandRegistry->new,
            event_bus => Mediabot::EventBus->new,
            loop => MB850T::Loop->new,
            scheduler => MB850T::Scheduler->new,
            logger => MB850T::Log->new,
        }, shift;
    }
    sub command_registry { $_[0]{registry} }
    sub registry { $_[0]{registry} }
    sub events { $_[0]{event_bus} }
    sub getLoop { $_[0]{loop} }
}

{
    package MB850T::CommandContext;
    sub new { bless {}, shift }
    sub nick { 'Tangy' }
    sub channel { '#test' }
    sub args { [] }
    sub is_private { 0 }
    sub reply { 1 }
    sub reply_private { 1 }
}

{
    package MB850T::Invocation;
    sub new { bless {}, shift }
    sub channel { '#test' }
}

return sub {
    my ($assert) = @_;
    # Fixed non-secret salt makes legacy byte compatibility and exact UTF-8
    # hashing directly checkable; no real credential or error text is stored.
    my $ledger = Mediabot::Plugin::FailureLedgerV3->new(clock => sub {100}, max_recent => 2);
    $ledger->{fingerprint_salt} = 'a' x 64;
    for my $text ('ASCII private', "caf\x{e9} private", '東京 private 🧭', 'L’erreur privée') {
        my $bytes = $text;
        $bytes = encode('UTF-8', $bytes) unless utf8::downgrade($bytes, 1);
        my ($record, $warning) = (undef, '');
        my $ok;
        {local $SIG{__WARN__} = sub {$warning .= $_[0]};
         $ok = eval {$record = $ledger->record_failure(kind => 'command', resource => 'roll',
             channel => '#test', error => $text); 1};}
        $assert->ok($ok, 'mb850: international exception records without a second exception');
        $assert->is($warning, '', 'mb850: international diagnostic emits no warning');
        $assert->is($record ? $record->{fingerprint} : '',
            substr(sha256_hex(('a' x 64) . "\0" . $bytes), 0, 16),
            'mb850: legacy byte fingerprints remain stable; wide text hashes explicit UTF-8');
    }
    my $private_report = JSON::PP->new->canonical->encode($ledger->report);
    $assert->unlike($private_report, qr/private|caf|L’erreur|東京|🧭/,
        'mb850: raw exception text never enters diagnostic report');
    $assert->is($ledger->report->{total_failures}, 4, 'mb850: all international failures are counted');
    $assert->is($ledger->report->{recent_count}, 2, 'mb850: Unicode does not expand the recent ring bound');
    $assert->is($ledger->report->{active_streaks}[0]{consecutive_failures}, 4,
        'mb850: Unicode failures contribute to the same resource streak');
    $ledger->record_success(kind => 'command', resource => 'roll', channel => '#test');
    $assert->is(scalar @{$ledger->report->{active_streaks}}, 0,
        'mb850: later success clears an international failure streak');
    my $copy = $ledger->report; $copy->{recent}[0]{fingerprint} = 'changed';
    $assert->unlike($ledger->report->{recent}[0]{fingerprint}, qr/changed/,
        'mb850: international diagnostic reports remain detached');

    require Mediabot::PluginManager;

    my $http = MB850T::HTTP->new;
    my $bot = MB850T::Bot->new;
    my $manager = Mediabot::PluginManager->new(
        bot => $bot, plugin_dir => 'plugins', v3_http_service => $http);
    $manager->load_package_v3('hello-v3', grants => [
        qw(events.subscribe irc.reply scheduler.jobs)
    ], channel_policies => {
        '#test' => { mode => 'on', config => {} },
    });
    $manager->enable('hello-v3');

    my $handler = $bot->{registry}->handler_for('v3hello', 'public');
    my $task = 'plugin.v3.hello-v3.heartbeat';
    my $event = {
        minute => 1, hour => 2, dow => 3,
        mday => 4, month => 5, year => 2026,
    };

    {
        no warnings 'redefine';
        local *Mediabot::Plugin::V3::Hello::command_hello =
            sub { die "command private secret 東京 🧭\n" };
        $handler->(MB850T::CommandContext->new);
        local *Mediabot::Plugin::V3::Hello::event_minute =
            sub { die "event private secret 東京 🧭\n" };
        $bot->{event_bus}->emit('plugin_cron_observed', $event);
        $bot->{loop}->run_all;
        local *Mediabot::Plugin::V3::Hello::job_heartbeat =
            sub { die "job private secret 東京 🧭\n" };
        $bot->{scheduler}->fire($task);
    }
    $manager->_v3_http_fetch('hello-v3', MB850T::Invocation->new, {},
        sub { die "http private secret 東京 🧭\n" });
    $http->complete;

    my $report = $manager->v3_failure_report('hello-v3');
    $assert->is($report->{total_failures}, 4,
        'all four runtime boundaries feed one plugin ledger');
    $assert->is(join(',', map { $_->{kind} } @{ $report->{recent} }),
        'command,event,job,http_callback',
        'failure order identifies every runtime kind');
    $assert->unlike(JSON::PP->new->encode($report), qr/private secret/,
        'manager report never returns raw runtime exceptions');

    {
        no warnings 'redefine';
        local *Mediabot::Plugin::V3::Hello::command_hello = sub { 1 };
        $handler->(MB850T::CommandContext->new);
        local *Mediabot::Plugin::V3::Hello::event_minute = sub { 1 };
        $bot->{event_bus}->emit('plugin_cron_observed', $event);
        $bot->{loop}->run_all;
        local *Mediabot::Plugin::V3::Hello::job_heartbeat = sub { 1 };
        $bot->{scheduler}->fire($task);
    }
    $manager->_v3_http_fetch('hello-v3', MB850T::Invocation->new, {}, sub { 1 });
    $http->complete;
    $report = $manager->v3_failure_report('hello-v3');
    $assert->is($report->{total_successes}, 4,
        'successful calls are counted at the same four boundaries');
    $assert->is(scalar(@{ $report->{active_streaks} }), 0,
        'successful calls clear all matching active streaks');
    $assert->is($report->{total_failures}, 4,
        'success does not erase recent forensic history');

    $manager->unregister_plugin('hello-v3');
    $manager->load_package_v3('hello-v3', grants => [
        qw(events.subscribe irc.reply scheduler.jobs)
    ]);
    $report = $manager->v3_failure_report('hello-v3');
    $assert->is($report->{total_failures}, 0,
        'unload destroys the old instance ledger before reload');
};
