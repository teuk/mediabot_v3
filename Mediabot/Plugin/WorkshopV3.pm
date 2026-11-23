package Mediabot::Plugin::WorkshopV3;

use strict;
use warnings;
use File::Spec;
use JSON::PP ();
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);
use Mediabot::IRC::Target qw(is_channel);
use Mediabot::Plugin::WorkshopFixture ();

# Stock USER_LEVEL rows from install/mediabot.sql, kept in this offline process.
my %role_level = (owner => 0, master => 1, administrator => 2, user => 3);
my $denied_metric = 'mediabot_plugin_command_denied_total';

sub offline_runtime {
    my ($directory) = @_;
    require Mediabot::Mediabot;
    require IO::Async::Loop;
    require Mediabot::Scheduler;

    my $bot = Mediabot->new({ conf => Mediabot::Plugin::WorkshopFixture::offline_config() });
    my $loop = IO::Async::Loop->new;
    $bot->setLoop($loop);
    $bot->{scheduler} = Mediabot::Scheduler->new(loop => $loop);
    my $manager = $bot->{plugin_manager}
        = Mediabot::PluginManager->new(bot => $bot, plugin_dir => $directory);
    return ($bot, $manager, $loop);
}

sub test_package {
    my (%args) = @_;
    my ($name, $directory, $grants) = @args{qw(name directory grants)};
    my %allowed_grants = map { $_ => 1 } qw(irc.reply irc.notice irc.channel_message events.subscribe scheduler.jobs storage.kv);
    for my $grant (@$grants) {
        die "Unsupported fixture grant '$grant'\n"
            unless $allowed_grants{$grant};
    }
    die "Invalid package name\n" unless $name =~ /\A[a-z0-9][a-z0-9-]{0,47}\z/;
    my $fixture = $args{fixture}
        // File::Spec->catfile($directory, $name, 'workshop.test.json');
    die "Test fixture '$fixture' is not a file; select one with --fixture\n" unless -f $fixture;
    my $steps = Mediabot::Plugin::WorkshopFixture::read_steps(
        $fixture, max_bytes => 65536, max_steps => 32);

    my ($bot, $manager, $loop) = offline_runtime($directory);
    require Mediabot::Metrics;
    bless $bot, 'Mediabot::Plugin::WorkshopV3::Bot';
    $bot->{logger} = bless {}, 'Mediabot::Plugin::WorkshopV3::Log';
    $bot->{metrics} = Mediabot::Metrics->new(enabled => 1);
    $bot->{_user_level_cache} = { %role_level };
    if (grep { $_ eq 'scheduler.jobs' } @$grants) {
        # Job timers live on a loop the workshop never drives. Command children
        # and deferred events keep using the normal offline bot loop.
        $bot->{scheduler} = Mediabot::Plugin::WorkshopV3::JobScheduler->new(
            loop => IO::Async::Loop->really_new, logger => $bot->{logger});
    }
    my $entry = $manager->load_package_v3($name, grants => $grants);
    my $processes = $entry->{metadata}{external_commands}
        ? $manager->v3_runtime->script_processes : undef;
    my ($count, $events, $jobs, $restarts, $lifecycle) = (0, 0, 0, 0, 0);
    my $ok = eval {
        $manager->enable($name) or die "Could not enable '$name' in the workshop\n";
        for my $step (@$steps) {
            $count++;
            my @kinds = ref($step) eq 'HASH'
                ? grep { exists $step->{$_} } qw(command event job restart lifecycle) : ();
            die "Step $count must declare one command, event, job, restart or lifecycle and a replies array\n"
                unless @kinds == 1 && ref($step->{replies}) eq 'ARRAY';
            my $storage;
            if (exists $step->{storage}) {
                die "Step $count: storage assertions require --grant storage.kv\n"
                    unless $entry->{metadata}{plugin_context}->has_capability('storage.kv');
                $step = { %$step };
                $storage = _storage_expectations(delete $step->{storage}, $count);
            }
            $bot->{workshop_replies} = [];
            delete $bot->{logger}{error};
            if ($kinds[0] eq 'restart') {
                $entry = _test_restart_step($manager, $name, $count, $step);
                $processes = $entry->{metadata}{external_commands}
                    ? $manager->v3_runtime->script_processes : undef;
                $restarts++;
            } elsif ($kinds[0] eq 'lifecycle') {
                _test_lifecycle_step($manager, $entry, $count, $step);
                $lifecycle++;
            } elsif ($kinds[0] eq 'job') {
                _test_job_step($bot, $manager, $entry, $count, $step);
                $jobs++;
            } elsif ($kinds[0] eq 'event') {
                _test_event_step($bot, $manager, $loop, $entry, $count, $step);
                $events++;
            } else {
                _test_command_step($bot, $manager, $loop, $processes, $name, $count, $step);
            }
            Mediabot::Plugin::WorkshopFixture::assert_replies(
                $count, $step->{replies}, $bot->{workshop_replies});
            _assert_storage($manager, $name, $count, $storage) if $storage;
        }
        1;
    };
    my $error = $@;
    my $unloaded = eval { $manager->unregister_plugin($name) };
    my $unload_error = $@;
    my $stopped = eval { $manager->shutdown_v3_scripts };
    die $error unless $ok;
    die($unload_error || "Could not unload '$name' in the workshop\n") unless $unloaded;
    die($@ || "Workshop script cleanup incomplete\n") unless $stopped;
    return {
        steps => $count, event_steps => $events, job_steps => $jobs,
        restart_steps => $restarts, lifecycle_steps => $lifecycle,
    };
}

