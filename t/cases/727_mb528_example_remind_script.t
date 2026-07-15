# t/cases/727_mb528_example_remind_script.t
# =============================================================================
# mb528 — exemple livré exploitant l'évènement timer : examples/remind.pl
# (routé `premind` dans la configuration d'exemple).
#
# L'arc mb525/mb527 a livré l'application des timers et leur visibilité ;
# mb528 livre le script de RÉFÉRENCE que les auteurs copieront. Ce test
# contracte donc trois niveaux :
#   1. statique : le script déclare protocol + ok, style des autres exemples ;
#   2. exécution réelle via ScriptRunner + validation via apply_actions_dry :
#      commande valide -> reply + timer bien formé + log ; entrées invalides
#      (délai absent/0/hors borne, message vide) -> usage, JAMAIS de timer ;
#      évènement timer -> livraison du message reconstruit depuis les args
#      d'origine, JAMAIS de nouveau timer (les chaînes sont interdites) ;
#      nick exotique -> nom de timer sanitizé [A-Za-z0-9_.-] et <= 64 ;
#   3. bout-en-bout réel dans le pipeline apply (vraie boucle IO::Async,
#      script_dir = plugins/scripts/examples) : confirmation immédiate puis
#      PRIVMSG différé portant le message.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

use Mediabot::ScriptRunner;
use Mediabot::ScriptActionRunner;
use Mediabot::Plugin::ScriptDryRun;

sub _slurp_727 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

{ package L727; sub new { bless {}, shift } sub log { 1 } }

{
    package IRC727;
    sub new { bless { sent => [] }, shift }
    sub send_message { my ($self, @args) = @_; push @{ $self->{sent} }, \@args; 1 }
    sub sent { $_[0]->{sent} }
}

{
    package Bot727;
    sub new { my ($class, %h) = @_; bless {%h, logger => L727->new}, $class }
    sub script_runner        { $_[0]->{script_runner} }
    sub script_action_runner { $_[0]->{script_action_runner} }
    sub getLoop              { $_[0]->{loop} }
    sub run_script_actions_dry { die "dry path must not run in apply mode" }
}

my $examples = File::Spec->catdir('plugins', 'scripts', 'examples');

