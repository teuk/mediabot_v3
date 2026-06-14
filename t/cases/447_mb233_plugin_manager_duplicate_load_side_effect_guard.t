# t/cases/447_mb233_plugin_manager_duplicate_load_side_effect_guard.t
use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;
use File::Temp qw(tempdir);

my $case = sub {
    my ($assert) = @_;

    my $root = File::Spec->catdir($Bin, '..', '..');
    unshift @INC, $root;

    eval { require Mediabot::PluginManager; 1 }
        or do { $assert->(0, "cannot load Mediabot::PluginManager: $@"); return; };

    my $tmp = tempdir(CLEANUP => 1);
    my $mod_dir = File::Spec->catdir($tmp, 'MB233');
    mkdir $mod_dir or do { $assert->(0, "cannot mkdir $mod_dir: $!"); return; };
    my $mod_file = File::Spec->catfile($mod_dir, 'SideEffect.pm');
    open my $mf, '>', $mod_file
        or do { $assert->(0, "cannot write $mod_file: $!"); return; };
    print {$mf} <<'PLUGIN';
package MB233::SideEffect;
use strict;
use warnings;
our $VERSION = '0.001';
sub register {
    my ($class, $bot, %opts) = @_;
    eval { $bot->{mb233_register_calls}++ };
    return bless { bot => $bot, manager => $opts{manager} }, $class;
}
1;
PLUGIN
    close $mf;

    unshift @INC, $tmp;

    my $bot = bless { mb233_register_calls => 0 }, 'MB233FakeBot';
    my $pm  = Mediabot::PluginManager->new(bot => $bot);

    my $first = eval { $pm->load_perl_module('MB233::SideEffect'); };
    $assert->($first && ref($first) eq 'HASH', 'first plugin load succeeds');
    $assert->($bot->{mb233_register_calls} == 1, 'first load calls plugin register once');
    $assert->($pm->count == 1, 'first load registers one plugin');

    my $dup_ok = eval { $pm->load_perl_module('MB233::SideEffect'); 1 };
    my $dup_err = $@ || '';
    $assert->(!$dup_ok && $dup_err =~ /already registered/, 'duplicate load is rejected');
    $assert->($bot->{mb233_register_calls} == 1, 'duplicate load does not call plugin register again');
    $assert->($pm->count == 1, 'duplicate load does not add another plugin entry');

    my $custom = eval { $pm->load_perl_module('MB233::SideEffect', name => 'CustomSpell'); };
    $assert->($custom && $custom->{name} eq 'customspell', 'same module can still be loaded under explicit different plugin name');
    $assert->($bot->{mb233_register_calls} == 2, 'explicit different plugin name still calls register once');

    my $dup_custom_ok = eval { $pm->load_perl_module('MB233::SideEffect', name => 'CustomSpell'); 1 };
    my $dup_custom_err = $@ || '';
    $assert->(!$dup_custom_ok && $dup_custom_err =~ /already registered/, 'duplicate explicit plugin name is rejected before register');
    $assert->($bot->{mb233_register_calls} == 2, 'duplicate explicit plugin name has no register side effect');

    my $pm2_bot = bless({ mb233_register_calls => 0 }, 'MB233FakeBot2');
    my $pm2  = Mediabot::PluginManager->new(bot => $pm2_bot);
    my $rep = $pm2->load_configured_plugins({ 'plugins.ENABLED' => 'MB233::SideEffect MB233::SideEffect' });
    $assert->(ref($rep) eq 'HASH', 'duplicate configured plugins return structured report');
    $assert->(ref($rep->{loaded}) eq 'ARRAY' && @{ $rep->{loaded} } == 1, 'duplicate configured plugins load only once');
    $assert->(ref($rep->{errors}) eq 'ARRAY' && @{ $rep->{errors} } == 1, 'duplicate configured plugin is reported as one load error');
    $assert->($pm2_bot->{mb233_register_calls} == 1, 'duplicate configured plugin has no second register side effect');

    my $pm_file = File::Spec->catfile($root, 'Mediabot', 'PluginManager.pm');
    open my $pfh, '<', $pm_file
        or do { $assert->(0, "cannot open PluginManager.pm: $!"); return; };
    my $src = do { local $/; <$pfh> };
    close $pfh;

    $assert->($src =~ /mb233-B1/, 'PluginManager source contains mb233 duplicate-load marker');
    $assert->($src !~ /`[^`]+`|\bqx\s*(?:\/|\(|\{)|\bsystem\s*(?:\(| )/, 'PluginManager duplicate-load guard does not introduce shell execution');
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
