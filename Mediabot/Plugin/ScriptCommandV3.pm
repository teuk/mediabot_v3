package Mediabot::Plugin::ScriptCommandV3;

use strict;
use warnings;
use Cwd qw(realpath);
use Mediabot::Plugin::ChannelPolicyV3 ();
use Mediabot::PluginContext ();
use Mediabot::ScriptRunner;

my %capability = (reply => 'irc.reply', notice => 'irc.notice');

sub new {
    my ($class, %args) = @_;
    my $runner = Mediabot::ScriptRunner->new(script_dir => $args{directory},
        timeout => 3, max_stdin_bytes => 16384, max_stdout_bytes => 16384,
        max_stderr_bytes => 16384, max_actions => 8);
    return bless { %args, runner => $runner }, $class;
}

sub stop {
    my ($self) = @_;
    delete $self->{active_channel};
    $self->{processes}->cancel($self) if $self->{processes};
    return 1;
}

sub policy_changed {
    my ($self, %args) = @_;
    my $channel = Mediabot::Plugin::ChannelPolicyV3::_channel_key($args{channel}, 1);
    $self->stop if ($self->{active_channel} // '') eq $channel;
    return;
}

sub dispatch {
    my ($self, $processes, $context, $invocation, $handler, $complete) = @_;
    my $runner = $self->{runner};
    my $entrypoint = $self->{entrypoint};
    my $plan = $runner->build_execution_plan($entrypoint, {
        protocol => 'mediabot-script-v1', event => 'public_command', data => {
            channel => $invocation->channel, nick => $invocation->nick,
            command => $invocation->command, args => $invocation->args,
            config => $invocation->config, handler => $handler,
            activation => $invocation->activation_mode,
        },
    });
    die "script entrypoint changed or is unavailable\n"
        unless $plan->{ok} && -f $plan->{full_path} && !-l $plan->{full_path}
            && (realpath($plan->{full_path}) // '') eq $self->{resolved};

    $self->{processes} = $processes;
    my $started = $processes->start($self, $plan, sub {
        my ($error, $stdout) = @_;
        delete $self->{active_channel};
        if (!$error) {
            my $result = $runner->decode_script_response($stdout);
            if (!$result->{ok}) {
                $error = 'script returned an invalid or failed response';
            } else {
                my $ok = eval {
                    _deliver($context, $invocation, $result->{actions});
                    1;
                };
                $error = 'script actions were refused or failed' unless $ok;
            }
        }
        $complete->($error);
    });
    $self->{active_channel} = Mediabot::Plugin::ChannelPolicyV3::_channel_key(
        $invocation->channel, 1) if $started;
    return $started;
}

sub _deliver {
    my ($context, $invocation, $actions) = @_;
    # Check the whole response before any reply is sent. The script supplies
    # text, while the invocation chooses the destination and checks policy.
    my @messages;
    for my $action (@$actions) {
        my $type = $action->{type};
        die "unsupported script action\n"
            unless exists $capability{$type} && keys(%$action) == 2 && exists $action->{text};
        $context->require_capability($capability{$type});
        push @messages, [$type, Mediabot::PluginContext::_text($action->{text})];
    }
    for my $message (@messages) {
        last unless $invocation->output_allowed;
        my ($type, $text) = @$message;
        $context->$type($invocation, $text);
    }
}

1;
