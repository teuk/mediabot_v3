# MB752 — manual quarantine blocks only the selected API v3 runtime resource.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

{
    package T1098::Log;
    sub new { bless {}, shift }
    sub log { 1 }
}

{
    package T1098::Loop;
    sub new { bless { later => [] }, shift }
    sub later { push @{ $_[0]{later} }, $_[1]; 1 }
    sub run_all {
        my ($self) = @_;
        while (my $cb = shift @{ $self->{later} }) { $cb->() }
    }
}

{
    package T1098::Scheduler;
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
    package T1098::HTTP;
    sub new { bless { callbacks => [] }, shift }
    sub fetch {
        my ($self, $plugin, $request, $callback) = @_;
        push @{ $self->{callbacks} }, $callback;
        return { accepted => 1, request_id => scalar @{ $self->{callbacks} } };
    }
    sub pending { scalar @{ $_[0]{callbacks} } }
    sub complete { (shift @{ $_[0]{callbacks} })->({ ok => 1 }) }
    sub cancel_plugin { 1 }
}

{
    package T1098::Bot;
    sub new {
        require Mediabot::CommandRegistry;
        require Mediabot::EventBus;
        return bless {
            registry => Mediabot::CommandRegistry->new,
            event_bus => Mediabot::EventBus->new,
            loop => T1098::Loop->new,
            scheduler => T1098::Scheduler->new,
            logger => T1098::Log->new,
        }, shift;
    }
    sub command_registry { $_[0]{registry} }
    sub registry { $_[0]{registry} }
    sub events { $_[0]{event_bus} }
    sub getLoop { $_[0]{loop} }
}

{
    package T1098::CommandContext;
    sub new { bless { replies => 0 }, shift }
    sub nick { 'Tangy' }
    sub channel { '#test' }
    sub args { [] }
    sub is_private { 0 }
    sub reply { $_[0]{replies}++; 1 }
    sub reply_private { 1 }
}

{
    package T1098::Invocation;
    sub new { bless {}, shift }
    sub channel { '#test' }
}

