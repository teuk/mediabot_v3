# t/cases/743_mb546_topicreminder_restore.t
# =============================================================================
# mb546 — topicreminder v2 : mode « restore » — le rappel différé RE-SET le
# topic via l'action topic (mb545) au lieu de le re-poster en reply. La
# démonstration canonique que la config par route peut sélectionner un TYPE
# d'action, et que la triple gate s'applique aux runs différés comme aux
# immédiats.
#
# Contrats :
#   [1] défaut inchangé : sans mode (ou mode invalide), comportement remind
#       à l'identique (zéro régression sur le 739) ;
#   [2] run réel mode=restore : timer -> action topic (texte = topic
#       d'origine) + log, AUCUNE reply ; topic vide -> rien ; remind_after
#       toujours honoré en restore ;
#   [3] bout-en-bout triple gate ouverte : le rappel différé envoie un TOPIC
#       réel dans le canal d'origine ;
#   [4] bout-en-bout gate fermée (ALLOW_TOPIC absent) : le différé échoue
#       proprement — apply error 'topic actions require allow_topic' visible
#       dans last_result, rien d'envoyé — la référence n'escamote pas ses
#       prérequis ;
#   [5] docs : README et cookbook enseignent le mode et la gate.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

use Mediabot::EventBus;
use Mediabot::ScriptRunner;
use Mediabot::ScriptActionRunner;
use Mediabot::Plugin::ScriptDryRun;

sub _slurp_743 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

{ package L743; sub new { bless {}, shift } sub log { 1 } }

{
    package IRC743;
    sub new { bless { sent => [] }, shift }
    sub send_message { my ($self, @args) = @_; push @{ $self->{sent} }, \@args; 1 }
    sub sent { $_[0]->{sent} }
}

{
    package Bot743;
    sub new { my ($class, %h) = @_; bless {%h, logger => L743->new}, $class }
    sub events               { $_[0]->{event_bus} }
    sub script_runner        { $_[0]->{script_runner} }
    sub script_action_runner { $_[0]->{script_action_runner} }
    sub getLoop              { $_[0]->{loop} }
    sub run_script_actions_dry { die "dry path must not run in apply mode" }
}

my $examples = File::Spec->catdir('plugins', 'scripts', 'examples');

my $mk_env = sub {
    my (%conf_extra) = @_;
    my $loop = IO::Async::Loop->new;
    my $bus  = Mediabot::EventBus->new;
    my $irc  = IRC743->new;
    my $conf = {
        'plugins.ScriptDryRun.ACTION_MODE'    => 'apply',
        'plugins.ScriptDryRun.ALLOW_IRC'      => 'yes',
        'plugins.ScriptDryRun.EVENTS'         => 'topic=topicreminder.pl',
        'plugins.ScriptDryRun.EVENT_COOLDOWN' => '1',
        %conf_extra,
    };
    my $bot = Bot743->new(irc => $irc, conf => $conf, event_bus => $bus, loop => $loop);
    $bot->{script_runner} = Mediabot::ScriptRunner->new(
        bot => $bot, script_dir => $examples, timeout => 5, max_stdout_bytes => 65536);
    $bot->{script_action_runner} = Mediabot::ScriptActionRunner->new(bot => $bot);
    my $plugin = Mediabot::Plugin::ScriptDryRun->register($bot);
    return ($bot, $bus, $irc, $plugin, $loop);
};

