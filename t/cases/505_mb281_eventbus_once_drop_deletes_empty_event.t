# t/cases/505_mb281_eventbus_once_drop_deletes_empty_event.t
# =============================================================================
# Régression mb281-B1 (Mediabot::EventBus) :
#
#   Bug : après qu'un listener `once` se soit déclenché,
#   _drop_once_entries_from_current_list() laissait une ARRAY ref vide pour la
#   clé d'événement au lieu de la supprimer (comme le fait off()). Conséquence :
#   events() listait un événement fantôme sans aucun listener — incohérent avec
#   off()/clear() et trompeur pour un appelant qui énumère les événements actifs.
#
#   Fix : quand le retrait des once-listeners vide l'événement, la clé est
#   supprimée entièrement.
#
# Exécutable sans DBI.
# =============================================================================

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../..";
use Test::More;

require Mediabot::EventBus;

# --- once seul : après emit, l'événement disparaît de events() ---
{
    my $bus = Mediabot::EventBus->new;
    $bus->once('foo', sub { 1 });
    is_deeply([ $bus->events ], ['foo'], 'event present before emit');

    $bus->emit('foo');
    is($bus->listener_count('foo'), 0, 'no listeners remain after once fired');
    is_deeply([ $bus->events ], [], 'event key removed from events() after once drop (no phantom)');
}

# --- once via emit_report : même nettoyage ---
{
    my $bus = Mediabot::EventBus->new;
    $bus->once('bar', sub { 1 });
    $bus->emit_report('bar');
    is_deeply([ $bus->events ], [], 'emit_report also removes the emptied event key');
}

# --- once + listener permanent : l'événement RESTE (clé non supprimée) ---
{
    my $bus = Mediabot::EventBus->new;
    my @log;
    $bus->on('e',   sub { push @log, 'perm' });
    $bus->once('e', sub { push @log, 'once' });

    $bus->emit('e');
    is_deeply(\@log, [ 'perm', 'once' ], 'both listeners ran on first emit');
    is($bus->listener_count('e'), 1, 'permanent listener survives the once drop');
    is_deeply([ $bus->events ], ['e'], 'event stays listed while a permanent listener remains');

    @log = ();
    $bus->emit('e');
    is_deeply(\@log, [ 'perm' ], 'only the permanent listener runs on second emit');
}

# --- non-régression mb230-B2 : listener ajouté pendant emit préservé ---
{
    my $bus = Mediabot::EventBus->new;
    my @log;
    $bus->once('x', sub {
        push @log, 'once';
        $bus->on('x', sub { push @log, 'added' });
    });

    $bus->emit('x');  # once runs, registers 'added' (must NOT run this emit)
    is_deeply(\@log, ['once'], 'listener added during emit does not run in the same emit');
    is($bus->listener_count('x'), 1, 'listener added during emit survives the once drop');
    is_deeply([ $bus->events ], ['x'], 'event not removed because a live listener was added during emit');

    @log = ();
    $bus->emit('x');
    is_deeply(\@log, ['added'], 'the listener added during the previous emit runs next time');
}

done_testing();
