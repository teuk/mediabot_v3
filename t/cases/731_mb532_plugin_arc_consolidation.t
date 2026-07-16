# t/cases/731_mb532_plugin_arc_consolidation.t
# =============================================================================
# mb532 — round de consolidation de l'arc plugins : trois incohérences
# trouvées à l'audit transversal de la couche, corrigées et contractées.
#
#   [A] la référence partyline `.scriptdryrun config` ne documentait AUCUNE
#       des clés introduites depuis mb529 : EVENTS, EVENT_COOLDOWN,
#       CONFIG_<route>. La référence est complétée et un contrat générique
#       est ajouté : toute clé `plugins.ScriptDryRun.*` lue par le plugin
#       (_conf_get_first) doit apparaître dans la sortie du mode config ;
#   [B] sample.conf documentait `## CONFIG_premind=max_delay=1800` mais
#       remind.pl ignorait data.config — le pattern exact du bug mb530
#       (doc → comportement fantôme). remind.pl honore désormais
#       config.max_delay (plancher/plafond protocolaires toujours gagnants) ;
#   [C] `.scriptdryrun status|last` n'indiquait pas l'ORIGINE du dernier run
#       alors que mb525/mb529 en ont créé trois sortes ; ligne `origin:`
#       (command | event:<type> | timer:<name>).
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

sub _slurp_731 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

{ package L731; sub new { bless {}, shift } sub log { 1 } }

{
    package Stream731;
    sub new { bless { out => '' }, shift }
    sub write { $_[0]->{out} .= $_[1]; 1 }
    sub out { $_[0]->{out} }
}

{
    package IRC731;
    sub new { bless { sent => [] }, shift }
    sub send_message { my ($self, @args) = @_; push @{ $self->{sent} }, \@args; 1 }
    sub sent { $_[0]->{sent} }
}

{
    package PM731;
    sub new { my ($class, $plugin) = @_; bless { plugin => $plugin }, $class }
    sub object_for {
        my ($self, $name) = @_;
        return $self->{plugin} if $name eq 'Mediabot::Plugin::ScriptDryRun';
        return undef;
    }
}

{
    package Bot731;
    sub new { my ($class, %h) = @_; bless {%h, logger => L731->new}, $class }
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
    my $irc = IRC731->new;
    my $conf = {
        'plugins.ScriptDryRun.ACTION_MODE' => 'apply',
        'plugins.ScriptDryRun.ALLOW_IRC'   => 'yes',
        %conf_extra,
    };
    my $bot = Bot731->new(irc => $irc, conf => $conf, event_bus => $bus);
    $bot->{script_runner} = Mediabot::ScriptRunner->new(
        bot => $bot, script_dir => $examples, timeout => 5, max_stdout_bytes => 65536);
    $bot->{script_action_runner} = Mediabot::ScriptActionRunner->new(bot => $bot);
    my $plugin = Mediabot::Plugin::ScriptDryRun->register($bot);
    $bot->{pm} = PM731->new($plugin);
    my $party = bless { bot => $bot }, 'Mediabot::Partyline';
    return ($bot, $bus, $irc, $plugin, $party);
};

