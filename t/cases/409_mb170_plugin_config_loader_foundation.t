# t/cases/409_mb170_plugin_config_loader_foundation.t
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

    my $pm = Mediabot::PluginManager->new();

    my $hash_conf = {
        'plugins.ENABLED' => 'Mediabot::Plugin::Alpha, Mediabot::Plugin::Beta ../evil /tmp/nope.pl',
    };

    my $parsed = $pm->configured_modules_from_conf($hash_conf);

    $assert->(ref($parsed) eq 'HASH',
        'configured_modules_from_conf returns hashref in scalar context');
    $assert->(join(',', @{ $parsed->{modules} }) eq 'Mediabot::Plugin::Alpha,Mediabot::Plugin::Beta',
        'configured_modules_from_conf extracts valid module names');
    $assert->(join(',', @{ $parsed->{invalid} }) eq '../evil,/tmp/nope.pl',
        'configured_modules_from_conf reports invalid module names');
    $assert->($parsed->{raw} =~ /Alpha/,
        'configured_modules_from_conf preserves raw configured value');

    my @modules = $pm->configured_modules_from_conf($hash_conf);
    $assert->(join(',', @modules) eq 'Mediabot::Plugin::Alpha,Mediabot::Plugin::Beta',
        'configured_modules_from_conf returns module list in list context');

    my $flat_conf = {
        PLUGINS_ENABLED => "Mediabot::Plugin::Gamma\nMediabot::Plugin::Delta",
    };
    my $flat = $pm->configured_modules_from_conf($flat_conf);
    $assert->(join(',', @{ $flat->{modules} }) eq 'Mediabot::Plugin::Gamma,Mediabot::Plugin::Delta',
        'flat PLUGINS_ENABLED key is supported');

    {
        package LocalConf;
        sub new { bless { 'plugins.enabled' => 'Mediabot::Plugin::FromObject' }, shift }
        sub get { my ($self, $key) = @_; return $self->{$key}; }
    }

    my $object_conf = LocalConf->new;
    my $obj = $pm->configured_modules_from_conf($object_conf);
    $assert->(join(',', @{ $obj->{modules} }) eq 'Mediabot::Plugin::FromObject',
        'Conf-like object with get() is supported');

    my $bad_ok = eval {
        $pm->load_perl_module('../evil');
        1;
    };
    $assert->(!$bad_ok && $@ =~ /invalid module name/,
        'load_perl_module rejects path-like module names');

    my $none = $pm->configured_modules_from_conf({});
    $assert->(ref($none->{modules}) eq 'ARRAY' && @{$none->{modules}} == 0,
        'missing plugin config yields empty module list');

    my $report = $pm->load_configured_plugins({
        'plugins.ENABLED' => 'Mediabot::Plugin::DefinitelyMissing',
    });
    $assert->(ref($report) eq 'HASH',
        'load_configured_plugins returns structured report');
    $assert->(ref($report->{loaded}) eq 'ARRAY' && @{$report->{loaded}} == 0,
        'missing configured plugin is not reported as loaded');
    $assert->(ref($report->{errors}) eq 'ARRAY' && @{$report->{errors}} == 1,
        'missing configured plugin is reported as load error');
    $assert->($report->{errors}[0]{module} eq 'Mediabot::Plugin::DefinitelyMissing',
        'load error preserves module name');

    my $pm_file = File::Spec->catfile($root, 'Mediabot', 'PluginManager.pm');
    open my $pfh, '<', $pm_file
        or do { $assert->(0, "cannot open PluginManager.pm: $!"); return; };
    my $pm_src = do { local $/; <$pfh> };
    close $pfh;

    $assert->($pm_src =~ /mb170-B1: accept several key spellings/,
        'PluginManager source contains mb170 config marker');
    $assert->($pm_src =~ /sub load_configured_plugins \{/,
        'PluginManager has load_configured_plugins method');

    eval { require 'Mediabot/Mediabot.pm'; 1 }
        or do { $assert->(0, "cannot load Mediabot/Mediabot.pm: $@"); return; };

    my $bot = Mediabot->new({ conf => bless({}, 'EmptyConf') });
    $assert->($bot->can('load_configured_plugins'),
        'Mediabot exposes explicit load_configured_plugins entry point');
    $assert->($bot->plugin_manager->count == 0,
        'Mediabot still auto-loads no plugin by default');

    my $main_file = File::Spec->catfile($root, 'Mediabot', 'Mediabot.pm');
    open my $mfh, '<', $main_file
        or do { $assert->(0, "cannot open Mediabot.pm: $!"); return; };
    my $main_src = do { local $/; <$mfh> };
    close $mfh;

    $assert->($main_src =~ /mb170-B1 does not call this automatically from the constructor/,
        'Mediabot source documents no automatic plugin load in mb170');
    $assert->($main_src !~ /load_configured_plugins\(\);\s*#\s*auto/s,
        'no obvious automatic plugin loading call is present');
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
