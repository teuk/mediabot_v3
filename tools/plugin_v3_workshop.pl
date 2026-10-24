#!/usr/bin/env perl
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/..";
use Getopt::Long qw(GetOptions);
use File::Temp qw(tempdir);
use Mediabot::Plugin::ScaffoldV3;
my ($check,$name,$command,$directory)=(0,undef,undef,'plugins');
GetOptions('check'=>\$check,'create=s'=>\$name,'command=s'=>\$command,'directory=s'=>\$directory)
    or die "Use --check or --create NAME [--command NAME] [--directory EXISTING_DIR]\n";
die "Use exactly --check or --create NAME\n" if @ARGV || ($check ? defined($name) || defined($command) : !defined($name));
if (!$check) {
    my $r=Mediabot::Plugin::ScaffoldV3::create(directory=>$directory,name=>$name,command=>$command);
    print "[OK] Created default-off package $r->{name}; command $r->{command}. No bot was loaded or changed.\n";
    exit 0;
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
