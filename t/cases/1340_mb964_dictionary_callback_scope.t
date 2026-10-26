use strict;
use warnings;
use utf8;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP ();
use IO::Async::Loop;
use Mediabot::Mediabot;
use Mediabot::Context;
use Mediabot::EventBus;
use Mediabot::CommandRegistry;
use Mediabot::Scheduler;
use Mediabot::PluginManager;

{
    package MB964::Conf;
    sub get { $_[0]{$_[1]} }
    package MB964::Log;
    sub log { 1 }
    package MB964::Bot;
    our @ISA = ('Mediabot');
    sub command_registry { $_[0]{registry} }
    sub getLoop { $_[0]{loop} }
    sub get_user_from_message { undef }
    sub getUserChannelLevel { 0 }
    package MB964::Dictionary;
    sub solve {
        my ($self, $plugin, $channel, $letters, $callback) = @_;
        push @{$self->{calls}}, { plugin => $plugin, channel => $channel,
            letters => $letters, callback => $callback };
        return { accepted => 1 };
    }
    sub complete {
        my ($self, $index) = @_;
        my $callback = delete $self->{calls}[$index]{callback};
        die 'completion already consumed' unless $callback;
        $callback->({ ok => 1, longest => 10, words => ['ORIENTATES'] });
    }
    sub cancel_scope { 1 }
    sub cancel_plugin { 1 }
}

# Load an actual package through RuntimeV3. Only the slow dictionary transport
# is held by the fixture; invocations, event queue, scheduler, policies,
# quarantine and failure recording are the native implementations.
my $tmp = tempdir(CLEANUP => 1);
my $name = 'dictionary-probe-v3';
make_path("$tmp/plugins/$name/lib");
my @caps = qw(data.dictionary.read events.subscribe scheduler.jobs irc.reply irc.notice);
my $manifest = {
    api => 3, name => $name, version => '1.0.0', description => 'Dictionary callback scope probe',
    runtime => { kind => 'perl', entrypoint => 'lib/Probe.pm', class => 'Mediabot::Plugin::MB964Probe' },
    compatibility => { mediabot => '>=3.6dev' }, activation => { default => 'off' },
    capabilities => \@caps,
    commands => { lookup => { source => 'public', help => 'Probe', level => 0, handler => 'command_lookup' } },
    events => [{ name => 'irc.channel.word', version => 1, handler => 'event_word' }],
    jobs => { pulse => { handler => 'job_pulse', interval_seconds => 5, first_delay_seconds => 5 } },
    config_schema => {},
};
open my $mf, '>:raw', "$tmp/plugins/$name/plugin.json" or die $!;
print {$mf} JSON::PP->new->utf8->encode($manifest); close $mf or die $!;
open my $pf, '>:raw', "$tmp/plugins/$name/lib/Probe.pm" or die $!;
print {$pf} <<'PLUGIN';
package Mediabot::Plugin::MB964Probe;
use strict;
use warnings;
sub new { bless { launches => [], completed => [] }, shift }
sub start { 1 }
sub stop { 1 }
sub _submit {
    my ($self, $context, $invocation, $kind) = @_;
    my $launch = { invocation => $invocation, context => $context,
        kind => $kind, channel => $invocation->channel };
    push @{$self->{launches}}, $launch;
    $launch->{result} = $context->dictionary_solve($invocation, 'AEEINORSTT', sub {
        die "private callback detail\n" if $self->{fail_callback};
        push @{$self->{completed}}, [$kind, $invocation->channel];
    });
    return 1;
}
sub command_lookup { $_[0]->_submit($_[1], $_[2], 'command') }
sub event_word { $_[0]->_submit($_[1], $_[3], 'event') }
sub job_pulse { $_[0]->_submit($_[1], $_[2], 'job') }
1;
PLUGIN
close $pf or die $!;

