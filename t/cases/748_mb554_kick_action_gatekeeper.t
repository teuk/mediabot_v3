# t/cases/748_mb554_kick_action_gatekeeper.t
# =============================================================================
# mb554 — action « kick » du protocole (sixième type, deuxième action de
# modération) + gatekeeper.pl, son usage canonique au join.
#
# Contrats :
#   [1] validation fail-closed : nick obligatoire/grammaire IRC/≤30, raison
#       bornée 120 octets UTF-8 avec défaut, AUCUN target, contexte canal sûr ;
#   [2] chaîne de gates : allow_irc -> allow_kick (erreurs distinctes),
#       et refus du self-kick fail-closed à l'application ;
#   [3] apply réel : KICK envoyé (canal d'origine, nick, raison en
#       trailing) ; dry-run planifie sans envoyer ;
#   [4] gatekeeper.pl : match sous-chaîne insensible à la casse -> kick +
#       log ; pas de match -> SILENCE TOTAL ; config désarmée -> jamais de
#       kick ; mauvais routage -> warning ; pipeline join bout-en-bout avec
#       les trois gates ; gate fermée -> erreur dédiée dans last_result ;
#   [5] hot-reload signale allow_kick (fingerprint mb537) ; status et
#       référence config partyline ; docs (README/cookbook/sample) — la
#       garde 736 (cité↔livré + « fifteen ») est couverte par la suite.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;
use Encode qw(encode);

use Mediabot::EventBus;
use Mediabot::Partyline;
use Mediabot::ScriptRunner;
use Mediabot::ScriptActionRunner;
use Mediabot::Plugin::ScriptDryRun;

sub _slurp_748 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

{ package L748; sub new { bless {}, shift } sub log { 1 } }

