# t/cases/412_mb173_partyline_plugins_status.t
use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;
use Test::More;

my $root = File::Spec->rel2abs("$Bin/../..");
my $file = File::Spec->catfile($root, 'Mediabot', 'Partyline.pm');
open my $fh, '<', $file or die "$file: $!";
local $/;
my $src = <$fh>;
close $fh;

my ($dispatch) = $src =~ /(# ---- Authenticated : dispatch commands.*?Unknown command\. Type \.help)/s;
my ($plugins)  = $src =~ /(sub _cmd_plugins \{.*?)(?=^sub _cmd_help)/ms;
my ($help)     = $src =~ /(sub _cmd_help \{.*?^\})/ms;

ok(defined($dispatch) && length($dispatch), 'authenticated partyline dispatch block extracted');
ok(defined($plugins) && length($plugins), '_cmd_plugins block extracted');
ok(defined($help) && length($help), '_cmd_help block extracted');

like($dispatch, qr/^    elsif \(\$line =~ \/\^\\\.plugins/ms,
    '.plugins dispatch is present');
like($dispatch, qr/mediabot_commands_partyline_total.*?command => '\.plugins'/s,
    '.plugins increments partyline command metric');
like($dispatch, qr/_cmd_plugins\(\$stream, \$id, \$1\)/,
    '.plugins dispatch passes optional argument');
like($help, qr/\.plugins \[loaded\|config\] - show plugin manager\/autoload status/,
    '.help documents .plugins command');

like($plugins, qr/Read-only Partyline visibility for the active PluginManager state/,
    '_cmd_plugins documents active read-only visibility');
like($plugins, qr/PluginManager: not initialized/,
    '_cmd_plugins handles missing PluginManager');
like($plugins, qr/plugin_autoload_enabled/,
    '_cmd_plugins reports autoload gate status');
like($plugins, qr/\$pm->list/,
    '_cmd_plugins reads PluginManager list');
like($plugins, qr/Usage: \.plugins \[loaded\|config\]/,
    '_cmd_plugins has usage branch');
like($plugins, qr/Plugin config:/,
    '_cmd_plugins has config view');
like($plugins, qr/plugins\.ENABLED_AUTOLOAD, PLUGIN_AUTOLOAD, PLUGINS_AUTOLOAD/,
    '_cmd_plugins lists all autoload compatibility keys');
like($plugins, qr/PLUGINS_ENABLED, PLUGIN_ENABLED, PLUGINS/,
    '_cmd_plugins lists all plugin-list compatibility keys');
like($plugins, qr/Loaded plugins:/,
    '_cmd_plugins has loaded plugin listing');
unlike($plugins, qr/load_configured_plugins|load_perl_module|register_plugin|unregister_plugin|enable\(|disable\(/,
    '_cmd_plugins is read-only and does not mutate PluginManager');

SKIP: {
    my $loaded = eval {
        local @INC = ($root, @INC);
        require 'Mediabot/Partyline.pm';
        1;
    };
    if (!$loaded && $@ =~ /Can't locate (?:IO\/Async|Net\/Async|Future)\b/) {
        skip 'optional async runtime dependency missing', 1;
    }
    ok($loaded, 'Partyline module loads with .plugins command') or diag($@);
}

done_testing();
