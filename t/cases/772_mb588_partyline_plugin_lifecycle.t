# t/cases/772_mb588_partyline_plugin_lifecycle.t
# =============================================================================
# mb588 — arc plugins v2, increment 3 : cycle de vie a chaud en partyline.
#   [1] gates : load/unload/reload = Owner (0) ; enable/disable = Master+
#       (<=1) ; refus explicites ; niveau indefini refuse tout.
#   [2] load reel via _cmd_plugins (module de test inline), sortie annonce
#       api + commandes montees ; erreur de load AFFICHEE en clair.
#   [3] disable/enable pilotent le silence de la commande montee.
#   [4] unload demonte ; reload = vrai rechargement (delete %INC + replace),
#       echec de reload = instance precedente TOUJOURS active.
#   [5] liste enrichie api=/commands= ; usage et .help a jour.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }

# Le module de test vit sur DISQUE : le reload partyline fait un vrai
# delete %INC + require, il lui faut un vrai fichier a recharger.
use File::Path qw(make_path);
use File::Temp qw(tempdir);
my $T772_DIR = tempdir(CLEANUP => 1);
make_path("$T772_DIR/T772");
sub _write_echo_772 {
    my ($ret, $version) = @_;
    open my $fh, '>', "$T772_DIR/T772/Echo.pm" or die $!;
    print $fh <<PM;
package T772::Echo;
use strict; use warnings;
sub manifest {
    return { api => 2, name => 'echo', version => '$version',
             commands => { echo772 => { help => 'Echo.', level => 0 } } };
}
sub register { bless {}, shift }
sub command_echo772 { '$ret' }
1;
PM
    close $fh;
}
_write_echo_772('v1', '1.0');
unshift @INC, $T772_DIR;
{
    package Stream772;
    sub new { bless { out => '' }, shift }
    sub write { $_[0]{out} .= $_[1]; 1 }
    sub out { $_[0]{out} }
    sub reset { $_[0]{out} = ''; 1 }
}
{
    package Bot772;
    sub new {
        require Mediabot::CommandRegistry;
        require Mediabot::PluginManager;
        my $self = bless { registry => Mediabot::CommandRegistry->new,
                           logger => Log772->new }, shift;
        $self->{pm} = Mediabot::PluginManager->new(bot => $self);
        return $self;
    }
    sub registry { $_[0]{registry} }
    sub plugin_manager { $_[0]{pm} }
    sub plugin_autoload_enabled { 0 }
    sub events { undef }
}
{
    package Log772;
    sub new { bless {}, shift }
    sub log { 1 }
}

sub _mk_772 {
    require Mediabot::Partyline;
    my ($level) = @_;
    my $bot = Bot772->new;
    my $pl  = bless { bot => $bot, users => { 7 => { login => 't', level => $level } } },
        'Mediabot::Partyline';
    my $stream = Stream772->new;
    return ($pl, $bot, $stream);
}

