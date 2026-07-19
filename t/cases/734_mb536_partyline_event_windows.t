# t/cases/734_mb536_partyline_event_windows.t
# =============================================================================
# mb536 — visibilité partyline des évènements : `.scriptdryrun events` et
# `.scriptdryrun clearevents` (pendant de mb527 pour le chemin évènements).
#
# Le cooldown par (évènement, canal) de mb529 était invisible : impossible de
# savoir quels canaux étaient en fenêtre ni pour combien de temps, et le seul
# moyen de débloquer un canal après un test était d'attendre.
#
# Contrats :
#   [1] plugin : event_cooldown_state() (lecture seule, ancienneté + restant,
#       0 = re-déclenchable) et clear_event_cooldowns() (fenêtres uniquement —
#       routes, compteurs et timers intacts, rien d'exécuté) ;
#   [2] partyline : rendu (routes/cooldown/compteurs/fenêtres cooling|ready,
#       tri actives d'abord, cap 20 + résumé), disabled sans routes,
#       clearevents avec compte, not loaded sans plugin ;
#   [3] bout-en-bout : une fenêtre créée par un vrai join est visible en
#       cooling, clearevents la purge et le canal redevient déclenchable
#       immédiatement ;
#   [4] usage/aide/docs à jour (contrats 419/726 évolués).
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

use Mediabot::EventBus;
use Mediabot::Partyline;
use Mediabot::ScriptRunner;
use Mediabot::ScriptActionRunner;
use Mediabot::Plugin::ScriptDryRun;

sub _slurp_734 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

{ package L734; sub new { bless {}, shift } sub log { 1 } }

{
    package Stream734;
    sub new { bless { out => '' }, shift }
    sub write { $_[0]->{out} .= $_[1]; 1 }
    sub out { $_[0]->{out} }
}

{
    package IRC734;
    sub new { bless { sent => [] }, shift }
    sub send_message { my ($self, @args) = @_; push @{ $self->{sent} }, \@args; 1 }
    sub sent { $_[0]->{sent} }
}

{
    package PM734;
    sub new { my ($class, $plugin) = @_; bless { plugin => $plugin }, $class }
    sub object_for {
        my ($self, $name) = @_;
        return $self->{plugin} if $name eq 'Mediabot::Plugin::ScriptDryRun';
        return undef;
    }
}

{
    package Bot734;
    sub new { my ($class, %h) = @_; bless {%h, logger => L734->new}, $class }
    sub events               { $_[0]->{event_bus} }
    sub plugin_manager       { $_[0]->{pm} }
    sub script_runner        { $_[0]->{script_runner} }
    sub script_action_runner { $_[0]->{script_action_runner} }
    sub getLoop              { undef }
    sub run_script_actions_dry { die "dry path must not run in apply mode" }
}

my $examples = File::Spec->catdir('plugins', 'scripts', 'examples');

my $mk_env = sub {
    my (%conf_extra) = @_;
    my $bus = Mediabot::EventBus->new;
    my $irc = IRC734->new;
    my $conf = {
        'plugins.ScriptDryRun.ACTION_MODE' => 'apply',
        'plugins.ScriptDryRun.ALLOW_IRC'   => 'yes',
        %conf_extra,
    };
    my $bot = Bot734->new(irc => $irc, conf => $conf, event_bus => $bus);
    $bot->{script_runner} = Mediabot::ScriptRunner->new(
        bot => $bot, script_dir => $examples, timeout => 5, max_stdout_bytes => 65536);
    $bot->{script_action_runner} = Mediabot::ScriptActionRunner->new(bot => $bot);
    my $plugin = Mediabot::Plugin::ScriptDryRun->register($bot);
    $bot->{pm} = PM734->new($plugin);
    my $party = bless { bot => $bot }, 'Mediabot::Partyline';
    return ($bot, $bus, $irc, $plugin, $party);
};