return sub {
    my ($assert) = @_;

    # ------------------------------------------------------------------
    # [A] Référence partyline complète — dont contrat générique
    # ------------------------------------------------------------------
    {
        my (undef, undef, undef, $plugin, $party) = $mk_env->();
        my $s = Stream731->new;
        $party->_cmd_scriptdryrun($s, 1, 'config');
        my $out = $s->out;

        for my $key (qw(EVENTS EVENT_COOLDOWN)) {
            $assert->like($out, qr/plugins\.ScriptDryRun\.\Q$key\E/,
                "config: cle $key documentee");
        }
        $assert->like($out, qr/plugins\.ScriptDryRun\.CONFIG_<route>/,
            'config: cle CONFIG_<route> documentee');
        $assert->like($out, qr/join\/part\/topic only, no SCRIPT fallback/,
            'config: whitelist des evenements rappelee');
        $assert->like($out, qr/one run per event per channel per window/,
            'config: cooldown explique');
        $assert->like($out, qr/injected as data\.config only when non-empty/,
            'config: livraison data.config expliquee');

        # Contrat générique anti-oubli : toute clé plugins.ScriptDryRun.* lue
        # par le plugin doit apparaître dans la sortie du mode config. Une
        # future clé mb53x oubliée fera échouer CE test, pas un audit manuel.
        my $plugin_src = _slurp_731(File::Spec->catfile('.', 'Mediabot', 'Plugin', 'ScriptDryRun.pm'));
        my %read_keys;
        while ($plugin_src =~ /'plugins\.ScriptDryRun\.([A-Za-z_]+)'/g) {
            $read_keys{$1} = 1;
        }
        $read_keys{'CONFIG_<route>'} = 1 if $plugin_src =~ /"plugins\.ScriptDryRun\.CONFIG_\$name"/;
        $assert->ok(scalar(keys %read_keys) >= 9,
            'contrat generique: au moins neuf cles lues par le plugin recensees');
        for my $key (sort keys %read_keys) {
            next if $key ne uc($key) && $key ne 'CONFIG_<route>';  # alias lowercase: variante d'une cle canonique
            $assert->like($out, qr/plugins\.ScriptDryRun\.\Q$key\E/,
                "contrat generique: cle lue '$key' presente dans la reference");
        }

        $plugin->unregister;
    }

    # ------------------------------------------------------------------
    # [B] remind.pl honore config.max_delay (la doc sample devient vraie)
    # ------------------------------------------------------------------
    {
        my $runner = Mediabot::ScriptRunner->new(script_dir => $examples, timeout => 5);

        # Sans config: comportement mb528 inchangé (300s accepté, 4000 refusé).
        my $r_ok = $runner->run_script('remind.pl', 'public_command',
            channel => '#mb532', target => '#mb532', nick => 'poyan',
            command => 'premind', args => [ '300', 'tea' ]);
        my ($t_ok) = grep { $_->{type} eq 'timer' } @{ $r_ok->{response}{actions} || [] };
        $assert->ok($t_ok && $t_ok->{delay} == 300, 'sans config: 300s accepte (mb528 inchange)');

        # Avec max_delay=1800 (la valeur documentée): 300 passe, 2000 refusé
        # avec un usage qui annonce la borne EFFECTIVE.
        my %cfg = (config => { max_delay => '1800' });
        my $r_low = $runner->run_script('remind.pl', 'public_command',
            channel => '#mb532', target => '#mb532', nick => 'poyan',
            command => 'premind', args => [ '300', 'tea' ], %cfg);
        my ($t_low) = grep { $_->{type} eq 'timer' } @{ $r_low->{response}{actions} || [] };
        $assert->ok($t_low && $t_low->{delay} == 300, 'config 1800: 300s accepte');

        my $r_high = $runner->run_script('remind.pl', 'public_command',
            channel => '#mb532', target => '#mb532', nick => 'poyan',
            command => 'premind', args => [ '2000', 'tea' ], %cfg);
        my $actions = $r_high->{response}{actions} || [];
        my @timers = grep { ($_->{type} || '') eq 'timer' } @$actions;
        $assert->ok(!@timers, 'config 1800: 2000s refuse');
        $assert->like(($actions->[0]{text} || ''), qr/usage: premind <seconds 1-1800>/,
            'config 1800: l\'usage annonce la borne effective');

        # Une config au-dela du protocole ne peut PAS l'assouplir.
        my $r_abuse = $runner->run_script('remind.pl', 'public_command',
            channel => '#mb532', target => '#mb532', nick => 'poyan',
            command => 'premind', args => [ '4000', 'tea' ],
            config => { max_delay => '9999' });
        my @t_abuse = grep { ($_->{type} || '') eq 'timer' } @{ $r_abuse->{response}{actions} || [] };
        $assert->ok(!@t_abuse, 'config 9999: le plafond protocolaire 3600 gagne toujours');

        # Valeur invalide: retour au defaut, pas de crash.
        my $r_bad = $runner->run_script('remind.pl', 'public_command',
            channel => '#mb532', target => '#mb532', nick => 'poyan',
            command => 'premind', args => [ '300', 'tea' ],
            config => { max_delay => 'soon' });
        my ($t_bad) = grep { $_->{type} eq 'timer' } @{ $r_bad->{response}{actions} || [] };
        $assert->ok($t_bad && $t_bad->{delay} == 300, 'config invalide: defaut protocolaire conserve');
    }

    # ------------------------------------------------------------------
    # [C] Ligne origin dans status/last
    # ------------------------------------------------------------------
    {
        my ($bot, $bus, $irc, $plugin, $party) = $mk_env->(
            'plugins.ScriptDryRun.COMMANDS' => 'premind',
            'plugins.ScriptDryRun.ROUTES'   => 'premind=remind.pl',
            'plugins.ScriptDryRun.EVENTS'   => 'join=greet.pl',
        );

        # Run de commande -> origin: command.
        $plugin->observe_public_command({
            channel => '#mb532', target => '#mb532', nick => 'poyan',
            command => 'premind', args => [],
        });
        my $s1 = Stream731->new;
        $party->_cmd_scriptdryrun($s1, 1, 'status');
        $assert->like($s1->out, qr/^  origin: command\r?$/m, 'origin: command apres une commande');

        # Run d'evenement -> origin: event:join (visible aussi en mode last).
        $bus->emit_report('channel_join_observed',
            { event_type => 'join', channel => '#mb532', nick => 'poyan', is_self => 0 });
        my $s2 = Stream731->new;
        $party->_cmd_scriptdryrun($s2, 1, 'last');
        $assert->like($s2->out, qr/^  origin: event:join\r?$/m, 'origin: event:join apres un join');

        # Run differe -> origin: timer:<name> (via _fire_script_timer direct,
        # sans attendre une vraie expiration).
        $plugin->_fire_script_timer('remind.pl',
            { name => 'remind_poyan', delay => 60 },
            { channel => '#mb532', target => '#mb532', nick => 'poyan',
              command => 'premind', args => [ '60', 'tea' ] });
        my $s3 = Stream731->new;
        $party->_cmd_scriptdryrun($s3, 1, 'status');
        $assert->like($s3->out, qr/^  origin: timer:remind_poyan\r?$/m,
            'origin: timer:<name> apres un rappel differe');

        $plugin->unregister;
    }

    # ------------------------------------------------------------------
    # Gardes de documentation
    # ------------------------------------------------------------------
    {
        my $remind_src = _slurp_731(File::Spec->catfile($examples, 'remind.pl'));
        $assert->like($remind_src, qr/config->\{max_delay\}/, 'remind.pl lit config.max_delay');
        $assert->like($remind_src, qr/mb532/, 'marqueur mb532 dans remind.pl');

        my $party_src = _slurp_731(File::Spec->catfile('.', 'Mediabot', 'Partyline.pm'));
        $assert->like($party_src, qr/mb532-B1/, 'marqueur mb532 dans Partyline');
    }
};
