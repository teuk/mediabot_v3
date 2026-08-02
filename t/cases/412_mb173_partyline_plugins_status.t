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
# mb588: .plugins pilote desormais le cycle de vie v2 — le .help l'annonce.
like($help, qr/\.plugins \[loaded\|config\|info\|load\|loadscript\|unload\|reload\|enable\|disable\|cleardata\] - plugin lifecycle \(v2\)/,
    '.help documents .plugins command');

like($plugins, qr/Read-only Partyline visibility for the active PluginManager state/,
    '_cmd_plugins documents active read-only visibility');
like($plugins, qr/PluginManager: not initialized/,
    '_cmd_plugins handles missing PluginManager');
like($plugins, qr/plugin_autoload_enabled/,
    '_cmd_plugins reports autoload gate status');
like($plugins, qr/\$pm->list/,
    '_cmd_plugins reads PluginManager list');
like($plugins, qr/Usage: \.plugins \[loaded\|config/,
    '_cmd_plugins has usage branch');
like($plugins, qr/\|load <Module> \[name\]\|loadscript <path> \[name\]\|unload <name>\|reload <name>/,
    '_cmd_plugins usage covers the lifecycle verbs (incl. loadscript mb590)');
like($plugins, qr/Plugin config:/,
    '_cmd_plugins has config view');
like($plugins, qr/plugins\.ENABLED_AUTOLOAD, PLUGIN_AUTOLOAD, PLUGINS_AUTOLOAD/,
    '_cmd_plugins lists all autoload compatibility keys');
like($plugins, qr/PLUGINS_ENABLED, PLUGIN_ENABLED, PLUGINS/,
    '_cmd_plugins lists all plugin-list compatibility keys');
like($plugins, qr/Loaded plugins:/,
    '_cmd_plugins has loaded plugin listing');
# mb588: le contrat evolue — les mutations existent mais UNIQUEMENT dans le
# bloc de cycle de vie gate par niveau ; la section de lecture (summary/
# loaded/config), qui suit le marqueur historique read-only, reste pure.
my ($lifecycle_412, $readonly_412) = $plugins =~
    /(mb588-B1.*?)(# Read-only Partyline visibility.*)/s;
ok(defined $readonly_412, '_cmd_plugins keeps a distinct read-only section');
unlike($readonly_412 // '', qr/load_configured_plugins|load_perl_module|register_plugin|unregister_plugin|->enable\(|->disable\(/,
    '_cmd_plugins read-only section does not mutate PluginManager');
like($lifecycle_412 // '', qr/requires Owner level/,
    '_cmd_plugins destructive verbs are Owner-gated');
like($lifecycle_412 // '', qr/requires Master or Owner level/,
    '_cmd_plugins enable\/disable are Master-gated');

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
