package Mediabot::Plugin::WorkshopV3;

use strict;
use warnings;
use File::Spec;
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);
use Mediabot::IRC::Target qw(is_channel);
use Mediabot::Plugin::WorkshopFixture ();

sub offline_runtime {
    my ($directory) = @_;
    require Mediabot::Mediabot;
    require IO::Async::Loop;
    require Mediabot::Scheduler;

    my $bot = Mediabot->new({});
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
    for my $grant (@$grants) {
        die "Command fixtures support only irc.reply and irc.notice grants\n"
            unless $grant eq 'irc.reply' || $grant eq 'irc.notice';
    }
    die "Invalid package name\n" unless $name =~ /\A[a-z0-9][a-z0-9-]{0,47}\z/;
    my $fixture = $args{fixture}
        // File::Spec->catfile($directory, $name, 'workshop.test.json');
    die "Test fixture '$fixture' is not a file; select one with --fixture\n" unless -f $fixture;
    my $steps = Mediabot::Plugin::WorkshopFixture::read_steps(
        $fixture, max_bytes => 65536, max_steps => 32);

    my ($bot, $manager, $loop) = offline_runtime($directory);
    bless $bot, 'Mediabot::Plugin::WorkshopV3::Bot';
    $bot->{logger} = bless {}, 'Mediabot::Plugin::WorkshopV3::Log';
    my $entry = $manager->load_package_v3($name, grants => $grants);
    my $processes = $entry->{metadata}{external_commands}
        ? $manager->v3_runtime->script_processes : undef;
    my $count = 0;
    my $ok = eval {
        $manager->enable($name) or die "Could not enable '$name' in the workshop\n";
        for my $step (@$steps) {
            $count++;
            _test_step($bot, $manager, $loop, $processes, $name, $count, $step);
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
    return $count;
}

sub _test_step {
    my ($bot, $manager, $loop, $processes, $name, $number, $step) = @_;
    die "Step $number must declare a command and a replies array\n"
        unless ref($step) eq 'HASH' && defined($step->{command})
            && !ref($step->{command}) && ref($step->{replies}) eq 'ARRAY';
    my $command = $step->{command};
    my %fields = map { $_ => 1 } qw(command mode config data replies);
    die "Step $number: unknown field\n" if grep { !$fields{$_} } keys %$step;
    my $registration = $bot->command_registry->command_for($command, 'public');
    die "Step $number: command is not registered by '$name'\n"
        unless $registration && ($registration->{plugin} // '') eq $name;
    die "Step $number: command fixtures require public level-0 commands\n"
        unless $registration->{level} eq '0';

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
    my $mode = exists($step->{mode}) ? $step->{mode} : 'on';
    die "Step $number: mode must be on, observe or off\n"
        unless defined($mode) && !ref($mode) && $mode =~ /\A(?:on|observe|off)\z/;
    $manager->reset_v3_channel_policy($name, $channel);
    $manager->set_v3_channel_policy($name, $channel, mode => $mode,
        (exists($step->{config}) ? (config => $step->{config}) : ()));

    $bot->{workshop_replies} = [];
    delete $bot->{logger}{error};
    my $before = $manager->v3_failure_report($name);
    my $ctx = Mediabot::Context->new(%input, bot => $bot, command => $command);
    $registration->{handler}->($ctx);
    die "Step $number: an off command started a script\n"
        if $mode eq 'off' && $processes && $processes->pending_count;
    if ($processes) {
        my $deadline = clock_gettime(CLOCK_MONOTONIC) + 5;
        while ($processes->pending_count) {
            die "Step $number: interpreter did not finish\n"
                if clock_gettime(CLOCK_MONOTONIC) >= $deadline;
            $loop->loop_once(0.1);
        }
    }
    my $after = $manager->v3_failure_report($name);
    if ($after->{total_failures} != $before->{total_failures}) {
        my $detail = $bot->{logger}{error} // 'API v3 command failed';
        die "Step $number failed: $detail\n";
    }
    my $ran = $after->{total_successes} - $before->{total_successes};
    die "Step $number: unexpected invocation count for mode '$mode'\n"
        unless $ran == ($mode eq 'off' ? 0 : 1);
    Mediabot::Plugin::WorkshopFixture::assert_replies(
        $number, $step->{replies}, $bot->{workshop_replies});
    return;
}

package Mediabot::Plugin::WorkshopV3::Bot;

our @ISA = ('Mediabot');
sub botPrivmsg { push @{ $_[0]{workshop_replies} }, ['PRIVMSG', $_[1], $_[2]]; return 1 }
sub botNotice { push @{ $_[0]{workshop_replies} }, ['NOTICE', $_[1], $_[2]]; return 1 }

package Mediabot::Plugin::WorkshopV3::Log;

sub log { $_[0]{error} = $_[2] if $_[1] == 1; return 1 }

1;
