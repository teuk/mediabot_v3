# t/cases/433_mb194_scriptdryrun_array_config_routes.t
use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;

{
    package ArrayConf;
    sub new { my ($class, %data) = @_; return bless \%data, $class; }
    sub get { my ($self, $key) = @_; return $self->{$key}; }
}

{
    package FakeBot;
    sub new {
        my ($class, $conf) = @_;
        return bless { conf => $conf }, $class;
    }
}

my $case = sub {
    my ($assert) = @_;

    my $root = File::Spec->catdir($Bin, '..', '..');
    unshift @INC, $root;

    eval { require Mediabot::Plugin::ScriptDryRun; 1 }
        or do { $assert->(0, "cannot load ScriptDryRun: $@"); return; };

    my $bot = FakeBot->new(ArrayConf->new(
        'plugins.ScriptDryRun.COMMANDS' => [ 'hello', 'pyhello,tclhello' ],
        'plugins.ScriptDryRun.ROUTES'   => [
            'hello=examples/hello_perl.pl',
            'pyhello=examples/hello_python.py, tclhello=examples/hello_tcl.tcl',
        ],
        'plugins.ScriptDryRun.ACTION_MODE'         => [ 'apply' ],
        'plugins.ScriptDryRun.ALLOW_IRC'           => [ 'yes' ],
        'plugins.ScriptDryRun.APPLY_REQUIRE_SCOPE' => [ 'yes' ],
    ));

    my $plugin = Mediabot::Plugin::ScriptDryRun->register($bot);

    $assert->($plugin->command_filter_enabled,
        'ARRAY COMMANDS enables command filter');
    $assert->($plugin->command_allowed('hello'),
        'ARRAY COMMANDS allows hello');
    $assert->($plugin->command_allowed('pyhello'),
        'ARRAY COMMANDS allows pyhello');
    $assert->($plugin->command_allowed('tclhello'),
        'ARRAY COMMANDS allows tclhello');
    $assert->(!$plugin->command_allowed('version'),
        'ARRAY COMMANDS still rejects unrelated command');

    $assert->($plugin->command_routes_enabled,
        'ARRAY ROUTES enables command routes');
    $assert->($plugin->script_for_command('hello') eq 'examples/hello_perl.pl',
        'ARRAY ROUTES maps hello to Perl example');
    $assert->($plugin->script_for_command('pyhello') eq 'examples/hello_python.py',
        'ARRAY ROUTES maps pyhello to Python example');
    $assert->($plugin->script_for_command('tclhello') eq 'examples/hello_tcl.tcl',
        'ARRAY ROUTES maps tclhello to Tcl example');

    $assert->($plugin->action_mode eq 'apply',
        'ARRAY ACTION_MODE is parsed as apply');
    $assert->($plugin->allow_irc,
        'ARRAY ALLOW_IRC is parsed as truthy');
    $assert->($plugin->apply_require_scope,
        'ARRAY APPLY_REQUIRE_SCOPE is parsed as truthy');
    $assert->($plugin->apply_scope_is_restricted,
        'ARRAY COMMANDS/ROUTES satisfy apply scope restriction');

    my $src_file = File::Spec->catfile($root, 'Mediabot', 'Plugin', 'ScriptDryRun.pm');
    open my $fh, '<', $src_file
        or do { $assert->(0, "cannot open ScriptDryRun.pm: $!"); return; };
    my $src = do { local $/; <$fh> };
    close $fh;

    $assert->($src =~ /mb194-B1: Config::Simple can return ARRAY refs/,
        'ScriptDryRun source contains mb194 marker');
    $assert->($src =~ /_flatten_config_values/,
        'ScriptDryRun source contains flatten helper');
    $assert->($src !~ /system\s*\(|qx\//,
        'ScriptDryRun array config fix does not introduce shell execution');
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
