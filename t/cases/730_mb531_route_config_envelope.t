# t/cases/730_mb531_route_config_envelope.t
# =============================================================================
# mb531 — configuration par route dans l'enveloppe JSON (piste D de l'arc).
#
# Une route (commande OU évènement) peut porter sa propre configuration via
# CONFIG_<route>="key=value; key2=value2". La map validée est injectée dans
# l'enveloppe sous data.config, uniquement si non vide, et voyage avec les
# rappels timer (snapshot mb525).
#
# Contrats :
#   [1] parsing plugin : format ';' (virgules autorisées dans les valeurs,
#       fragments Config::Simple rejoints), clés [A-Za-z0-9_.-]{1,64},
#       valeurs ≤ 512 (paire REJETÉE au-delà, jamais tronquée), cap 20 clés,
#       copie défensive via route_config() ;
#   [2] normalisation runner : la clé réservée 'config' accepte un HASH d'UN
#       niveau (refs internes écartées) ; le contrat mb289 des AUTRES champs
#       est inchangé (HASH arbitraire -> null) ;
#   [3] pipeline : injection sur commande et sur évènement, absence de champ
#       quand rien n'est configuré, config transportée par un rappel timer ;
#   [4] exemple : greet.pl utilise config.welcome avec défaut inchangé ;
#   [5] partyline : status expose config_routes ;
#   [6] docs : sample.conf + README.
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

sub _slurp_730 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

{ package L730; sub new { bless {}, shift } sub log { 1 } }

{
    package IRC730;
    sub new { bless { sent => [] }, shift }
    sub send_message { my ($self, @args) = @_; push @{ $self->{sent} }, \@args; 1 }
    sub sent { $_[0]->{sent} }
}

{
    package PM730;
    sub new { my ($class, $plugin) = @_; bless { plugin => $plugin }, $class }
    sub object_for {
        my ($self, $name) = @_;
        return $self->{plugin} if $name eq 'Mediabot::Plugin::ScriptDryRun';
        return undef;
    }
}

{
    package Bot730;
    sub new { my ($class, %h) = @_; bless {%h, logger => L730->new}, $class }
    sub events               { $_[0]->{event_bus} }
    sub plugin_manager       { $_[0]->{pm} }
    sub script_runner        { $_[0]->{script_runner} }
    sub script_action_runner { $_[0]->{script_action_runner} }
    sub getLoop              { $_[0]->{loop} }
    sub run_script_actions_dry { die "dry path must not run in apply mode" }
}

# Fixture : renvoie le contenu de data.config dans une reply, et sur commande
# arme un timer pour prouver que la config voyage avec le rappel.
my $script_dir = tempdir('mediabot_mb531_XXXXXX', TMPDIR => 1, CLEANUP => 1);
{
    my $path = File::Spec->catfile($script_dir, 'cfgecho.pl');
    open my $fh, '>:encoding(UTF-8)', $path or die "cannot create $path: $!";
    print {$fh} <<'FIX';
#!/usr/bin/env perl
use strict; use warnings;
use JSON::PP qw(decode_json encode_json);
my $p = eval { decode_json(do { local $/; <STDIN> } || '{}') } || {};
my $d = ref($p->{data}) eq 'HASH' ? $p->{data} : {};
my $ev = $p->{event} // 'unknown';
my $cfg = ref($d->{config}) eq 'HASH' ? $d->{config} : {};
my $dump = join('|', map { "$_=$cfg->{$_}" } sort keys %$cfg);
$dump = '(none)' unless length $dump;
my @actions = ( { type => 'reply', text => "cfg[$ev]: $dump" } );
push @actions, { type => 'timer', name => 'cfg_probe', delay => 1 }
    if $ev ne 'timer';
print encode_json({ protocol => 'mediabot-script-v1', ok => JSON::PP::true, actions => \@actions });
FIX
    close $fh or die "cannot close $path: $!";
}

