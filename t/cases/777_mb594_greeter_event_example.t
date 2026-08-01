# t/cases/777_mb594_greeter_event_example.t
# =============================================================================
# mb594 — greeter.tcl : l'exemple event-driven du depot (vitrine mb593).
#   [1] sidecar JSON strict, aucun commands, un event routable declare.
#   [2] chargement reel via load_script_v2 sur plugins/scripts du depot :
#       zero commande montee, UN listener channel_join_observed pose.
#   [3] EXECUTION REELLE tclsh via run_script : join utilisateur -> ok +
#       reply contenant le nick ; join du bot (is_self) -> ok + AUCUNE
#       action (silence, motif cookbook 6).
#   [4] unload retire le listener (zero fantome).
#   [5] le cookbook reference le greeter.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use JSON::PP ();

{
    package Bot777;
    sub new {
        require Mediabot::CommandRegistry;
        require Mediabot::ScriptRunner;
        require Mediabot::EventBus;
        my ($class, $dir) = @_;
        my $self = bless { registry => Mediabot::CommandRegistry->new,
                           bus => Mediabot::EventBus->new,
                           logger => Log777->new }, $class;
        $self->{runner} = Mediabot::ScriptRunner->new(bot => $self, script_dir => $dir);
        return $self;
    }
    sub registry { $_[0]{registry} }
    sub events { $_[0]{bus} }
    sub script_runner { $_[0]{runner} }
    sub script_action_runner { $_[0] }
    sub apply_actions { return { applied_ok => 1 } }
}
{
    package Log777; sub new { bless {}, shift } sub log { 1 }
}

return sub {
    my ($assert) = @_;

    require Mediabot::PluginManager;

    my $scripts_dir = "$Bin/../../plugins/scripts";
    my $rel = 'examples-v2/greeter.tcl';

    # [1] sidecar
    my $sidecar = "$scripts_dir/$rel.manifest.json";
    $assert->ok(-f $sidecar, 'mb594-777: sidecar present');
    open my $fh, '<:raw', $sidecar or die $!;
    my $m = eval { JSON::PP->new->decode(do { local $/; <$fh> }) };
    close $fh;
    $assert->ok(ref($m) eq 'HASH', 'mb594-777: JSON strict');
    $assert->ok(!exists $m->{commands}, 'mb594-777: aucune commande — pur event');
    $assert->is(join(',', @{ $m->{events} || [] }), 'channel_join_observed',
        'mb594-777: event routable declare');

    # [2] chargement reel
    my $bot = Bot777->new($scripts_dir);
    my $pm  = Mediabot::PluginManager->new(bot => $bot);
    my $entry = eval { $pm->load_script_v2($rel) };
    $assert->ok($entry, 'mb594-777: greeter charge depuis le depot')
        or return;
    $assert->is(scalar @{ $entry->{mounted_commands} || [] }, 0,
        'mb594-777: zero commande montee');
    $assert->is($bot->events->listener_count('channel_join_observed'), 1,
        'mb594-777: listener join pose');

    # [3] execution reelle tclsh — join utilisateur
    my $result = $bot->script_runner->run_script(
        $rel, 'channel_join_observed',
        event_type => 'join', channel => '#t777',
        nick => 'Canard', is_self => '0',
    );
    $assert->ok(ref($result) eq 'HASH' && $result->{ok},
        'mb594-777: execution reelle ok (join utilisateur)');
    my $resp = ref($result->{response}) eq 'HASH' ? $result->{response} : {};
    my ($reply) = grep { ($_->{type} // '') eq 'reply' } @{ $resp->{actions} || [] };
    $assert->ok($reply && ($reply->{text} // '') =~ /Canard/,
        'mb594-777: reply de bienvenue contient le nick');

    # join du bot lui-meme : silence
    $result = $bot->script_runner->run_script(
        $rel, 'channel_join_observed',
        event_type => 'join', channel => '#t777',
        nick => 'mediabot', is_self => '1',
    );
    $assert->ok(ref($result) eq 'HASH' && $result->{ok},
        'mb594-777: execution reelle ok (join du bot)');
    $resp = ref($result->{response}) eq 'HASH' ? $result->{response} : {};
    $assert->is(scalar @{ $resp->{actions} || [] }, 0,
        'mb594-777: is_self — silence, zero action (motif 6)');

    # [4] unload
    $pm->unregister_plugin('greeter');
    $assert->is($bot->events->listener_count('channel_join_observed'), 0,
        'mb594-777: unload retire le listener — zero fantome');

    # [5] cookbook
    my $cb = do { open my $cf, '<:encoding(UTF-8)', "$scripts_dir/COOKBOOK.md" or die $!; local $/; <$cf> };
    $assert->like($cb, qr/greeter\.tcl.*the event\s+showcase/s,
        'mb594-777: cookbook reference le greeter');
};
