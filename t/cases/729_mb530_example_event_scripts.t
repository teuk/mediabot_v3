# t/cases/729_mb530_example_event_scripts.t
# =============================================================================
# mb530 — exemples livrés pour les routes d'évènements : greet.pl (join) et
# topicwatch.pl (topic).
#
# mb529 documentait `EVENTS=join=examples/greet.pl, topic=examples/topicwatch.pl`
# dans sample.conf et le README... sans livrer les fichiers : la configuration
# d'exemple référençait des scripts INEXISTANTS. mb530 rétablit la vérité
# documentaire en livrant les deux références, et ajoute une garde générique :
# toute route d'exemple documentée dans sample.conf doit exister sur disque.
#
# Contrats :
#   [1] statique : protocole + ok explicites (style mb284), et les deux
#       scripts restent silencieux sur IRC si routés sur un mauvais évènement ;
#   [2] exécution réelle : join -> welcome dans le canal, topic -> accusé avec
#       le topic transmis (champ dédié), topic vide -> "(cleared)" ; plans
#       validés par apply_actions_dry ;
#   [3] bout-en-bout : pipeline apply réel via EVENTS, reply dans le canal ;
#   [4] vérité documentaire : chaque script référencé par les lignes
#       #ROUTES/## EVENTS de sample.conf existe dans le dépôt.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

use Mediabot::EventBus;
use Mediabot::ScriptRunner;
use Mediabot::ScriptActionRunner;
use Mediabot::Plugin::ScriptDryRun;

sub _slurp_729 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

{ package L729; sub new { bless {}, shift } sub log { 1 } }

{
    package IRC729;
    sub new { bless { sent => [] }, shift }
    sub send_message { my ($self, @args) = @_; push @{ $self->{sent} }, \@args; 1 }
    sub sent { $_[0]->{sent} }
}

