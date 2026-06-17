# t/cases/431_mb192_sample_conf_scriptdryrun_docs.t
use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;
use Test::More;

my $root = File::Spec->rel2abs("$Bin/../..");
my $sample = File::Spec->catfile($root, 'mediabot.sample.conf');

open my $fh, '<', $sample or die "$sample: $!";
local $/;
my $src = <$fh>;
close $fh;

like($src, qr/Optional trusted plugins and external Perl\/Python\/Tcl script bridge/,
    'sample conf contains current multilingual plugin bridge section');
like($src, qr/Mediabot::Plugin::ScriptDryRun/,
    'sample conf references ScriptDryRun plugin');
like($src, qr/mediabot-script-v1 JSON object/,
    'sample conf documents script protocol boundary');
like($src, qr/supported action types: reply, notice, log, timer/,
    'sample conf documents all action types');
like($src, qr/Supported extensions: \.pl, \.py and \.tcl/,
    'sample conf documents supported script languages');

like($src, qr/^#AUTOLOAD=0$/m,
    'sample conf keeps plugin autoload disabled in canonical example');
like($src, qr/^#ENABLED=Mediabot::Plugin::ScriptDryRun$/m,
    'sample conf documents the ScriptDryRun module');
like($src, qr/^## SCRIPT=examples\/hello_perl\.pl$/m,
    'sample conf documents optional SCRIPT fallback');
like($src, qr/^#COMMANDS=hello$/m,
    'sample conf documents a safe COMMANDS scope');
like($src, qr/^#ROUTES=hello=examples\/hello_perl\.pl$/m,
    'sample conf documents a safe route-only example');
like($src, qr/^#ACTION_MODE=dry-run$/m,
    'sample conf documents dry-run action mode');
like($src, qr/^#ALLOW_IRC=no$/m,
    'sample conf documents safe IRC-disabled mode');
like($src, qr/^#APPLY_REQUIRE_SCOPE=yes$/m,
    'sample conf documents enabled apply scope guard');

like($src, qr/^#COMMANDS=hello,pyhello,tclhello,proll,p8ball,pchoose$/m,
    'sample conf documents all conflict-safe example aliases');
like($src, qr/^#ROUTES=hello=examples\/hello_perl\.pl, pyhello=examples\/hello_python\.py, tclhello=examples\/hello_tcl\.tcl, proll=examples\/roll\.py, p8ball=examples\/eightball\.tcl, pchoose=examples\/choose\.pl$/m,
    'sample conf documents all six example routes');
like($src, qr/^#ACTION_MODE=apply$/m,
    'sample conf documents guarded apply mode');
like($src, qr/^#ALLOW_IRC=yes$/m,
    'sample conf documents the explicit IRC gate');

like($src, qr/PLUGIN_AUTOLOAD, PLUGINS_AUTOLOAD/,
    'sample conf documents plugin autoload compatibility aliases');
like($src, qr/PLUGINS_ENABLED, PLUGIN_ENABLED, PLUGINS/,
    'sample conf documents plugin list compatibility aliases');
like($src, qr/SCRIPT_DRYRUN_SCRIPT, SCRIPT_DRYRUN_PATH/,
    'sample conf documents flat script fallback aliases');
like($src, qr/SCRIPT_DRYRUN_ACTION_MODE, SCRIPT_DRYRUN_ALLOW_IRC/,
    'sample conf documents flat action aliases');
like($src, qr/SCRIPT_DRYRUN_APPLY_REQUIRE_SCOPE/,
    'sample conf documents flat scope-guard alias');

unlike($src, qr/^AUTOLOAD=1$/m,
    'sample conf does not enable plugin autoload');
unlike($src, qr/^ENABLED=Mediabot::Plugin::ScriptDryRun$/m,
    'sample conf does not actively load ScriptDryRun');
unlike($src, qr/^ACTION_MODE=apply$/m,
    'sample conf does not actively enable apply mode');
unlike($src, qr/^ALLOW_IRC=yes$/m,
    'sample conf does not actively enable IRC output');

my @plugin_headers = ($src =~ /^#\[plugins\]$/mg);
my @script_headers = ($src =~ /^#\[plugins\.ScriptDryRun\]$/mg);
is(scalar @plugin_headers, 1, 'sample conf has one commented plugin section');
is(scalar @script_headers, 1, 'sample conf has one commented ScriptDryRun section');

for my $rel (
    'plugins/scripts/examples/hello_perl.pl',
    'plugins/scripts/examples/hello_python.py',
    'plugins/scripts/examples/hello_tcl.tcl',
    'plugins/scripts/examples/roll.py',
    'plugins/scripts/examples/eightball.tcl',
    'plugins/scripts/examples/choose.pl',
) {
    ok(-f File::Spec->catfile($root, split m{/}, $rel), "documented route exists: $rel");
}

done_testing();
