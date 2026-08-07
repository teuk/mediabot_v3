# t/cases/782_mb599_extended_events_cron.t
# =============================================================================
# mb599 — chantier C : la surface d'evenements s'elargit.
#   [1] observe_channel_event accepte nick (avec new_nick) et quit ; le ctx
#       reste scalar-only ; l'inconnu reste refuse.
#   [2] observe_cron_event : emet plugin_cron_observed avec minute/hour/dow/
#       mday/month/year ; N'EMET QU'AU CHANGEMENT de minute (2e appel dans la
#       meme minute = no-op) ; no-op sans listener ne casse rien.
#   [3] la liste blanche routable des scripts gagne les 3 events ; le pont
#       _script_event_data transmet new_nick et les champs cron.
#   [4] cablages structurels dans mediabot.pl : cron eval-garde dans le
#       tick ; NICK emet avec old/new + is_self ; QUIT n'emet JAMAIS sur
#       netsplit (unless $is_netsplit).
#   [5] cookbook : liste + bind time documentes.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use JSON::PP ();

{
    package Bus782;
    sub new { bless { emitted => [] }, shift }
    sub emit_report { push @{ $_[0]{emitted} }, [ $_[1], $_[2] ]; { ok => 1 } }
    sub on { return { cb => $_[2] } }
    sub off { 1 }
    sub listener_count { 0 }
}

