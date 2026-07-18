# t/cases/733_mb535_kick_event_routing.t
# =============================================================================
# mb535 — évènement `kick` routé vers les scripts (extension de la whitelist
# mb529) + exemple de référence kickwatch.pl.
#
# Spécificités du kick contractées ici :
#   - enveloppe : nick = AUTEUR du kick, kicked = VICTIME, message = raison ;
#   - is_self couvre les DEUX rôles : bot auteur (ne se commente pas) ou bot
#     victime (ne peut plus parler dans le canal) → jamais de script ;
#   - l'émission cœur couvre les deux branches du handler (bot kické = rejoin
#     auto, utilisateur kické = nettoyage) — garde statique : 4 hooks ;
#   - le pipeline hérite de tout mb529 : opt-in, cooldown, scope, dry/apply.
#   - `nick` reste volontairement NON supporté (pas de canal unique — hors
#     modèle de scope, cf. passation mb534) : contracté négativement.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

use Mediabot::EventBus;
use Mediabot::ScriptRunner;
use Mediabot::ScriptActionRunner;
use Mediabot::Plugin::ScriptDryRun;

sub _slurp_733 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

{ package L733; sub new { bless {}, shift } sub log { 1 } }

{
    package IRC733;
    sub new { bless { sent => [] }, shift }
    sub send_message { my ($self, @args) = @_; push @{ $self->{sent} }, \@args; 1 }
    sub sent { $_[0]->{sent} }
}

{
    package Bot733;
    sub new { my ($class, %h) = @_; bless {%h, logger => L733->new}, $class }
    sub events               { $_[0]->{event_bus} }
    sub script_runner        { $_[0]->{script_runner} }
    sub script_action_runner { $_[0]->{script_action_runner} }
    sub getLoop              { undef }
    sub run_script_actions_dry { die "dry path must not run in apply mode" }
}

my $examples = File::Spec->catdir('plugins', 'scripts', 'examples');

