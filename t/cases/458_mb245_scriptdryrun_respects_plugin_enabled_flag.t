#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../..";

use Mediabot::EventBus;
use Mediabot::PluginManager;
use Mediabot::Plugin::ScriptDryRun;

{
    package Local::MB245::Conf;
    sub new { bless {}, shift }
    sub get {
        my ($self, $key) = @_;
        return 'examples/hello_perl.pl' if $key =~ /ScriptDryRun\.SCRIPT\z/;
        return 'hello'                  if $key =~ /ScriptDryRun\.COMMANDS\z/;
        return undef;
    }
}

{
    package Local::MB245::Bot;
    sub new {
        return bless {
            conf      => Local::MB245::Conf->new,
            events    => Mediabot::EventBus->new,
            dry_calls => 0,
        }, shift;
    }
    sub events { $_[0]->{events} }
    sub run_script_actions_dry {
        my ($self, @args) = @_;
        $self->{dry_calls}++;
        return {
            ok            => 1,
            dry_run       => 1,
            script_result => { ok => 1, response => { ok => 1, actions => [] } },
            action_plan   => { ok => 1, planned => [], applied => [], errors => [] },
        };
    }
}

my $bot = Local::MB245::Bot->new;
my $pm  = Mediabot::PluginManager->new(bot => $bot);

my $entry = $pm->load_perl_module('Mediabot::Plugin::ScriptDryRun');
ok($entry && ref($entry) eq 'HASH', 'ScriptDryRun loads through PluginManager');
ok($entry->{object} && $entry->{object}->can('plugin_enabled'), 'ScriptDryRun exposes plugin_enabled guard');
is($entry->{object}->{plugin_name}, 'Mediabot::Plugin::ScriptDryRun', 'ScriptDryRun stores manager-facing plugin name');
ok($entry->{object}->plugin_enabled, 'ScriptDryRun starts enabled through PluginManager');

my $ctx1 = { command => 'hello', channel => '#test', target => '#test', nick => 'TeuK', args => [] };
my $ran1 = $bot->events->emit('public_command_observed', $ctx1);
is($ran1, 1, 'enabled plugin listener runs once');
is($bot->{dry_calls}, 1, 'enabled plugin executes dry-run bridge');
ok($ctx1->{scriptdryrun_handled}, 'enabled plugin marks command handled');

is($pm->disable('Mediabot::Plugin::ScriptDryRun'), 1, 'PluginManager disables ScriptDryRun');
ok(!$entry->{object}->plugin_enabled, 'ScriptDryRun sees disabled manager state');

my $ctx2 = { command => 'hello', channel => '#test', target => '#test', nick => 'TeuK', args => [] };
my $ran2 = $bot->events->emit('public_command_observed', $ctx2);
is($ran2, 1, 'disabled plugin listener may still be subscribed');
is($bot->{dry_calls}, 1, 'disabled plugin does not execute script bridge');
ok(!$ctx2->{scriptdryrun_handled}, 'disabled plugin does not mark command handled');
is($entry->{object}->last_error, 'ScriptDryRun plugin is disabled', 'disabled state is visible as last_error');

is($pm->enable('Mediabot::Plugin::ScriptDryRun'), 1, 'PluginManager re-enables ScriptDryRun');
ok($entry->{object}->plugin_enabled, 'ScriptDryRun sees enabled manager state again');

my $ctx3 = { command => 'hello', channel => '#test', target => '#test', nick => 'TeuK', args => [] };
$bot->events->emit('public_command_observed', $ctx3);
is($bot->{dry_calls}, 2, 're-enabled plugin executes bridge again');
ok($ctx3->{scriptdryrun_handled}, 're-enabled plugin marks command handled again');

my $custom_bot = Local::MB245::Bot->new;
my $custom_pm  = Mediabot::PluginManager->new(bot => $custom_bot);
my $custom = $custom_pm->load_perl_module('Mediabot::Plugin::ScriptDryRun', name => 'ScriptSpell');
is($custom->{object}->{plugin_name}, 'ScriptSpell', 'custom plugin name is passed to plugin register');
ok($custom->{object}->plugin_enabled, 'custom-named plugin starts enabled');
is($custom_pm->disable('ScriptSpell'), 1, 'custom-named plugin can be disabled');
ok(!$custom->{object}->plugin_enabled, 'custom-named plugin honours disabled flag');

my $plugin_src = do { open my $fh, '<:encoding(UTF-8)', "$Bin/../../Mediabot/Plugin/ScriptDryRun.pm" or die $!; local $/; <$fh> };
my $pm_src     = do { open my $fh, '<:encoding(UTF-8)', "$Bin/../../Mediabot/PluginManager.pm" or die $!; local $/; <$fh> };

like($plugin_src, qr/mb245-B1/, 'ScriptDryRun source contains mb245 enabled-state marker');
like($pm_src, qr/mb245-B2/, 'PluginManager source contains mb245 plugin-name marker');
unlike($plugin_src . $pm_src, qr/`[^`]+`|\bqx\s*(?:\/|\(|\{)|\bsystem\s*(?:\(|\s)/, 'mb245 enabled guard does not introduce shell execution');

done_testing();
