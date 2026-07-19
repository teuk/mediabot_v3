# t/cases/739_mb542_topicreminder_example.t
# =============================================================================
# mb542 — exemple combiné évènement+timer+config : topicreminder.pl, la seule
# case de la matrice qu'aucun exemple ne couvrait (les trois briques de l'arc
# dans un seul script de référence).
#
# Contrats :
#   [1] statique : protocole/ok/mauvais routage (patterns de l'arc) ;
#   [2] exécution réelle : topic -> timer armé + log, SILENCE IRC immédiat ;
#       timer -> re-post du topic reconstruit depuis l'enveloppe d'origine ;
#       topic vide -> rien d'armé ; config remind_after appliquée/bornée/
#       invalide->défaut ;
#   [3] bout-en-bout pipeline : topic réel -> rappel livré dans le canal avec
#       le topic ET l'auteur d'origine ; la sémantique un-pending-par-nom est
#       exposée honnêtement (un second topic pendant le pending échoue à
#       l'armement, run marqué non-ok) ;
#   [4] la garde 736 (cookbook) reste verte : citation + compte « fourteen »
#       (vérifié par la suite complète, pas dupliqué ici) ; docs README.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

use Mediabot::EventBus;
use Mediabot::ScriptRunner;
use Mediabot::ScriptActionRunner;
use Mediabot::Plugin::ScriptDryRun;

sub _slurp_739 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

{ package L739; sub new { bless {}, shift } sub log { 1 } }

{
    package IRC739;
    sub new { bless { sent => [] }, shift }
    sub send_message { my ($self, @args) = @_; push @{ $self->{sent} }, \@args; 1 }
    sub sent { $_[0]->{sent} }
}

{
    package Bot739;
    sub new { my ($class, %h) = @_; bless {%h, logger => L739->new}, $class }
    sub events               { $_[0]->{event_bus} }
    sub script_runner        { $_[0]->{script_runner} }
    sub script_action_runner { $_[0]->{script_action_runner} }
    sub getLoop              { $_[0]->{loop} }
    sub run_script_actions_dry { die "dry path must not run in apply mode" }
}

my $examples = File::Spec->catdir('plugins', 'scripts', 'examples');

