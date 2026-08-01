# t/cases/776_mb593_script_event_routing.t
# =============================================================================
# mb593 — les events du manifest deviennent des ROUTAGES reels pour les
# scripts sidecar.
#   [1] validation : event hors liste blanche refuse pour un script (avec la
#       liste dans le message) ; le meme manifest reste valide pour un
#       plugin in-process (liste informationnelle).
#   [2] load d'un script declarant channel_join_observed -> listener present
#       sur l'EventBus (etiquette plugin) ; un emit route vers run_script
#       avec le nom d'event et le contexte scalar ; les actions passent par
#       apply_actions (apply+allow_irc, gates fermees).
#   [3] echec du run = journal seulement, AUCUNE notice (pas d'appelant).
#   [4] disable = l'emission ne lance plus le script ; enable = reprise.
#   [5] unload = listener retire (zero fantome) ; replace transactionnel :
#       le nouveau sidecar remplace l'abonnement SANS doublon ; un sidecar
#       devenu invalide restaure l'abonnement precedent.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use JSON::PP ();

my $DIR = tempdir(CLEANUP => 1);

sub _sidecar_776 {
    my ($events, $version) = @_;
    open my $fh, '>', "$DIR/watch.py.manifest.json" or die $!;
    print $fh JSON::PP::encode_json({
        api => 2, name => 'watch', version => $version // '1.0',
        events => $events });
    close $fh;
}

{
    package Bot776;
    sub new {
        require Mediabot::CommandRegistry;
        require Mediabot::ScriptRunner;
        require Mediabot::EventBus;
        my ($class, $dir) = @_;
        my $self = bless { registry => Mediabot::CommandRegistry->new,
                           bus => Mediabot::EventBus->new,
                           logger => Log776->new, runs => [], applies => [] }, $class;
        $self->{runner} = Mediabot::ScriptRunner->new(bot => $self, script_dir => $dir);
        return $self;
    }
    sub registry { $_[0]{registry} }
    sub events { $_[0]{bus} }
    sub script_runner { $_[0]{runner} }
    sub script_action_runner { $_[0] }
    sub apply_actions {
        my ($self, $result, $context, %opts) = @_;
        push @{ $self->{applies} }, { opts => {%opts}, context => $context };
        return { applied_ok => 1 };
    }
}
{
    package Log776;
    sub new { bless { lines => [] }, shift }
    sub log { push @{ $_[0]{lines} }, $_[2]; 1 }
}

