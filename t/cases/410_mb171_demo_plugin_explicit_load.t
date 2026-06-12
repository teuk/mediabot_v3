# t/cases/410_mb171_demo_plugin_explicit_load.t
use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;

my $case = sub {
    my ($assert) = @_;

    my $root = File::Spec->catdir($Bin, '..', '..');
    unshift @INC, $root;

    eval { require 'Mediabot/Mediabot.pm'; 1 }
        or do { $assert->(0, "cannot load Mediabot/Mediabot.pm: $@"); return; };

    my $bot = Mediabot->new({ conf => {} });

    $assert->($bot->plugin_manager->count == 0,
        'Mediabot still loads no plugin by default');
    $assert->($bot->events->listener_count('public_command_observed') == 0,
        'Demo plugin listener is not present before explicit load');

    my $report = $bot->plugin_manager->load_configured_plugins({
        'plugins.ENABLED' => 'Mediabot::Plugin::Demo',
    });

    $assert->(ref($report) eq 'HASH',
        'explicit plugin load returns structured report');
    $assert->(ref($report->{loaded}) eq 'ARRAY' && @{$report->{loaded}} == 1,
        'Demo plugin is explicitly loaded from config');
    $assert->(ref($report->{errors}) eq 'ARRAY' && @{$report->{errors}} == 0,
        'Demo plugin explicit load has no errors');
    $assert->($bot->plugin_manager->is_registered('Mediabot::Plugin::Demo'),
        'PluginManager registers Demo plugin');
    $assert->($bot->plugin_manager->is_enabled('Mediabot::Plugin::Demo'),
        'Demo plugin is enabled after explicit load');

    my $obj = $bot->plugin_manager->object_for('Mediabot::Plugin::Demo');
    $assert->($obj && ref($obj) eq 'Mediabot::Plugin::Demo',
        'Demo plugin register() returned object stored by PluginManager');
    $assert->($bot->events->listener_count('public_command_observed') == 1,
        'Demo plugin registered one EventBus listener');

    my $emitted = $bot->emit_event_report('public_command_observed', bless({}, 'FakeCtx'));
    $assert->($emitted->{ran} == 1,
        'public_command_observed reaches Demo plugin listener');
    $assert->($obj->observed_public == 1,
        'Demo plugin observed_public counter increments');

    my $plugin_file = File::Spec->catfile($root, 'Mediabot', 'Plugin', 'Demo.pm');
    open my $pfh, '<', $plugin_file
        or do { $assert->(0, "cannot open Demo.pm: $!"); return; };
    my $plugin_src = do { local $/; <$pfh> };
    close $pfh;

    $assert->($plugin_src =~ /mb171-B1: first trusted in-process Perl demo plugin/,
        'Demo plugin source contains mb171 marker');
    $assert->($plugin_src =~ /public_command_observed/,
        'Demo plugin listens to public_command_observed');
    $assert->($plugin_src !~ /send_privmsg|botPrivmsg|dbh->|prepare\(/,
        'Demo plugin does not send IRC messages or touch DB');

    my $main_file = File::Spec->catfile($root, 'Mediabot', 'Mediabot.pm');
    open my $mfh, '<', $main_file
        or do { $assert->(0, "cannot open Mediabot.pm: $!"); return; };
    my $main_src = do { local $/; <$mfh> };
    close $mfh;

    $assert->($main_src !~ /Mediabot::Plugin::Demo/,
        'Mediabot core does not hard-code Demo plugin');
    $assert->($bot->plugin_manager->count == 1,
        'PluginManager contains exactly one explicitly loaded plugin in this test');
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
