# MB742 — explicit API v3 loading, lifecycle and registry integration.

use strict;
use warnings;
use utf8;
use File::Temp qw(tempdir);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

{
    package T1068::Log;
    sub new { bless { lines => [] }, shift }
    sub log { push @{ $_[0]{lines} }, $_[2]; 1 }
}

{
    package T1068::Bot;
    sub new {
        require Mediabot::CommandRegistry;
        return bless {
            registry => Mediabot::CommandRegistry->new,
            logger   => T1068::Log->new,
        }, shift;
    }
    sub command_registry { $_[0]{registry} }
    sub registry { $_[0]{registry} }
    sub getLoop { $_[0]{loop} }
}

{
    package T1068::Context;
    sub new { my ($class, %args) = @_; bless { %args, replies => [], notices => [] }, $class }
    sub nick { $_[0]{nick} }
    sub channel { $_[0]{channel} }
    sub command { $_[0]{command} }
    sub args { $_[0]{args} || [] }
    sub is_private { 0 }
    sub reply { push @{ $_[0]{replies} }, $_[1]; 1 }
    sub reply_private { push @{ $_[0]{notices} }, $_[1]; 1 }
}

sub drain_script_1068 {
    my ($bot, $processes) = @_;
    my $deadline = clock_gettime(CLOCK_MONOTONIC) + 5;
    while (keys %{ $processes->{active} }) {
        die "API v3 script subprocess was never reaped" if clock_gettime(CLOCK_MONOTONIC) > $deadline;
        $bot->{loop}->loop_once(0.1);
    }
    return;
}

sub write_script_1068 {
    my ($path, $source) = @_;
    open my $fh, '>:encoding(UTF-8)', $path or die "open script fixture: $!";
    print {$fh} $source;
    close $fh or die "close script fixture: $!";
    return;
}