return sub {
    my ($assert) = @_;

    # ------------------------------------------------------------------
    # [1] Accesseurs plugin (état simulé pour maîtriser l'horloge)
    # ------------------------------------------------------------------
    {
        my (undef, undef, undef, $plugin) = $mk_env->(
            'plugins.ScriptDryRun.EVENTS'         => 'join=greet.pl',
            'plugins.ScriptDryRun.EVENT_COOLDOWN' => '30',
        );

        $assert->ok(scalar($plugin->event_cooldown_state) == 0,
            'etat vide au depart');

        my $now = time();
        $plugin->{event_last_run} = {
            join => { '#hot' => $now - 5, '#cold' => $now - 300 },
            kick => { '#hot' => $now - 29 },
        };

        my @state = $plugin->event_cooldown_state;
        $assert->ok(@state == 3, 'trois fenetres connues');
        my ($hot) = grep { $_->{event} eq 'join' && $_->{channel} eq '#hot' } @state;
        $assert->ok($hot && $hot->{remaining} >= 24 && $hot->{remaining} <= 25
            && $hot->{last_run_ago} >= 5 && $hot->{last_run_ago} <= 6,
            'fenetre active: restant et anciennete coherents');
        my ($cold) = grep { $_->{event} eq 'join' && $_->{channel} eq '#cold' } @state;
        $assert->ok($cold && $cold->{remaining} == 0,
            'fenetre expiree: remaining=0 (re-declenchable)');

        my $cleared = $plugin->clear_event_cooldowns;
        $assert->ok($cleared == 3, 'clear_event_cooldowns compte les fenetres');
        $assert->ok(scalar($plugin->event_cooldown_state) == 0, 'etat purge');
        $assert->ok($plugin->event_cooldown == 30 && $plugin->event_routes_enabled,
            'purge: routes et cooldown intacts');

        $plugin->unregister;
    }

    # ------------------------------------------------------------------
    # [2] Rendu partyline
    # ------------------------------------------------------------------
    {
        my (undef, undef, undef, $plugin, $party) = $mk_env->(
            'plugins.ScriptDryRun.EVENTS'         => 'join=greet.pl, kick=kickwatch.pl',
            'plugins.ScriptDryRun.EVENT_COOLDOWN' => '60',
        );

        my $now = time();
        $plugin->{event_last_run} = {
            join => { '#a' => $now - 10, '#b' => $now - 500 },
        };
        $plugin->{observed_events}      = 7;
        $plugin->{skipped_events}       = 3;
        $plugin->{event_cooldown_skips} = 2;

        my $s = Stream734->new;
        $party->_cmd_scriptdryrun($s, 1, 'events');
        my $out = $s->out;

        $assert->like($out, qr/^ScriptDryRun events:/m, 'entete');
        $assert->like($out, qr/event_map: join=greet\.pl,kick=kickwatch\.pl/, 'routes triees');
        $assert->like($out, qr/event_cooldown: 60s/, 'cooldown expose');
        $assert->like($out, qr/observed_events: 7/, 'compteur observe');
        $assert->like($out, qr/skipped_events: 3 \(cooldown: 2\)/, 'compteurs de skip');
        $assert->like($out, qr/join #a: last=1?\ds ago, cooling \(\d+s left\)/,
            'fenetre active rendue cooling avec restant');
        $assert->like($out, qr/join #b: last=\d+s ago, ready/, 'fenetre expiree rendue ready');
        my ($pos_a) = index($out, 'join #a:');
        my ($pos_b) = index($out, 'join #b:');
        $assert->ok($pos_a >= 0 && $pos_b > $pos_a, 'tri: actives avant expirees');

        # clearevents via partyline.
        my $s2 = Stream734->new;
        $party->_cmd_scriptdryrun($s2, 1, 'clearevents');
        $assert->like($s2->out, qr/^ScriptDryRun event cooldown windows cleared: 2/m,
            'clearevents annonce le compte');
        my $s3 = Stream734->new;
        $party->_cmd_scriptdryrun($s3, 1, 'events');
        $assert->like($s3->out, qr/windows: none/, 'plus de fenetre apres purge');

        $plugin->unregister;

        # Cap d'affichage: 25 fenetres -> 20 lignes + resume.
        my (undef, undef, undef, $plugin2, $party2) = $mk_env->(
            'plugins.ScriptDryRun.EVENTS' => 'join=greet.pl',
        );
        my $now2 = time();
        $plugin2->{event_last_run} = { join => { map { ("#c$_" => $now2 - 1) } 1 .. 25 } };
        my $s4 = Stream734->new;
        $party2->_cmd_scriptdryrun($s4, 1, 'events');
        my @lines = grep { /join #c\d+:/ } split /\r?\n/, $s4->out;
        $assert->ok(@lines == 20, 'cap: 20 fenetres affichees');
        $assert->like($s4->out, qr/\.\.\. and 5 more window\(s\)/, 'cap: resume du reste');
        $plugin2->unregister;

        # Sans routes / sans plugin.
        my (undef, undef, undef, $plugin3, $party3) = $mk_env->();
        my $s5 = Stream734->new;
        $party3->_cmd_scriptdryrun($s5, 1, 'events');
        $assert->like($s5->out, qr/event_routes: disabled/, 'disabled sans routes');
        $plugin3->unregister;

        my $party4 = bless { bot => Bot734->new(pm => PM734->new(undef)) }, 'Mediabot::Partyline';
        for my $sub (qw(events clearevents)) {
            my $sx = Stream734->new;
            $party4->_cmd_scriptdryrun($sx, 1, $sub);
            $assert->like($sx->out, qr/ScriptDryRun: not loaded/, "$sub sans plugin -> not loaded");
        }
    }

    # ------------------------------------------------------------------
    # [3] Bout-en-bout : fenêtre réelle créée par un join, purge, re-run
    # ------------------------------------------------------------------
    {
        my (undef, $bus, $irc, $plugin, $party) = $mk_env->(
            'plugins.ScriptDryRun.EVENTS'         => 'join=greet.pl',
            'plugins.ScriptDryRun.EVENT_COOLDOWN' => '3600',
        );

        $bus->emit_report('channel_join_observed',
            { event_type => 'join', channel => '#mb536', nick => 'poyan', is_self => 0 });
        $assert->ok(@{ $irc->sent } == 1, 'join initial applique');

        my $s = Stream734->new;
        $party->_cmd_scriptdryrun($s, 1, 'events');
        $assert->like($s->out, qr/join #mb536: last=\d+s ago, cooling/,
            'fenetre reelle visible en cooling');

        # Bloque par le cooldown (3600s), puis debloque par clearevents.
        $bus->emit_report('channel_join_observed',
            { event_type => 'join', channel => '#mb536', nick => 'teuk2', is_self => 0 });
        $assert->ok(@{ $irc->sent } == 1, 'second join bloque par la fenetre');

        my $s2 = Stream734->new;
        $party->_cmd_scriptdryrun($s2, 1, 'clearevents');
        $assert->like($s2->out, qr/cleared: 1/, 'purge de la fenetre reelle');

        $bus->emit_report('channel_join_observed',
            { event_type => 'join', channel => '#mb536', nick => 'teuk2', is_self => 0 });
        $assert->ok(@{ $irc->sent } == 2
            && ($irc->sent->[1][3] || '') =~ /welcome to #mb536, teuk2!/,
            'apres purge: le canal redevient declenchable immediatement');

        $plugin->unregister;
    }

    # ------------------------------------------------------------------
    # [4] Usage, aide et docs
    # ------------------------------------------------------------------
    {
        my (undef, undef, undef, $plugin, $party) = $mk_env->();
        my $s = Stream734->new;
        $party->_cmd_scriptdryrun($s, 1, 'bogus');
        $assert->like($s->out,
            qr/Usage: \.scriptdryrun \[status\|last\|config\|timers\|canceltimers\|events\|clearevents\|reload\]/,
            'usage liste les nouvelles sous-commandes');
        $plugin->unregister;

        my $party_src = _slurp_734(File::Spec->catfile('.', 'Mediabot', 'Partyline.pm'));
        $assert->like($party_src, qr/mb536-B1/, 'marqueur mb536 dans Partyline');
        $assert->like($party_src, qr/show external script bridge status and last run/,
            'contrat mb291 de la ligne d\'aide conserve');

        my $plugin_src = _slurp_734(File::Spec->catfile('.', 'Mediabot', 'Plugin', 'ScriptDryRun.pm'));
        $assert->like($plugin_src, qr/sub event_cooldown_state/, 'accesseur present');
        $assert->like($plugin_src, qr/sub clear_event_cooldowns/, 'purge presente');
        $assert->unlike($plugin_src, qr/`[^`]+`/, 'aucun backtick apparie (garde mb203)');

        my $sample = _slurp_734('mediabot.sample.conf');
        $assert->like($sample, qr/\.scriptdryrun events/, 'sample conf documente events');
        $assert->like($sample, qr/\.scriptdryrun clearevents/, 'sample conf documente clearevents');

        my $readme = _slurp_734(File::Spec->catfile('.', 'plugins', 'scripts', 'README.md'));
        $assert->like($readme, qr/\.scriptdryrun events/, 'README documente events');
        $assert->like($readme, qr/cooldown windows only/, 'README: clearevents = fenetres uniquement');
    }
};