sub _test_lifecycle_step {
    my ($manager, $entry, $number, $step) = @_;
    die "Step $number: unknown lifecycle step field\n"
        if grep { $_ ne 'lifecycle' && $_ ne 'replies' } keys %$step;
    my $action = $step->{lifecycle};
    die "Step $number: lifecycle must be enable or disable\n"
        unless defined($action) && !ref($action) && $action =~ /\A(?:enable|disable)\z/;

    my $name = $entry->{name};
    my $changed = eval { $manager->$action($name) };
    my $error = $@;
    die "Step $number: cannot $action '$name': " . ($error || "operation refused\n")
        unless $changed;
    die "Step $number: $action did not leave '$name' loaded in the expected state\n"
        unless ($manager->plugin($name) // 0) == $entry
            && $manager->is_enabled($name) == ($action eq 'enable' ? 1 : 0);
    return;
}

sub _test_restart_step {
    my ($manager, $name, $number, $step) = @_;
    die "Step $number: unknown restart step field\n"
        if grep { $_ ne 'restart' && $_ ne 'replies' } keys %$step;
    die "Step $number: restart must be JSON true\n"
        unless JSON::PP::is_bool($step->{restart}) && $step->{restart};

    my $before = $manager->v3_runtime_state_snapshot;
    my ($saved, $error) = $manager->store_v3_runtime_state;
    die "Step $number: cannot save runtime state: $error\n" unless $saved;

    # Save before stopping so the persisted enabled flag is kept. Disable
    # explicitly so a failing stop hook is surfaced by the workshop.
    my $removed = eval {
        $manager->disable($name) && $manager->unregister_plugin($name);
    };
    my $detail = $@;
    die "Step $number: cannot stop or unload '$name': " . ($detail || "operation refused\n")
        unless $removed;

    my $report = $manager->restore_v3_runtime_state;
    if (@{ $report->{errors} }) {
        my $error = $report->{errors}[0]{error};
        die "Step $number: cannot restore '$name': $error\n";
    }
    my $entry = $manager->plugin($name);
    die "Step $number: restore did not load '$name'\n"
        unless $entry && @{ $report->{loaded} } == 1 && $report->{loaded}[0]{package} eq $name;
    Mediabot::Plugin::WorkshopFixture::assert_json(
        $number, 'restored runtime state', $before, $manager->v3_runtime_state_snapshot);
    return $entry;
}

sub _storage_expectations {
    my ($storage, $number) = @_;
    die "Step $number: storage must contain global or channel snapshots\n"
        unless ref($storage) eq 'HASH' && keys(%$storage)
            && !grep { $_ ne 'global' && $_ ne 'channels' } keys %$storage;
    my @checks;
    push @checks, [undef, $storage->{global}] if exists $storage->{global};
    if (exists $storage->{channels}) {
        my $channels = $storage->{channels};
        die "Step $number: storage channels must be a non-empty object\n"
            unless ref($channels) eq 'HASH' && keys %$channels;
        for my $channel (sort keys %$channels) {
            die "Step $number: invalid storage channel '$channel'\n" unless is_channel($channel);
            push @checks, [$channel, $channels->{$channel}];
        }
    }
    for my $check (@checks) {
        my ($channel, $snapshot) = @$check;
        my $label = defined($channel) ? "channel storage '$channel'" : 'global storage';
        die "Step $number: $label expects a revision and a values object\n"
            unless ref($snapshot) eq 'HASH' && keys(%$snapshot) == 2
                && defined($snapshot->{revision}) && !ref($snapshot->{revision})
                && "$snapshot->{revision}" =~ /\A(?:0|[1-9][0-9]{0,14})\z/
                && ref($snapshot->{values}) eq 'HASH'
                && !grep { !defined($_) || ref($_) } values %{ $snapshot->{values} };
    }
    return \@checks;
}

sub _assert_storage {
    my ($manager, $name, $number, $checks) = @_;
    for my $check (@$checks) {
        my ($channel, $expected) = @$check;
        my $label = defined($channel) ? "channel storage '$channel'" : 'global storage';
        my $actual = eval {
            my $repository = defined($channel)
                ? $manager->_v3_channel_repository($name, { channel => $channel })
                : $manager->_v3_repository_for($name);
            $repository->snapshot;
        };
        die "Step $number: cannot read $label: $@" unless $actual;
        Mediabot::Plugin::WorkshopFixture::assert_json($number, $label, $expected, $actual);
    }
    return;
}

sub _test_command_step {
    my ($bot, $manager, $loop, $processes, $name, $number, $step) = @_;
    my $command = $step->{command};
    die "Step $number: command must be a scalar\n" unless defined($command) && !ref($command);
    my %fields = map { $_ => 1 } qw(command mode config data caller expect replies);
    die "Step $number: unknown field\n" if grep { !$fields{$_} } keys %$step;
    my $registration = $bot->command_registry->command_for($command, 'public');
    die "Step $number: command is not registered by '$name'\n"
        unless $registration && ($registration->{plugin} // '') eq $name;
    die "Step $number: unsupported access level '$registration->{level}'\n"
        unless $registration->{level} eq '0' || exists $role_level{lc $registration->{level}};

    my $data = exists($step->{data}) ? $step->{data} : {};
    my %input_fields = map { $_ => 1 } qw(channel nick args);
    die "Step $number: data must contain only channel, nick or args\n"
        unless ref($data) eq 'HASH' && !grep { !$input_fields{$_} } keys %$data;
    my %input = (channel => '#workshop', nick => 'Pablo', args => [], %$data);
    my ($channel, $nick, $arguments) = @input{qw(channel nick args)};
    die "Step $number: expected a channel, a nick and an array of scalar arguments\n"
        unless defined($channel) && !ref($channel) && is_channel($channel)
            && defined($nick) && !ref($nick) && $nick =~ /\A[^\s\x00,:]+\z/
            && ref($arguments) eq 'ARRAY' && !grep { !defined($_) || ref($_) } @$arguments;
    my $mode = _step_mode($step, $number);
    my $default_expect = $mode eq 'off' ? 'off' : 'ran';
    $default_expect = 'disabled' unless $manager->is_enabled($name);
    my $expect = exists($step->{expect}) ? $step->{expect} : $default_expect;
    my @valid_expectations = ($default_expect);
    push @valid_expectations, 'denied' if $default_expect eq 'ran';
    die "Step $number: expect must be " . join(' or ', @valid_expectations) . "\n"
        unless defined($expect) && !ref($expect) && grep { $_ eq $expect } @valid_expectations;

    local $bot->{_user_cache} = {};
    local $bot->{_user_cache_ts} = {};
    my $message = exists($step->{caller})
        ? _caller_message($bot, $step->{caller}, $number, $nick, $channel) : undef;
    _configure_policy($manager, $name, $channel, $mode, $step);
    my $before = $manager->v3_failure_report($name);
    my $labels = { plugin => $name, command => $registration->{name} };
    my $before_denied = $bot->{metrics}->get($denied_metric, $labels) // 0;
    my $ctx = Mediabot::Context->new(%input, bot => $bot, command => $command, message => $message);
    $registration->{handler}->($ctx);
    die "Step $number: expected '$expect' but a script started\n"
        if $expect ne 'ran' && $processes && $processes->pending_count;
    _wait_pending($loop, $processes, $number, 'interpreter') if $processes;
    my $ran = _completed_count($bot, $manager, $name, $number, $before, 'command');
    my $denied = ($bot->{metrics}->get($denied_metric, $labels) // 0) - $before_denied;
    die "Step $number: expected '$expect' in '$mode', saw $ran execution(s) and $denied access denial(s)\n"
        unless $ran == ($expect eq 'ran' ? 1 : 0) && $denied == ($expect eq 'denied' ? 1 : 0);
    return;
}

sub _test_event_step {
    my ($bot, $manager, $loop, $entry, $number, $step) = @_;
    my %fields = map { $_ => 1 } qw(event version mode config data replies);
    die "Step $number: unknown event step field\n" if grep { !$fields{$_} } keys %$step;
    my $name = $entry->{name};
    my $event = $step->{event};
    my $version = exists($step->{version}) ? $step->{version} : 1;
    die "Step $number: expected an event name and an integer version\n"
        unless defined($event) && !ref($event) && defined($version) && !ref($version)
            && "$version" =~ /\A[1-9][0-9]*\z/;
    die "Step $number: event '$event' version $version is not declared by '$name'\n"
        unless grep { $_->{name} eq $event && $_->{version} eq $version } @{ $entry->{manifest}{events} };
    my $queue = $entry->{event_queue}
        or die "Step $number: event fixture requires --grant events.subscribe\n";

    require Mediabot::Plugin::EventCatalogV3;
    my $catalog = 'Mediabot::Plugin::EventCatalogV3';
    my $schema = $catalog->schema($event, $version);
    die "Step $number: event fixtures require a channel-scoped event\n"
        unless $schema && exists $schema->{fields}{channel};
    my $data = exists($step->{data}) ? $step->{data} : {};
    die "Step $number: event data must be an object\n" unless ref($data) eq 'HASH';
    my %raw = (channel => '#workshop', nick => 'Pablo', %$data);
    for my $field (sort keys %raw) {
        my $rule = $schema->{fields}{$field}
            or die "Step $number: unknown event data field '$field'\n";
        if ($rule->[0] eq 'bool' && JSON::PP::is_bool($raw{$field})) {
            $raw{$field} = $raw{$field} ? 1 : 0;
        }
    }
    my $channel = $raw{channel};
    die "Step $number: expected an event channel and a nick\n"
        unless defined($channel) && !ref($channel) && is_channel($channel)
            && defined($raw{nick}) && !ref($raw{nick}) && $raw{nick} =~ /\A[^\s\x00,:]+\z/;
    my $normalized = $catalog->normalize_data($event, $version, \%raw);
    for my $field (sort keys %raw) {
        die "Step $number: invalid event data field '$field'\n"
            unless exists $normalized->{$field};
    }
    die "Step $number: event channel exceeds the catalogue limit\n"
        unless $normalized->{channel} eq $channel;

    my $mode = _step_mode($step, $number);
    _configure_policy($manager, $name, $channel, $mode, $step);
    my $before = $manager->v3_failure_report($name);
    my $gate = $manager->is_enabled($name) ? $mode : 'disabled';
    my $expected = $gate eq 'off' || $gate eq 'disabled' ? 0 : 1;
    my $report;
    if ($event eq 'irc.channel.word') {
        $report = $bot->observe_public_word(undef, $channel, $raw{nick}, $raw{word}, 0);
    } elsif ($schema->{bus_event} =~ /\Achannel_(join|part|topic|kick)_observed\z/) {
        my $type = $1;
        $report = $bot->observe_channel_event($type, %raw);
    } else {
        $report = $bot->emit_event_report($schema->{bus_event}, \%raw);
    }
    die "Step $number: event '$event' did not reach its bus listener\n"
        unless $report && $report->{ran} == 1;
    if (@{ $report->{errors} }) {
        die "Step $number failed: $report->{errors}[0]{error}\n";
    }
    die "Step $number: event '$event' entered the queue in '$gate'\n"
        if !$expected && $queue->pending_count;
    _wait_pending($loop, $queue, $number, 'event queue');
    my $ran = _completed_count($bot, $manager, $name, $number, $before, 'event');
    die "Step $number: expected $expected execution(s) for event '$event' in '$gate', saw $ran\n"
        unless $ran == $expected;
    return;
}

sub _step_mode {
    my ($step, $number) = @_;
    my $mode = exists($step->{mode}) ? $step->{mode} : 'on';
    die "Step $number: mode must be on, observe or off\n"
        unless defined($mode) && !ref($mode) && $mode =~ /\A(?:on|observe|off)\z/;
    return $mode;
}

sub _test_job_step {
    my ($bot, $manager, $entry, $number, $step) = @_;
    my %fields = map { $_ => 1 } qw(job channels replies);
    die "Step $number: unknown job step field\n" if grep { !$fields{$_} } keys %$step;
    my $job = $step->{job};
    my $name = $entry->{name};
    my $jobs = $entry->{manifest}{jobs} // {};
    die "Step $number: job must be declared by '$name'\n"
        unless defined($job) && !ref($job) && exists($jobs->{$job});
    my ($mounted) = grep { $_->{name} eq $job } @{ $entry->{mounted_jobs} };
    die "Step $number: job fixture requires --grant scheduler.jobs\n" unless $mounted;
    my $channels = $step->{channels};
    die "Step $number: job channels must be an object\n" unless ref($channels) eq 'HASH';

    $manager->reset_v3_channel_policy($name, $_->{channel}) for $manager->v3_channel_policies($name);
    my $expected = 0;
    for my $channel (sort keys %$channels) {
        my $policy = $channels->{$channel};
        die "Step $number: expected a policy with mode or config for '$channel'\n"
            unless is_channel($channel) && ref($policy) eq 'HASH'
                && !grep { $_ ne 'mode' && $_ ne 'config' } keys %$policy;
        my $mode = _step_mode($policy, $number);
        $manager->set_v3_channel_policy($name, $channel, mode => $mode,
            (exists($policy->{config}) ? (config => $policy->{config}) : ()));
        $expected++ if $mode ne 'off';
    }
    my @configured = $manager->v3_channel_policies($name);
    die "Step $number: duplicate IRC channel in job policies\n" if @configured != keys %$channels;

    my $scheduler = $bot->{scheduler};
    my $before = $manager->v3_failure_report($name);
    my $task = $mounted->{task};
    my $previous = $scheduler->task_info($task);
    die "Step $number: job '$job' has no matching scheduler registration\n"
        unless $previous && $previous->{task_id} == $mounted->{task_id};
    my $enabled = $manager->is_enabled($name);
    my $ticked = $scheduler->tick_workshop_job($task, $mounted->{task_id});
    die "Step $number: enabled job '$job' has no active scheduler registration\n"
        if $enabled && !$ticked;
    die "Step $number: disabled job '$job' is still active\n"
        if !$enabled && ($previous->{started} || $ticked);
    $expected = 0 unless $enabled;
    my $current = $scheduler->task_info($task);
    die "Step $number: unexpected scheduler tick count for job '$job'\n"
        unless $current && $current->{task_id} == $previous->{task_id}
            && $current->{ticks} == $previous->{ticks} + $enabled;
    if ($current->{callback_exceptions} != $previous->{callback_exceptions}) {
        my $detail = $bot->{logger}{error} // 'scheduler callback failed';
        die "Step $number failed: $detail\n";
    }
    my $ran = _completed_count($bot, $manager, $name, $number, $before, 'job');
    die "Step $number: expected $expected execution(s) for job '$job', saw $ran\n"
        unless $ran == $expected;
    return;
}

sub _configure_policy {
    my ($manager, $name, $channel, $mode, $step) = @_;
    $manager->reset_v3_channel_policy($name, $channel);
    $manager->set_v3_channel_policy($name, $channel, mode => $mode,
        (exists($step->{config}) ? (config => $step->{config}) : ()));
    return;
}

sub _wait_pending {
    my ($loop, $pending, $number, $resource) = @_;
    return unless $pending->pending_count;
    my $deadline = clock_gettime(CLOCK_MONOTONIC) + 5;
    while ($pending->pending_count) {
        die "Step $number: $resource did not finish\n" if clock_gettime(CLOCK_MONOTONIC) >= $deadline;
        $loop->loop_once(0.1);
    }
    return;
}

sub _completed_count {
    my ($bot, $manager, $name, $number, $before, $kind) = @_;
    my $after = $manager->v3_failure_report($name);
    if ($after->{total_failures} != $before->{total_failures}) {
        my $detail = $bot->{logger}{error} // "API v3 $kind failed";
        die "Step $number failed: $detail\n";
    }
    return $after->{total_successes} - $before->{total_successes};
}

sub _caller_message {
    my ($bot, $caller, $number, $nick, $channel) = @_;
    die "Step $number: caller must have a stock role and a JSON authenticated boolean\n"
        unless ref($caller) eq 'HASH' && keys(%$caller) == 2
            && defined($caller->{role}) && !ref($caller->{role})
            && exists $role_level{lc $caller->{role}}
            && JSON::PP::is_bool($caller->{authenticated});
    die "Step $number: caller nick must not contain ! or @\n" if $nick =~ /[!@]/;

    require Protocol::IRC::Message;
    my $prefix = "$nick!offline\@workshop.invalid";
    my $role = lc $caller->{role};
    my $level = $role_level{$role};
    my $user = Mediabot::User->new({
        id_user => 1, nickname => $nick, id_user_level => $level + 1,
        auth => $caller->{authenticated} ? 1 : 0,
    });
    $user->{level} = $level;
    $user->{level_desc} = ucfirst $role;
    # Seed the regular hostmask cache so authorization and the v3 principal
    # both resolve the same synthetic user via the normal helper.
    $bot->{_user_cache}{$prefix} = $user;
    $bot->{_user_cache_ts}{$prefix} = time;
    return Protocol::IRC::Message->new_from_line(":$prefix PRIVMSG $channel :workshop");
}

package Mediabot::Plugin::WorkshopV3::Bot;

our @ISA = ('Mediabot');
sub botPrivmsg { push @{ $_[0]{workshop_replies} }, ['PRIVMSG', $_[1], $_[2]]; return 1 }
sub botNotice { push @{ $_[0]{workshop_replies} }, ['NOTICE', $_[1], $_[2]]; return 1 }
sub plugin_channel_message { shift->botPrivmsg(@_) }
sub getUserChannelLevel { return 0 } # No per-channel privileges in the offline fixture.

package Mediabot::Plugin::WorkshopV3::Log;

sub log { $_[0]{error} = $_[2] if $_[1] == 1; return 1 }

package Mediabot::Plugin::WorkshopV3::JobScheduler;

our @ISA = ('Mediabot::Scheduler');

sub tick_workshop_job {
    my ($self, $name, $id) = @_;
    my $task = $self->{_tasks}{$name};
    return 0 unless $task && $task->{task_id} == $id && $task->{started}
        && $task->{mode} eq 'periodic' && $task->{timer}->is_running;
    # Invoke the native tick event so the Scheduler and PluginManager
    # both apply their normal ownership, accounting and dispatch checks.
    $task->{timer}->invoke_event('on_tick');
    return 1;
}

1;
