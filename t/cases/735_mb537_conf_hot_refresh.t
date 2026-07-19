# t/cases/735_mb537_conf_hot_refresh.t
# =============================================================================
# mb537 — rechargement à chaud de l'état de conf du plugin (.scriptdryrun
# reload), dernière piste fonctionnelle de l'arc.
#
# Contexte : .reloadconf/.rehash rechargent le fichier dans $bot->{conf} mais
# ne touchent pas aux plugins — ScriptDryRun gardait son état figé du
# register (routes, EVENTS, cooldown, CONFIG_, ACTION_MODE...).
#
# Contrats :
#   [1] refresh_from_conf() relit TOUTES les clés (lecture factorisée
#       _collect_conf_raw, partagée avec register — une seule source de
#       vérité) et retourne la liste triée des champs modifiés ;
#   [2] resouscription EventBus quand les routes d'évènements changent
#       (nouvelle route active, route retirée inerte, pas de doublons) ;
#   [3] conservation volontaire : compteurs, fenêtres de cooldown, timers
#       armés — et un timer armé livre avec le SNAPSHOT de config de son
#       armement, pas la config rechargée ;
#   [4] partyline : reload liste les changements / (no changes) / not loaded ;
#   [5] le refactor du register est neutre (couvert par la suite complète).
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;
use File::Temp qw(tempdir);

use Mediabot::EventBus;
use Mediabot::Partyline;
use Mediabot::ScriptRunner;
use Mediabot::ScriptActionRunner;
use Mediabot::Plugin::ScriptDryRun;

sub _slurp_735 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

{ package L735; sub new { bless {}, shift } sub log { 1 } }

{
    package Stream735;
    sub new { bless { out => '' }, shift }
    sub write { $_[0]->{out} .= $_[1]; 1 }
    sub out { $_[0]->{out} }
}

{
    package IRC735;
    sub new { bless { sent => [] }, shift }
    sub send_message { my ($self, @args) = @_; push @{ $self->{sent} }, \@args; 1 }
    sub sent { $_[0]->{sent} }
}

{
    package PM735;
    sub new { my ($class, $plugin) = @_; bless { plugin => $plugin }, $class }
    sub object_for {
        my ($self, $name) = @_;
        return $self->{plugin} if $name eq 'Mediabot::Plugin::ScriptDryRun';
        return undef;
    }
}

{
    package Bot735;
    sub new { my ($class, %h) = @_; bless {%h, logger => L735->new}, $class }
    sub events               { $_[0]->{event_bus} }
    sub plugin_manager       { $_[0]->{pm} }
    sub script_runner        { $_[0]->{script_runner} }
    sub script_action_runner { $_[0]->{script_action_runner} }
    sub getLoop              { $_[0]->{loop} }
    sub run_script_actions_dry { die "dry path must not run in apply mode" }
}

# Fixture : echo de data.config, timer sur commande (pour le test snapshot).
my $script_dir = tempdir('mediabot_mb537_XXXXXX', TMPDIR => 1, CLEANUP => 1);
{
    my $path = File::Spec->catfile($script_dir, 'cfgprobe.pl');
    open my $fh, '>:encoding(UTF-8)', $path or die "cannot create $path: $!";
    print {$fh} <<'FIX';
#!/usr/bin/env perl
use strict; use warnings;
use JSON::PP qw(decode_json encode_json);
my $p = eval { decode_json(do { local $/; <STDIN> } || '{}') } || {};
my $d = ref($p->{data}) eq 'HASH' ? $p->{data} : {};
my $ev = $p->{event} // 'unknown';
my $cfg = ref($d->{config}) eq 'HASH' ? $d->{config} : {};
my $tag = defined $cfg->{tag} ? $cfg->{tag} : '(none)';
my @actions = ( { type => 'reply', text => "probe[$ev] tag=$tag" } );
push @actions, { type => 'timer', name => 'probe_hold', delay => 1 }
    if $ev eq 'public_command';
print encode_json({ protocol => 'mediabot-script-v1', ok => JSON::PP::true, actions => \@actions });
FIX
    close $fh or die "cannot close $path: $!";
}