return sub {
    my ($assert) = @_;
    require Mediabot::PluginManager;

    my $http = T1098::HTTP->new;
    my $bot = T1098::Bot->new;
    my $manager = Mediabot::PluginManager->new(
        bot => $bot, plugin_dir => 'plugins', v3_http_service => $http);
    $manager->load_package_v3('hello-v3', grants => [
        qw(events.subscribe irc.reply scheduler.jobs)
    ], channel_policies => {
        '#test' => { mode => 'on', config => {} },
    });
    $manager->enable('hello-v3');

    my ($command_calls, $event_calls, $job_calls) = (0, 0, 0);
    my $captured_invocation;
    my $handler = $bot->{registry}->handler_for('v3hello', 'public');
    my $task = 'plugin.v3.hello-v3.heartbeat';
    my $event = {
        minute => 1, hour => 2, dow => 3,
        mday => 4, month => 5, year => 2026,
    };

    {
        no warnings 'redefine';
        local *Mediabot::Plugin::V3::Hello::command_hello = sub {
            $command_calls++;
            $captured_invocation = $_[2];
            return 1;
        };
        my $ctx = T1098::CommandContext->new;
        $handler->($ctx);
        $assert->is($command_calls, 1,
            'command runs before an operator quarantine');
        $manager->set_v3_quarantine(
            'hello-v3', 'command', 'v3hello', '#TEST');
        $assert->ok(!$captured_invocation->output_allowed,
            'late command output is suppressed immediately after quarantine');
        $handler->($ctx);
        $assert->is($command_calls, 1,
            'quarantined command handler is not invoked');
        $manager->reset_v3_quarantine(
            'hello-v3', 'command', 'v3hello', '#test');
        $handler->($ctx);
        $assert->is($command_calls, 2,
            'explicit release restores command execution');
    }

    {
        no warnings 'redefine';
        local *Mediabot::Plugin::V3::Hello::event_minute = sub {
            $event_calls++;
            return 1;
        };
        $bot->{event_bus}->emit('plugin_cron_observed', $event);
        $manager->set_v3_quarantine(
            'hello-v3', 'event', 'scheduler.minute', '#test');
        $bot->{loop}->run_all;
        $assert->is($event_calls, 0,
            'already queued event is discarded when quarantined before dispatch');
        $manager->reset_v3_quarantine(
            'hello-v3', 'event', 'scheduler.minute', '#test');
        $bot->{event_bus}->emit('plugin_cron_observed', $event);
        $bot->{loop}->run_all;
        $assert->is($event_calls, 1,
            'explicit release restores event delivery');
    }

    {
        no warnings 'redefine';
        local *Mediabot::Plugin::V3::Hello::job_heartbeat = sub {
            $job_calls++;
            return 1;
        };
        $manager->set_v3_quarantine(
            'hello-v3', 'job', 'heartbeat', '#test');
        $bot->{scheduler}->fire($task);
        $assert->is($job_calls, 0,
            'quarantined scheduled job is skipped for the selected channel');
        $manager->reset_v3_quarantine(
            'hello-v3', 'job', 'heartbeat', '#test');
        $bot->{scheduler}->fire($task);
        $assert->is($job_calls, 1,
            'explicit release restores scheduled job execution');
    }

    my $ok = eval {
        $manager->set_v3_quarantine(
            'hello-v3', 'command', 'not_declared', '#test');
        1;
    };
    $assert->like($@ // '', qr/is not declared/,
        'operator cannot quarantine an undeclared runtime resource');

    $manager->load_package_v3('short-content-v3', grants => [
        qw(http.fetch irc.reply storage.kv)
    ], channel_policies => {
        '#test' => { mode => 'on', config => {
            endpoint => 'https://example.invalid/advice',
        } },
    });
    $manager->enable('short-content-v3');
    $manager->set_v3_quarantine(
        'short-content-v3', 'http_callback', 'callback', '#test');
    my $callback_calls = 0;
    my $fetch = $manager->_v3_http_fetch(
        'short-content-v3', T1098::Invocation->new, {},
        sub { $callback_calls++; 1 });
    $assert->is($fetch->{error}, 'quarantined',
        'quarantined HTTP callback rejects new shared fetch work');
    $assert->is($http->pending, 0,
        'quarantined callback does not reach the HTTP service');
    $manager->reset_v3_quarantine(
        'short-content-v3', 'http_callback', 'callback', '#test');
    $fetch = $manager->_v3_http_fetch(
        'short-content-v3', T1098::Invocation->new, {},
        sub { $callback_calls++; 1 });
    $assert->is($fetch->{accepted}, 1,
        'released HTTP callback accepts shared fetch work again');
    $manager->set_v3_quarantine(
        'short-content-v3', 'http_callback', 'callback', '#test');
    $http->complete;
    $assert->is($callback_calls, 0,
        'in-flight HTTP completion is discarded after a late quarantine');
    $manager->reset_v3_quarantine(
        'short-content-v3', 'http_callback', 'callback', '#test');
    $fetch = $manager->_v3_http_fetch(
        'short-content-v3', T1098::Invocation->new, {},
        sub { $callback_calls++; 1 });
    $assert->is($fetch->{accepted}, 1,
        'released callback accepts a new fetch after the late block');
    $http->complete;
    $assert->is($callback_calls, 1,
        'released HTTP completion reaches the plugin callback');

    $manager->set_v3_quarantine(
        'hello-v3', 'command', 'v3hello', '#test');
    my $doctor = $manager->v3_diagnostic_report('hello-v3');
    $assert->is($doctor->{status}, 'limited',
        'doctor marks an otherwise operational quarantined plugin as limited');
    $assert->is($doctor->{reason}, 'quarantined_resources',
        'doctor names manual quarantine as the limiting reason');
    $assert->is($doctor->{quarantine}{total}, 1,
        'doctor reports the bounded quarantine count');

    $manager->disable('hello-v3');
    $manager->enable('hello-v3');
    $assert->is($manager->v3_quarantine_report('hello-v3')->{total}, 1,
        'disable and enable preserve quarantine for the loaded instance');

    $manager->_record_v3_failure('hello-v3',
        kind => 'command', resource => 'v3hello', channel => '#test',
        error => 'kept after release');
    $manager->reset_v3_quarantine(
        'hello-v3', 'command', 'v3hello', '#test');
    $assert->is($manager->v3_failure_report('hello-v3')->{total_failures}, 1,
        'release never clears the separate failure history');

    $manager->unregister_plugin('hello-v3');
    $manager->load_package_v3('hello-v3', grants => [
        qw(events.subscribe irc.reply scheduler.jobs)
    ]);
    $assert->is($manager->v3_quarantine_report('hello-v3')->{total}, 0,
        'unload discards quarantine with the old plugin instance');
};