my $loop = IO::Async::Loop->new;
my $bot = bless { loop => $loop, registry => Mediabot::CommandRegistry->new,
    event_bus => Mediabot::EventBus->new, logger => bless({}, 'MB964::Log'),
    conf => bless({ 'plugins.DATA_DIR' => "$tmp/data" }, 'MB964::Conf') }, 'MB964::Bot';
$bot->{scheduler} = Mediabot::Scheduler->new(loop => $loop, logger => $bot->{logger});
my $service = bless { calls => [] }, 'MB964::Dictionary';
my $manager = Mediabot::PluginManager->new(bot => $bot, plugin_dir => "$tmp/plugins",
    v3_dictionary_service => $service);
my $entry = $manager->load_package_v3($name, grants => \@caps);
for my $channel ('#test', '#other') {
    $manager->set_v3_channel_policy($name, $channel, mode => 'on');
}
$manager->enable($name);
my $object = $entry->{object};
my %resource = (command => 'lookup', event => 'irc.channel.word', job => 'pulse');
my @warnings;
local $SIG{__WARN__} = sub { push @warnings, @_ };

sub launch_1340 {
    my ($kind, $channel) = @_;
    my $before = @{$object->{launches}};
    if ($kind eq 'command') {
        $bot->{registry}->handler_for('lookup', 'public')->(Mediabot::Context->new(
            bot => $bot, message => {}, nick => 'Alice', channel => $channel,
            command => 'lookup', args => []));
    } elsif ($kind eq 'event') {
        $bot->observe_public_word({}, $channel, 'Alice', 'ORIENTATES', 0);
        for (1 .. 10) {
            last unless $entry->{event_queue}->pending_count;
            $loop->loop_once(0);
        }
    } else {
        $bot->{scheduler}{_tasks}{"plugin.v3.$name.pulse"}{cb}->();
    }
    my @new = @{$object->{launches}}[$before .. $#{$object->{launches}}];
    my ($found) = grep { $_->{kind} eq $kind && $_->{channel} eq $channel } @new;
    return $found;
}
sub retain_1340 {
    my ($launch, $callback) = @_;
    return $launch->{context}->dictionary_solve($launch->{invocation}, 'AEEINORSTT', $callback);
}
sub last_call_1340 {
    my ($channel) = @_;
    my @indices = grep { $service->{calls}[$_]{channel} eq $channel } 0 .. $#{$service->{calls}};
    return $indices[-1];
}
sub streak_1340 {
    my ($kind, $channel) = @_;
    return [grep { $_->{kind} eq $kind && $_->{resource} eq $resource{$kind}
        && $_->{channel} eq $channel } @{$manager->v3_failure_report($name)->{active_streaks}}];
}

for my $kind (qw(command event job)) {
    my $launch = launch_1340($kind, '#test');
    ok($launch, "$kind: native dispatcher supplies a scoped invocation");
    is($launch->{result}{accepted}, 1, "$kind: ordinary dictionary read is accepted");
    my $index = last_call_1340('#test');
    my $before = @{$object->{completed}};
    $service->complete($index);
    is(scalar @{$object->{completed}}, $before + 1, "$kind: ordinary completion reaches the package");

    $manager->set_v3_quarantine($name, $kind, $resource{$kind}, '#TEST');
    my $calls = @{$service->{calls}};
    my $escaped = 0;
    my $blocked = retain_1340($launch, sub { $escaped++ });
    is($blocked->{error}, 'quarantined', "$kind: retained invocation cannot start quarantined work");
    is(scalar @{$service->{calls}}, $calls, "$kind: blocked read never reaches the dictionary service");
    my $launches = @{$object->{launches}};
    launch_1340($kind, '#test');
    is(scalar(grep { $_->{kind} eq $kind && $_->{channel} eq '#test' }
        @{$object->{launches}}[$launches .. $#{$object->{launches}}]), 0,
        "$kind: native dispatch also suppresses a quarantined resource");
    my $other = launch_1340($kind, '#other');
    is($other->{result}{accepted}, 1, "$kind: quarantine stays within its channel");
    $index = last_call_1340('#other'); $before = @{$object->{completed}};
    $service->complete($index);
    is(scalar @{$object->{completed}}, $before + 1, "$kind: other channel still receives its result");
    $manager->reset_v3_quarantine($name, $kind, $resource{$kind}, '#test');

    retain_1340($launch, sub { $escaped++ });
    $index = last_call_1340('#test');
    $manager->set_v3_quarantine($name, $kind, $resource{$kind}, '#test');
    $service->complete($index);
    is($escaped, 0, "$kind: late quarantine suppresses an already accepted callback");
    $manager->reset_v3_quarantine($name, $kind, $resource{$kind}, '#test');
    is($escaped, 0, "$kind: release does not replay the discarded result");
    retain_1340($launch, sub { $escaped++ });
    $service->complete(last_call_1340('#test'));
    is($escaped, 1, "$kind: explicit release permits a fresh lookup and completion");

    # No new handler runs between these completions: a dispatcher success
    # must not mask a missing success record at the asynchronous boundary.
    my $failures = $manager->v3_failure_report($name)->{total_failures};
    retain_1340($launch, sub { die "private callback detail\n" });
    my $ok = eval { $service->complete(last_call_1340('#test')); 1 };
    ok($ok, "$kind: throwing completion stays inside the plugin boundary");
    my $report = $manager->v3_failure_report($name);
    is($report->{total_failures}, $failures + 1, "$kind: callback failure is recorded once");
    is_deeply([@{$report->{recent}[-1]}{qw(kind resource channel)}],
        [$kind, $resource{$kind}, '#test'], "$kind: failure names the actual runtime resource");
    is(scalar @{streak_1340($kind, '#test')}, 1, "$kind: the failed resource has an active streak");
    my $quarantined = eval {
        my $f = $report->{recent}[-1];
        $manager->set_v3_quarantine($name, @$f{qw(kind resource channel)}); 1;
    };
    ok($quarantined, "$kind: operator can quarantine the resource shown by the failure report");
    $manager->reset_v3_quarantine($name, $kind, $resource{$kind}, '#test');
    my $successes = $manager->v3_failure_report($name)->{total_successes};
    retain_1340($launch, sub { 1 });
    $service->complete(last_call_1340('#test'));
    $report = $manager->v3_failure_report($name);
    is($report->{total_successes}, $successes + 1, "$kind: successful callback is recorded once");
    is(scalar @{streak_1340($kind, '#test')}, 0, "$kind: later callback success clears its failure streak");
    is($report->{total_failures}, $failures + 1, "$kind: recovery keeps the failure history");
    unlike(JSON::PP->new->encode($report), qr/private callback detail/,
        "$kind: public failure report contains no raw exception");
}

# A command quarantine must not silence bare-word reads or scheduled reads.
$manager->set_v3_quarantine($name, 'command', 'lookup', '#test');
for my $kind (qw(event job)) {
    my $launch = launch_1340($kind, '#test');
    is($launch->{result}{accepted}, 1, "$kind: unrelated command quarantine leaves this read available");
}
$manager->reset_v3_quarantine($name, 'command', 'lookup', '#test');

for my $kind (qw(command event job)) {
    my $launch = launch_1340($kind, '#test');
    my $called = 0;
    retain_1340($launch, sub { $called++ });
    my $index = last_call_1340('#test');
    $manager->set_v3_channel_policy($name, '#test', mode => 'off');
    $manager->set_v3_channel_policy($name, '#test', mode => 'on');
    $service->complete($index);
    is($called, 0, "$kind: off/on still invalidates an older dictionary result");
}
my $launch = launch_1340('event', '#test');
my $called = 0;
retain_1340($launch, sub { $called++ });
my $index = last_call_1340('#test');
$manager->disable($name);
$service->complete($index);
is($called, 0, 'disable still suppresses an in-flight event dictionary callback');
$manager->unregister_plugin($name);
is_deeply(\@warnings, [], 'native dictionary scope checks emit no warnings');
done_testing;