return sub {
    my ($assert) = @_;

    # ------------------------------------------------------------------
    # [1] Statique
    # ------------------------------------------------------------------
    {
        my $src = _slurp_739(File::Spec->catfile($examples, 'topicreminder.pl'));
        $assert->like($src, qr/mediabot-script-v1/, 'declare le protocole');
        $assert->like($src, qr/ok\s*=>\s*JSON::PP::true/, 'emet ok explicitement');
        $assert->like($src, qr/unexpected event/, 'gere le mauvais routage');
        $assert->like($src, qr/remind_after/, 'lit config.remind_after');
    }

    # ------------------------------------------------------------------
    # [2] Exécution réelle
    # ------------------------------------------------------------------
    my $runner = Mediabot::ScriptRunner->new(script_dir => $examples, timeout => 5);

    {
        # topic -> timer + log, aucune reply.
        my $r = $runner->run_script('topicreminder.pl', 'topic',
            channel => '#mb542', target => '#mb542', nick => 'Te[u]K',
            topic => 'release ce soir', args => []);
        my $actions = $r->{response}{actions} || [];
        my ($timer) = grep { ($_->{type} || '') eq 'timer' } @$actions;
        my @replies = grep { ($_->{type} || '') eq 'reply' } @$actions;
        $assert->ok($r->{ok} && $timer && !@replies,
            'topic: timer arme, silence IRC immediat');
        $assert->ok($timer->{delay} == 300, 'topic: delai par defaut 300s');
        $assert->ok(($timer->{name} || '') =~ /\Atopic_reminder_[A-Za-z0-9_.-]+_[0-9a-f]{10}\z/
            && length($timer->{name} || '') <= 64,
            'topic: nom lisible, borne et renforce par digest');

        my $r_collision = $runner->run_script('topicreminder.pl', 'topic',
            channel => '#mb/542', target => '#mb/542', nick => 'x',
            topic => 't', args => []);
        my ($t_collision) = grep { $_->{type} eq 'timer' }
            @{ $r_collision->{response}{actions} || [] };
        my $r_collision_2 = $runner->run_script('topicreminder.pl', 'topic',
            channel => '#mb_542', target => '#mb_542', nick => 'x',
            topic => 't', args => []);
        my ($t_collision_2) = grep { $_->{type} eq 'timer' }
            @{ $r_collision_2->{response}{actions} || [] };
        $assert->ok(($t_collision->{name} || '') ne ($t_collision_2->{name} || ''),
            'topic: deux canaux qui se sanitizent pareil gardent des noms distincts');

        # timer -> re-post reconstruit.
        my $r_t = $runner->run_script('topicreminder.pl', 'timer',
            channel => '#mb542', target => '#mb542', nick => 'Te[u]K',
            topic => 'release ce soir', args => [],
            timer_name => 'topic_reminder__mb542', timer_delay => 300);
        my ($reply_t) = grep { $_->{type} eq 'reply' } @{ $r_t->{response}{actions} || [] };
        $assert->like(($reply_t->{text} || ''),
            qr/topic reminder: release ce soir \(set by Te\[u\]K\)/,
            'timer: topic ET auteur reconstruits depuis l\'enveloppe d\'origine');
        my @t_t = grep { ($_->{type} || '') eq 'timer' } @{ $r_t->{response}{actions} || [] };
        $assert->ok(!@t_t, 'timer: aucune chaine');

        # topic vide -> rien d'arme.
        my $r_c = $runner->run_script('topicreminder.pl', 'topic',
            channel => '#mb542', target => '#mb542', nick => 'x', topic => '', args => []);
        my @t_c = grep { ($_->{type} || '') eq 'timer' } @{ $r_c->{response}{actions} || [] };
        $assert->ok($r_c->{ok} && !@t_c, 'topic vide: rien d\'arme');

        # config appliquee / bornee / invalide.
        my $r_cfg = $runner->run_script('topicreminder.pl', 'topic',
            channel => '#mb542', target => '#mb542', nick => 'x',
            topic => 't', args => [], config => { remind_after => '900' });
        my ($t_cfg) = grep { $_->{type} eq 'timer' } @{ $r_cfg->{response}{actions} || [] };
        $assert->ok($t_cfg && $t_cfg->{delay} == 900, 'config 900: appliquee');

        my $r_abuse = $runner->run_script('topicreminder.pl', 'topic',
            channel => '#mb542', target => '#mb542', nick => 'x',
            topic => 't', args => [], config => { remind_after => '9999' });
        my ($t_abuse) = grep { $_->{type} eq 'timer' } @{ $r_abuse->{response}{actions} || [] };
        $assert->ok($t_abuse && $t_abuse->{delay} == 300,
            'config 9999: hors bornes, retour au defaut');

        my $r_bad = $runner->run_script('topicreminder.pl', 'topic',
            channel => '#mb542', target => '#mb542', nick => 'x',
            topic => 't', args => [], config => { remind_after => 'soon' });
        my ($t_bad) = grep { $_->{type} eq 'timer' } @{ $r_bad->{response}{actions} || [] };
        $assert->ok($t_bad && $t_bad->{delay} == 300, 'config invalide: defaut');
    }

    # ------------------------------------------------------------------
    # [3] Bout-en-bout : livraison réelle + sémantique un-pending-par-nom
    # ------------------------------------------------------------------
    my $have_loop = eval { require IO::Async::Loop; 1 };
    if (!$have_loop) {
        $assert->ok(1, 'SKIP bout-en-bout: IO::Async::Loop indisponible');
    }
    else {
        my $loop = IO::Async::Loop->new;
        my $bus  = Mediabot::EventBus->new;
        my $irc  = IRC739->new;
        my $conf = {
            'plugins.ScriptDryRun.ACTION_MODE'    => 'apply',
            'plugins.ScriptDryRun.ALLOW_IRC'      => 'yes',
            'plugins.ScriptDryRun.EVENTS'         => 'topic=topicreminder.pl',
            'plugins.ScriptDryRun.CONFIG_topic'   => 'remind_after=1',
            'plugins.ScriptDryRun.EVENT_COOLDOWN' => '1',
        };
        my $bot = Bot739->new(irc => $irc, conf => $conf, event_bus => $bus, loop => $loop);
        $bot->{script_runner} = Mediabot::ScriptRunner->new(
            bot => $bot, script_dir => $examples, timeout => 5, max_stdout_bytes => 65536);
        $bot->{script_action_runner} = Mediabot::ScriptActionRunner->new(bot => $bot);
        my $plugin = Mediabot::Plugin::ScriptDryRun->register($bot);

        $bus->emit_report('channel_topic_observed',
            { event_type => 'topic', channel => '#mb542', nick => 'Te[u]K',
              topic => 'meeting at nine', is_self => 0 });
        $assert->ok(@{ $irc->sent } == 0, 'pipeline: silence immediat');
        $assert->ok($bot->script_action_runner->pending_timer_count == 1,
            'pipeline: rappel arme (config 1s)');

        # Second topic pendant le pending : l'armement echoue, run non-ok,
        # le rappel ORIGINAL reste arme — la limitation documentee, prouvee.
        select(undef, undef, undef, 1.05);  # laisser passer le cooldown 1s
        $bus->emit_report('channel_topic_observed',
            { event_type => 'topic', channel => '#mb542', nick => 'other',
              topic => 'changed again', is_self => 0 });
        my $lr = $plugin->last_result || {};
        $assert->ok(!$lr->{ok} && $bot->script_action_runner->pending_timer_count == 1,
            'pipeline: second armement refuse (un pending par nom), l\'original conserve');

        $loop->delay_future(after => 1.2)->get;
        $assert->ok(@{ $irc->sent } == 1
            && ($irc->sent->[0][2] || '') eq '#mb542'
            && ($irc->sent->[0][3] || '') =~ /topic reminder: meeting at nine \(set by Te\[u\]K\)/,
            'pipeline: le rappel ORIGINAL livre topic et auteur dans le canal');
        $assert->ok($bot->script_action_runner->pending_timer_count == 0, 'slot libere');

        $plugin->unregister;
    }

    # ------------------------------------------------------------------
    # [4] Docs
    # ------------------------------------------------------------------
    {
        my $readme = _slurp_739(File::Spec->catfile('.', 'plugins', 'scripts', 'README.md'));
        $assert->like($readme, qr/topicreminder\.pl/, 'README: exemple reference');
        $assert->like($readme, qr/remind_after=900/, 'README: config documentee');

        my $cookbook = _slurp_739(File::Spec->catfile('.', 'plugins', 'scripts', 'COOKBOOK.md'));
        $assert->like($cookbook, qr/examples\/topicreminder\.pl/, 'cookbook: recette combinee');
        $assert->like($cookbook, qr/one-pending-timer-per-name/,
            'cookbook: la limitation est enseignee, pas cachee');
    }
};
