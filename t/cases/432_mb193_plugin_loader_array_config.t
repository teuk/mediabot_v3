# t/cases/432_mb193_plugin_loader_array_config.t
use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;

{
    package ArrayConf;
    sub new { my ($class, %data) = @_; return bless \%data, $class; }
    sub get { my ($self, $key) = @_; return $self->{$key}; }
}

my $case = sub {
    my ($assert) = @_;

    my $root = File::Spec->catdir($Bin, '..', '..');
    unshift @INC, $root;

    eval { require Mediabot::PluginManager; 1 }
        or do { $assert->(0, "cannot load Mediabot::PluginManager: $@"); return; };

    my $pm = Mediabot::PluginManager->new;

    my @from_array = $pm->configured_modules_from_conf(ArrayConf->new(
        'plugins.ENABLED' => [ 'Mediabot::Plugin::Demo', 'Mediabot::Plugin::ScriptDryRun' ],
    ));

    $assert->(@from_array == 2,
        'configured_modules_from_conf accepts ARRAY ref values');
    $assert->($from_array[0] eq 'Mediabot::Plugin::Demo',
        'first ARRAY configured plugin preserved');
    $assert->($from_array[1] eq 'Mediabot::Plugin::ScriptDryRun',
        'second ARRAY configured plugin preserved');

    my @from_mixed_array = $pm->configured_modules_from_conf(ArrayConf->new(
        'plugins.ENABLED' => [ 'Mediabot::Plugin::Demo,Mediabot::Plugin::ScriptDryRun', 'Mediabot::Plugin::Demo' ],
    ));

    $assert->(@from_mixed_array == 3,
        'ARRAY entries can still contain comma-separated values');

    my $report = $pm->load_configured_plugins(ArrayConf->new(
        'plugins.ENABLED' => [ 'Mediabot::Plugin::Demo', 'Mediabot::Plugin::ScriptDryRun' ],
    ));

    $assert->(ref($report) eq 'HASH',
        'load_configured_plugins returns a report hash');
    $assert->(ref($report->{loaded}) eq 'ARRAY',
        'load_configured_plugins has loaded array');
    $assert->(ref($report->{invalid}) eq 'ARRAY',
        'load_configured_plugins has invalid array');
    $assert->(ref($report->{errors}) eq 'ARRAY',
        'load_configured_plugins has errors array');
    my @invalid_array_refs = grep { /ARRAY/ } @{ $report->{invalid} };
    $assert->(@invalid_array_refs == 0,
        'ARRAY ref is not treated as an invalid module name');

    my $src_file = File::Spec->catfile($root, 'Mediabot', 'PluginManager.pm');
    open my $fh, '<', $src_file
        or do { $assert->(0, "cannot open PluginManager.pm: $!"); return; };
    my $src = do { local $/; <$fh> };
    close $fh;

    $assert->($src =~ /mb193-B2: Config::Simple may return ARRAY refs/,
        'PluginManager source contains mb193 marker');
    $assert->($src =~ /ref\(\$(?:value|entry)\) eq 'ARRAY'/,
        'PluginManager explicitly handles ARRAY ref values');
    $assert->($src !~ /system\s*\(|qx\//,
        'PluginManager array config fix does not introduce shell execution');
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
