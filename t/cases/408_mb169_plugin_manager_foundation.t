# t/cases/408_mb169_plugin_manager_foundation.t
use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;

my $case = sub {
    my ($assert) = @_;

    my $root = File::Spec->catdir($Bin, '..', '..');
    unshift @INC, $root;

    eval { require Mediabot::PluginManager; 1 }
        or do { $assert->(0, "cannot load Mediabot::PluginManager: $@"); return; };

    my $fake_bot = bless({}, 'FakeBot');
    my $pm = Mediabot::PluginManager->new(bot => $fake_bot, plugin_dir => 'plugins');

    $assert->(ref($pm) eq 'Mediabot::PluginManager',
        'PluginManager object can be created');
    $assert->($pm->bot == $fake_bot,
        'PluginManager stores bot reference');
    $assert->($pm->plugin_dir eq 'plugins',
        'PluginManager stores plugin_dir');
    $assert->($pm->count == 0,
        'new PluginManager starts empty');

    my $entry = $pm->register_plugin(
        name        => 'Radio',
        module      => 'Mediabot::Plugin::Radio',
        object      => bless({}, 'RadioObj'),
        version     => '1.0',
        description => 'Radio plugin',
        metadata    => { category => 'media' },
    );

    $assert->($entry->{name} eq 'radio',
        'plugin name is normalized');
    $assert->($pm->is_registered('RADIO'),
        'registered plugin lookup is case-insensitive');
    $assert->($pm->is_enabled('radio'),
        'registered plugin is enabled by default');
    $assert->($pm->object_for('radio') && ref($pm->object_for('radio')) eq 'RadioObj',
        'object_for returns stored plugin object');
    $assert->($pm->plugin('radio')->{metadata}{category} eq 'media',
        'metadata is stored');

    $pm->disable('radio');
    $assert->(!$pm->is_enabled('radio'),
        'disable() marks plugin disabled');
    $pm->enable('radio');
    $assert->($pm->is_enabled('radio'),
        'enable() marks plugin enabled');

    my $dup_ok = eval {
        $pm->register_plugin(name => 'radio');
        1;
    };
    $assert->(!$dup_ok && $@ =~ /already registered/,
        'duplicate plugin registration is rejected by default');

    $pm->register_plugin(name => 'quotes', enabled => 0);
    $assert->($pm->count == 2,
        'count() sees all plugins');
    $assert->($pm->count(enabled => 1) == 1,
        'count(enabled => 1) filters enabled plugins');
    $assert->($pm->count(enabled => 0) == 1,
        'count(enabled => 0) filters disabled plugins');

    my @names = $pm->names;
    $assert->(join(',', @names) eq 'radio,quotes',
        'names() preserves registration order');

    $assert->($pm->unregister_plugin('quotes') == 1 && !$pm->is_registered('quotes'),
        'unregister_plugin removes plugin');

    my $bad_module_ok = eval {
        $pm->load_perl_module('../evil');
        1;
    };
    $assert->(!$bad_module_ok && $@ =~ /invalid module name/,
        'load_perl_module rejects path-like module names');

    eval { require 'Mediabot/Mediabot.pm'; 1 }
        or do { $assert->(0, "cannot load Mediabot/Mediabot.pm: $@"); return; };

    my $bot = Mediabot->new({});
    $assert->($bot->plugin_manager && ref($bot->plugin_manager) eq 'Mediabot::PluginManager',
        'Mediabot constructor creates a PluginManager');
    $assert->($bot->plugins == $bot->plugin_manager,
        'Mediabot->plugins is a short alias to plugin_manager');
    $assert->($bot->plugin_manager->count == 0,
        'Mediabot PluginManager loads no plugin by default');

    my $main_file = File::Spec->catfile($root, 'Mediabot', 'Mediabot.pm');
    open my $mfh, '<', $main_file
        or do { $assert->(0, "cannot open Mediabot.pm: $!"); return; };
    my $main_src = do { local $/; <$mfh> };
    close $mfh;

    $assert->($main_src =~ /use Mediabot::PluginManager;/,
        'Mediabot.pm loads Mediabot::PluginManager');
    $assert->($main_src =~ /Mediabot::PluginManager->new\(bot => \$self\)/,
        'Mediabot object initializes PluginManager with bot reference');
    $assert->($main_src !~ /load_perl_module\(/,
        'Mediabot constructor does not auto-load plugins yet');
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
