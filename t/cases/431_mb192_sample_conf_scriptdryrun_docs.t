# t/cases/431_mb192_sample_conf_scriptdryrun_docs.t
use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;

my $case = sub {
    my ($assert) = @_;

    my $root = File::Spec->catdir($Bin, '..', '..');
    my $sample = File::Spec->catfile($root, 'mediabot.sample.conf');

    open my $fh, '<', $sample
        or do { $assert->(0, "cannot open mediabot.sample.conf: $!"); return; };

    my $src = do { local $/; <$fh> };
    close $fh;

    $assert->($src =~ /Optional trusted Perl\/plugin bridge/,
        'sample conf contains plugin bridge documentation section');
    $assert->($src =~ /Mediabot::Plugin::ScriptDryRun/,
        'sample conf references ScriptDryRun plugin');
    $assert->($src =~ /mediabot-script-v1 JSON stdin\/stdout protocol/,
        'sample conf documents script protocol boundary');
    $assert->($src =~ /^#AUTOLOAD=0$/m,
        'sample conf keeps plugin autoload disabled in example');
    $assert->($src =~ /^#ENABLED=Mediabot::Plugin::ScriptDryRun$/m,
        'sample conf shows disabled ScriptDryRun plugin enable line');
    $assert->($src =~ /^#SCRIPT=examples\/hello_perl\.pl$/m,
        'sample conf documents ScriptDryRun SCRIPT key');
    $assert->($src =~ /^#COMMANDS=hello$/m,
        'sample conf documents ScriptDryRun COMMANDS key');
    $assert->($src =~ /^#ROUTES=hello=examples\/hello_perl\.pl, pyhello=examples\/hello_python\.py, tclhello=examples\/hello_tcl\.tcl$/m,
        'sample conf documents ScriptDryRun ROUTES key');
    $assert->($src =~ /^#ACTION_MODE=dry-run$/m,
        'sample conf documents dry-run action mode');
    $assert->($src =~ /^#ACTION_MODE=apply$/m,
        'sample conf documents apply action mode');
    $assert->($src =~ /^#ALLOW_IRC=no$/m && $src =~ /^#ALLOW_IRC=yes$/m,
        'sample conf documents allow IRC gate values');
    $assert->($src =~ /^#APPLY_REQUIRE_SCOPE=yes$/m,
        'sample conf documents apply scope guard');
    $assert->($src =~ /SCRIPT_DRYRUN_ACTION_MODE/,
        'sample conf documents flat action mode compatibility key');
    $assert->($src =~ /SCRIPT_DRYRUN_APPLY_REQUIRE_SCOPE/,
        'sample conf documents flat apply scope compatibility key');

    $assert->($src !~ /^AUTOLOAD=1$/m,
        'sample conf does not enable plugin autoload by default');
    $assert->($src !~ /^ENABLED=Mediabot::Plugin::ScriptDryRun$/m,
        'sample conf does not enable ScriptDryRun by default');
    $assert->($src !~ /^ACTION_MODE=apply$/m,
        'sample conf does not enable apply mode by default');
    $assert->($src !~ /^ALLOW_IRC=yes$/m,
        'sample conf does not enable IRC output by default');

    my @plugin_headers = ($src =~ /^\#?\[plugins\]$/mg);
    my @script_headers = ($src =~ /^\#?\[plugins\.ScriptDryRun\]$/mg);

    $assert->(@plugin_headers <= 1,
        'sample conf has at most one plugin section example');
    $assert->(@script_headers <= 1,
        'sample conf has at most one ScriptDryRun section example');
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
