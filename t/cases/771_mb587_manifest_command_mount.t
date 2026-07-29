# t/cases/771_mb587_manifest_command_mount.t
# =============================================================================
# mb587 — arc plugins v2, increment 2 : montage automatique des commandes.
#   [1] load d'un plugin v2 avec commands -> la commande vit dans le
#       CommandRegistry (source public) et DISPATCHE vers command_<nom>.
#   [2] disable -> le handler se tait sans decharger ; enable -> repond.
#   [3] unregister -> commande retiree (pas de fantome, jumeau mb233).
#   [4] refus fail-closed : manifest declarant une commande sans methode ;
#       level>0 refuse au montage (pont d'auth = increment suivant).
#   [5] replace same-object = les commandes restent montees.
#   [6] registry : unregister_command retire entree + aliases, idempotent.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }

{
    package T771::Hello;
    our $CALLS = 0;
    sub manifest {
        return { api => 2, name => 'hello', version => '1.0',
                 commands => { hello771 => { help => 'Say hello.', level => 0 } } };
    }
    sub register { my ($class, $bot, %o) = @_; return bless { bot => $bot }, $class }
    sub command_hello771 { my ($self, $ctx) = @_; $CALLS++; return 'hi' }
    $INC{'T771/Hello.pm'} = __FILE__;
}
{
    package T771::Liar;
    sub manifest {
        return { api => 2, name => 'liar', version => '1.0',
                 commands => { fib771 => { help => 'Missing method.', level => 0 } } };
    }
    sub register { bless {}, shift }
    $INC{'T771/Liar.pm'} = __FILE__;
}
{
    package T771::Privileged;
    sub manifest {
        return { api => 2, name => 'privileged', version => '1.0',
                 commands => { adminy771 => { help => 'Needs auth.', level => 100 } } };
    }
    sub register { bless {}, shift }
    sub command_adminy771 { 1 }
    $INC{'T771/Privileged.pm'} = __FILE__;
}
{
    package Bot771;
    sub new {
        require Mediabot::CommandRegistry;
        bless { registry => Mediabot::CommandRegistry->new,
                logger   => Log771->new }, shift;
    }
    sub registry { $_[0]{registry} }
    sub events { undef }
}
{
    package Log771;
    sub new { bless { lines => [] }, shift }
    sub log { push @{ $_[0]{lines} }, [ $_[1], $_[2] ]; 1 }
}

return sub {
    my ($assert) = @_;

    require Mediabot::PluginManager;

    my $bot = Bot771->new;
    my $pm  = Mediabot::PluginManager->new(bot => $bot);

    # [1] montage + dispatch reel
    my $entry = $pm->load_perl_module('T771::Hello', name => 'hello');
    $assert->ok($entry, 'mb587-771: plugin v2 avec commande charge');
    $assert->is($bot->registry->has_command('hello771', 'public'), 1,
        'mb587-771: commande montee dans le registry (source public)');
    $assert->is(join(',', @{ $entry->{mounted_commands} || [] }), 'hello771',
        'mb587-771: entry memorise les commandes montees');
    my $reg_entry = $bot->registry->command_for('hello771', 'public');
    $assert->is($reg_entry->{plugin}, 'hello', 'mb587-771: entry registry marque plugin');
    $assert->is($reg_entry->{description}, 'Say hello.',
        'mb587-771: help du manifest devient la description');
    my $handler = $bot->registry->handler_for('hello771', 'public');
    $T771::Hello::CALLS = 0;
    my $out = $handler->({});
    $assert->is($out, 'hi', 'mb587-771: le handler dispatche vers command_<nom>');
    $assert->is($T771::Hello::CALLS, 1, 'mb587-771: methode du plugin appelee');

    # [2] disable = silence sans dechargement ; enable = reprise
    $pm->disable('hello');
    $out = $handler->({});
    $assert->ok(!defined $out, 'mb587-771: plugin disable — la commande se tait');
    $assert->is($T771::Hello::CALLS, 1, 'mb587-771: methode NON appelee quand disable');
    $pm->enable('hello');
    $handler->({});
    $assert->is($T771::Hello::CALLS, 2, 'mb587-771: enable — la commande repond de nouveau');

    # [5] replace same-object : commandes conservees
    my $same = $pm->register_plugin(name => 'hello', module => 'T771::Hello',
        object => $entry->{object}, manifest => $entry->{manifest}, replace => 1);
    $assert->is($bot->registry->has_command('hello771', 'public'), 1,
        'mb587-771: same-object refresh conserve la commande montee');
    $assert->is(join(',', @{ $same->{mounted_commands} || [] }), 'hello771',
        'mb587-771: mounted_commands herite au refresh');

    # [3] unregister = demontage (pas de commande fantome)
    $pm->unregister_plugin('hello');
    $assert->is($bot->registry->has_command('hello771', 'public'), 0,
        'mb587-771: unregister retire la commande du registry');

    # [4] refus fail-closed
    my $ok = eval { $pm->load_perl_module('T771::Liar', name => 'liar'); 1 };
    $assert->ok(!$ok, 'mb587-771: manifest menteur (methode absente) refuse');
    $assert->like($@ // '', qr/no matching method command_fib771/,
        'mb587-771: raison precise — methode manquante');
    $assert->is($pm->is_registered('liar') ? 1 : 0, 0,
        'mb587-771: le plugin menteur n est PAS enregistre (aucun demi-etat)');

    # mb589: le pont d'auth existe — les entiers >0 recoivent desormais le
    # message de migration vers les descriptions USER_LEVEL.
    $ok = eval { $pm->load_perl_module('T771::Privileged', name => 'privileged'); 1 };
    $assert->ok(!$ok, 'mb587-771: level entier >0 refuse (migration mb589)');
    $assert->like($@ // '', qr/since mb589 declare 0 \(public\) or a USER_LEVEL description/,
        'mb587-771: raison — migrer vers une description USER_LEVEL');

    # [6] unregister_command unitaire : aliases + idempotence
    my $reg = $bot->registry;
    $reg->register_command(name => 'zeta771', source => 'public',
        handler => sub { 1 }, aliases => ['zz771']);
    $assert->is($reg->has_command('zz771', 'public'), 1, 'mb587-771: alias resolu');
    $assert->is($reg->unregister_command('zeta771', 'public'), 1,
        'mb587-771: unregister_command retire la commande');
    $assert->is($reg->has_command('zz771', 'public'), 0,
        'mb587-771: alias retire avec la commande');
    $assert->is($reg->unregister_command('zeta771', 'public'), 0,
        'mb587-771: idempotent — absent rend 0 sans die');

    # garde structurelle : le demontage precede le teardown objet
    my $src = do { open my $fh, '<:encoding(UTF-8)', 'Mediabot/PluginManager.pm' or die $!; local $/; <$fh> };
    my $i_un = index($src, "sub unregister_plugin");
    my $i_mv = index($src, '_unmount_entry_commands($entry)', $i_un);
    my $i_td = index($src, "can('unregister')", $i_un);
    $assert->ok($i_un > -1 && $i_mv > -1 && $i_td > -1 && $i_mv < $i_td,
        'mb587-771: demontage AVANT le teardown objet dans unregister_plugin');
};
