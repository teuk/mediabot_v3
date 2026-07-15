# t/cases/726_mb527_partyline_script_timers.t
# =============================================================================
# mb527 — visibilite partyline des timers de scripts (.scriptdryrun timers)
# et annulation explicite (.scriptdryrun canceltimers).
#
# AVANT : les timers appliques par mb525 etaient invisibles pour l'operateur
# (aucun moyen de voir ce qui est arme ni de purger sans decharger le plugin).
#
# APRES :
#   - ScriptDryRun stocke des METADONNEES avec chaque timer arme (delai,
#     armed_at/expires_at, canal/nick/commande d'origine, script) et expose
#     script_timer_list() (copies, lecture seule) + cancel_script_timer($name).
#   - Partyline : `.scriptdryrun timers` liste les timers en attente avec le
#     plafond du runner (et signale toute incoherence de slots) ;
#     `.scriptdryrun canceltimers` annule tout et libere les slots pending.
#     L'annulation n'execute et ne cree JAMAIS rien.
#
# Couche 1 : rendu partyline avec plugin/runner factices.
# Couche 2 : bout-en-bout reel (vraie boucle IO::Async, vrai plugin, fixture
#            tempdir comme mb526) : armement, liste, annulation, silence.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;
use File::Temp qw(tempdir);

use Mediabot::Partyline;
use Mediabot::ScriptRunner;
use Mediabot::ScriptActionRunner;
use Mediabot::Plugin::ScriptDryRun;

sub _slurp_726 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

{
    package Stream726;
    sub new { bless { out => '' }, shift }
    sub write { $_[0]->{out} .= $_[1]; 1 }
    sub out { $_[0]->{out} }
}

{ package L726; sub new { bless {}, shift } sub log { 1 } }

{
    package IRC726;
    sub new { bless { sent => [] }, shift }
    sub send_message { my ($self, @args) = @_; push @{ $self->{sent} }, \@args; 1 }
    sub sent { $_[0]->{sent} }
}

{
    package PM726;
    sub new { my ($class, $plugin) = @_; bless { plugin => $plugin }, $class }
    sub object_for {
        my ($self, $name) = @_;
        return $self->{plugin} if $name eq 'Mediabot::Plugin::ScriptDryRun';
        return undef;
    }
}

{
    package FakeRunner726;
    sub new { my ($class, %h) = @_; bless {%h}, $class }
    sub max_pending_timers { $_[0]->{cap} }
    sub pending_timer_count { $_[0]->{pending} }
}

{
    package FakePlugin726;
    sub new { my ($class, %h) = @_; bless {%h}, $class }
    sub script_timer_list { @{ $_[0]->{timers} || [] } }
    sub cancel_script_timers {
        my ($self) = @_;
        my $n = scalar @{ $self->{timers} || [] };
        $self->{timers} = [];
        return $n;
    }
}

{
    package Bot726;
    sub new { my ($class, %h) = @_; bless {%h, logger => L726->new}, $class }
    sub plugin_manager { $_[0]->{pm} }
    sub script_runner        { $_[0]->{script_runner} }
    sub script_action_runner { $_[0]->{script_action_runner} }
    sub getLoop              { $_[0]->{loop} }
    sub run_script_actions_dry { die "dry path must not run in apply mode" }
}