return sub {
    my ($assert) = @_;

    my $runner = Mediabot::ScriptRunner->new(script_dir => $examples, timeout => 5);

    # ------------------------------------------------------------------
    # [1] Défaut inchangé
    # ------------------------------------------------------------------
    {
        my $r = $runner->run_script('topicreminder.pl', 'timer',
            channel => '#mb546', target => '#mb546', nick => 'teuk',
            topic => 'stable topic', args => [],
            timer_name => 'topic_reminder__mb546', timer_delay => 300);
        my @replies = grep { ($_->{type} || '') eq 'reply' } @{ $r->{response}{actions} || [] };
        my @topics  = grep { ($_->{type} || '') eq 'topic' } @{ $r->{response}{actions} || [] };
        $assert->ok(@replies == 1 && !@topics
            && $replies[0]{text} =~ /topic reminder: stable topic/,
            'sans mode: remind par defaut, inchange');

        my $r_bad = $runner->run_script('topicreminder.pl', 'timer',
            channel => '#mb546', target => '#mb546', nick => 'teuk',
            topic => 't', args => [], config => { mode => 'banana' },
            timer_name => 'x', timer_delay => 300);
        my @rb = grep { ($_->{type} || '') eq 'reply' } @{ $r_bad->{response}{actions} || [] };
        $assert->ok(@rb == 1, 'mode invalide: retour au defaut remind');
    }

    # ------------------------------------------------------------------
    # [2] Run réel mode=restore
    # ------------------------------------------------------------------
    {
        my $r = $runner->run_script('topicreminder.pl', 'timer',
            channel => '#mb546', target => '#mb546', nick => 'teuk',
            topic => 'the real topic', args => [], config => { mode => 'restore' },
            timer_name => 'topic_reminder__mb546', timer_delay => 300);
        my $actions = $r->{response}{actions} || [];
        my ($topic_a) = grep { ($_->{type} || '') eq 'topic' } @$actions;
        my @replies   = grep { ($_->{type} || '') eq 'reply' } @$actions;
        my ($log_a)   = grep { ($_->{type} || '') eq 'log' } @$actions;
        $assert->ok($topic_a && ($topic_a->{text} || '') eq 'the real topic',
            'restore: action topic avec le topic d\'origine');
        $assert->ok(!@replies, 'restore: aucune reply');
        $assert->like(($log_a->{text} || ''), qr/restored topic on #mb546 \(set by teuk\)/,
            'restore: log explicite');
        $assert->ok(!exists $topic_a->{target}, 'restore: pas de champ target emis');

        # Armement: remind_after honore aussi en restore.
        my $r_arm = $runner->run_script('topicreminder.pl', 'topic',
            channel => '#mb546', target => '#mb546', nick => 'teuk',
            topic => 't', args => [],
            config => { mode => 'restore', remind_after => '900' });
        my ($t) = grep { ($_->{type} || '') eq 'timer' } @{ $r_arm->{response}{actions} || [] };
        $assert->ok($t && $t->{delay} == 900, 'restore: remind_after honore');

        # Topic vide: rien.
        my $r_c = $runner->run_script('topicreminder.pl', 'timer',
            channel => '#mb546', target => '#mb546', nick => 'x', topic => '',
            args => [], config => { mode => 'restore' },
            timer_name => 'y', timer_delay => 300);
        my @any = grep { ($_->{type} || '') =~ /^(topic|reply)$/ } @{ $r_c->{response}{actions} || [] };
        $assert->ok($r_c->{ok} && !@any, 'restore: topic vide, rien a re-set');
    }

    # ------------------------------------------------------------------
    # [3] + [4] Bout-en-bout : gate ouverte puis fermée
    # ------------------------------------------------------------------
    my $have_loop = eval { require IO::Async::Loop; 1 };
    if (!$have_loop) {
        $assert->ok(1, 'SKIP bout-en-bout: IO::Async::Loop indisponible');
    }
    else {
        # Gate ouverte: TOPIC reellement envoye par le differe.
        my ($bot, $bus, $irc, $plugin, $loop) = $mk_env->(
            'plugins.ScriptDryRun.ALLOW_TOPIC'  => 'yes',
            'plugins.ScriptDryRun.CONFIG_topic' => 'remind_after=1;mode=restore',
        );
        $bus->emit_report('channel_topic_observed',
            { event_type => 'topic', channel => '#mb546', nick => 'teuk',
              topic => 'be excellent', is_self => 0 });
        $assert->ok(@{ $irc->sent } == 0
            && $bot->script_action_runner->pending_timer_count == 1,
            'gate ouverte: silence immediat, rappel arme');

        $loop->delay_future(after => 1.2)->get;
        $assert->ok(@{ $irc->sent } == 1
            && $irc->sent->[0][0] eq 'TOPIC'
            && ($irc->sent->[0][2] || '') eq '#mb546'
            && ($irc->sent->[0][3] || '') eq 'be excellent',
            'gate ouverte: le differe RE-SET le topic d\'origine dans le canal');
        $plugin->unregister;

        # Gate fermee: apply error dedie, rien d'envoye.
        my ($bot2, $bus2, $irc2, $plugin2, $loop2) = $mk_env->(
            'plugins.ScriptDryRun.CONFIG_topic' => 'remind_after=1;mode=restore',
        );
        $bus2->emit_report('channel_topic_observed',
            { event_type => 'topic', channel => '#mb546', nick => 'teuk',
              topic => 'blocked', is_self => 0 });
        $loop2->delay_future(after => 1.2)->get;
        my $lr = $plugin2->last_result || {};
        my @errs = @{ ($lr->{action_plan} || {})->{apply_errors} || [] };
        $assert->ok(!$lr->{ok}
            && (grep { ($_->{error} || '') eq 'topic actions require allow_topic' } @errs) == 1,
            'gate fermee: erreur dediee visible dans last_result');
        $assert->ok(@{ $irc2->sent } == 0, 'gate fermee: rien d\'envoye');
        $plugin2->unregister;
    }

    # ------------------------------------------------------------------
    # [5] Docs
    # ------------------------------------------------------------------
    {
        my $readme = _slurp_743(File::Spec->catfile('.', 'plugins', 'scripts', 'README.md'));
        $assert->like($readme, qr/mode=restore/, 'README: mode restore documente');

        my $cookbook = _slurp_743(File::Spec->catfile('.', 'plugins', 'scripts', 'COOKBOOK.md'));
        $assert->like($cookbook, qr/CONFIG_topic=mode=restore/, 'cookbook: recette a jour');
        $assert->like($cookbook, qr/applies to deferred runs exactly as to immediate ones/,
            'cookbook: la gate differee est enseignee');

        my $src = _slurp_743(File::Spec->catfile($examples, 'topicreminder.pl'));
        $assert->like($src, qr/mode=restore/, 'script: header documente restore');
    }
};
