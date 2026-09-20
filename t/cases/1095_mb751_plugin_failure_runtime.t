# MB751 — commands, events, jobs and HTTP callbacks share one runtime ledger.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

use JSON::PP ();

{
    package T1095::Log;
    sub new { bless {}, shift }
    sub log { 1 }
}

{
    package T1095::Loop;
    sub new { bless { later => [] }, shift }
    sub later { push @{ $_[0]{later} }, $_[1]; 1 }
    sub run_all {
        my ($self) = @_;
        while (my $cb = shift @{ $self->{later} }) { $cb->() }
    }
}

{
    package T1095::Scheduler;
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
    package T1095::HTTP;
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
    package T1095::Bot;
    sub new {
        require Mediabot::CommandRegistry;
        require Mediabot::EventBus;
        return bless {
            registry => Mediabot::CommandRegistry->new,
            event_bus => Mediabot::EventBus->new,
            loop => T1095::Loop->new,
            scheduler => T1095::Scheduler->new,
            logger => T1095::Log->new,
        }, shift;
    }
    sub command_registry { $_[0]{registry} }
    sub registry { $_[0]{registry} }
    sub events { $_[0]{event_bus} }
    sub getLoop { $_[0]{loop} }
}

{
    package T1095::CommandContext;
    sub new { bless {}, shift }
    sub nick { 'Tangy' }
    sub channel { '#test' }
    sub args { [] }
    sub is_private { 0 }
    sub reply { 1 }
    sub reply_private { 1 }
}

{
    package T1095::Invocation;
    sub new { bless {}, shift }
    sub channel { '#test' }
}

return sub {
    my ($assert) = @_;
    require Mediabot::PluginManager;

    my $http = T1095::HTTP->new;
    my $bot = T1095::Bot->new;
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
            sub { die "command private secret\n" };
        $handler->(T1095::CommandContext->new);
        local *Mediabot::Plugin::V3::Hello::event_minute =
            sub { die "event private secret\n" };
        $bot->{event_bus}->emit('plugin_cron_observed', $event);
        $bot->{loop}->run_all;
        local *Mediabot::Plugin::V3::Hello::job_heartbeat =
            sub { die "job private secret\n" };
        $bot->{scheduler}->fire($task);
    }
    $manager->_v3_http_fetch('hello-v3', T1095::Invocation->new, {},
        sub { die "http private secret\n" });
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
        $handler->(T1095::CommandContext->new);
        local *Mediabot::Plugin::V3::Hello::event_minute = sub { 1 };
        $bot->{event_bus}->emit('plugin_cron_observed', $event);
        $bot->{loop}->run_all;
        local *Mediabot::Plugin::V3::Hello::job_heartbeat = sub { 1 };
        $bot->{scheduler}->fire($task);
    }
    $manager->_v3_http_fetch('hello-v3', T1095::Invocation->new, {}, sub { 1 });
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