my $mk_bot = sub {
    my (%conf_extra) = @_;
    my $bus = Mediabot::EventBus->new;
    my $irc = IRC730->new;
    my $conf = {
        'plugins.ScriptDryRun.ACTION_MODE' => 'apply',
        'plugins.ScriptDryRun.ALLOW_IRC'   => 'yes',
        %conf_extra,
    };
    my $bot = Bot730->new(irc => $irc, conf => $conf, event_bus => $bus);
    $bot->{script_runner} = Mediabot::ScriptRunner->new(
        bot => $bot, script_dir => $script_dir, timeout => 5, max_stdout_bytes => 65536);
    $bot->{script_action_runner} = Mediabot::ScriptActionRunner->new(bot => $bot);
    return ($bot, $bus, $irc);
};

return sub {
    my ($assert) = @_;

    # ------------------------------------------------------------------
    # [1] Parsing plugin
    # ------------------------------------------------------------------
    {
        my ($bot) = $mk_bot->(
            'plugins.ScriptDryRun.COMMANDS'     => 'pcfg',
            'plugins.ScriptDryRun.ROUTES'       => 'pcfg=cfgecho.pl',
            'plugins.ScriptDryRun.CONFIG_pcfg'  =>
                'greeting=Bonjour, à tous; max=5; bad key=x; empty=; keep.dots-and_underscores=ok',
        );
        my $plugin = Mediabot::Plugin::ScriptDryRun->register($bot);

        my $cfg = $plugin->route_config('pcfg');
        $assert->ok(($cfg->{greeting} || '') eq 'Bonjour, à tous',
            'valeur avec virgule reconstituee (fragments Config::Simple rejoints)');
        $assert->ok(($cfg->{max} || '') eq '5', 'paire simple parsee');
        $assert->ok(($cfg->{'keep.dots-and_underscores'} || '') eq 'ok',
            'cle avec points/tirets/underscores acceptee');
        $assert->ok(exists $cfg->{empty} && $cfg->{empty} eq '',
            'valeur vide autorisee (cle presente)');
        $assert->ok(!exists $cfg->{'bad key'}, 'cle avec espace rejetee');
        $assert->ok(join(',', $plugin->configured_routes) eq 'pcfg',
            'configured_routes expose la route');

        # Copie defensive.
        $cfg->{max} = 'mute';
        $assert->ok($plugin->route_config('pcfg')->{max} eq '5',
            'route_config retourne une copie (pas de mutation possible)');

        # Valeur trop longue: paire rejetee, jamais tronquee.
        my ($bot2) = $mk_bot->(
            'plugins.ScriptDryRun.COMMANDS'    => 'pcfg',
            'plugins.ScriptDryRun.ROUTES'      => 'pcfg=cfgecho.pl',
            'plugins.ScriptDryRun.CONFIG_pcfg' => 'big=' . ('x' x 600) . '; ok=1',
        );
        my $plugin2 = Mediabot::Plugin::ScriptDryRun->register($bot2);
        my $cfg2 = $plugin2->route_config('pcfg');
        $assert->ok(!exists $cfg2->{big} && ($cfg2->{ok} || '') eq '1',
            'valeur >512 rejetee entierement, le reste conserve');

        # Cap de 20 cles.
        my ($bot3) = $mk_bot->(
            'plugins.ScriptDryRun.COMMANDS'    => 'pcfg',
            'plugins.ScriptDryRun.ROUTES'      => 'pcfg=cfgecho.pl',
            'plugins.ScriptDryRun.CONFIG_pcfg' => join('; ', map { "k$_=$_" } 1 .. 25),
        );
        my $plugin3 = Mediabot::Plugin::ScriptDryRun->register($bot3);
        $assert->ok(scalar(keys %{ $plugin3->route_config('pcfg') }) == 20,
            'cap de 20 cles par route');

        # Route sans config / route inconnue -> hash vide.
        $assert->ok(!%{ $plugin->route_config('join') } && !%{ $plugin->route_config('') },
            'route sans config -> map vide');
        $plugin->unregister; $plugin2->unregister; $plugin3->unregister;
    }

    # ------------------------------------------------------------------
    # [2] Normalisation runner : exception 'config', contrat mb289 preserve
    # ------------------------------------------------------------------
    {
        my $runner = Mediabot::ScriptRunner->new(script_dir => $script_dir, timeout => 5);
        my $payload = $runner->build_event_payload('join',
            channel => '#mb531',
            config  => { ok => 'yes', 'bad key' => 'x', nested => { deep => 1 }, big => ('y' x 600) },
            other   => { must => 'not leak' },
        );
        my $cfg = $payload->{data}{config};
        $assert->ok(ref($cfg) eq 'HASH' && ($cfg->{ok} || '') eq 'yes',
            'runner: la cle reservee config traverse en HASH');
        $assert->ok(!exists $cfg->{'bad key'} && !exists $cfg->{nested} && !exists $cfg->{big},
            'runner: cles invalides, refs imbriquees et valeurs >512 ecartees');
        $assert->ok(exists $payload->{data}{other} && !defined $payload->{data}{other},
            'runner: contrat mb289 inchange pour les autres champs (HASH -> null)');
    }

    # ------------------------------------------------------------------
    # [3] Pipeline : commande, evenement, absence, voyage timer
    # ------------------------------------------------------------------
    my $have_loop = eval { require IO::Async::Loop; 1 };
    if (!$have_loop) {
        $assert->ok(1, 'SKIP pipeline: IO::Async::Loop indisponible');
    }
    else {
        my $loop = IO::Async::Loop->new;
        my ($bot, $bus, $irc) = $mk_bot->(
            'plugins.ScriptDryRun.COMMANDS'     => 'pcfg',
            'plugins.ScriptDryRun.ROUTES'       => 'pcfg=cfgecho.pl',
            'plugins.ScriptDryRun.EVENTS'       => 'topic=cfgecho.pl',
            'plugins.ScriptDryRun.CONFIG_pcfg'  => 'mode=fast; label=Équipe A',
            'plugins.ScriptDryRun.CONFIG_topic' => 'watch=on',
        );
        $bot->{loop} = $loop;
        my $plugin = Mediabot::Plugin::ScriptDryRun->register($bot);

        # Commande: config injectee.
        $plugin->observe_public_command({
            channel => '#mb531', target => '#mb531', nick => 'poyan',
            command => 'pcfg', args => [],
        });
        $assert->ok(@{ $irc->sent } == 1
            && ($irc->sent->[0][3] || '') =~ /cfg\[pcfg\]: label=Équipe A\|mode=fast/,
            'commande: data.config injectee (tri stable, UTF-8 intact)');

        # Voyage timer: le rappel differe revoit la MEME config.
        $assert->ok($bot->script_action_runner->pending_timer_count == 1,
            'timer arme par la commande');
        $loop->delay_future(after => 1.6)->get;
        $assert->ok(@{ $irc->sent } == 2
            && ($irc->sent->[1][3] || '') =~ /cfg\[timer\]: label=Équipe A\|mode=fast/,
            'timer: la config voyage avec le rappel differe (snapshot mb525)');

        # Evenement: config de la route topic.
        $bus->emit_report('channel_topic_observed',
            { event_type => 'topic', channel => '#mb531b', nick => 'Te[u]K',
              topic => 'x', is_self => 0 });
        $assert->ok(@{ $irc->sent } == 3
            && ($irc->sent->[2][3] || '') =~ /cfg\[topic\]: watch=on/,
            'evenement: data.config injectee depuis CONFIG_topic');

        $plugin->unregister;

        # Sans CONFIG_: champ absent de l'enveloppe (le script voit (none)).
        my ($bot2, $bus2, $irc2) = $mk_bot->(
            'plugins.ScriptDryRun.COMMANDS' => 'pcfg',
            'plugins.ScriptDryRun.ROUTES'   => 'pcfg=cfgecho.pl',
        );
        my $plugin2 = Mediabot::Plugin::ScriptDryRun->register($bot2);
        $plugin2->observe_public_command({
            channel => '#mb531', target => '#mb531', nick => 'poyan',
            command => 'pcfg', args => [],
        });
        $assert->ok(@{ $irc2->sent } == 1
            && ($irc2->sent->[0][3] || '') =~ /cfg\[pcfg\]: \(none\)/,
            'sans CONFIG_: pas de champ config dans l\'enveloppe');
        $plugin2->unregister;
    }

    # ------------------------------------------------------------------
    # [4] Exemple greet.pl : welcome configurable, defaut inchange
    # ------------------------------------------------------------------
    {
        my $examples = File::Spec->catdir('plugins', 'scripts', 'examples');
        my $runner = Mediabot::ScriptRunner->new(script_dir => $examples, timeout => 5);

        my $r_default = $runner->run_script('greet.pl', 'join',
            channel => '#mb531', target => '#mb531', nick => 'poyan', args => []);
        my ($reply_d) = grep { $_->{type} eq 'reply' } @{ $r_default->{response}{actions} || [] };
        $assert->like(($reply_d->{text} || ''), qr/welcome to #mb531, poyan!/,
            'greet sans config: defaut mb530 inchange');

        my $r_custom = $runner->run_script('greet.pl', 'join',
            channel => '#mb531', target => '#mb531', nick => 'poyan', args => [],
            config => { welcome => 'Bienvenue sur ce canal,' });
        my ($reply_c) = grep { $_->{type} eq 'reply' } @{ $r_custom->{response}{actions} || [] };
        $assert->like(($reply_c->{text} || ''), qr/Bienvenue sur ce canal, poyan!/,
            'greet avec config.welcome: message personnalise');
    }

    # ------------------------------------------------------------------
    # [5] Partyline : status expose config_routes
    # ------------------------------------------------------------------
    {
        {
            package Stream730;
            sub new { bless { out => '' }, shift }
            sub write { $_[0]->{out} .= $_[1]; 1 }
            sub out { $_[0]->{out} }
        }
        my ($bot, $bus, $irc) = $mk_bot->(
            'plugins.ScriptDryRun.COMMANDS'    => 'pcfg',
            'plugins.ScriptDryRun.ROUTES'      => 'pcfg=cfgecho.pl',
            'plugins.ScriptDryRun.CONFIG_pcfg' => 'mode=fast',
        );
        my $plugin = Mediabot::Plugin::ScriptDryRun->register($bot);
        $bot->{pm} = PM730->new($plugin);
        my $party = bless { bot => $bot }, 'Mediabot::Partyline';
        my $s = Stream730->new;
        $party->_cmd_scriptdryrun($s, 1, 'status');
        $assert->like($s->out, qr/config_routes: pcfg/, 'status: routes configurees listees');
        $plugin->unregister;

        my ($bot2) = $mk_bot->();
        my $plugin2 = Mediabot::Plugin::ScriptDryRun->register($bot2);
        $bot2->{pm} = PM730->new($plugin2);
        my $party2 = bless { bot => $bot2 }, 'Mediabot::Partyline';
        my $s2 = Stream730->new;
        $party2->_cmd_scriptdryrun($s2, 1, 'status');
        $assert->like($s2->out, qr/config_routes: none/, 'status: none sans config');
        $plugin2->unregister;
    }

    # ------------------------------------------------------------------
    # [6] Gardes de source et de documentation
    # ------------------------------------------------------------------
    {
        my $plugin_src = _slurp_730(File::Spec->catfile('.', 'Mediabot', 'Plugin', 'ScriptDryRun.pm'));
        $assert->like($plugin_src, qr/mb531-B1/, 'marqueur mb531 dans ScriptDryRun');
        $assert->unlike($plugin_src, qr/`[^`]+`/, 'aucun backtick apparie (garde mb203)');

        my $runner_src = _slurp_730(File::Spec->catfile('.', 'Mediabot', 'ScriptRunner.pm'));
        $assert->like($runner_src, qr/sub _normalize_config_map/, 'normaliseur config present');
        $assert->unlike($runner_src, qr/`[^`]+`/, 'runner: aucun backtick apparie');

        my $sample = _slurp_730('mediabot.sample.conf');
        $assert->like($sample, qr/^## CONFIG_join=welcome=/m, 'sample conf documente CONFIG_');
        $assert->like($sample, qr/data\.config/, 'sample conf explique data.config');

        my $readme = _slurp_730(File::Spec->catfile('.', 'plugins', 'scripts', 'README.md'));
        $assert->like($readme, qr/## Per-route configuration/, 'README: section config par route');
        $assert->like($readme, qr/only\s+structured envelope fields/, 'README: contrat des champs structures documente (config + network, mb552)');
    }
};
