# t/cases/412_mb173_partyline_plugins_status.t
use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;

my $case = sub {
    my ($assert) = @_;

    my $root = File::Spec->catdir($Bin, '..', '..');
    unshift @INC, $root;

    my $file = File::Spec->catfile($root, 'Mediabot', 'Partyline.pm');
    open my $fh, '<', $file
        or do { $assert->(0, "cannot open Partyline.pm: $!"); return; };
    my $src = do { local $/; <$fh> };
    close $fh;

    my ($dispatch) = $src =~ /# ---- Authenticated : dispatch commands.*?Unknown command\. Type \.help/s;
    my ($plugins) = $src =~ /sub _cmd_plugins \{(.*?)^sub _cmd_help/ms;
    my ($help)    = $src =~ /sub _cmd_help \{(.*?)^\}/ms;

    $assert->(defined($dispatch) && length($dispatch) > 0,
        'authenticated partyline dispatch block extracted');
    $assert->(defined($plugins) && length($plugins) > 0,
        '_cmd_plugins block extracted');
    $assert->(defined($help) && length($help) > 0,
        '_cmd_help block extracted');

    $assert->($dispatch =~ /^    elsif \(\$line =~ \/\^\\\.plugins/ms,
        '.plugins dispatch is present');
    $assert->($dispatch =~ /mediabot_commands_partyline_total.*?command => '\.plugins'/s,
        '.plugins increments partyline command metric');
    $assert->($dispatch =~ /_cmd_plugins\(\$stream, \$id, \$1\)/,
        '.plugins dispatch passes optional argument');

    $assert->($help =~ /\.plugins \[loaded\|config\] - show plugin manager\/autoload status/,
        '.help documents .plugins command');

    $assert->($plugins =~ /mb173-B1: partyline visibility for the new plugin foundation/,
        '_cmd_plugins contains mb173 marker');
    $assert->($plugins =~ /PluginManager: not initialized/,
        '_cmd_plugins handles missing PluginManager');
    $assert->($plugins =~ /plugin_autoload_enabled/,
        '_cmd_plugins reports autoload gate status');
    $assert->($plugins =~ /\$pm->list/,
        '_cmd_plugins reads PluginManager list');
    $assert->($plugins =~ /Usage: \.plugins \[loaded\|config\]/,
        '_cmd_plugins has usage branch');
    $assert->($plugins =~ /Plugin config:/ && $plugins =~ /plugin list keys:/,
        '_cmd_plugins has config view');
    $assert->($plugins =~ /Loaded plugins:/,
        '_cmd_plugins has loaded plugin listing');

    $assert->($plugins !~ /load_configured_plugins|load_perl_module|register_plugin|unregister_plugin|enable\(|disable\(/,
        '_cmd_plugins is read-only and does not mutate PluginManager');

    eval { require 'Mediabot/Partyline.pm'; 1 }
        or do { $assert->(0, "cannot load Mediabot/Partyline.pm: $@"); return; };

    $assert->(1, 'Partyline module loads with .plugins command');
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