return sub {
    my ($assert) = @_;

    # ------------------------------------------------------------------
    # Couche 1 — rendu partyline avec factices
    # ------------------------------------------------------------------
    {
        my $plugin = FakePlugin726->new(timers => [
            {
                name => 'demo_alpha', delay => 60, remaining => 42,
                channel => '#teuk', nick => 'Te[u]K', command => 'ptimer',
                script  => 'examples/timer_demo.pl',
            },
            {
                name => 'demo_beta', delay => 30, remaining => 5,
                channel => '#mb527', nick => 'poyan', command => 'premind',
                script  => 'examples/remind.pl',
            },
        ]);
        my $runner = FakeRunner726->new(cap => 4, pending => 2);
        my $bot = Bot726->new(
            pm => PM726->new($plugin),
            script_action_runner => $runner,
        );
        my $party = bless { bot => $bot }, 'Mediabot::Partyline';

        my $s = Stream726->new;
        $party->_cmd_scriptdryrun($s, 1, 'timers');
        my $out = $s->out;

        $assert->like($out, qr/^ScriptDryRun timers:/m, 'entete de la liste des timers');
        $assert->like($out, qr/pending: 2 \(cap 4\)/, 'compteur et plafond affiches');
        $assert->unlike($out, qr/mismatch/, 'pas de mismatch quand plugin et runner concordent');
        $assert->like($out,
            qr/demo_alpha: remaining=42s delay=60s channel=#teuk nick=Te\[u\]K command=ptimer script=examples\/timer_demo\.pl/,
            'ligne complete du premier timer');
        $assert->like($out, qr/demo_beta: remaining=5s delay=30s channel=#mb527/,
            'second timer liste');

        # Incoherence plugin/runner signalee.
        my $bot2 = Bot726->new(
            pm => PM726->new($plugin),
            script_action_runner => FakeRunner726->new(cap => 4, pending => 3),
        );
        my $party2 = bless { bot => $bot2 }, 'Mediabot::Partyline';
        my $s2 = Stream726->new;
        $party2->_cmd_scriptdryrun($s2, 1, 'timers');
        $assert->like($s2->out, qr/runner_pending: 3 \(mismatch\)/,
            'incoherence de slots exposee');

        # Annulation via la partyline.
        my $s3 = Stream726->new;
        $party->_cmd_scriptdryrun($s3, 1, 'canceltimers');
        $assert->like($s3->out, qr/^ScriptDryRun timers cancelled: 2/m,
            'canceltimers annonce le nombre annule');

        my $s4 = Stream726->new;
        $party->_cmd_scriptdryrun($s4, 1, 'timers');
        $assert->like($s4->out, qr/pending: 0/, 'liste vide apres annulation');

        # Champs manquants -> '-' et pas de warning fatal.
        my $sparse = FakePlugin726->new(timers => [ { name => 'bare', delay => 10, remaining => 9 } ]);
        my $party3 = bless { bot => Bot726->new(pm => PM726->new($sparse)) }, 'Mediabot::Partyline';
        my $s5 = Stream726->new;
        $party3->_cmd_scriptdryrun($s5, 1, 'timers');
        $assert->like($s5->out, qr/bare: remaining=9s delay=10s channel=- nick=- command=- script=-/,
            'champs absents rendus en tirets');
        $assert->like($s5->out, qr/pending: 1\r?\n/, 'plafond omis sans runner');

        # Plugin absent.
        my $party4 = bless { bot => Bot726->new(pm => PM726->new(undef)) }, 'Mediabot::Partyline';
        for my $sub (qw(timers canceltimers)) {
            my $sx = Stream726->new;
            $party4->_cmd_scriptdryrun($sx, 1, $sub);
            $assert->like($sx->out, qr/ScriptDryRun: not loaded/, "$sub sans plugin -> not loaded");
        }

        # Usage mis a jour.
        my $s6 = Stream726->new;
        $party->_cmd_scriptdryrun($s6, 1, 'bogus');
        $assert->like($s6->out, qr/Usage: \.scriptdryrun \[status\|last\|config\|timers\|canceltimers\]/,
            'usage liste les nouvelles sous-commandes');
    }

    # ------------------------------------------------------------------
    # Couche 2 — bout-en-bout reel
    # ------------------------------------------------------------------
    my $have_loop = eval { require IO::Async::Loop; 1 };
    if (!$have_loop) {
        $assert->ok(1, 'SKIP bout-en-bout: IO::Async::Loop indisponible');
    }
    else {
        my $loop = IO::Async::Loop->new;
        my $irc  = IRC726->new;

        # Fixture en tempdir (contrainte mb526 : t/tmp_mb* est de l'etat local
        # genere, jamais un fichier suivi).
        my $script_dir = tempdir('mediabot_mb527_XXXXXX', TMPDIR => 1, CLEANUP => 1);
        my $fixture_path = File::Spec->catfile($script_dir, 'timer_hold.pl');
        open my $fh, '>:encoding(UTF-8)', $fixture_path or die "cannot create $fixture_path: $!";
        print {$fh} <<'MB527_FIXTURE';
#!/usr/bin/env perl
use strict;
use warnings;
use JSON::PP qw(decode_json encode_json);
my $input   = do { local $/; <STDIN> };
my $payload = eval { decode_json($input || '{}') };
$payload = {} unless ref($payload) eq 'HASH';
my $event = defined($payload->{event}) && !ref($payload->{event}) ? $payload->{event} : 'unknown';
my $data  = ref($payload->{data}) eq 'HASH' ? $payload->{data} : {};
my $channel = defined($data->{channel}) && !ref($data->{channel}) ? $data->{channel} : '';
my @actions;
if ($event eq 'timer') {
    @actions = ( { type => 'reply', target => $channel, text => 'mb527 deferred output' } );
}
else {
    @actions = ( { type => 'timer', name => 'mb527_hold', delay => 60 } );
}
print encode_json({ protocol => 'mediabot-script-v1', ok => JSON::PP::true, actions => \@actions });
MB527_FIXTURE
        close $fh or die "cannot close $fixture_path: $!";

        my $conf = {
            'plugins.ScriptDryRun.COMMANDS'    => 'phold',
            'plugins.ScriptDryRun.ROUTES'      => 'phold=timer_hold.pl',
            'plugins.ScriptDryRun.ACTION_MODE' => 'apply',
            'plugins.ScriptDryRun.ALLOW_IRC'   => 'yes',
        };

        my $bot = Bot726->new(irc => $irc, conf => $conf, loop => $loop);
        $bot->{conf} = $conf;

        my $script_runner = Mediabot::ScriptRunner->new(
            bot              => $bot,
            script_dir       => $script_dir,
            timeout          => 5,
            max_stdout_bytes => 65536,
        );
        my $action_runner = Mediabot::ScriptActionRunner->new(bot => $bot);
        $bot->{script_runner}        = $script_runner;
        $bot->{script_action_runner} = $action_runner;

        my $plugin = Mediabot::Plugin::ScriptDryRun->register($bot);
        $bot->{pm} = PM726->new($plugin);

        my $ctx = {
            channel => '#mb527',
            target  => '#mb527',
            nick    => 'Te[u]K',
            command => 'phold',
            args    => [],
        };

        my $result = $plugin->observe_public_command($ctx);
        $assert->ok(ref($result) eq 'HASH' && $result->{ok}, 'timer de 60s arme via la commande');
        $assert->ok($action_runner->pending_timer_count == 1, 'slot pending occupe');

        # Metadonnees exposees par le plugin.
        my @list = $plugin->script_timer_list;
        $assert->ok(@list == 1, 'script_timer_list expose un timer');
        my $t = $list[0] || {};
        $assert->ok(($t->{name} || '') eq 'mb527_hold', 'nom expose');
        $assert->ok(($t->{delay} || 0) == 60, 'delai expose');
        $assert->ok(defined $t->{remaining} && $t->{remaining} > 0 && $t->{remaining} <= 60,
            'remaining coherent (0 < r <= delay)');
        $assert->ok(($t->{channel} || '') eq '#mb527' && ($t->{command} || '') eq 'phold',
            'origine (canal/commande) exposee');
        $assert->ok(($t->{script} || '') eq 'timer_hold.pl',
            'script expose (valeur routee, telle que configuree)');
        $assert->ok(!exists $t->{timer}, 'objet IO::Async jamais expose');

        # Rendu partyline sur le vrai plugin.
        my $party = bless { bot => $bot }, 'Mediabot::Partyline';
        my $s = Stream726->new;
        $party->_cmd_scriptdryrun($s, 1, 'timers');
        $assert->like($s->out, qr/pending: 1 \(cap 4\)/, 'partyline: compteur reel + plafond runner');
        $assert->like($s->out, qr/mb527_hold: remaining=\d+s delay=60s channel=#mb527 nick=Te\[u\]K command=phold/,
            'partyline: ligne du timer reel');
        $assert->unlike($s->out, qr/mismatch/, 'partyline: plugin et runner concordent');

        # Annulation ciblee puis verification de l'etat.
        $assert->ok($plugin->cancel_script_timer('inconnu') == 0, 'annulation ciblee: nom inconnu -> 0');
        my $s2 = Stream726->new;
        $party->_cmd_scriptdryrun($s2, 1, 'canceltimers');
        $assert->like($s2->out, qr/ScriptDryRun timers cancelled: 1/, 'partyline: annulation reelle');
        $assert->ok($plugin->active_script_timer_count == 0, 'plus de timer actif cote plugin');
        $assert->ok($action_runner->pending_timer_count == 0, 'slot pending libere par l\'annulation');

        my $s3 = Stream726->new;
        $party->_cmd_scriptdryrun($s3, 1, 'timers');
        $assert->like($s3->out, qr/pending: 0/, 'partyline: liste vide apres annulation');

        # Un timer annule ne produit jamais de sortie differee.
        $loop->delay_future(after => 0.3)->get;
        $assert->ok(@{ $irc->sent } == 0, 'aucune sortie IRC apres annulation');

        # Re-armement possible apres liberation du slot (cycle complet).
        my $again = $plugin->observe_public_command($ctx);
        $assert->ok(ref($again) eq 'HASH' && $again->{ok} && $action_runner->pending_timer_count == 1,
            're-armement possible apres annulation');
        $plugin->unregister;
        $assert->ok($action_runner->pending_timer_count == 0, 'unregister libere toujours les slots');
    }

    # ------------------------------------------------------------------
    # Gardes de source et de documentation
    # ------------------------------------------------------------------
    {
        my $plugin_src = _slurp_726(File::Spec->catfile('.', 'Mediabot', 'Plugin', 'ScriptDryRun.pm'));
        $assert->like($plugin_src, qr/mb527-B1/, 'marqueur mb527 dans ScriptDryRun');
        $assert->like($plugin_src, qr/sub script_timer_list/, 'liste en lecture seule presente');
        $assert->like($plugin_src, qr/sub cancel_script_timer\b/, 'annulation ciblee presente');

        my $party_src = _slurp_726(File::Spec->catfile('.', 'Mediabot', 'Partyline.pm'));
        $assert->like($party_src, qr/mb527-B1/, 'marqueur mb527 dans Partyline');
        $assert->like($party_src, qr/show external script bridge status and last run/,
            'contrat mb291 de la ligne d\'aide conserve');

        my $sample_src = _slurp_726(File::Spec->catfile('.', 'mediabot.sample.conf'));
        $assert->like($sample_src, qr/\.scriptdryrun timers/, 'sample conf documente timers');
        $assert->like($sample_src, qr/\.scriptdryrun canceltimers/, 'sample conf documente canceltimers');

        my $readme_src = _slurp_726(File::Spec->catfile('.', 'plugins', 'scripts', 'README.md'));
        $assert->like($readme_src, qr/\.scriptdryrun timers/, 'README documente timers');
        $assert->like($readme_src, qr/\.scriptdryrun canceltimers/, 'README documente canceltimers');
    }
};
