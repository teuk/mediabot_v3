# t/cases/411_mb172_plugin_autoload_gate.t
use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;

{
    package GateConf;
    sub new { my ($class, %data) = @_; return bless \%data, $class; }
    sub get { my ($self, $key) = @_; return $self->{$key}; }
}

my $case = sub {
    my ($assert) = @_;

    my $root = File::Spec->catdir($Bin, '..', '..');
    unshift @INC, $root;

    eval { require 'Mediabot/Mediabot.pm'; 1 }
        or do { $assert->(0, "cannot load Mediabot/Mediabot.pm: $@"); return; };

    my $bot_disabled = Mediabot->new({ conf => GateConf->new() });
    my $disabled_report = $bot_disabled->load_configured_plugins_if_enabled();

    $assert->($bot_disabled->can('plugin_autoload_enabled'),
        'Mediabot exposes plugin_autoload_enabled');
    $assert->($bot_disabled->can('load_configured_plugins_if_enabled'),
        'Mediabot exposes gated plugin loader');
    $assert->(!$bot_disabled->plugin_autoload_enabled,
        'plugin autoload is disabled by default');
    $assert->($disabled_report->{skipped} && $disabled_report->{reason} =~ /disabled/,
        'gated loader skips when autoload flag is absent');
    $assert->($bot_disabled->plugin_manager->count == 0,
        'no plugin is loaded when autoload is disabled');

    my $bot_enabled = Mediabot->new({
        conf => GateConf->new(
            'plugins.AUTOLOAD' => '1',
            'plugins.ENABLED'  => 'Mediabot::Plugin::Demo',
        ),
    });

    $assert->($bot_enabled->plugin_autoload_enabled,
        'plugins.AUTOLOAD=1 enables plugin autoload gate');

    my $enabled_report = $bot_enabled->load_configured_plugins_if_enabled();

    $assert->(!$enabled_report->{skipped},
        'enabled gated loader does not skip');
    $assert->(ref($enabled_report->{loaded}) eq 'ARRAY' && @{$enabled_report->{loaded}} == 1,
        'enabled gated loader loads configured Demo plugin');
    $assert->($bot_enabled->plugin_manager->is_registered('Mediabot::Plugin::Demo'),
        'Demo plugin registered through gated loader');

    my $bot_truthy = Mediabot->new({
        conf => GateConf->new(
            PLUGIN_AUTOLOAD => 'yes',
            PLUGINS_ENABLED => 'Mediabot::Plugin::Demo',
        ),
    });

    $assert->($bot_truthy->plugin_autoload_enabled,
        'flat PLUGIN_AUTOLOAD=yes is accepted as truthy');

    my $truthy_report = $bot_truthy->load_configured_plugins_if_enabled();
    $assert->(ref($truthy_report->{loaded}) eq 'ARRAY' && @{$truthy_report->{loaded}} == 1,
        'flat PLUGINS_ENABLED is loaded through gated loader');

    my $bot_false = Mediabot->new({
        conf => GateConf->new(
            'plugins.AUTOLOAD' => '0',
            'plugins.ENABLED'  => 'Mediabot::Plugin::Demo',
        ),
    });

    my $false_report = $bot_false->load_configured_plugins_if_enabled();
    $assert->($false_report->{skipped} && $bot_false->plugin_manager->count == 0,
        'plugins.AUTOLOAD=0 keeps plugins disabled even when ENABLED is set');

    my $main_file = File::Spec->catfile($root, 'Mediabot', 'Mediabot.pm');
    open my $mfh, '<', $main_file
        or do { $assert->(0, "cannot open Mediabot.pm: $!"); return; };
    my $main_src = do { local $/; <$mfh> };
    close $mfh;

    $assert->($main_src =~ /mb172-B1: plugins are loaded at boot only when explicitly enabled in config/,
        'Mediabot source documents mb172 autoload gate');
    $assert->($main_src =~ /sub log_plugin_load_report \{/,
        'Mediabot has plugin autoload report logger');

    my $boot_file = File::Spec->catfile($root, 'mediabot.pl');
    open my $bfh, '<', $boot_file
        or do { $assert->(0, "cannot open mediabot.pl: $!"); return; };
    my $boot_src = do { local $/; <$bfh> };
    close $bfh;

    $assert->($boot_src =~ /optional trusted Perl plugin autoload/,
        'mediabot.pl contains optional plugin autoload hook');
    $assert->($boot_src =~ /load_configured_plugins_if_enabled\(\)/,
        'mediabot.pl calls gated plugin loader');
    $assert->($boot_src =~ /log_plugin_load_report\(\$plugin_load_report\)/,
        'mediabot.pl logs plugin load report');
};

if (caller) { return $case; }

my $tests = 0;
my $fail  = 0;

my $assert = sub {
    my ($ok, $name) = @_;
    $tests++;
    $name = 'unnamed assertion' unless defined $name && $name ne '';

    if ($ok) {
        print "ok $tests - $name\n";
    }
    else {
        print "not ok $tests - $name\n";
        $fail++;
    }
};

$case->($assert);
print "1..$tests\n";
exit($fail ? 1 : 0);