return sub {
    my ($assert) = @_;

    # ------------------------------------------------------------------
    # Cœur : émission kick avec le champ kicked, garde statique des hooks
    # ------------------------------------------------------------------
    {
        my $core_ok = eval { require Mediabot::Mediabot; 1 };
        if ($core_ok) {
            my $bus = Mediabot::EventBus->new;
            my @seen;
            $bus->on(channel_kick_observed => sub { push @seen, $_[0]; 1 }, name => 'mb535-probe');

            my $core = bless { event_bus => $bus, logger => L733->new }, 'Mediabot';
            $core->observe_channel_event('kick',
                channel => '#mb535', nick => 'opnick', kicked => 'poyan',
                message => 'flood', is_self => 0);

            $assert->ok(@seen == 1, 'coeur: listener kick notifie');
            my $ctx = $seen[0] || {};
            $assert->ok(($ctx->{event_type} || '') eq 'kick'
                && ($ctx->{nick} || '') eq 'opnick'
                && ($ctx->{kicked} || '') eq 'poyan'
                && ($ctx->{message} || '') eq 'flood',
                'coeur: auteur, victime et raison transmis');
        }
        else {
            $assert->ok(1, 'SKIP coeur: Mediabot::Mediabot non chargeable ici');
        }

        my $main_src = _slurp_733('mediabot.pl');
        $assert->like($main_src, qr/eval \{ \$mediabot->observe_channel_event\('kick',/,
            'mediabot.pl: emission kick cablee sous eval');
        $assert->like($main_src, qr/is_nick_me\(\$kicker_nick\) \|\| \$self->is_nick_me\(\$kicked_nick\)/,
            'mediabot.pl: is_self couvre auteur ET victime');
    }

    # ------------------------------------------------------------------
    # Plugin : route kick, enveloppe, is_self, dry-run
    # ------------------------------------------------------------------
    {
        my $bus = Mediabot::EventBus->new;
        my $irc = IRC733->new;
        my $conf = {
            'plugins.ScriptDryRun.ACTION_MODE' => 'apply',
            'plugins.ScriptDryRun.ALLOW_IRC'   => 'yes',
            'plugins.ScriptDryRun.EVENTS'      => 'kick=kickwatch.pl',
        };
        my $bot = Bot733->new(irc => $irc, conf => $conf, event_bus => $bus);
        $bot->{script_runner} = Mediabot::ScriptRunner->new(
            bot => $bot, script_dir => $examples, timeout => 5, max_stdout_bytes => 65536);
        $bot->{script_action_runner} = Mediabot::ScriptActionRunner->new(bot => $bot);
        my $plugin = Mediabot::Plugin::ScriptDryRun->register($bot);

        $assert->ok(join(',', $plugin->event_route_list) eq 'kick',
            'plugin: kick accepte par la whitelist');

        # Kick réel appliqué dans le canal, avec raison citée.
        $bus->emit_report('channel_kick_observed',
            { event_type => 'kick', channel => '#mb535', nick => 'opnick',
              kicked => 'poyan', message => 'flood', is_self => 0 });
        $assert->ok(@{ $irc->sent } == 1
            && ($irc->sent->[0][2] || '') eq '#mb535'
            && ($irc->sent->[0][3] || '') eq 'poyan was shown the door by opnick ("flood")',
            'pipeline: trace de moderation dans le canal du kick');

        # is_self (bot auteur ou victime) : jamais de script.
        $bus->emit_report('channel_kick_observed',
            { event_type => 'kick', channel => '#mb535b', nick => 'mediabot',
              kicked => 'poyan', message => 'x', is_self => 1 });
        $assert->ok(@{ $irc->sent } == 1
            && ($plugin->{last_error} || '') =~ /self kick event/,
            'is_self: kick du bot (auteur ou victime) ignore avec raison');

        # Sans raison : pas de parenthèse (cooldown par canal : autre canal).
        $bus->emit_report('channel_kick_observed',
            { event_type => 'kick', channel => '#mb535c', nick => 'opnick',
              kicked => 'teuk2', is_self => 0 });
        $assert->ok(@{ $irc->sent } == 2
            && ($irc->sent->[1][3] || '') eq 'teuk2 was shown the door by opnick',
            'kickwatch: sans raison, pas de parenthese');

        # nick n'est PAS supporté (contrat négatif, cf. passation).
        my ($bot2) = Bot733->new(event_bus => Mediabot::EventBus->new, conf => {
            'plugins.ScriptDryRun.EVENTS' => 'nick=kickwatch.pl, kick=kickwatch.pl',
        });
        $bot2->{script_runner} = $bot->{script_runner};
        $bot2->{script_action_runner} = $bot->{script_action_runner};
        my $plugin2 = Mediabot::Plugin::ScriptDryRun->register($bot2);
        $assert->ok(join(',', $plugin2->event_route_list) eq 'kick',
            'whitelist: nick reste refuse (pas de canal unique)');
        $plugin2->unregister;

        $plugin->unregister;
    }

    # Mauvais routage : silence IRC.
    {
        my $runner = Mediabot::ScriptRunner->new(script_dir => $examples, timeout => 5);
        my $r = $runner->run_script('kickwatch.pl', 'join',
            channel => '#mb535', target => '#mb535', nick => 'x', args => []);
        my $actions = $r->{response}{actions} || [];
        my @replies = grep { ($_->{type} || '') eq 'reply' } @$actions;
        $assert->ok($r->{ok} && @$actions == 1 && !@replies
            && ($actions->[0]{level} || '') eq 'warning',
            'kickwatch mal route: log warning, silence IRC');

        my $src = _slurp_733(File::Spec->catfile($examples, 'kickwatch.pl'));
        $assert->like($src, qr/mediabot-script-v1/, 'kickwatch declare le protocole');
        $assert->like($src, qr/ok\s*=>\s*JSON::PP::true/, 'kickwatch emet ok explicitement');
    }

    # ------------------------------------------------------------------
    # Gardes de documentation
    # ------------------------------------------------------------------
    {
        my $sample = _slurp_733('mediabot.sample.conf');
        $assert->like($sample, qr/supported events: join, part, topic, kick;/,
            'sample: whitelist a jour');
        $assert->like($sample, qr/kick=examples\/kickwatch\.pl/, 'sample: route kick documentee');

        my $readme = _slurp_733(File::Spec->catfile('.', 'plugins', 'scripts', 'README.md'));
        $assert->like($readme, qr/## Channel events \(join\/part\/topic\/kick\)/,
            'README: titre de section a jour');
        $assert->like($readme, qr/kickwatch\.pl.*kicked.*victim/s,
            'README: champs specifiques du kick documentes');
    }
};