return sub {
    my ($assert) = @_;

    # ------------------------------------------------------------------
    # 1. Contrat statique (style mb284)
    # ------------------------------------------------------------------
    my $src = _slurp_727(File::Spec->catfile($examples, 'remind.pl'));
    $assert->like($src, qr/mediabot-script-v1/, 'remind declare le protocole');
    $assert->like($src, qr/ok\s*=>\s*JSON::PP::true/, 'remind emet ok => true explicitement');
    $assert->like($src, qr/timer-invoked run can never schedule another timer/,
        'remind documente l\'interdiction des chaines');

    # ------------------------------------------------------------------
    # 2. Exécution réelle + validation dry-run
    # ------------------------------------------------------------------
    my $runner = Mediabot::ScriptRunner->new(script_dir => $examples, timeout => 5);
    my $ar     = Mediabot::ScriptActionRunner->new;

    my $run = sub {
        my ($event, %data) = @_;
        return $runner->run_script('remind.pl', $event, %data);
    };

    # Commande valide.
    {
        my $r = $run->('public_command',
            channel => '#mb528', target => '#mb528', nick => 'Te[u]K',
            command => 'premind', args => [ '300', 'stretch', 'your', 'legs' ]);
        $assert->ok(ref($r) eq 'HASH' && $r->{ok} && ($r->{exit_code} // -1) == 0,
            'commande valide: script ok, exit 0');

        my $actions = $r->{response}{actions} || [];
        $assert->ok(@$actions == 3, 'commande valide: trois actions (reply, timer, log)');

        my ($reply) = grep { $_->{type} eq 'reply' } @$actions;
        my ($timer) = grep { $_->{type} eq 'timer' } @$actions;
        $assert->like(($reply->{text} || ''), qr/remind you in 300s/,
            'confirmation immediate avec le delai');
        $assert->ok($timer && $timer->{delay} == 300, 'action timer avec le bon delai');
        $assert->ok(($timer->{name} || '') eq 'remind_Te_u_K',
            'nom de timer derive du nick et sanitize ([ et ] -> _)');

        my $plan = $ar->apply_actions_dry($r, { channel => '#mb528' });
        $assert->ok($plan->{ok} && @{ $plan->{planned} } == 3 && !@{ $plan->{errors} },
            'le plan complet passe la validation du bridge');
    }

    # Entrées invalides -> usage, jamais de timer.
    for my $case (
        [ 'delai absent',    [ 'soon', 'tea' ] ],
        [ 'delai zero',      [ '0', 'tea' ] ],
        [ 'delai hors borne',[ '4000', 'tea' ] ],
        [ 'message vide',    [ '60' ] ],
        [ 'aucun argument',  [] ],
    ) {
        my ($label, $args) = @$case;
        my $r = $run->('public_command',
            channel => '#mb528', target => '#mb528', nick => 'poyan',
            command => 'premind', args => $args);
        my $actions = $r->{response}{actions} || [];
        my @timers = grep { ($_->{type} || '') eq 'timer' } @$actions;
        $assert->ok($r->{ok} && @$actions == 1 && !@timers,
            "$label: une seule action, pas de timer");
        $assert->like(($actions->[0]{text} || ''), qr/usage: premind <seconds 1-3600> <message>/,
            "$label: reply d'usage");
    }

    # Évènement timer -> livraison, jamais de nouveau timer.
    {
        my $r = $run->('timer',
            channel => '#mb528', target => '#mb528', nick => 'Te[u]K',
            command => 'premind', args => [ '300', 'stretch', 'your', 'legs' ],
            timer_name => 'remind_Te_u_K', timer_delay => 300);
        my $actions = $r->{response}{actions} || [];
        my ($reply) = grep { $_->{type} eq 'reply' } @$actions;
        my @timers  = grep { $_->{type} eq 'timer' } @$actions;
        $assert->like(($reply->{text} || ''), qr/reminder: stretch your legs/,
            'livraison: message reconstruit depuis les args d\'origine');
        $assert->ok(!@timers, 'livraison: aucun nouveau timer (chaines interdites)');
    }

    # Nick exotique -> nom conforme au protocole.
    {
        my $r = $run->('public_command',
            channel => '#mb528', target => '#mb528',
            nick => 'we|rd{nick}' . ('x' x 80),
            command => 'premind', args => [ '60', 'hi' ]);
        my ($timer) = grep { $_->{type} eq 'timer' } @{ $r->{response}{actions} || [] };
        $assert->ok($timer, 'nick exotique: timer emis');
        $assert->like(($timer->{name} || ''), qr/\A[A-Za-z0-9_.-]{1,64}\z/,
            'nick exotique: nom sanitize et borne a 64');
        my $plan = $ar->apply_actions_dry($r, { channel => '#mb528' });
        $assert->ok($plan->{ok}, 'nick exotique: le plan passe la validation mb235');
    }

    # ------------------------------------------------------------------
    # 3. Bout-en-bout réel dans le pipeline apply
    # ------------------------------------------------------------------
    my $have_loop = eval { require IO::Async::Loop; 1 };
    if (!$have_loop) {
        $assert->ok(1, 'SKIP bout-en-bout: IO::Async::Loop indisponible');
    }
    else {
        my $loop = IO::Async::Loop->new;
        my $irc  = IRC727->new;

        my $conf = {
            'plugins.ScriptDryRun.COMMANDS'    => 'premind',
            'plugins.ScriptDryRun.ROUTES'      => 'premind=remind.pl',
            'plugins.ScriptDryRun.ACTION_MODE' => 'apply',
            'plugins.ScriptDryRun.ALLOW_IRC'   => 'yes',
        };

        my $bot = Bot727->new(irc => $irc, conf => $conf, loop => $loop);
        $bot->{script_runner} = Mediabot::ScriptRunner->new(
            bot => $bot, script_dir => $examples, timeout => 5, max_stdout_bytes => 65536);
        $bot->{script_action_runner} = Mediabot::ScriptActionRunner->new(bot => $bot);

        my $plugin = Mediabot::Plugin::ScriptDryRun->register($bot);

        my $result = $plugin->observe_public_command({
            channel => '#mb528', target => '#mb528', nick => 'Te[u]K',
            command => 'premind', args => [ '1', 'tea', 'is', 'ready' ],
        });

        $assert->ok(ref($result) eq 'HASH' && $result->{ok},
            'pipeline: commande premind appliquee');
        $assert->ok(@{ $irc->sent } == 1
            && ($irc->sent->[0][3] || '') =~ /ok, I will remind you in 1s/,
            'pipeline: confirmation immediate envoyee');
        $assert->ok($bot->script_action_runner->pending_timer_count == 1,
            'pipeline: timer en attente');

        $loop->delay_future(after => 1.6)->get;

        $assert->ok(@{ $irc->sent } == 2, 'pipeline: livraison differee envoyee');
        $assert->like(($irc->sent->[1][3] || ''), qr/reminder: tea is ready/,
            'pipeline: le message differe porte le texte d\'origine');
        $assert->ok(($irc->sent->[1][2] || '') eq '#mb528',
            'pipeline: livraison dans le canal d\'origine (scope mb524)');
        $assert->ok($bot->script_action_runner->pending_timer_count == 0,
            'pipeline: slot libere apres livraison');

        $plugin->unregister;
    }

    # ------------------------------------------------------------------
    # 4. Gardes de documentation
    # ------------------------------------------------------------------
    {
        my $readme = _slurp_727(File::Spec->catfile('.', 'plugins', 'scripts', 'README.md'));
        $assert->like($readme, qr/`premind`\s*\|\s*Perl/, 'README: premind dans la table des exemples');
        $assert->like($readme, qr/premind=examples\/remind\.pl/, 'README: route premind documentee');
        $assert->like($readme, qr/examples\/remind\.pl.*reference implementation/s,
            'README: la section timer renvoie vers l\'exemple');

        my $sample = _slurp_727(File::Spec->catfile('.', 'mediabot.sample.conf'));
        $assert->like($sample, qr/premind=examples\/remind\.pl/, 'sample conf: route premind documentee');
        $assert->like($sample, qr/COMMANDS=hello,pyhello,tclhello,proll,p8ball,pchoose,pcalc,premind/,
            'sample conf: premind ajoute en fin de liste (contrat mb291 preserve)');
    }
};