return sub {
    my ($assert) = @_;

    # [1] gates
    {
        my ($pl, undef, $st) = _mk_772(1);   # Master
        $pl->_cmd_plugins($st, 7, 'load T772::Echo');
        $assert->like($st->out, qr/requires Owner level/,
            'mb588-772: load refuse a Master');
        $st->reset;
        $pl->_cmd_plugins($st, 7, 'reload echo');
        $assert->like($st->out, qr/requires Owner level/,
            'mb588-772: reload refuse a Master');
    }
    {
        my ($pl, undef, $st) = _mk_772(2);
        $pl->_cmd_plugins($st, 7, 'disable echo');
        $assert->like($st->out, qr/requires Master or Owner/,
            'mb588-772: disable refuse sous Master');
    }
    {
        my ($pl, undef, $st) = _mk_772(undef);
        $pl->_cmd_plugins($st, 7, 'unload echo');
        $assert->like($st->out, qr/Access denied/,
            'mb588-772: niveau indefini refuse tout');
    }

    # [2] load reel en Owner
    my ($pl, $bot, $st) = _mk_772(0);
    $pl->_cmd_plugins($st, 7, 'load T772::Echo echo');
    $assert->like($st->out, qr/Loaded plugin 'echo' \(api=2, commands: echo772\)/,
        'mb588-772: load annonce api et commandes montees');
    $assert->is($bot->registry->has_command('echo772', 'public'), 1,
        'mb588-772: commande vivante apres load partyline');
    $st->reset;
    $pl->_cmd_plugins($st, 7, 'load T772::Echo echo');
    $assert->like($st->out, qr/Load failed: .*already registered/,
        'mb588-772: erreur de load affichee en clair (doublon)');

    # [3] disable/enable pilotent la commande
    my $handler = $bot->registry->handler_for('echo772', 'public');
    $st->reset;
    $pl->_cmd_plugins($st, 7, 'disable echo');
    $assert->like($st->out, qr/now disabled \(mounted commands stay silent\)/,
        'mb588-772: disable annonce le silence');
    $assert->ok(!defined $handler->({}), 'mb588-772: commande muette apres disable');
    $st->reset;
    $pl->_cmd_plugins($st, 7, 'enable echo');
    $assert->is($handler->({}), 'v1', 'mb588-772: commande repond apres enable');

    # [5] liste enrichie
    $st->reset;
    $pl->_cmd_plugins($st, 7, 'loaded');
    $assert->like($st->out, qr/- echo \[enabled\] api=2 module=T772::Echo version=1\.0 commands=echo772/,
        'mb588-772: liste montre api et commandes');

    # [4] reload = vrai rechargement : le fichier change sur disque, le
    # delete %INC + require du .plugins reload sert le nouveau code.
    _write_echo_772('v2', '2.0');
    $st->reset;
    $pl->_cmd_plugins($st, 7, 'reload echo');
    $assert->like($st->out, qr/Reloaded plugin 'echo' \(version 2\.0\)/,
        'mb588-772: reload rapporte le succes et la nouvelle version');
    my $h2 = $bot->registry->handler_for('echo772', 'public');
    $assert->is($h2->({}), 'v2', 'mb588-772: le nouveau code sert apres reload');

    # echec de reload : module inconnu au %INC et introuvable sur disque
    $st->reset;
    {
        my $entry = $bot->plugin_manager->plugin('echo');
        local $entry->{module} = 'T772::DoesNotExist';
        $pl->_cmd_plugins($st, 7, 'reload echo');
    }
    $assert->like($st->out, qr/Reload failed \(previous instance still active\)/,
        'mb588-772: echec de reload = instance precedente conservee');
    $assert->is($bot->registry->has_command('echo772', 'public'), 1,
        'mb588-772: la commande de l instance precedente vit toujours');

    # unload demonte
    $st->reset;
    $pl->_cmd_plugins($st, 7, 'unload echo');
    $assert->like($st->out, qr/Unloaded plugin 'echo' \(commands unmounted\)/,
        'mb588-772: unload annonce le demontage');
    $assert->is($bot->registry->has_command('echo772', 'public'), 0,
        'mb588-772: commande retiree apres unload');
    $st->reset;
    $pl->_cmd_plugins($st, 7, 'unload echo');
    $assert->like($st->out, qr/Unknown plugin 'echo'/,
        'mb588-772: unload d un inconnu explique le refus');

    # usage + .help
    $st->reset;
    $pl->_cmd_plugins($st, 7, 'bogus');
    $assert->like($st->out, qr/Usage: \.plugins \[loaded\|config\|info <name>\|load <Module>/,
        'mb588-772: usage montre le cycle de vie');
    my $src = do { open my $fh, '<:encoding(UTF-8)', 'Mediabot/Partyline.pm' or die $!; local $/; <$fh> };
    $assert->like($src, qr/\.plugins \[loaded\|config\|info\|load\|loadscript\|unload\|reload\|enable\|disable\|cleardata\] - plugin lifecycle \(v2\)/,
        'mb588-772: .help documente le cycle de vie');
};