{
    package IRC748;
    sub new { my ($class, %h) = @_; bless { sent => [], %h }, $class }
    sub send_message { my ($self, @args) = @_; push @{ $self->{sent} }, \@args; 1 }
    sub sent { $_[0]->{sent} }
    sub is_nick_me {
        my ($self, $nick) = @_;
        die "identity check failed\n" if $self->{identity_check_dies};
        return lc($nick // '') eq lc($self->{own_nick} // '') ? 1 : 0;
    }
}

{
    package Bot748;
    sub new { my ($class, %h) = @_; bless {%h, logger => L748->new}, $class }
    sub events               { $_[0]->{event_bus} }
    sub script_runner        { $_[0]->{script_runner} }
    sub script_action_runner { $_[0]->{script_action_runner} }
    sub getLoop              { undef }
    sub run_script_actions_dry { die "dry path must not run in apply mode" }
}

my $examples = File::Spec->catdir('plugins', 'scripts', 'examples');

return sub {
    my ($assert) = @_;

    my $ar = Mediabot::ScriptActionRunner->new;
    my $ctx = { channel => '#mb554', target => '#mb554' };

    # ------------------------------------------------------------------
    # [1] Validation
    # ------------------------------------------------------------------
    {
        my ($ok, $err, $planned) = $ar->validate_action(
            { type => 'kick', nick => 'Spam[bot]' }, $ctx);
        $assert->ok($ok && $planned->{target} eq '#mb554'
            && $planned->{nick} eq 'Spam[bot]'
            && $planned->{reason} eq 'requested by script',
            'validation: nick charset IRC, cible imposee, raison par defaut');

        my ($ok_r, undef, $p_r) = $ar->validate_action(
            { type => 'kick', nick => 'x', reason => 'be nice' }, $ctx);
        $assert->ok($ok_r && $p_r->{reason} eq 'be nice', 'validation: raison gardee');

        my ($ok_t, $err_t) = $ar->validate_action(
            { type => 'kick', nick => 'x', target => '#ailleurs' }, $ctx);
        $assert->ok(!$ok_t && $err_t =~ /takes no target/, 'validation: target refuse');

        my ($ok_n, $err_n) = $ar->validate_action({ type => 'kick' }, $ctx);
        $assert->ok(!$ok_n && $err_n =~ /requires a nick/, 'validation: nick obligatoire');

        my ($ok_c, $err_c) = $ar->validate_action(
            { type => 'kick', nick => 'bad nick!' }, $ctx);
        $assert->ok(!$ok_c && $err_c =~ /invalid characters/, 'validation: charset applique');

        my ($ok_l, $err_l) = $ar->validate_action(
            { type => 'kick', nick => ('x' x 31) }, $ctx);
        $assert->ok(!$ok_l && $err_l =~ /too long \(max 30\)/, 'validation: nick borne');

        my ($ok_rl, $err_rl) = $ar->validate_action(
            { type => 'kick', nick => 'x', reason => ('r' x 121) }, $ctx);
        $assert->ok(!$ok_rl && $err_rl =~ /reason is too long \(max 120 UTF-8 bytes\)/,
            'validation: raison bornee');

        my ($ok_pv, $err_pv) = $ar->validate_action(
            { type => 'kick', nick => 'x' }, { nick => 'someone' });
        $assert->ok(!$ok_pv && $err_pv =~ /requires a channel context/,
            'validation: contexte canal requis');

        my ($ok_s, $err_s, $planned_s) = $ar->validate_action(
            { type => 'kick', nick => 'x' }, { target => '@#mb554' });
        $assert->ok($ok_s && ($planned_s->{target} || '') eq '#mb554',
            'validation: STATUSMSG reduit au vrai canal avant KICK');

        my ($ok_m, $err_m) = $ar->validate_action(
            { type => 'kick', nick => 'x' }, { channel => '#mb554 bad' });
        $assert->ok(!$ok_m && $err_m =~ /invalid kick channel context/,
            'validation: contexte canal malforme refuse');

        for my $bad_first ('123', '-intrus') {
            my ($ok_f, $err_f) = $ar->validate_action(
                { type => 'kick', nick => $bad_first }, $ctx);
            $assert->ok(!$ok_f && $err_f =~ /invalid characters/,
                "validation: premier caractere IRC refuse ($bad_first)");
        }

        my ($ok_utf8_len, $err_utf8_len) = $ar->validate_action(
            { type => 'kick', nick => 'x', reason => (chr(0x1f9d9) x 31) }, $ctx);
        $assert->ok(!$ok_utf8_len && $err_utf8_len =~ /120 UTF-8 bytes/,
            'validation: raison bornee sur les octets du wire');
    }

    # ------------------------------------------------------------------
    # [2] + [3] Gates, self-kick, envoi réel
    # ------------------------------------------------------------------
    {
        my $irc = IRC748->new(own_nick => 'mediabot');
        my $bot = Bot748->new(irc => $irc);
        my $runner = Mediabot::ScriptActionRunner->new(bot => $bot);
        my $mk = sub {
            my (%a) = @_;
            return { ok => 1, response => { protocol => 'mediabot-script-v1',
                ok => JSON::PP::true,
                actions => [ { type => 'kick', nick => 'intrus', %a } ] } };
        };

        my $p1 = $runner->apply_actions($mk->(), $ctx, apply => 1);
        $assert->ok(($p1->{apply_errors}[0]{error} || '') eq 'irc actions require allow_irc',
            'gate 1: allow_irc d\'abord');

        my $p2 = $runner->apply_actions($mk->(), $ctx, apply => 1, allow_irc => 1);
        $assert->ok(($p2->{apply_errors}[0]{error} || '') eq 'kick actions require allow_kick',
            'gate 2: refus dedie distinct');
        $assert->ok(@{ $irc->sent } == 0, 'gates: rien envoye');

        my $p3 = $runner->apply_actions($mk->(reason => 'spam'), $ctx,
            apply => 1, allow_irc => 1, allow_kick => 1);
        $assert->ok($p3->{applied_ok} && @{ $irc->sent } == 1
            && $irc->sent->[0][0] eq 'KICK'
            && $irc->sent->[0][2] eq '#mb554'
            && $irc->sent->[0][3] eq 'intrus'
            && $irc->sent->[0][4] eq 'spam',
            'apply: KICK canal/nick/raison envoyes');

        my $p_self = $runner->apply_actions(
            { ok => 1, response => { protocol => 'mediabot-script-v1',
                ok => JSON::PP::true,
                actions => [ { type => 'kick', nick => 'MediaBot' } ] } },
            $ctx, apply => 1, allow_irc => 1, allow_kick => 1);
        $assert->ok(!$p_self->{applied_ok}
            && ($p_self->{apply_errors}[0]{error} || '') eq 'refusing to kick the bot itself'
            && @{ $irc->sent } == 1,
            'self-kick: refuse (case-insensitive), rien envoye');

        my $wide = 'caf' . chr(0x00e9) . ' ' . chr(0x1f9d9);
        my $p_wire = $runner->apply_actions($mk->(reason => $wide), $ctx,
            apply => 1, allow_irc => 1, allow_kick => 1);
        my $wire_reason = $irc->sent->[1][4];
        $assert->ok($p_wire->{applied_ok} && !utf8::is_utf8($wire_reason)
            && $wire_reason eq encode('UTF-8', $wide),
            'wire: raison Unicode encodee en UTF-8 avant KICK');

        my $irc_bad_identity = IRC748->new(
            own_nick => 'mediabot', identity_check_dies => 1);
        my $runner_bad_identity = Mediabot::ScriptActionRunner->new(
            bot => Bot748->new(irc => $irc_bad_identity));
        my $p_identity = $runner_bad_identity->apply_actions(
            $mk->(reason => 'x'), $ctx,
            apply => 1, allow_irc => 1, allow_kick => 1);
        $assert->ok(!$p_identity->{applied_ok}
            && ($p_identity->{apply_errors}[0]{error} || '')
                eq 'cannot verify bot identity for kick action'
            && !@{ $irc_bad_identity->sent },
            'self-check: erreur identite => kick refuse fail-closed');
    }

    # ------------------------------------------------------------------
    # [4] gatekeeper.pl
    # ------------------------------------------------------------------
    {
        my $runner = Mediabot::ScriptRunner->new(script_dir => $examples, timeout => 5);

        my $hit = $runner->run_script('gatekeeper.pl', 'join',
            channel => '#mb554', target => '#mb554', nick => 'SpamBot42',
            args => [], config => { kick_substrings => 'spambot flood',
                                    kick_reason => 'not welcome here' });
        my $actions = $hit->{response}{actions} || [];
        my ($kick) = grep { ($_->{type} || '') eq 'kick' } @$actions;
        $assert->ok($kick && $kick->{nick} eq 'SpamBot42'
            && $kick->{reason} eq 'not welcome here'
            && !exists $kick->{target},
            'gatekeeper: match sous-chaine insensible a la casse -> kick');

        my ($hit_log) = grep { ($_->{type} || '') eq 'log' } @$actions;
        $assert->like(($hit_log->{text} || ''), qr/kick requested/,
            'gatekeeper: log de demande reste vrai si application refusee');

        my $unicode_reason = chr(0x1f9d9) x 40;
        my $hit_utf8 = $runner->run_script('gatekeeper.pl', 'join',
            channel => '#mb554', target => '#mb554', nick => 'SpamBot42',
            args => [], config => { kick_substrings => 'spambot',
                                    kick_reason => $unicode_reason });
        my ($kick_utf8) = grep { ($_->{type} || '') eq 'kick' }
            @{ $hit_utf8->{response}{actions} || [] };
        $assert->ok($kick_utf8
            && length(encode('UTF-8', $kick_utf8->{reason})) <= 120,
            'gatekeeper: raison Unicode tronquee a la borne wire');

        my $miss = $runner->run_script('gatekeeper.pl', 'join',
            channel => '#mb554', target => '#mb554', nick => 'gentil',
            args => [], config => { kick_substrings => 'spambot' });
        $assert->ok($miss->{ok} && !@{ $miss->{response}{actions} || [] },
            'gatekeeper: pas de match -> SILENCE TOTAL');

        my $unarmed = $runner->run_script('gatekeeper.pl', 'join',
            channel => '#mb554', target => '#mb554', nick => 'SpamBot42', args => []);
        my @k_un = grep { ($_->{type} || '') eq 'kick' } @{ $unarmed->{response}{actions} || [] };
        $assert->ok($unarmed->{ok} && !@k_un,
            'gatekeeper: config desarmee -> jamais de kick');

        my $wrong = $runner->run_script('gatekeeper.pl', 'topic',
            channel => '#mb554', target => '#mb554', nick => 'x',
            topic => 't', args => []);
        my ($warn) = grep { ($_->{type} || '') eq 'log' } @{ $wrong->{response}{actions} || [] };
        $assert->like(($warn->{text} || ''), qr/unexpected event/, 'gatekeeper: mauvais routage');

        # Pipeline bout-en-bout, trois gates ouvertes.
        my $bus = Mediabot::EventBus->new;
        my $irc = IRC748->new(own_nick => 'mediabot');
        my $conf = {
            'plugins.ScriptDryRun.ACTION_MODE' => 'apply',
            'plugins.ScriptDryRun.ALLOW_IRC'   => 'yes',
            'plugins.ScriptDryRun.ALLOW_KICK'  => 'yes',
            'plugins.ScriptDryRun.EVENTS'      => 'join=gatekeeper.pl',
            'plugins.ScriptDryRun.CONFIG_join' => 'kick_substrings=spambot;kick_reason=out',
        };
        my $bot = Bot748->new(irc => $irc, conf => $conf, event_bus => $bus);
        $bot->{script_runner} = Mediabot::ScriptRunner->new(
            bot => $bot, script_dir => $examples, timeout => 5, max_stdout_bytes => 65536);
        $bot->{script_action_runner} = Mediabot::ScriptActionRunner->new(bot => $bot);
        my $plugin = Mediabot::Plugin::ScriptDryRun->register($bot);

        $assert->ok($plugin->allow_kick == 1, 'plugin: ALLOW_KICK lu');

        $bus->emit_report('channel_join_observed',
            { event_type => 'join', channel => '#mb554', nick => 'SpamBot42', is_self => 0 });
        $assert->ok(@{ $irc->sent } == 1
            && $irc->sent->[0][0] eq 'KICK'
            && $irc->sent->[0][3] eq 'SpamBot42'
            && $irc->sent->[0][4] eq 'out',
            'pipeline: join hostile -> KICK applique');

        # Gate refermee a chaud : le prochain match echoue avec l'erreur dediee.
        $bot->{conf}{'plugins.ScriptDryRun.ALLOW_KICK'} = 'no';
        my @changed = $plugin->refresh_from_conf;
        $assert->ok((grep { $_ eq 'allow_kick' } @changed) == 1,
            'hot-reload: changement d\'ALLOW_KICK signale');

        $plugin->clear_event_cooldowns;
        $bus->emit_report('channel_join_observed',
            { event_type => 'join', channel => '#mb554', nick => 'FloodSpamBot', is_self => 0 });
        my $lr = $plugin->last_result || {};
        my @errs = @{ ($lr->{action_plan} || {})->{apply_errors} || [] };
        $assert->ok(!$lr->{ok}
            && (grep { ($_->{error} || '') eq 'kick actions require allow_kick' } @errs) == 1
            && @{ $irc->sent } == 1,
            'gate fermee: erreur dediee visible, rien de nouveau envoye');

        $plugin->unregister;
    }

    # ------------------------------------------------------------------
    # [5] Visibilité et docs
    # ------------------------------------------------------------------
    {
        {
            package Stream748;
            sub new { bless { out => '' }, shift }
            sub write { $_[0]->{out} .= $_[1]; 1 }
            sub out { $_[0]->{out} }
        }
        {
            package PM748;
            sub new { my ($class, $plugin) = @_; bless { plugin => $plugin }, $class }
            sub object_for { $_[0]->{plugin} }
        }
        my $bus = Mediabot::EventBus->new;
        my $bot = Bot748->new(irc => IRC748->new, conf => {}, event_bus => $bus);
        $bot->{script_runner} = Mediabot::ScriptRunner->new(
            bot => $bot, script_dir => $examples, timeout => 5);
        $bot->{script_action_runner} = Mediabot::ScriptActionRunner->new(bot => $bot);
        my $plugin = Mediabot::Plugin::ScriptDryRun->register($bot);
        $bot->{pm} = PM748->new($plugin);
        { no warnings 'once'; *Bot748::plugin_manager = sub { $_[0]->{pm} }; }
        my $party = bless { bot => $bot }, 'Mediabot::Partyline';

        my $s = Stream748->new;
        $party->_cmd_scriptdryrun($s, 1, 'status');
        $assert->like($s->out, qr/allow_kick: no/, 'status: gate visible (defaut no)');

        my $s2 = Stream748->new;
        $party->_cmd_scriptdryrun($s2, 1, 'config');
        $assert->like($s2->out, qr/plugins\.ScriptDryRun\.ALLOW_KICK/,
            'reference config: cle documentee (contrat 731)');
        $assert->like($s2->out, qr/the bot never kicks itself/,
            'reference config: protection self-kick annoncee');
        $plugin->unregister;

        my $sample = _slurp_748('mediabot.sample.conf');
        $assert->like($sample, qr/^#ALLOW_KICK=no/m, 'sample: gate documentee');

        my $readme = _slurp_748(File::Spec->catfile('plugins', 'scripts', 'README.md'));
        $assert->like($readme, qr/## Kick action/, 'README: section kick');
        $assert->like($readme, qr/gatekeeper\.pl/, 'README: exemple reference');

        my $ar_src = _slurp_748(File::Spec->catfile('Mediabot', 'ScriptActionRunner.pm'));
        $assert->like($ar_src, qr/mb554-B1/, 'marqueur mb554');
        $assert->unlike($ar_src, qr/`[^`]+`/, 'runner: aucun backtick apparie (garde mb203)');
    }
};
