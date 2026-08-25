# t/cases/912_mb698_plugin_v2_boot_autoload.t
# =============================================================================
# mb698-P2 — v2 sidecar plugins can participate in the existing explicit
# plugins.AUTOLOAD boot gate through plugins.SCRIPTS. The list remains separate
# from trusted in-process Perl modules and all paths still pass through the
# existing ScriptRunner/load_script_v2 containment + manifest validation.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Temp qw(tempdir);
use JSON::PP qw(encode_json);

{
    package Conf912;
    sub new { my ($class, %kv) = @_; bless \%kv, $class }
    sub get { $_[0]{ $_[1] } }
}
{
    package Log912;
    sub new { bless {}, shift }
    sub log { 1 }
}
{
    package Bot912;
    sub new {
        my ($class, $dir, $conf) = @_;
        require Mediabot::CommandRegistry;
        require Mediabot::EventBus;
        require Mediabot::ScriptRunner;
        my $self = bless {
            command_registry => Mediabot::CommandRegistry->new,
            events           => Mediabot::EventBus->new,
            conf             => $conf,
            logger           => Log912->new,
        }, $class;
        $self->{runner} = Mediabot::ScriptRunner->new(bot => $self, script_dir => $dir);
        return $self;
    }
    sub command_registry { $_[0]{command_registry} }
    sub commands { $_[0]{command_registry} }
    sub events { $_[0]{events} }
    sub script_runner { $_[0]{runner} }
    sub script_action_runner { $_[0] }
    sub apply_actions { return { applied_ok => 1 } }
}

return sub {
    my ($assert) = @_;
    require Mediabot::PluginManager;

    my $dir = tempdir(CLEANUP => 1);
    open my $sf, '>', "$dir/auto.py" or die $!;
    print {$sf} "print('{}')\n";
    close $sf;

    open my $mf, '>', "$dir/auto.py.manifest.json" or die $!;
    print {$mf} encode_json({
        api => 2,
        name => 'auto',
        version => '1.0',
        commands => { auto912 => { help => 'Autoload proof.', level => 0 } },
    });
    close $mf;

    my $conf = Conf912->new('plugins.SCRIPTS' => [ 'auto.py' ]);
    my $bot = Bot912->new($dir, $conf);
    my $pm = Mediabot::PluginManager->new(bot => $bot);

    $assert->ok(!$bot->can('registry'),
        'mb698-912: fixture mirrors production and has no registry() alias');

    my @scripts = $pm->configured_scripts_from_conf($conf);
    $assert->is(scalar @scripts, 1,
        'mb698-912: one v2 script parsed from plugins.SCRIPTS');
    $assert->is($scripts[0], 'auto.py',
        'mb698-912: configured script path preserved');

    my $report = $pm->load_configured_plugins($conf);
    $assert->is(scalar @{ $report->{errors} || [] }, 0,
        'mb698-912: configured v2 script autoload has no error');
    $assert->is(scalar @{ $report->{loaded} || [] }, 1,
        'mb698-912: configured v2 script is included in loaded report');
    $assert->ok($pm->is_registered('auto'),
        'mb698-912: configured v2 script is registered');
    $assert->is($pm->plugin('auto')->{metadata}{kind}, 'script',
        'mb698-912: autoloaded entry keeps script kind');
    $assert->is($pm->plugin('auto')->{metadata}{script_path}, 'auto.py',
        'mb698-912: autoloaded entry keeps normalized script path');
    $assert->is($bot->commands->has_command('auto912', 'public'), 1,
        'mb698-912: autoloaded v2 command is mounted');

    my $bad_conf = Conf912->new('plugins.SCRIPTS' => 'missing.py');
    my $bad_bot = Bot912->new($dir, $bad_conf);
    my $bad_pm = Mediabot::PluginManager->new(bot => $bad_bot);
    my $bad = $bad_pm->load_configured_plugins($bad_conf);

    $assert->is(scalar @{ $bad->{loaded} || [] }, 0,
        'mb698-912: missing sidecar script does not half-load');
    $assert->is(scalar @{ $bad->{errors} || [] }, 1,
        'mb698-912: missing sidecar script is reported once');
    $assert->is($bad->{errors}[0]{script}, 'missing.py',
        'mb698-912: script autoload error identifies the configured path');
    $assert->like($bad->{errors}[0]{error} // '',
        qr/script file not found or not regular/,
        'mb698-912: script autoload error preserves fail-closed diagnostic');

    my $src = do {
        open my $fh, '<:encoding(UTF-8)', 'Mediabot/Mediabot.pm' or die $!;
        local $/;
        <$fh>;
    };
    $assert->like($src, qr/load_configured_plugins_if_enabled/,
        'mb698-912: existing AUTOLOAD gate remains the boot entry point');
};
