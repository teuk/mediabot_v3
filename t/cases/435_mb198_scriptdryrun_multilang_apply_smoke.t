#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use File::Spec;
use lib File::Spec->rel2abs(File::Spec->curdir());

use Mediabot::ScriptRunner;
use Mediabot::ScriptActionRunner;

{
    package MB198::FakeIRC;
    sub new { bless { messages => [] }, shift }
    sub send_message {
        my ($self, @args) = @_;
        push @{ $self->{messages} }, \@args;
        return 1;
    }
    sub messages { @{ $_[0]->{messages} } }
}

{
    package MB198::FakeLogger;
    sub new { bless { logs => [] }, shift }
    sub log {
        my ($self, @args) = @_;
        push @{ $self->{logs} }, \@args;
        return 1;
    }
    sub logs { @{ $_[0]->{logs} } }
}

{
    package MB198::FakeBot;
    sub new {
        my ($class) = @_;
        return bless {
            irc    => MB198::FakeIRC->new,
            logger => MB198::FakeLogger->new,
        }, $class;
    }
}

my @fail;

sub ok {
    my ($cond, $msg) = @_;
    if ($cond) {
        print "ok - $msg\n";
    }
    else {
        print "not ok - $msg\n";
        push @fail, $msg;
    }
}

sub command_exists {
    my ($cmd) = @_;
    return system('sh', '-c', "command -v '$cmd' >/dev/null 2>&1") == 0 ? 1 : 0;
}

ok(command_exists('python3'), 'python3 interpreter is available');
ok(command_exists('tclsh'),   'tclsh interpreter is available');

my $bot = MB198::FakeBot->new;
my $runner = Mediabot::ScriptRunner->new(
    bot              => $bot,
    script_dir       => 'plugins/scripts',
    timeout          => 5,
    max_stdout_bytes => 65536,
);
my $applier = Mediabot::ScriptActionRunner->new(bot => $bot);

my @cases = (
    [ hello    => 'examples/hello_perl.pl',   'Perl script bridge OK for command: hello' ],
    [ pyhello  => 'examples/hello_python.py', 'Python script bridge OK for command: pyhello' ],
    [ tclhello => 'examples/hello_tcl.tcl',   'Tcl script bridge OK for command: tclhello' ],
);

my $message_count = 0;

for my $case (@cases) {
    my ($command, $script, $expected_text) = @$case;

    my $script_result = $runner->run_script(
        $script,
        'public_command',
        channel => '#mb198',
        target  => '#mb198',
        nick    => 'Te[u]K',
        command => $command,
        args    => [],
    );

    ok(ref($script_result) eq 'HASH', "$command returns a structured script result");
    ok($script_result->{ok}, "$command script_result ok");
    ok(!$script_result->{timeout}, "$command script_result did not time out");
    ok(($script_result->{exit_code} // -1) == 0, "$command script exits 0");

    my $actions = $script_result->{response}{actions};
    ok(ref($actions) eq 'ARRAY' && @$actions == 2, "$command produced two actions");

    my $plan = $applier->apply_actions(
        $script_result,
        {
            event   => 'public_command',
            channel => '#mb198',
            target  => '#mb198',
            nick    => 'Te[u]K',
            command => $command,
            args    => [],
        },
        apply     => 1,
        allow_irc => 1,
    );

    ok(ref($plan) eq 'HASH', "$command returns a structured action plan");
    ok($plan->{ok}, "$command action plan ok");
    ok($plan->{applied_ok}, "$command action plan applied ok");

    my @messages = $bot->{irc}->messages;
    ok(@messages == $message_count + 1, "$command emitted exactly one IRC message");
    $message_count = scalar @messages;

    my $last = $messages[-1];
    ok($last->[0] eq 'PRIVMSG', "$command IRC action is PRIVMSG");
    ok($last->[2] eq '#mb198', "$command IRC target is default channel");
    ok($last->[3] eq $expected_text, "$command IRC text matches expected bridge reply");
}

my @logs = $bot->{logger}->logs;
ok(@logs == 3, 'three log actions were applied');

if (@fail) {
    print "FAILED: @fail\n";
    exit 1;
}

exit 0;
