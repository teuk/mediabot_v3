#!/usr/bin/env perl
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/..";
use Getopt::Long qw(GetOptions);
use File::Temp qw(tempdir);
use Mediabot::Plugin::ScaffoldV3;
my $usage = <<'USAGE';
Usage:
  perl tools/plugin_v3_workshop.pl --check
  perl tools/plugin_v3_workshop.pl --create NAME [--command NAME] [--directory DIR]
  perl tools/plugin_v3_workshop.pl --validate NAME [--grant CAPABILITY ...] [--directory DIR]

--validate loads trusted local Perl code in a disposable, disabled runtime.
--directory is the parent of the package (default: plugins).
USAGE

my ($check, $name, $package, $command, $help) = (0);
my $directory = 'plugins';
my @grants;
GetOptions(
    'check'       => \$check,
    'create=s'    => \$name,
    'validate=s'  => \$package,
    'command=s'   => \$command,
    'grant=s@'    => \@grants,
    'directory=s' => \$directory,
    'help'        => \$help,
) or die $usage;
if ($help) {
    print $usage;
    exit 0;
}
my $mode_count = $check + defined($name) + defined($package);
die $usage if @ARGV || $mode_count != 1
    || (defined($command) && !defined($name)) || (@grants && !defined($package));

if (defined $name) {
    my $r=Mediabot::Plugin::ScaffoldV3::create(directory=>$directory,name=>$name,command=>$command);
    print "[OK] Created default-off package $r->{name}; command $r->{command}. No bot was loaded or changed.\n";
    exit 0;
}

if (defined $package) {
    validate_package($package, $directory, \@grants);
    exit 0;
}

sub validate_package {
    my ($name, $directory, $grants) = @_;
    require Mediabot::Mediabot;
    require IO::Async::Loop;
    require Mediabot::Scheduler;

    # Build the actual built-in registry, without opening any live services.
    my $bot = Mediabot->new({});
    my $loop = IO::Async::Loop->new;
    $bot->setLoop($loop);
    $bot->{scheduler} = Mediabot::Scheduler->new(loop => $loop);
    my $manager = Mediabot::PluginManager->new(bot => $bot, plugin_dir => $directory);
    $manager->load_package_v3($name, grants => $grants);

    my $report = $manager->v3_diagnostic_report($name);
    my ($declared, $mounted) = @{$report->{runtime}}{qw(declared mounted)};
    die "Package was unexpectedly enabled\n" unless $report->{lifecycle} eq 'disabled';

    $manager->unregister_plugin($name) or die "Package could not be unloaded\n";
    die "Package left runtime registrations after unload\n"
        if $manager->count || $bot->{scheduler}->task_names || $bot->events->events
        || grep { ($_->{plugin} // '') eq $name } $bot->command_registry->list;

    print "[OK] $report->{plugin} $report->{version} loaded disabled and unloaded.\n";
    for my $kind (qw(commands events jobs)) {
        print "  $kind: $mounted->{$kind}/$declared->{$kind} mounted\n";
    }
    print "  grants: ", (@$grants ? join(', ', sort @$grants) : 'none'), "\n";
}

{
    package Workshop::Bot;
    sub command_registry {$_[0]{registry}}
    sub registry {$_[0]{registry}}
    package Workshop::Caller;
    sub nick {'Pablo'} sub channel {$_[0]{channel} // '#test'}
    sub command {'workshop_greet'} sub args {[]} sub is_private {0}
    sub reply {push @{$_[0]{replies}},$_[1];1}
    sub reply_private {die 'unexpected notice'}
}
require Mediabot::CommandRegistry;
require Mediabot::PluginManager;
my $tmp=tempdir('mediabot-workshop-XXXXXX',TMPDIR=>1,CLEANUP=>1);
Mediabot::Plugin::ScaffoldV3::create(directory=>$tmp,name=>'workshop-v3',command=>'workshop_greet');
my $bot=bless {registry=>Mediabot::CommandRegistry->new},'Workshop::Bot';
my $m=Mediabot::PluginManager->new(bot=>$bot,plugin_dir=>$tmp);
my $p=$m->load_package_v3('workshop-v3',grants=>['irc.reply']);
my $handler=$bot->{registry}->handler_for('workshop_greet','public');
my $c=bless {replies=>[]},'Workshop::Caller';
$handler->($c);die "Disabled output escaped\n" if @{$c->{replies}};
$m->enable('workshop-v3');$handler->($c);die "Unconfigured output escaped\n" if @{$c->{replies}};
$m->set_v3_channel_policy('workshop-v3','#test',mode=>'observe');
$handler->($c);die "Observe output escaped\n" if @{$c->{replies}};
$m->set_v3_channel_policy('workshop-v3','#test',mode=>'on');
$handler->($c);die "Configured greeting missing\n" unless @{$c->{replies}}==1 && $c->{replies}[0] eq 'Hello from this channel.';
$c->{channel}='#other';$handler->($c);die "Cross-channel output escaped\n" unless @{$c->{replies}}==1;
$c->{channel}='#test';$m->set_v3_channel_policy('workshop-v3','#test',mode=>'off');
$handler->($c);die "Off output escaped\n" unless @{$c->{replies}}==1;
$m->disable('workshop-v3');die "Stop missing\n" if $p->{object}{started};
$m->unregister_plugin('workshop-v3');$handler->($c);
die "Unload leaked ownership\n" if $m->count || $bot->{registry}->has_command('workshop_greet','public') || @{$c->{replies}}!=1;
print "[OK] Generated package: load disabled, explicit enable, observe/on/off, channel isolation, stop, unload and stale-handler refusal.\n";
print "[OK] Native API v3 runtime exercised offline; no database, IRC connection, live configuration or service touched.\n";