{
    package Bot729;
    sub new { my ($class, %h) = @_; bless {%h, logger => L729->new}, $class }
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
    # [1] Contrat statique
    # ------------------------------------------------------------------
    for my $name (qw(greet.pl topicwatch.pl)) {
        my $src = _slurp_729(File::Spec->catfile($examples, $name));
        $assert->like($src, qr/mediabot-script-v1/, "$name declare le protocole");
        $assert->like($src, qr/ok\s*=>\s*JSON::PP::true/, "$name emet ok => true explicitement");
        $assert->like($src, qr/unexpected event/, "$name gere le mauvais routage");
    }

    # ------------------------------------------------------------------
    # [2] Exécution réelle + validation des plans
    # ------------------------------------------------------------------
    my $runner = Mediabot::ScriptRunner->new(script_dir => $examples, timeout => 5);
    my $ar     = Mediabot::ScriptActionRunner->new;

    {
        my $r = $runner->run_script('greet.pl', 'join',
            channel => '#mb530', target => '#mb530', nick => 'poyan',
            ident => 'p', host => 'h.example', args => []);
        my $actions = $r->{response}{actions} || [];
        my ($reply) = grep { $_->{type} eq 'reply' } @$actions;
        $assert->ok($r->{ok} && @$actions == 2, 'greet/join: deux actions');
        $assert->like(($reply->{text} || ''), qr/welcome to #mb530, poyan!/,
            'greet/join: welcome avec canal et nick');
        my $plan = $ar->apply_actions_dry($r, { event => 'join', channel => '#mb530' });
        $assert->ok($plan->{ok} && @{ $plan->{planned} } == 2, 'greet/join: plan valide');
    }

    {
        my $r = $runner->run_script('greet.pl', 'topic',
            channel => '#mb530', target => '#mb530', nick => 'poyan', args => []);
        my $actions = $r->{response}{actions} || [];
        my @replies = grep { ($_->{type} || '') eq 'reply' } @$actions;
        $assert->ok($r->{ok} && @$actions == 1 && !@replies
            && ($actions->[0]{level} || '') eq 'warning',
            'greet mal route: log warning, silence IRC');
    }

    {
        my $r = $runner->run_script('topicwatch.pl', 'topic',
            channel => '#mb530', target => '#mb530', nick => 'Te[u]K',
            topic => 'release 3.4 ce soir', args => []);
        my ($reply) = grep { $_->{type} eq 'reply' } @{ $r->{response}{actions} || [] };
        $assert->like(($reply->{text} || ''), qr/topic set by Te\[u\]K: release 3\.4 ce soir/,
            'topicwatch: topic transmis via le champ dedie');
        my $plan = $ar->apply_actions_dry($r, { event => 'topic', channel => '#mb530' });
        $assert->ok($plan->{ok}, 'topicwatch: plan valide');
    }

    {
        my $r = $runner->run_script('topicwatch.pl', 'topic',
            channel => '#mb530', target => '#mb530', nick => 'Te[u]K',
            topic => '', args => []);
        my ($reply) = grep { $_->{type} eq 'reply' } @{ $r->{response}{actions} || [] };
        $assert->like(($reply->{text} || ''), qr/\(cleared\)/,
            'topicwatch: topic vide rendu "(cleared)"');
    }

    # ------------------------------------------------------------------
    # [3] Bout-en-bout : pipeline apply réel via EVENTS
    # ------------------------------------------------------------------
    {
        my $bus = Mediabot::EventBus->new;
        my $irc = IRC729->new;
        my $conf = {
            'plugins.ScriptDryRun.ACTION_MODE' => 'apply',
            'plugins.ScriptDryRun.ALLOW_IRC'   => 'yes',
            'plugins.ScriptDryRun.EVENTS'      =>
                'join=greet.pl, topic=topicwatch.pl',
        };
        my $bot = Bot729->new(irc => $irc, conf => $conf, event_bus => $bus);
        $bot->{script_runner} = Mediabot::ScriptRunner->new(
            bot => $bot, script_dir => $examples, timeout => 5, max_stdout_bytes => 65536);
        $bot->{script_action_runner} = Mediabot::ScriptActionRunner->new(bot => $bot);

        my $plugin = Mediabot::Plugin::ScriptDryRun->register($bot);

        $bus->emit_report('channel_join_observed',
            { event_type => 'join', channel => '#mb530', nick => 'poyan', is_self => 0 });
        $assert->ok(@{ $irc->sent } == 1
            && ($irc->sent->[0][2] || '') eq '#mb530'
            && ($irc->sent->[0][3] || '') =~ /welcome to #mb530, poyan!/,
            'pipeline: greet applique dans le canal du join');

        $bus->emit_report('channel_topic_observed',
            { event_type => 'topic', channel => '#mb530b', nick => 'Te[u]K',
              topic => 'nouveau', is_self => 0 });
        $assert->ok(@{ $irc->sent } == 2
            && ($irc->sent->[1][2] || '') eq '#mb530b'
            && ($irc->sent->[1][3] || '') =~ /topic set by Te\[u\]K: nouveau/,
            'pipeline: topicwatch applique dans le canal du topic');

        $plugin->unregister;
    }

    # ------------------------------------------------------------------
    # [4] Vérité documentaire : toute route d'exemple documentée existe
    # ------------------------------------------------------------------
    {
        my $sample = _slurp_729('mediabot.sample.conf');
        my %documented;
        while ($sample =~ /^#+\s*(?:ROUTES|EVENTS)=(.+)$/mg) {
            for my $entry (split /\s*,\s*/, $1) {
                my (undef, $script) = split /\s*=\s*/, $entry, 2;
                next unless defined $script && $script =~ /\Aexamples\//;
                $documented{$script} = 1;
            }
        }
        $assert->ok(scalar(keys %documented) >= 9,
            'sample conf: au moins neuf routes d\'exemple documentees');
        for my $script (sort keys %documented) {
            my $path = File::Spec->catfile('plugins', 'scripts', $script);
            $assert->ok(-f $path, "route documentee -> fichier livre: $script");
        }
    }
};
