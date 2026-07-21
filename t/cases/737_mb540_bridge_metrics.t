# t/cases/737_mb540_bridge_metrics.t
# =============================================================================
# mb540 — métriques Prometheus du bridge (premier round post-arc, besoin
# neuf : le bot a Mediabot::Metrics et une stack Prometheus/Grafana, le
# bridge n'exposait rien).
#
# Quatre séries sous mediabot_scriptbridge_* :
#   runs_total{origin,result} ; events_total{event,outcome} ;
#   timers_total{outcome=armed|delivered|cancelled} ; pending_timers (gauge).
#
# Contrats :
#   [1] déclaration des quatre séries au register (types corrects) ;
#   [2] runs par origine et résultat (command/event/timer, ok/error) ;
#   [3] cycle timer complet : armed -> gauge=1 -> delivered + runs timer ->
#       gauge=0 ; cancel -> cancelled + gauge ;
#   [4] outcomes d'évènements : accepted/cooldown/self/unrouted, et label
#       event=invalid pour un type inconnu (cardinalité bornée) ;
#   [5] best-effort absolu : un bot SANS metrics fonctionne à l'identique
#       (aucun crash, aucun appel) — le bridge ne dépend jamais de
#       l'observabilité ;
#   [6] aucune nouvelle clé de conf (le contrat générique 731 reste inerte) ;
#       docs README.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;
use File::Temp qw(tempdir);

use Mediabot::EventBus;
use Mediabot::ScriptRunner;
use Mediabot::ScriptActionRunner;
use Mediabot::Plugin::ScriptDryRun;

sub _slurp_737 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

{ package L737; sub new { bless {}, shift } sub log { 1 } }

{
    # Faux Metrics compatible API (declare/inc/add/set/enabled) qui journalise.
    package Metrics737;
    sub new { bless { declared => {}, counts => {}, gauges => {} }, shift }
    sub enabled { 1 }
    sub declare {
        my ($self, $name, $type, $help) = @_;
        $self->{declared}{$name} = { type => $type, help => $help };
        return 1;
    }
    sub _key {
        my ($labels) = @_;
        return '' unless ref($labels) eq 'HASH' && %$labels;
        return join(',', map { "$_=$labels->{$_}" } sort keys %$labels);
    }
    sub inc {
        my ($self, $name, $labels) = @_;
        $self->{counts}{$name}{ _key($labels) } += 1;
        return 1;
    }
    sub add { my ($self, $name, $v, $labels) = @_; $self->{counts}{$name}{ _key($labels) } += $v; 1 }
    sub set { my ($self, $name, $v, $labels) = @_; $self->{gauges}{$name}{ _key($labels) } = $v; 1 }
    sub count { my ($self, $name, $key) = @_; $self->{counts}{$name}{$key} || 0 }
    sub gauge { my ($self, $name) = @_; $self->{gauges}{$name}{''} }
}

{
    package IRC737;
    sub new { bless { sent => [] }, shift }
    sub send_message { my ($self, @args) = @_; push @{ $self->{sent} }, \@args; 1 }
    sub sent { $_[0]->{sent} }
}

{
    package Bot737;
    sub new { my ($class, %h) = @_; bless {%h, logger => L737->new}, $class }
    sub events               { $_[0]->{event_bus} }
    sub script_runner        { $_[0]->{script_runner} }
    sub script_action_runner { $_[0]->{script_action_runner} }
    sub getLoop              { $_[0]->{loop} }
    sub run_script_actions_dry { die "dry path must not run in apply mode" }
}

