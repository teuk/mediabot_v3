# t/cases/742_mb545_topic_action_gate.t
# =============================================================================
# mb545 — action « topic » du protocole : un script peut changer le topic de
# son canal D'ORIGINE, derrière une gate dédiée.
#
# Design fail-closed contracté ici :
#   [1] validation : AUCUN champ target accepté (pas de version cross-canal
#       possible par construction), contexte canal obligatoire, texte ≤ 300 ;
#   [2] triple gate à l'application : apply + allow_irc + ALLOW_TOPIC (défaut
#       non) — chaque refus a son erreur distincte ;
#   [3] apply réel : TOPIC envoyé au canal du contexte, y compris depuis le
#       pipeline évènement ; dry-run planifie sans envoyer ;
#   [4] intégration mb537 : ALLOW_TOPIC est hot-reloadable (lu dans
#       _collect_conf_raw) et le refresh signale son changement ;
#   [5] visibilité : status affiche allow_topic, la référence config documente
#       la clé (le contrat générique 731 la vérifie déjà — assertion locale
#       en plus), sample.conf/README/cookbook documentés.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;
use File::Temp qw(tempdir);
use Encode qw(encode);

use Mediabot::EventBus;
use Mediabot::Partyline;
use Mediabot::ScriptRunner;
use Mediabot::ScriptActionRunner;
use Mediabot::Plugin::ScriptDryRun;

sub _slurp_742 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

{ package L742; sub new { bless {}, shift } sub log { 1 } }

{
    package IRC742;
    sub new { bless { sent => [] }, shift }
    sub send_message { my ($self, @args) = @_; push @{ $self->{sent} }, \@args; 1 }
    sub sent { $_[0]->{sent} }
}

{
    package PM742;
    sub new { my ($class, $plugin) = @_; bless { plugin => $plugin }, $class }
    sub object_for {
        my ($self, $name) = @_;
        return $self->{plugin} if $name eq 'Mediabot::Plugin::ScriptDryRun';
        return undef;
    }
}

{
    package Bot742;
    sub new { my ($class, %h) = @_; bless {%h, logger => L742->new}, $class }
    sub events               { $_[0]->{event_bus} }
    sub plugin_manager       { $_[0]->{pm} }
    sub script_runner        { $_[0]->{script_runner} }
    sub script_action_runner { $_[0]->{script_action_runner} }
    sub getLoop              { undef }
    sub run_script_actions_dry {
        my ($self, $script, $event, %data) = @_;
        my $script_result = $self->{script_runner}->run_script($script, $event, %data);
        my $action_plan   = $self->{script_action_runner}->apply_actions_dry(
            $script_result,
            { event => $event, channel => $data{channel}, target => $data{target},
              nick => $data{nick}, args => $data{args} });
        return { ok => ($script_result->{ok} && $action_plan->{ok}) ? 1 : 0,
                 dry_run => 1, script_result => $script_result, action_plan => $action_plan };
    }
}