return sub {
    my ($assert) = @_;

    require Mediabot::Mediabot;

    my $bot = bless { logger => undef }, 'Mediabot';
    my $bus = Bus782->new;
    { no warnings 'redefine';
      *Mediabot::event_bus = sub { $bus }; }   # emit_event_report lit event_bus

    # [1] nick / quit observables
    my $r = $bot->observe_channel_event('nick',
        nick => 'SlaY', new_nick => 'SlaY_away', ident => 'i', host => 'h',
        is_self => 0);
    $assert->ok($r, 'mb599-782: nick est observable');
    my ($name, $ctx) = @{ $bus->{emitted}[-1] };
    $assert->is($name, 'channel_nick_observed', 'mb599-782: event nick emis');
    $assert->is($ctx->{nick}, 'SlaY', 'mb599-782: nick = ancien nick');
    $assert->is($ctx->{new_nick}, 'SlaY_away', 'mb599-782: new_nick transmis');
    $assert->ok(!exists $ctx->{channel},
        'mb599-782: evenement reseau — pas de champ channel');

    $r = $bot->observe_channel_event('quit',
        nick => 'Canard', message => 'bye', is_self => 0);
    ($name, $ctx) = @{ $bus->{emitted}[-1] };
    $assert->is($name, 'channel_quit_observed', 'mb599-782: event quit emis');
    $assert->is($ctx->{message}, 'bye', 'mb599-782: raison du quit transmise');

    $r = $bot->observe_channel_event('mode', nick => 'x');
    $assert->ok(!defined $r, 'mb599-782: type inconnu toujours refuse');

    # [2] cron : emission au changement de minute seulement
    delete $bot->{_last_cron_stamp};
    my $n = scalar @{ $bus->{emitted} };
    $bot->observe_cron_event;
    $assert->is(scalar @{ $bus->{emitted} }, $n + 1,
        'mb599-782: cron emet au premier appel');
    ($name, $ctx) = @{ $bus->{emitted}[-1] };
    $assert->is($name, 'plugin_cron_observed', 'mb599-782: nom d event cron');
    for my $field (qw(minute hour dow mday month year)) {
        $assert->ok(defined $ctx->{$field} && $ctx->{$field} =~ /\A[0-9]+\z/,
            "mb599-782: champ cron $field numerique");
    }
    $bot->observe_cron_event;
    $assert->is(scalar @{ $bus->{emitted} }, $n + 1,
        'mb599-782: meme minute — pas de re-emission');

    # [3] routable + pont de champs, en conditions reelles
    require Mediabot::PluginManager;
    require Mediabot::ScriptRunner;
    require Mediabot::CommandRegistry;
    require Mediabot::EventBus;
    no warnings 'redefine';
    my $DIR = tempdir(CLEANUP => 1);
    open my $sf, '>', "$DIR/watch2.py" or die $!; print $sf "1\n"; close $sf;
    open my $mf, '>', "$DIR/watch2.py.manifest.json" or die $!;
    print $mf JSON::PP::encode_json({ api => 2, name => 'watch2',
        version => '1.0',
        events => ['channel_nick_observed', 'plugin_cron_observed'] });
    close $mf;
    local *Mediabot::ScriptRunner::run_script = sub {
        push @{ $_[0]{bot}{runs} }, { path => $_[1], event => $_[2],
            data => { @_[3..$#_] } };
        return { ok => 1, response => { ok => 1, actions => [] } };
    };
    {
        package Bot782;
        sub new {
            my ($class, $dir) = @_;
            my $self = bless { registry => Mediabot::CommandRegistry->new,
                               bus => Mediabot::EventBus->new,
                               logger => Log782->new, runs => [] }, $class;
            $self->{runner} = Mediabot::ScriptRunner->new(bot => $self, script_dir => $dir);
            return $self;
        }
        sub registry { $_[0]{registry} }
        sub events { $_[0]{bus} }
        sub script_runner { $_[0]{runner} }
        sub script_action_runner { $_[0] }
        sub apply_actions { return { applied_ok => 1 } }
    }
    { package Log782; sub new { bless {}, shift } sub log { 1 } }

    my $sbot = Bot782->new($DIR);
    my $pm = Mediabot::PluginManager->new(bot => $sbot);
    my $entry = eval { $pm->load_script_v2('watch2.py') };
    $assert->ok($entry, 'mb599-782: sidecar avec nick+cron accepte (routables)');
    $sbot->events->emit('channel_nick_observed',
        { event_type => 'nick', nick => 'a', new_nick => 'b', is_self => 0 });
    my $run = $sbot->{runs}[-1];
    $assert->is($run->{data}{new_nick}, 'b',
        'mb599-782: new_nick traverse le pont _script_event_data');
    $sbot->events->emit('plugin_cron_observed',
        { event_type => 'cron', minute => 7, hour => 9, dow => 5,
          mday => 1, month => 8, year => 2026 });
    $run = $sbot->{runs}[-1];
    $assert->is($run->{event}, 'plugin_cron_observed',
        'mb599-782: le script recoit l event cron');
    $assert->is($run->{data}{hour}, 9, 'mb599-782: hour traverse le pont');
    $assert->is($run->{data}{dow}, 5, 'mb599-782: dow traverse le pont');
    $assert->is($run->{data}{year}, 2026, 'mb605-782: year traverse le pont');

    # [4] cablages structurels dans mediabot.pl
    my $main = do { open my $fh, '<:encoding(UTF-8)', 'mediabot.pl' or die $!; local $/; <$fh> };
    $assert->like($main, qr/eval \{ \$mediabot->observe_cron_event\(\); \};/,
        'mb599-782: cron eval-garde dans le tick');
    $assert->like($main, qr/observe_channel_event\('nick',\n\s+nick => \$old_nick, new_nick => \$new_nick/,
        'mb599-782: NICK emet old+new');
    $assert->like($main, qr/unless \(\$is_netsplit\) \{\n\s+eval \{ \$mediabot->observe_channel_event\('quit'/,
        'mb599-782: QUIT n emet JAMAIS sur netsplit');

    # [5] cookbook
    my $cb = do { open my $fh, '<:encoding(UTF-8)', 'plugins/scripts/COOKBOOK.md' or die $!; local $/; <$fh> };
    $assert->like($cb, qr/channel_nick_observed.*channel_quit_observed.*plugin_cron_observed/s,
        'mb599-782: les 3 events documentes');
    $assert->like($cb, qr/bind time,?\n?\s*reborn/s,
        'mb599-782: bind time documente');
};