return sub {
    my ($assert) = @_;

    require Mediabot::PluginManager;
    require Mediabot::Helpers;
    require Mediabot::ScriptRunner;
    my @notices;
    no warnings 'redefine';
    local *Mediabot::Helpers::botNotice =
        sub { my (undef, $nick, $text) = @_; push @notices, "$nick: $text"; 1 };
    my $run_ret = { ok => 1, response => { ok => 1, actions => [] } };
    local *Mediabot::ScriptRunner::run_script = sub {
        my ($self2, $path, $event, %data) = @_;
        push @{ $self2->{bot}{runs} }, { path => $path, event => $event, data => {%data} };
        return $run_ret;
    };

    open my $sf, '>', "$DIR/watch.py" or die $!; print $sf "1\n"; close $sf;

    # [1] validation de routabilite
    _sidecar_776(['totally_made_up']);
    my $bot = Bot776->new($DIR);
    my $pm  = Mediabot::PluginManager->new(bot => $bot);
    my $ok = eval { $pm->load_script_v2('watch.py'); 1 };
    $assert->ok(!$ok, 'mb593-776: event hors liste blanche refuse (script)');
    $assert->like($@ // '', qr/not routable to scripts.*channel_join_observed/,
        'mb593-776: le refus liste les events routables');
    $assert->ok(!$pm->is_registered('watch'),
        'mb593-776: refus = aucun demi-etat');
    {
        # le meme events[] reste informationnel (donc libre) pour un module
        package T776::Free;
        sub manifest { { api=>2, name=>'free', version=>'1.0',
                         events=>['totally_made_up'] } }
        sub register { bless {}, shift }
        $INC{'T776/Free.pm'} = __FILE__;
    }
    my $free = eval { $pm->load_perl_module('T776::Free', name => 'free') };
    $assert->ok($free, 'mb593-776: meme event accepte pour un plugin in-process');

    # [2] abonnement + routage reel
    _sidecar_776(['channel_join_observed']);
    my $entry = $pm->load_script_v2('watch.py');
    $assert->ok($entry, 'mb593-776: script avec event routable charge');
    $assert->is($bot->events->listener_count('channel_join_observed'), 1,
        'mb593-776: listener pose sur l EventBus');
    $assert->is(scalar @{ $entry->{event_listeners} || [] }, 1,
        'mb593-776: entry memorise l abonnement');

    my $ctx = { event_type => 'join', channel => '#quebec',
                nick => 'SlaY', is_self => 0 };
    $bot->events->emit('channel_join_observed', $ctx);
    $assert->is(scalar @{ $bot->{runs} }, 1, 'mb593-776: emit lance le script');
    my $run = $bot->{runs}[0];
    $assert->is($run->{event}, 'channel_join_observed',
        'mb593-776: le nom d event est transmis au script');
    $assert->is($run->{data}{channel}, '#quebec', 'mb593-776: contexte channel transmis');
    $assert->is($run->{data}{nick}, 'SlaY', 'mb593-776: contexte nick transmis');
    my $ap = $bot->{applies}[-1];
    $assert->ok($ap && $ap->{opts}{apply} && $ap->{opts}{allow_irc},
        'mb593-776: actions via apply_actions apply+allow_irc');
    $assert->ok(!$ap->{opts}{allow_kick} && !$ap->{opts}{allow_ban},
        'mb593-776: gates intrusives fermees sur un event');
    $assert->is($ap->{context}{event}, 'channel_join_observed',
        'mb593-776: contexte d application porte l event');

    # [3] echec du run : journal, pas de notice
    $run_ret = { ok => 0, error => 'boom' };
    @notices = ();
    $bot->events->emit('channel_join_observed', $ctx);
    $assert->is(scalar @notices, 0, 'mb593-776: echec d event = aucune notice');
    $assert->ok((grep { /script event 'channel_join_observed' failed: boom/ }
        @{ $bot->{logger}{lines} }), 'mb593-776: echec au journal');
    $run_ret = { ok => 1, response => { ok => 1, actions => [] } };

    # [4] disable/enable
    my $n = scalar @{ $bot->{runs} };
    $pm->disable('watch');
    $bot->events->emit('channel_join_observed', $ctx);
    $assert->is(scalar @{ $bot->{runs} }, $n, 'mb593-776: disable — le script ne tourne plus');
    $pm->enable('watch');
    $bot->events->emit('channel_join_observed', $ctx);
    $assert->is(scalar @{ $bot->{runs} }, $n + 1, 'mb593-776: enable — reprise');

    # [5] replace : nouveau sidecar, pas de doublon d abonnement
    _sidecar_776(['channel_join_observed', 'channel_part_observed'], '2.0');
    my $e2 = $pm->load_script_v2('watch.py', name => 'watch', replace => 1);
    $assert->is($e2->{version}, '2.0', 'mb593-776: replace relit le sidecar');
    $assert->is($bot->events->listener_count('channel_join_observed'), 1,
        'mb593-776: pas de doublon d abonnement au replace');
    $assert->is($bot->events->listener_count('channel_part_observed'), 1,
        'mb593-776: nouvel event abonne au replace');

    # sidecar devenu invalide : rollback restaure l abonnement precedent
    _sidecar_776(['nope_not_routable'], '3.0');
    $ok = eval { $pm->load_script_v2('watch.py', name => 'watch', replace => 1); 1 };
    $assert->ok(!$ok, 'mb593-776: sidecar invalide au replace = die');
    $assert->is($bot->events->listener_count('channel_part_observed'), 1,
        'mb593-776: rollback — l abonnement precedent est restaure');
    my $n2 = scalar @{ $bot->{runs} };
    $bot->events->emit('channel_part_observed', { channel => '#q', nick => 'x' });
    $assert->is(scalar @{ $bot->{runs} }, $n2 + 1,
        'mb593-776: l instance restauree route toujours');

    # unload = zero fantome
    $pm->unregister_plugin('watch');
    $assert->is($bot->events->listener_count('channel_join_observed'), 0,
        'mb593-776: unload retire le listener join');
    $assert->is($bot->events->listener_count('channel_part_observed'), 0,
        'mb593-776: unload retire le listener part — zero fantome');

    # cookbook
    my $cb = do { open my $fh, '<:encoding(UTF-8)', 'plugins/scripts/COOKBOOK.md' or die $!; local $/; <$fh> };
    $assert->like($cb, qr/Declared events are real subscriptions \(mb593\)/,
        'mb593-776: regle 6 documentee au cookbook');
};