# Fixture : émet une action topic (texte depuis les args ou le topic reçu).
my $script_dir = tempdir('mediabot_mb545_XXXXXX', TMPDIR => 1, CLEANUP => 1);
{
    my $path = File::Spec->catfile($script_dir, 'settopic.pl');
    open my $fh, '>:encoding(UTF-8)', $path or die "cannot create $path: $!";
    print {$fh} <<'FIX';
#!/usr/bin/env perl
use strict; use warnings;
use JSON::PP qw(decode_json encode_json);
my $p = eval { decode_json(do { local $/; <STDIN> } || '{}') } || {};
my $d = ref($p->{data}) eq 'HASH' ? $p->{data} : {};
my $args = ref($d->{args}) eq 'ARRAY' ? $d->{args} : [];
my $text = @$args ? join(' ', @$args) : ($d->{topic} // 'default topic');
print encode_json({ protocol => 'mediabot-script-v1', ok => JSON::PP::true,
    actions => [ { type => 'topic', text => $text } ] });
FIX
    close $fh or die "cannot close $path: $!";
}

return sub {
    my ($assert) = @_;

    my $ar = Mediabot::ScriptActionRunner->new;

    # ------------------------------------------------------------------
    # [1] Validation
    # ------------------------------------------------------------------
    {
        my $ctx = { channel => '#mb545', target => '#mb545' };

        my ($ok, $err, $planned) = $ar->validate_action(
            { type => 'topic', text => 'new topic' }, $ctx);
        $assert->ok($ok && $planned->{target} eq '#mb545',
            'validation: cible imposee au canal du contexte');

        my ($ok_t, $err_t) = $ar->validate_action(
            { type => 'topic', text => 'x', target => '#elsewhere' }, $ctx);
        $assert->ok(!$ok_t && $err_t =~ /takes no target/,
            'validation: champ target refuse (pas de cross-canal par construction)');

        my ($ok_l, $err_l) = $ar->validate_action(
            { type => 'topic', text => ('x' x 301) }, $ctx);
        $assert->ok(!$ok_l && $err_l =~ /too long \(max 300\)/,
            'validation: texte >300 refuse');

        my ($ok_n, $err_n) = $ar->validate_action(
            { type => 'topic', text => 'x' }, { nick => 'poyan' });
        $assert->ok(!$ok_n && $err_n =~ /requires a channel context/,
            'validation: contexte non-canal refuse');

        my ($ok_s, $err_s, $planned_s) = $ar->validate_action(
            { type => 'topic', text => 'x' }, { target => '@#mb545' });
        $assert->ok($ok_s && ($planned_s->{target} || '') eq '#mb545',
            'validation: STATUSMSG reduit au vrai canal avant envoi');

        my ($ok_m, $err_m) = $ar->validate_action(
            { type => 'topic', text => 'x' }, { channel => '#mb545 bad' });
        $assert->ok(!$ok_m && $err_m =~ /invalid topic channel context/,
            'validation: contexte canal malforme refuse avant envoi');
    }

    # ------------------------------------------------------------------
    # [2] Triple gate à l'application
    # ------------------------------------------------------------------
    {
        my $irc = IRC742->new;
        my $bot = Bot742->new(irc => $irc);
        my $runner = Mediabot::ScriptActionRunner->new(bot => $bot);
        my $result = { ok => 1, response => { protocol => 'mediabot-script-v1',
            ok => JSON::PP::true, actions => [ { type => 'topic', text => 't' } ] } };
        my $ctx = { channel => '#mb545', target => '#mb545' };

        my $p1 = $runner->apply_actions($result, $ctx, apply => 1);
        $assert->ok(!$p1->{applied_ok}
            && ($p1->{apply_errors}[0]{error} || '') eq 'irc actions require allow_irc',
            'gate 1: sans allow_irc, refus irc');

        my $p2 = $runner->apply_actions($result, $ctx, apply => 1, allow_irc => 1);
        $assert->ok(!$p2->{applied_ok}
            && ($p2->{apply_errors}[0]{error} || '') eq 'topic actions require allow_topic',
            'gate 2: sans allow_topic, refus dedie distinct');
        $assert->ok(@{ $irc->sent } == 0, 'gates: rien envoye');

        my $p3 = $runner->apply_actions($result, $ctx, apply => 1,
            allow_irc => 1, allow_topic => 1);
        $assert->ok($p3->{applied_ok} && @{ $irc->sent } == 1
            && $irc->sent->[0][0] eq 'TOPIC'
            && $irc->sent->[0][2] eq '#mb545'
            && $irc->sent->[0][3] eq 't',
            'gate 3: les trois portes ouvertes, TOPIC envoye au canal du contexte');

        my $wide = 'caf' . chr(0x00e9) . ' ' . chr(0x1f9d9);
        my $wide_result = { ok => 1, response => {
            protocol => 'mediabot-script-v1', ok => JSON::PP::true,
            actions => [ { type => 'topic', text => $wide } ],
        } };
        my $p4 = $runner->apply_actions($wide_result, $ctx, apply => 1,
            allow_irc => 1, allow_topic => 1);
        my $wire = $irc->sent->[1][3];
        $assert->ok($p4->{applied_ok} && !utf8::is_utf8($wire)
            && $wire eq encode('UTF-8', $wide),
            'wire: topic Unicode encode en octets UTF-8 avant send_message');
    }

    # ------------------------------------------------------------------
    # [3] Pipelines réels : commande dry, évènement apply
    # ------------------------------------------------------------------
    {
        # Dry-run: planifie sans envoyer, meme sans les gates.
        my $bus = Mediabot::EventBus->new;
        my $irc = IRC742->new;
        my $conf = {
            'plugins.ScriptDryRun.COMMANDS' => 'psettopic',
            'plugins.ScriptDryRun.ROUTES'   => 'psettopic=settopic.pl',
        };
        my $bot = Bot742->new(irc => $irc, conf => $conf, event_bus => $bus);
        $bot->{script_runner} = Mediabot::ScriptRunner->new(
            bot => $bot, script_dir => $script_dir, timeout => 5, max_stdout_bytes => 65536);
        $bot->{script_action_runner} = Mediabot::ScriptActionRunner->new(bot => $bot);
        my $plugin = Mediabot::Plugin::ScriptDryRun->register($bot);

        $plugin->observe_public_command({
            channel => '#mb545', target => '#mb545', nick => 'poyan',
            command => 'psettopic', args => [ 'fresh', 'topic' ],
        });
        my $lr = $plugin->last_result || {};
        $assert->ok($lr->{dry_run}
            && @{ $lr->{action_plan}{planned} || [] } == 1
            && $lr->{action_plan}{planned}[0]{type} eq 'topic'
            && @{ $irc->sent } == 0,
            'dry-run: action topic planifiee, rien envoye');
        $plugin->unregister;

        # Evenement apply avec les trois gates.
        my $bus2 = Mediabot::EventBus->new;
        my $irc2 = IRC742->new;
        my $conf2 = {
            'plugins.ScriptDryRun.ACTION_MODE' => 'apply',
            'plugins.ScriptDryRun.ALLOW_IRC'   => 'yes',
            'plugins.ScriptDryRun.ALLOW_TOPIC' => 'yes',
            'plugins.ScriptDryRun.EVENTS'      => 'kick=settopic.pl',
        };
        my $bot2 = Bot742->new(irc => $irc2, conf => $conf2, event_bus => $bus2);
        $bot2->{script_runner} = Mediabot::ScriptRunner->new(
            bot => $bot2, script_dir => $script_dir, timeout => 5, max_stdout_bytes => 65536);
        $bot2->{script_action_runner} = Mediabot::ScriptActionRunner->new(bot => $bot2);
        my $plugin2 = Mediabot::Plugin::ScriptDryRun->register($bot2);

        $assert->ok($plugin2->allow_topic == 1, 'plugin: ALLOW_TOPIC lu');

        $bus2->emit_report('channel_kick_observed',
            { event_type => 'kick', channel => '#mb545', nick => 'op',
              kicked => 'poyan', message => 'x', is_self => 0 });
        $assert->ok(@{ $irc2->sent } == 1
            && $irc2->sent->[0][0] eq 'TOPIC'
            && $irc2->sent->[0][2] eq '#mb545',
            'pipeline evenement: TOPIC applique dans le canal de l\'evenement');

        # [4] Hot-reload: la gate est signalee au refresh.
        $bot2->{conf}{'plugins.ScriptDryRun.ALLOW_TOPIC'} = 'no';
        my @changed = $plugin2->refresh_from_conf;
        $assert->ok((grep { $_ eq 'allow_topic' } @changed) == 1,
            'hot-reload: changement d\'ALLOW_TOPIC signale');
        $assert->ok($plugin2->allow_topic == 0, 'hot-reload: gate refermee');

        $plugin2->unregister;
    }

    # ------------------------------------------------------------------
    # [5] Visibilité et docs
    # ------------------------------------------------------------------
    {
        {
            package Stream742;
            sub new { bless { out => '' }, shift }
            sub write { $_[0]->{out} .= $_[1]; 1 }
            sub out { $_[0]->{out} }
        }
        my $bus = Mediabot::EventBus->new;
        my $bot = Bot742->new(irc => IRC742->new, conf => {}, event_bus => $bus);
        $bot->{script_runner} = Mediabot::ScriptRunner->new(
            bot => $bot, script_dir => $script_dir, timeout => 5);
        $bot->{script_action_runner} = Mediabot::ScriptActionRunner->new(bot => $bot);
        my $plugin = Mediabot::Plugin::ScriptDryRun->register($bot);
        $bot->{pm} = PM742->new($plugin);
        my $party = bless { bot => $bot }, 'Mediabot::Partyline';

        my $s = Stream742->new;
        $party->_cmd_scriptdryrun($s, 1, 'status');
        $assert->like($s->out, qr/allow_topic: no/, 'status: gate visible (defaut no)');

        my $s2 = Stream742->new;
        $party->_cmd_scriptdryrun($s2, 1, 'config');
        $assert->like($s2->out, qr/plugins\.ScriptDryRun\.ALLOW_TOPIC/,
            'reference config: cle documentee (contrat 731 satisfait)');
        $assert->like($s2->out, qr/require apply \+ ALLOW_IRC \+ ALLOW_TOPIC/,
            'reference config: triple gate expliquee');
        $plugin->unregister;

        my $ar_src = _slurp_742(File::Spec->catfile('.', 'Mediabot', 'ScriptActionRunner.pm'));
        $assert->like($ar_src, qr/mb545-B1/, 'marqueur mb545 dans le runner');
        $assert->unlike($ar_src, qr/`[^`]+`/, 'runner: aucun backtick apparie (garde mb203)');
        my $plugin_src = _slurp_742(File::Spec->catfile('.', 'Mediabot', 'Plugin', 'ScriptDryRun.pm'));
        $assert->unlike($plugin_src, qr/`[^`]+`/, 'plugin: aucun backtick apparie');

        my $sample = _slurp_742('mediabot.sample.conf');
        $assert->like($sample, qr/^#ALLOW_TOPIC=no/m, 'sample: gate documentee');

        my $readme = _slurp_742(File::Spec->catfile('.', 'plugins', 'scripts', 'README.md'));
        $assert->like($readme, qr/## Topic action/, 'README: section topic');
        $assert->like($readme, qr/ORIGINATING channel/, 'README: scope documente');

        my $cookbook = _slurp_742(File::Spec->catfile('.', 'plugins', 'scripts', 'COOKBOOK.md'));
        $assert->like($cookbook, qr/ALLOW_TOPIC/, 'cookbook: regle de survie a jour');
    }
};