sub script_commands_1068 {
    my ($assert) = @_;
    require IO::Async::Loop;
    require Mediabot::Plugin::ScaffoldV3;
    my $root = tempdir(CLEANUP => 1);
    my $bot = T1068::Bot->new;
    $bot->{loop} = IO::Async::Loop->new;
    my $manager = Mediabot::PluginManager->new(bot => $bot, plugin_dir => $root);

    for my $language (qw(python tcl)) {
        my $name = "hello-$language";
        my $command = "hello_$language";
        Mediabot::Plugin::ScaffoldV3::create(
            directory => $root, name => $name, language => $language);
        if ($language eq 'tcl') {
            # Tcllib is optional. Exercise the generated template when it is installed.
            open my $tcl, '|-', 'tclsh' or die "cannot launch tclsh: $!";
            print {$tcl} "if {[catch {package require json; package require json::write}]} {exit 1}\nexit 0\n";
            unless (close $tcl) {
                write_script_1068("$root/$name/lib/greeting.tcl", <<'TCL');
fconfigure stdin -encoding utf-8
fconfigure stdout -encoding utf-8
set request [read stdin]
if {![string match {*Élodie*} $request] || ![string match {*Salut*} $request]} {exit 1}
puts {{"protocol":"mediabot-script-v1","ok":true,"actions":[{"type":"reply","text":"Salut, Élodie!"}]}}
TCL
            }
        }
        my $entry = $manager->load_package_v3($name, grants => ['irc.reply']);
        my $handler = $bot->{registry}->handler_for($command, 'public');
        my $ctx = T1068::Context->new(nick => 'Tangy', channel => '#v3',
            args => ['Élodie']);
        my $processes = $manager->v3_runtime->script_processes;
        $handler->($ctx);
        $assert->is(scalar(keys %{ $processes->{active} }), 0, "$language stays off after load");
        $manager->enable($name);
        $handler->($ctx);
        $assert->is(scalar(keys %{ $processes->{active} }), 0, "$language runs only on channels opted in");
        $manager->set_v3_channel_policy($name, '#v3', mode => 'observe', config => {greeting => 'Salut'});
        $handler->($ctx);
        $assert->is(scalar(keys %{ $processes->{active} }), 1, "$language runs asynchronously in observe");
        drain_script_1068($bot, $processes);
        $assert->is(scalar @{ $ctx->{replies} }, 0, "$language observe suppresses output");
        $manager->set_v3_channel_policy($name, '#v3', mode => 'on');
        $handler->($ctx);
        $handler->($ctx);
        drain_script_1068($bot, $processes);
        $assert->is(join('|', @{ $ctx->{replies} }), 'Salut, Élodie!',
            "$language round-trips channel config and Unicode, one command in flight");
        $handler->($ctx);
        $manager->set_v3_channel_policy($name, '#V3', mode => 'off');
        $manager->set_v3_channel_policy($name, '#v3', mode => 'on');
        drain_script_1068($bot, $processes);
        $assert->is(scalar @{ $ctx->{replies} }, 1, "$language discards work on policy change");
        $handler->($ctx);
        $manager->unregister_plugin($name);
        $handler->($ctx);
        drain_script_1068($bot, $processes);
        $assert->is(scalar @{ $ctx->{replies} }, 1, "$language unload cancels work and old callbacks");
    }

    my $name = 'hello-python';
    my $path = "$root/$name/lib/greeting.py";
    write_script_1068($path, <<'PYTHON');
import json
import sys
import time
data = json.load(sys.stdin.buffer)["data"]
assert set(data) == {"channel", "nick", "command", "args", "handler", "activation", "config"}
assert data["handler"] == "command_greet"
mode = data["args"][0]
if mode == "large":
    sys.stderr.write("x" * 17000)
if mode == "slow":
    time.sleep(30)
actions = [{"type": "reply", "text": "ready"}]
if mode == "bad":
    actions.append({"type": "notice", "text": "ungranted"})
print(json.dumps({"protocol": "mediabot-script-v1", "actions": actions}))
PYTHON
    $manager->load_package_v3($name, grants => ['irc.reply']);
    $manager->enable($name);
    $manager->set_v3_channel_policy($name, '#v3', mode => 'on');
    my $handler = $bot->{registry}->handler_for('hello_python', 'public');
    my $processes = $manager->v3_runtime->script_processes;
    for my $case (['bad', qr/actions were refused/],
                   ['large', qr/output exceeds the byte limit/],
                   ['slow', qr/script timed out/]) {
        my ($mode, $failure) = @$case;
        my $ctx = T1068::Context->new(channel => '#v3', nick => 'Tangy', args => [$mode]);
        $handler->($ctx);
        drain_script_1068($bot, $processes);
        $assert->is(scalar @{ $ctx->{replies} }, 0, "$mode script response cannot leak a partial reply");
        $assert->like($bot->{logger}{lines}[-1] // '', $failure, "$mode script failure is reported");
        if ($mode ne 'slow') {
            $ctx->{args} = ['valid'];
            $handler->($ctx);
            drain_script_1068($bot, $processes);
            $assert->is($ctx->{replies}[0] // '', 'ready', "script can recover after $mode failure");
        }
    }
    $assert->ok($manager->shutdown_v3_scripts, 'script runtime can shut down after child cleanup');
    $manager->unregister_plugin($name);
}

return sub {
    my ($assert) = @_;

    require Mediabot::PluginManager;
    my $bot = T1068::Bot->new;
    my $manager = Mediabot::PluginManager->new(
        bot => $bot, plugin_dir => 'plugins');

    my @packages = $manager->discover_v3_packages;
    $assert->ok(grep($_->{name} eq 'hello-v3', @packages),
        'manager exposes read-only v3 discovery');
    $assert->is($manager->count, 0,
        'discovery neither registers nor activates a package');

    my $entry = $manager->load_package_v3(
        'hello-v3', grants => ['irc.reply']);
    $assert->is($entry->{metadata}{api}, 3,
        'explicit load registers API v3 metadata');
    $assert->is($manager->is_enabled('hello-v3'), 0,
        'explicit load still leaves package disabled');
    $assert->is($bot->{registry}->has_command('v3hello', 'public'), 1,
        'declared command is mounted through CommandRegistry');
    $assert->is($entry->{metadata}{effective_capabilities}[0], 'irc.reply',
        'entry records the effective capability set');
    $assert->ok(!exists($entry->{object}{bot})
            && !$entry->{metadata}{plugin_context}->can('bot'),
        'plugin object and PluginContext contain no bot reference');

    my $handler = $bot->{registry}->handler_for('v3hello', 'public');
    my $ctx = T1068::Context->new(
        nick => 'Tangy', channel => '#i/o', command => 'v3hello', args => []);
    $handler->($ctx);
    $assert->is(scalar @{ $ctx->{replies} }, 0,
        'loaded but disabled command stays silent');

    $manager->enable('hello-v3');
    $assert->is($entry->{object}{started}, 1,
        'explicit enable invokes start');
    $handler->($ctx);
    $assert->is(scalar @{ $ctx->{replies} }, 0,
        'global enable does not opt any channel into API v3 behavior');
    $manager->set_v3_channel_policy('hello-v3', '#i/o', mode => 'on');
    $handler->($ctx);
    $assert->like($ctx->{replies}[0] // '', qr/capability-scoped API v3 plugin/,
        'enabled witness replies through its granted facade');

    $manager->disable('hello-v3');
    $assert->is($entry->{object}{started}, 0,
        'disable invokes stop before leaving the plugin silent');
    $handler->($ctx);
    $assert->is(scalar @{ $ctx->{replies} }, 1,
        'disabled command remains mounted but emits nothing');

    $manager->unregister_plugin('hello-v3');
    $assert->is($bot->{registry}->has_command('v3hello', 'public'), 0,
        'unregister transactionally unmounts v3 command');

    my $no_grant = $manager->load_package_v3('hello-v3', grants => []);
    $manager->enable('hello-v3');
    $manager->set_v3_channel_policy('hello-v3', '#i/o', mode => 'on');
    my $denied = $bot->{registry}->handler_for('v3hello', 'public');
    my $ok = eval { $denied->($ctx); 1 };
    $assert->ok($ok && !$@,
        'ungranted output capability is contained by the core');
    $assert->is(scalar @{ $ctx->{replies} }, 1,
        'capability failure emits no IRC line');
    $assert->like($bot->{logger}{lines}[-1] // '',
        qr/capability 'irc\.reply' was not granted/,
        'contained capability failure remains operator-visible');
    $manager->unregister_plugin('hello-v3');

    $ok = eval {
        $manager->load_package_v3('hello-v3', grants => ['http.fetch']);
        1;
    };
    $assert->like($@ // '', qr/was not requested/,
        'operator cannot grant a capability absent from manifest');
    $assert->is($manager->count, 0,
        'failed grant validation leaves no registered plugin');
    # MB909: service scopes stay attached to their exact runtime registration.
    require JSON::PP;
    open my $probe, '-|', $^X, '-I.', '-It/lib', '-MMB909PluginFixture',
        '-MJSON::PP', '-e',
        'print JSON::PP->new->encode(MB909PluginFixture::run_contracts())'
        or die "MB909 service fixture: $!";
    my $json = do { local $/; <$probe> };
    close $probe or die "MB909 service fixture failed: $?";
    my $contracts = JSON::PP->new->decode($json);
    die "MB909 service fixture returned an invalid matrix"
        unless ref($contracts) eq 'ARRAY' && @$contracts == 13;
    for my $contract (@$contracts) {
        $assert->ok($contract->{ok}, "mb909: $contract->{case}");
    }
    {
        # MB910: partial starts own real timers/listeners and need best-effort stop.
        require JSON::PP;
        open my $probe, '-|', $^X, '-I.', '-It/lib', '-MMB910PluginFixture',
            '-MJSON::PP', '-e',
            'print JSON::PP->new->encode(MB910PluginFixture::run_contracts())'
            or die "MB910 activation fixture: $!";
        my $json = do { local $/; <$probe> };
        close $probe or die "MB910 activation fixture failed: $?";
        my $contracts = JSON::PP->new->decode($json);
        die "MB910 activation fixture returned an invalid matrix"
            unless ref($contracts) eq 'ARRAY' && @$contracts == 9;
        for my $contract (@$contracts) {
            $assert->ok($contract->{ok}, "mb910: $contract->{case}");
        }
    }
    script_commands_1068($assert);
};