my $script_dir = tempdir('mediabot_mb540_XXXXXX', TMPDIR => 1, CLEANUP => 1);
{
    my $path = File::Spec->catfile($script_dir, 'mecho.pl');
    open my $fh, '>:encoding(UTF-8)', $path or die "cannot create $path: $!";
    print {$fh} <<'FIX';
#!/usr/bin/env perl
use strict; use warnings;
use JSON::PP qw(decode_json encode_json);
my $p = eval { decode_json(do { local $/; <STDIN> } || '{}') } || {};
my $d = ref($p->{data}) eq 'HASH' ? $p->{data} : {};
my $ev = $p->{event} // 'unknown';
my @actions = ( { type => 'reply', text => "m[$ev]" } );
push @actions, { type => 'timer', name => 'mhold', delay => 1 }
    if $ev eq 'public_command' && ($d->{args}[0] // '') eq 'arm';
print encode_json({ protocol => 'mediabot-script-v1', ok => JSON::PP::true, actions => \@actions });
FIX
    close $fh or die "cannot close $path: $!";
}

my $mk_env = sub {
    my ($with_metrics, %conf_extra) = @_;
    my $bus = Mediabot::EventBus->new;
    my $irc = IRC737->new;
    my $conf = {
        'plugins.ScriptDryRun.ACTION_MODE' => 'apply',
        'plugins.ScriptDryRun.ALLOW_IRC'   => 'yes',
        %conf_extra,
    };
    my $metrics = $with_metrics ? Metrics737->new : undef;
    my $bot = Bot737->new(irc => $irc, conf => $conf, event_bus => $bus,
        ($with_metrics ? (metrics => $metrics) : ()));
    $bot->{script_runner} = Mediabot::ScriptRunner->new(
        bot => $bot, script_dir => $script_dir, timeout => 5, max_stdout_bytes => 65536);
    $bot->{script_action_runner} = Mediabot::ScriptActionRunner->new(bot => $bot);
    my $plugin = Mediabot::Plugin::ScriptDryRun->register($bot);
    return ($bot, $bus, $irc, $plugin, $metrics);
};

return sub {
    my ($assert) = @_;

    # ------------------------------------------------------------------
    # [1] Déclarations au register
    # ------------------------------------------------------------------
    {
        my (undef, undef, undef, $plugin, $m) = $mk_env->(1);
        for my $pair ([ 'mediabot_scriptbridge_runs_total', 'counter' ],
                      [ 'mediabot_scriptbridge_events_total', 'counter' ],
                      [ 'mediabot_scriptbridge_timers_total', 'counter' ],
                      [ 'mediabot_scriptbridge_pending_timers', 'gauge' ]) {
            my ($name, $type) = @$pair;
            $assert->ok(($m->{declared}{$name}{type} || '') eq $type,
                "declare: $name ($type)");
        }
        $assert->ok(defined($m->gauge('mediabot_scriptbridge_pending_timers'))
            && $m->gauge('mediabot_scriptbridge_pending_timers') == 0,
            'gauge: echantillon initial a zero des le register');
        $assert->unlike(($m->{declared}{'mediabot_scriptbridge_timers_total'}{help} || ''),
            qr/rejected/, 'help timers: uniquement les outcomes reellement emis');
        $plugin->unregister;
    }

    # ------------------------------------------------------------------
    # [2]+[3] Runs par origine, cycle timer, gauge
    # ------------------------------------------------------------------
    my $have_loop = eval { require IO::Async::Loop; 1 };
    if (!$have_loop) {
        $assert->ok(1, 'SKIP runs/timer: IO::Async::Loop indisponible');
    }
    else {
        my $loop = IO::Async::Loop->new;
        my ($bot, $bus, $irc, $plugin, $m) = $mk_env->(1,
            'plugins.ScriptDryRun.COMMANDS' => 'mecho',
            'plugins.ScriptDryRun.ROUTES'   => 'mecho=mecho.pl',
            'plugins.ScriptDryRun.EVENTS'   => 'join=mecho.pl',
        );
        $bot->{loop} = $loop;

        # Commande simple: run command/ok, gauge a 0.
        $plugin->observe_public_command({
            channel => '#mb540', target => '#mb540', nick => 'poyan',
            command => 'mecho', args => [],
        });
        $assert->ok($m->count('mediabot_scriptbridge_runs_total', 'origin=command,result=ok') == 1,
            'runs: command/ok comptee');
        $assert->ok(($m->gauge('mediabot_scriptbridge_pending_timers') || 0) == 0,
            'gauge: 0 sans timer');

        # Commande armant un timer: armed + gauge=1.
        $plugin->observe_public_command({
            channel => '#mb540', target => '#mb540', nick => 'poyan',
            command => 'mecho', args => [ 'arm' ],
        });
        $assert->ok($m->count('mediabot_scriptbridge_timers_total', 'outcome=armed') == 1,
            'timers: armed compte');
        $assert->ok($m->gauge('mediabot_scriptbridge_pending_timers') == 1,
            'gauge: 1 apres armement');

        # Livraison: delivered + run timer/ok + gauge=0.
        $loop->delay_future(after => 1.6)->get;
        $assert->ok($m->count('mediabot_scriptbridge_timers_total', 'outcome=delivered') == 1,
            'timers: delivered compte');
        $assert->ok($m->count('mediabot_scriptbridge_runs_total', 'origin=timer,result=ok') == 1,
            'runs: timer/ok comptee');
        $assert->ok($m->gauge('mediabot_scriptbridge_pending_timers') == 0,
            'gauge: 0 apres livraison');

        # Annulation: re-armer puis canceltimers -> cancelled + gauge=0.
        $plugin->observe_public_command({
            channel => '#mb540b', target => '#mb540b', nick => 'poyan',
            command => 'mecho', args => [ 'arm' ],
        });
        $assert->ok($m->gauge('mediabot_scriptbridge_pending_timers') == 1, 'gauge: re-arme');
        my $cancelled = $plugin->cancel_script_timers;
        $assert->ok($cancelled == 1
            && $m->count('mediabot_scriptbridge_timers_total', 'outcome=cancelled') == 1,
            'timers: cancelled compte');
        $assert->ok($m->gauge('mediabot_scriptbridge_pending_timers') == 0,
            'gauge: 0 apres annulation');

        # Expiration alors que le plugin est repasse en dry-run : aucun rappel
        # n'est execute, mais le slot libere doit etre reflechi immediatement.
        $plugin->observe_public_command({
            channel => '#mb540skip', target => '#mb540skip', nick => 'poyan',
            command => 'mecho', args => [ 'arm' ],
        });
        $assert->ok($m->gauge('mediabot_scriptbridge_pending_timers') == 1,
            'gauge: timer arme avant rappel saute');
        $bot->{conf}{'plugins.ScriptDryRun.ACTION_MODE'} = 'dry-run';
        $plugin->refresh_from_conf;
        $loop->delay_future(after => 1.6)->get;
        $assert->ok($m->gauge('mediabot_scriptbridge_pending_timers') == 0,
            'gauge: zero meme quand le rappel est saute');
        $assert->ok($m->count('mediabot_scriptbridge_timers_total', 'outcome=delivered') == 1,
            'timer saute: delivered non incremente');
        $bot->{conf}{'plugins.ScriptDryRun.ACTION_MODE'} = 'apply';
        $plugin->refresh_from_conf;

        # Evenement accepte: events accepted + run event/ok.
        $bus->emit_report('channel_join_observed',
            { event_type => 'join', channel => '#mb540', nick => 'a', is_self => 0 });
        $assert->ok($m->count('mediabot_scriptbridge_events_total', 'event=join,outcome=accepted') == 1,
            'events: accepted compte');
        $assert->ok($m->count('mediabot_scriptbridge_runs_total', 'origin=event,result=ok') == 1,
            'runs: event/ok comptee');

        # Erreur de script (route vers un fichier absent): run event/error.
        $bot->{conf}{'plugins.ScriptDryRun.EVENTS'} = 'join=mecho.pl, topic=missing.pl';
        $plugin->refresh_from_conf;
        $bus->emit_report('channel_topic_observed',
            { event_type => 'topic', channel => '#mb540', nick => 'a',
              topic => 'x', is_self => 0 });
        $assert->ok($m->count('mediabot_scriptbridge_runs_total', 'origin=event,result=error') == 1,
            'runs: event/error comptee sur script manquant');

        $plugin->unregister;
    }

    # ------------------------------------------------------------------
    # [4] Outcomes d'évènements
    # ------------------------------------------------------------------
    {
        my ($bot, $bus, undef, $plugin, $m) = $mk_env->(1,
            'plugins.ScriptDryRun.EVENTS'         => 'join=mecho.pl',
            'plugins.ScriptDryRun.EVENT_COOLDOWN' => '3600',
        );

        # self
        $plugin->observe_channel_event('join',
            { channel => '#x', nick => 'bot', is_self => 1 });
        $assert->ok($m->count('mediabot_scriptbridge_events_total', 'event=join,outcome=self') == 1,
            'events: self compte');

        # unrouted (part n'est pas route)
        $plugin->observe_channel_event('part',
            { channel => '#x', nick => 'a', is_self => 0 });
        $assert->ok($m->count('mediabot_scriptbridge_events_total', 'event=part,outcome=unrouted') == 1,
            'events: unrouted compte');

        # other : evenement route mais contexte incomplet.
        $plugin->observe_channel_event('join',
            { nick => 'a', is_self => 0 });
        $assert->ok($m->count('mediabot_scriptbridge_events_total', 'event=join,outcome=other') == 1,
            'events: contexte sans canal compte sous other');

        # other : evenement route mais runner indisponible.
        my $saved_runner = $bot->{script_runner};
        $bot->{script_runner} = undef;
        $plugin->observe_channel_event('join',
            { channel => '#norunner', nick => 'a', is_self => 0 });
        $bot->{script_runner} = $saved_runner;
        $assert->ok($m->count('mediabot_scriptbridge_events_total', 'event=join,outcome=other') == 2,
            'events: runner absent compte sous other');

        # invalid (type inconnu agrege)
        $plugin->observe_channel_event('quit',
            { channel => '#x', nick => 'a', is_self => 0 });
        $assert->ok($m->count('mediabot_scriptbridge_events_total', 'event=invalid,outcome=other') == 1,
            'events: type inconnu agrege sous invalid');

        # cooldown (accepted puis second join bloque)
        $bus->emit_report('channel_join_observed',
            { event_type => 'join', channel => '#cd', nick => 'a', is_self => 0 });
        $bus->emit_report('channel_join_observed',
            { event_type => 'join', channel => '#cd', nick => 'b', is_self => 0 });
        $assert->ok($m->count('mediabot_scriptbridge_events_total', 'event=join,outcome=cooldown') == 1,
            'events: cooldown compte');

        $plugin->unregister;
    }

    # ------------------------------------------------------------------
    # [5] Best-effort : bot sans metrics, comportement identique
    # ------------------------------------------------------------------
    {
        my ($bot, $bus, $irc, $plugin) = $mk_env->(0,
            'plugins.ScriptDryRun.COMMANDS' => 'mecho',
            'plugins.ScriptDryRun.ROUTES'   => 'mecho=mecho.pl',
            'plugins.ScriptDryRun.EVENTS'   => 'join=mecho.pl',
        );

        my $ok = eval {
            $plugin->observe_public_command({
                channel => '#mb540', target => '#mb540', nick => 'poyan',
                command => 'mecho', args => [],
            });
            $bus->emit_report('channel_join_observed',
                { event_type => 'join', channel => '#mb540', nick => 'a', is_self => 0 });
            1;
        };
        $assert->ok($ok && !$@, 'sans metrics: aucun crash');
        $assert->ok(@{ $irc->sent } == 2, 'sans metrics: pipeline identique');

        $plugin->unregister;
    }

    # ------------------------------------------------------------------
    # [6] Gardes : pas de nouvelle clé de conf, docs, source
    # ------------------------------------------------------------------
    {
        my $plugin_src = _slurp_737(File::Spec->catfile('.', 'Mediabot', 'Plugin', 'ScriptDryRun.pm'));
        $assert->like($plugin_src, qr/mb540-B1/, 'marqueur mb540 dans ScriptDryRun');
        $assert->unlike($plugin_src, qr/`[^`]+`/, 'aucun backtick apparie (garde mb203)');
        my @metric_conf_keys = $plugin_src =~ /'plugins\.ScriptDryRun\.([A-Z_]+)'/g;
        my %known = map { $_ => 1 } qw(SCRIPT COMMANDS ROUTES ACTION_MODE ALLOW_IRC
            ALLOW_TOPIC APPLY_REQUIRE_SCOPE EVENTS EVENT_COOLDOWN);
        my @new_keys = grep { !$known{$_} } @metric_conf_keys;
        $assert->ok(!@new_keys, 'aucune nouvelle cle de conf introduite par les metriques');

        my $readme = _slurp_737(File::Spec->catfile('.', 'plugins', 'scripts', 'README.md'));
        $assert->like($readme, qr/## Metrics/, 'README: section Metrics');
        $assert->like($readme, qr/mediabot_scriptbridge_runs_total/, 'README: serie runs documentee');
        $assert->like($readme, qr/mediabot_scriptbridge_pending_timers/, 'README: gauge documentee');
    }
};