my $mk_env = sub {
    my (%conf) = @_;
    my $bus = Mediabot::EventBus->new;
    my $irc = IRC735->new;
    my $bot = Bot735->new(irc => $irc, conf => { %conf }, event_bus => $bus);
    $bot->{script_runner} = Mediabot::ScriptRunner->new(
        bot => $bot, script_dir => $script_dir, timeout => 5, max_stdout_bytes => 65536);
    $bot->{script_action_runner} = Mediabot::ScriptActionRunner->new(bot => $bot);
    my $plugin = Mediabot::Plugin::ScriptDryRun->register($bot);
    $bot->{pm} = PM735->new($plugin);
    my $party = bless { bot => $bot }, 'Mediabot::Partyline';
    return ($bot, $bus, $irc, $plugin, $party);
};

return sub {
    my ($assert) = @_;

    # ------------------------------------------------------------------
    # [1] Diff des champs + relecture complète
    # ------------------------------------------------------------------
    {
        my ($bot, undef, undef, $plugin) = $mk_env->(
            'plugins.ScriptDryRun.ACTION_MODE'  => 'apply',
            'plugins.ScriptDryRun.ALLOW_IRC'    => 'yes',
            'plugins.ScriptDryRun.COMMANDS'     => 'pcfg',
            'plugins.ScriptDryRun.ROUTES'       => 'pcfg=cfgprobe.pl',
            'plugins.ScriptDryRun.CONFIG_pcfg'  => 'tag=alpha',
            'plugins.ScriptDryRun.EVENT_COOLDOWN' => '30',
        );

        my @none = $plugin->refresh_from_conf;
        $assert->ok(@none == 0, 'conf inchangee -> aucun champ modifie');

        # Mutation en memoire (simule .reloadconf) : mode, config, cooldown.
        $bot->{conf}{'plugins.ScriptDryRun.ACTION_MODE'}    = 'dry-run';
        $bot->{conf}{'plugins.ScriptDryRun.CONFIG_pcfg'}    = 'tag=beta';
        $bot->{conf}{'plugins.ScriptDryRun.EVENT_COOLDOWN'} = '99';

        my @changed = $plugin->refresh_from_conf;
        $assert->ok(join(',', @changed) eq 'action_mode,event_cooldown,route_configs',
            'liste triee des champs modifies');
        $assert->ok($plugin->action_mode eq 'dry-run', 'action_mode rafraichi');
        $assert->ok($plugin->event_cooldown == 99, 'cooldown rafraichi');
        $assert->ok(($plugin->route_config('pcfg')->{tag} || '') eq 'beta',
            'config par route rafraichie');

        # mb539-B1: Config::Simple may expose a single SCRIPT value as an
        # ARRAY ref. register() already normalizes it; refresh must do the same.
        $bot->{conf}{'plugins.ScriptDryRun.SCRIPT'} = [ 'cfgprobe.pl' ];
        my @script_changed = $plugin->refresh_from_conf;
        my $fallback = $plugin->script_for_command('not-routed');
        $assert->ok((grep { $_ eq 'script_path' } @script_changed) == 1,
            'SCRIPT array refresh signale script_path modifie');
        $assert->ok(!ref($fallback) && $fallback eq 'cfgprobe.pl',
            'SCRIPT array refresh reste un chemin scalaire utilisable');

        $plugin->unregister;
    }

    # ------------------------------------------------------------------
    # [2] Resouscription EventBus au changement de routes d'évènements
    # ------------------------------------------------------------------
    {
        my ($bot, $bus, $irc, $plugin) = $mk_env->(
            'plugins.ScriptDryRun.ACTION_MODE' => 'apply',
            'plugins.ScriptDryRun.ALLOW_IRC'   => 'yes',
            'plugins.ScriptDryRun.EVENTS'      => 'join=cfgprobe.pl',
        );

        # Route retiree + route ajoutee.
        $bot->{conf}{'plugins.ScriptDryRun.EVENTS'} = 'topic=cfgprobe.pl';
        my @changed = $plugin->refresh_from_conf;
        $assert->ok((grep { $_ eq 'event_routes' } @changed) == 1,
            'event_routes signale comme modifie');

        my $join_report = $bus->emit_report('channel_join_observed',
            { event_type => 'join', channel => '#mb537', nick => 'a', is_self => 0 });
        $assert->ok(($join_report->{ran} || 0) == 0 && @{ $irc->sent } == 0,
            'ancienne route join: listener retire, rien ne tourne');

        $bus->emit_report('channel_topic_observed',
            { event_type => 'topic', channel => '#mb537', nick => 'a',
              topic => 'x', is_self => 0 });
        $assert->ok(@{ $irc->sent } == 1
            && ($irc->sent->[0][3] || '') =~ /probe\[topic\]/,
            'nouvelle route topic: active immediatement');

        # Refresh sans changement de routes: pas de double abonnement.
        $plugin->refresh_from_conf;
        $bus->emit_report('channel_topic_observed',
            { event_type => 'topic', channel => '#mb537b', nick => 'a',
              topic => 'y', is_self => 0 });
        $assert->ok(@{ $irc->sent } == 2, 'pas de doublon de listener apres refresh neutre');

        $plugin->unregister;
        my $after = $bus->emit_report('channel_topic_observed',
            { event_type => 'topic', channel => '#x', nick => 'a', topic => 'z', is_self => 0 });
        $assert->ok(($after->{ran} || 0) == 0, 'unregister retire les listeners resouscrits');
    }

    # ------------------------------------------------------------------
    # [3] Conservation : compteurs, fenêtres, timers (snapshot mb525/mb531)
    # ------------------------------------------------------------------
    my $have_loop = eval { require IO::Async::Loop; 1 };
    if (!$have_loop) {
        $assert->ok(1, 'SKIP conservation: IO::Async::Loop indisponible');
    }
    else {
        my $loop = IO::Async::Loop->new;
        my ($bot, $bus, $irc, $plugin) = $mk_env->(
            'plugins.ScriptDryRun.ACTION_MODE'  => 'apply',
            'plugins.ScriptDryRun.ALLOW_IRC'    => 'yes',
            'plugins.ScriptDryRun.COMMANDS'     => 'pcfg',
            'plugins.ScriptDryRun.ROUTES'       => 'pcfg=cfgprobe.pl',
            'plugins.ScriptDryRun.CONFIG_pcfg'  => 'tag=alpha',
            'plugins.ScriptDryRun.EVENTS'       => 'join=cfgprobe.pl',
        );
        $bot->{loop} = $loop;

        # Fenetre + compteurs via un join, timer via la commande.
        $bus->emit_report('channel_join_observed',
            { event_type => 'join', channel => '#mb537', nick => 'poyan', is_self => 0 });
        $plugin->observe_public_command({
            channel => '#mb537', target => '#mb537', nick => 'poyan',
            command => 'pcfg', args => [],
        });
        $assert->ok(@{ $irc->sent } == 2
            && ($irc->sent->[1][3] || '') =~ /probe\[public_command\] tag=alpha/,
            'commande initiale: tag alpha en direct');
        $assert->ok($bot->script_action_runner->pending_timer_count == 1, 'timer arme');
        my $observed_before = $plugin->observed_events;

        # Changement de config PENDANT que le timer est arme.
        $bot->{conf}{'plugins.ScriptDryRun.CONFIG_pcfg'} = 'tag=omega';
        my @changed = $plugin->refresh_from_conf;
        $assert->ok((grep { $_ eq 'route_configs' } @changed) == 1, 'config signalee modifiee');

        $assert->ok($plugin->observed_events == $observed_before,
            'compteurs conserves au refresh');
        $assert->ok(scalar($plugin->event_cooldown_state) == 1,
            'fenetres de cooldown conservees');
        $assert->ok($bot->script_action_runner->pending_timer_count == 1,
            'timer arme conserve');

        $loop->delay_future(after => 1.6)->get;
        $assert->ok(@{ $irc->sent } == 3
            && ($irc->sent->[2][3] || '') =~ /probe\[timer\] tag=alpha/,
            'le rappel differe livre avec le SNAPSHOT alpha, pas la conf omega');

        # Une NOUVELLE commande voit bien omega.
        $plugin->clear_event_cooldowns;
        $plugin->observe_public_command({
            channel => '#mb537', target => '#mb537', nick => 'poyan',
            command => 'pcfg', args => [],
        });
        $assert->ok(($irc->sent->[3][3] || '') =~ /tag=omega/,
            'une nouvelle execution voit la config rechargee');

        $plugin->unregister;
    }

    # ------------------------------------------------------------------
    # [4] Partyline
    # ------------------------------------------------------------------
    {
        my ($bot, undef, undef, $plugin, $party) = $mk_env->(
            'plugins.ScriptDryRun.COMMANDS' => 'pcfg',
            'plugins.ScriptDryRun.ROUTES'   => 'pcfg=cfgprobe.pl',
        );

        my $s0 = Stream735->new;
        $party->_cmd_scriptdryrun($s0, 1, 'reload');
        $assert->like($s0->out, qr/^ScriptDryRun conf refreshed \(no changes\)/m,
            'partyline: no changes');

        $bot->{conf}{'plugins.ScriptDryRun.ALLOW_IRC'} = 'yes';
        my $s1 = Stream735->new;
        $party->_cmd_scriptdryrun($s1, 1, 'reload');
        $assert->like($s1->out, qr/conf refreshed \(changed: allow_irc\)/,
            'partyline: champs modifies listes');
        $assert->like($s1->out, qr/armed timers keep the config snapshot/,
            'partyline: note snapshot affichee');

        $plugin->unregister;

        my $party2 = bless { bot => Bot735->new(pm => PM735->new(undef)) }, 'Mediabot::Partyline';
        my $s2 = Stream735->new;
        $party2->_cmd_scriptdryrun($s2, 1, 'reload');
        $assert->like($s2->out, qr/ScriptDryRun: not loaded/, 'partyline: not loaded');
    }

    # ------------------------------------------------------------------
    # [5] Gardes de source et de documentation
    # ------------------------------------------------------------------
    {
        my $plugin_src = _slurp_735(File::Spec->catfile('.', 'Mediabot', 'Plugin', 'ScriptDryRun.pm'));
        $assert->like($plugin_src, qr/sub _collect_conf_raw/, 'lecture factorisee presente');
        $assert->like($plugin_src, qr/sub refresh_from_conf/, 'refresh present');
        $assert->ok(() = $plugin_src =~ /SCRIPT_DRYRUN_EVENTS/g,
            'les cles ne sont lues qu\'a UN endroit (factorisation)')
            if ($plugin_src =~ s/SCRIPT_DRYRUN_EVENTS/X/g) == 1;
        $assert->unlike($plugin_src, qr/`[^`]+`/, 'aucun backtick apparie (garde mb203)');

        my $party_src = _slurp_735(File::Spec->catfile('.', 'Mediabot', 'Partyline.pm'));
        $assert->like($party_src, qr/mb537-B1/, 'marqueur mb537 dans Partyline');
        $assert->like($party_src, qr/show external script bridge status and last run/,
            'contrat mb291 conserve');

        my $sample = _slurp_735('mediabot.sample.conf');
        $assert->like($sample, qr/\.scriptdryrun reload/, 'sample conf documente reload');

        my $readme = _slurp_735(File::Spec->catfile('.', 'plugins', 'scripts', 'README.md'));
        $assert->like($readme, qr/\.scriptdryrun reload/, 'README documente reload');
        $assert->like($readme, qr/config snapshot it was armed with/,
            'README: regle du snapshot des timers documentee');
    }
};
