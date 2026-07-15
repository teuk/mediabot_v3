# t/cases/725_mb525_script_timer_apply.t
# =============================================================================
# mb525 — application des actions timer des scripts Perl/Python/Tcl.
#
# AVANT : {type:"timer"} etait valide/planifie mais apply_actions() repondait
# "not implemented yet" — dernier type d'action a moitie cable du bridge.
#
# APRES :
#   - ScriptActionRunner porte la POLITIQUE : ordonnanceur injecte
#     (schedule_timer => coderef), plafond max_pending_timers (defaut 4,
#     borne 1..20), rejet des noms deja en attente, garde timer_depth
#     (une execution declenchee par un timer ne replanifie JAMAIS de timer).
#   - Plugin::ScriptDryRun arme un IO::Async::Timer::Countdown et re-execute
#     le MEME script avec event "timer" a l'expiration ; les actions differees
#     repassent par les portes apply / ALLOW_IRC / scope canal (mb524).
#   - unregister() annule les timers actifs et libere les slots pending.
#
# Couche 1 : politique de ScriptActionRunner avec un faux ordonnanceur.
# Couche 2 : bout-en-bout reel (boucle IO::Async + script fixture Perl).
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;
use File::Temp qw(tempdir);

use Mediabot::ScriptRunner;
use Mediabot::ScriptActionRunner;
use Mediabot::Plugin::ScriptDryRun;

sub _slurp_725 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

{ package L725; sub new { bless {}, shift } sub log { } }

{
    package IRC725;
    sub new { bless { sent => [] }, shift }
    sub send_message { my ($self, @args) = @_; push @{ $self->{sent} }, \@args; 1 }
    sub sent { $_[0]->{sent} }
}

{
    package Bot725;
    sub new {
        my ($class, %h) = @_;
        return bless {
            irc    => $h{irc},
            logger => L725->new,
            conf   => $h{conf} || {},
            loop   => $h{loop},
            script_runner        => $h{script_runner},
            script_action_runner => $h{script_action_runner},
        }, $class;
    }
    sub script_runner        { $_[0]->{script_runner} }
    sub script_action_runner { $_[0]->{script_action_runner} }
    sub getLoop              { $_[0]->{loop} }
    # observe_public_command exige la presence de cette methode meme en mode
    # apply (garde historique mb173) ; elle n'est pas appelee dans ce test.
    sub run_script_actions_dry { die "dry path must not run in apply mode" }
}

my $timer_result = sub {
    my (%over) = @_;
    return {
        response => {
            actions => [
                { type => 'timer', name => ($over{name} // 'mb525_t1'), delay => ($over{delay} // 5) },
            ],
        },
    };
};

return sub {
    my ($assert) = @_;

    # ------------------------------------------------------------------
    # Couche 1 — politique du runner avec un faux ordonnanceur
    # ------------------------------------------------------------------
    {
        my @scheduled;
        my $sched_ok = sub { push @scheduled, [ @_ ]; return (1, undef) };

        my $runner = Mediabot::ScriptActionRunner->new(logger => L725->new);
        my $ctx    = { channel => '#mb525' };

        my $plan = $runner->apply_actions($timer_result->(), $ctx,
            apply => 1, allow_irc => 0, schedule_timer => $sched_ok);

        $assert->ok($plan->{applied_ok}, 'timer applique avec ordonnanceur injecte');
        $assert->ok(@{ $plan->{applied} } == 1
            && $plan->{applied}[0]{type} eq 'timer'
            && $plan->{applied}[0]{name} eq 'mb525_t1'
            && $plan->{applied}[0]{delay} == 5,
            'entree applied porte type/name/delay');
        $assert->ok(!$plan->{apply_errors} || !@{ $plan->{apply_errors} },
            'aucune erreur d\'application');
        $assert->ok(@scheduled == 1, 'ordonnanceur appele exactement une fois');
        $assert->ok(ref($scheduled[0][0]) eq 'HASH' && $scheduled[0][0]{name} eq 'mb525_t1',
            'ordonnanceur recoit l\'action planifiee');
        $assert->ok(ref($scheduled[0][1]) eq 'HASH' && $scheduled[0][1]{channel} eq '#mb525',
            'ordonnanceur recoit le contexte');
        $assert->ok($runner->pending_timer_count == 1 && $runner->timer_pending('mb525_t1'),
            'slot pending reserve apres armement');
        $assert->ok(($runner->pending_timer_names)[0] eq 'mb525_t1',
            'pending_timer_names expose le nom');

        # Un timer NE requiert PAS allow_irc (verifie ci-dessus: allow_irc=0).

        # Doublon: meme nom encore en attente -> rejet explicite.
        my $dup = $runner->apply_actions($timer_result->(), $ctx,
            apply => 1, schedule_timer => $sched_ok);
        $assert->ok(!$dup->{applied_ok}, 'nom deja en attente -> non applique');
        $assert->like(($dup->{apply_errors}[0]{error} || ''), qr/already pending/,
            'message: already pending');
        $assert->ok(@scheduled == 1, 'ordonnanceur PAS appele pour un doublon');

        # Liberation du slot -> replanification possible.
        $assert->ok($runner->release_timer('mb525_t1') == 1, 'release_timer libere le slot');
        $assert->ok($runner->pending_timer_count == 0, 'plus aucun timer en attente');
        my $again = $runner->apply_actions($timer_result->(), $ctx,
            apply => 1, schedule_timer => $sched_ok);
        $assert->ok($again->{applied_ok}, 'replanification possible apres liberation');
    }

    # Plafond max_pending_timers.
    {
        my $sched_ok = sub { return (1, undef) };
        my $runner = Mediabot::ScriptActionRunner->new(
            logger => L725->new, max_pending_timers => 2);

        $assert->ok($runner->max_pending_timers == 2, 'plafond configurable via le constructeur');

        for my $n (qw(cap_a cap_b)) {
            my $p = $runner->apply_actions($timer_result->(name => $n), {},
                apply => 1, schedule_timer => $sched_ok);
            $assert->ok($p->{applied_ok}, "timer $n applique sous le plafond");
        }

        my $over = $runner->apply_actions($timer_result->(name => 'cap_c'), {},
            apply => 1, schedule_timer => $sched_ok);
        $assert->ok(!$over->{applied_ok}, 'plafond atteint -> non applique');
        $assert->like(($over->{apply_errors}[0]{error} || ''), qr/too many pending timers/,
            'message: too many pending timers');

        # Bornes du constructeur (coherence _constructor_positive_int).
        my $clamped = Mediabot::ScriptActionRunner->new(max_pending_timers => 999);
        $assert->ok($clamped->max_pending_timers == 20, 'plafond borne a 20');
        my $default = Mediabot::ScriptActionRunner->new;
        $assert->ok($default->max_pending_timers == 4, 'defaut = 4');
    }

    # Garde de profondeur et absence d'ordonnanceur.
    {
        my $called = 0;
        my $sched  = sub { $called++; return (1, undef) };
        my $runner = Mediabot::ScriptActionRunner->new(logger => L725->new);

        my $deep = $runner->apply_actions($timer_result->(), {},
            apply => 1, schedule_timer => $sched, timer_depth => 1);
        $assert->ok(!$deep->{applied_ok}, 'timer_depth=1 -> non applique');
        $assert->like(($deep->{apply_errors}[0]{error} || ''), qr/chaining is not allowed/,
            'message: chaining is not allowed');
        $assert->ok($called == 0 && $runner->pending_timer_count == 0,
            'profondeur 1: ni ordonnanceur ni slot consomme');

        my $none = $runner->apply_actions($timer_result->(), {}, apply => 1);
        $assert->ok(!$none->{applied_ok}, 'sans ordonnanceur -> non applique (fail closed)');
        $assert->like(($none->{apply_errors}[0]{error} || ''), qr/require a scheduler/,
            'message: require a scheduler');
    }

    # Echec de l'ordonnanceur: slot libere, erreur remontee, un die est capture.
    {
        my $runner = Mediabot::ScriptActionRunner->new(logger => L725->new);

        my $fail = $runner->apply_actions($timer_result->(), {},
            apply => 1, schedule_timer => sub { return (0, 'boucle indisponible') });
        $assert->ok(!$fail->{applied_ok}, 'echec ordonnanceur -> non applique');
        $assert->like(($fail->{apply_errors}[0]{error} || ''), qr/boucle indisponible/,
            'erreur de l\'ordonnanceur remontee');
        $assert->ok($runner->pending_timer_count == 0, 'slot libere apres echec');

        my $die = $runner->apply_actions($timer_result->(), {},
            apply => 1, schedule_timer => sub { die "explosion controlee\n" });
        $assert->ok(!$die->{applied_ok}, 'die de l\'ordonnanceur -> non applique');
        $assert->like(($die->{apply_errors}[0]{error} || ''), qr/explosion controlee/,
            'die capture et transforme en erreur');
        $assert->ok($runner->pending_timer_count == 0, 'slot libere apres die');
    }

    # ------------------------------------------------------------------
    # Couche 2 — bout-en-bout : boucle IO::Async reelle + script fixture
    # ------------------------------------------------------------------
    my $have_loop = eval { require IO::Async::Loop; 1 };
    if (!$have_loop) {
        $assert->ok(1, 'SKIP bout-en-bout: IO::Async::Loop indisponible');
    }
    else {
        my $loop = IO::Async::Loop->new;
        my $irc  = IRC725->new;

        # mb526-B2: build the executable fixture in a real temporary directory.
        # t/tmp_mb*_scripts is intentionally protected by .gitignore/commit.sh
        # as generated local state and must never be required as a tracked file.
        my $script_dir = tempdir('mediabot_mb525_XXXXXX', TMPDIR => 1, CLEANUP => 1);
        my $fixture_path = File::Spec->catfile($script_dir, 'timer_echo.pl');
        open my $fixture_fh, '>:encoding(UTF-8)', $fixture_path
            or die "cannot create $fixture_path: $!";
        print {$fixture_fh} <<'MB525_FIXTURE';
#!/usr/bin/env perl
use strict;
use warnings;
use JSON::PP qw(decode_json encode_json);

my $input   = do { local $/; <STDIN> };
my $payload = eval { decode_json($input || '{}') };
$payload = {} unless ref($payload) eq 'HASH';

my $event = defined($payload->{event}) && !ref($payload->{event})
    ? $payload->{event}
    : 'unknown';
my $data = ref($payload->{data}) eq 'HASH' ? $payload->{data} : {};
my $channel = defined($data->{channel}) && !ref($data->{channel}) && length($data->{channel})
    ? $data->{channel}
    : (defined($data->{target}) && !ref($data->{target}) ? $data->{target} : '');

my @actions;
if ($event eq 'timer') {
    my $timer_name = defined($data->{timer_name}) && !ref($data->{timer_name})
        ? $data->{timer_name}
        : 'unknown';
    @actions = (
        { type => 'reply', target => $channel, text => "timer fired: $timer_name" },
        { type => 'timer', name => 'mb525_chain', delay => 1 },
    );
}
else {
    @actions = (
        { type => 'log', level => 'info', text => 'mb525 fixture scheduling a timer' },
        { type => 'timer', name => 'mb525_demo', delay => 1 },
    );
}

print encode_json({
    protocol => 'mediabot-script-v1',
    ok       => JSON::PP::true,
    actions  => \@actions,
});
MB525_FIXTURE
        close $fixture_fh or die "cannot close $fixture_path: $!";

        my $conf = {
            'plugins.ScriptDryRun.COMMANDS'    => 'ptimer',
            'plugins.ScriptDryRun.ROUTES'      => 'ptimer=timer_echo.pl',
            'plugins.ScriptDryRun.ACTION_MODE' => 'apply',
            'plugins.ScriptDryRun.ALLOW_IRC'   => 'yes',
        };

        my $bot = Bot725->new(irc => $irc, conf => $conf, loop => $loop);

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

        my $ctx = {
            channel => '#mb525',
            target  => '#mb525',
            nick    => 'Te[u]K',
            command => 'ptimer',
            args    => [],
        };

        my $result = $plugin->observe_public_command($ctx);

        $assert->ok(ref($result) eq 'HASH' && $result->{ok},
            'commande routee: script execute et actions appliquees');
        $assert->ok($result->{action_plan}{applied_ok},
            'plan direct applique (log + timer)');
        $assert->ok($action_runner->pending_timer_count == 1
            && $action_runner->timer_pending('mb525_demo'),
            'timer mb525_demo en attente apres la commande');
        $assert->ok($plugin->active_script_timer_count == 1,
            'plugin garde une reference au timer actif');
        $assert->ok(@{ $irc->sent } == 0, 'aucune sortie IRC avant expiration');

        # Attendre l'expiration (delay=1) sur la vraie boucle.
        $loop->delay_future(after => 1.6)->get;

        $assert->ok(@{ $irc->sent } == 1, 'une sortie IRC apres expiration');
        my $sent = $irc->sent->[0] || [];
        $assert->ok(($sent->[0] || '') eq 'PRIVMSG'
            && ($sent->[2] || '') eq '#mb525'
            && ($sent->[3] || '') eq 'timer fired: mb525_demo',
            'reply differe: bon canal, bon texte, event timer recu par le script');

        $assert->ok($action_runner->pending_timer_count == 0,
            'slot pending libere apres expiration');
        $assert->ok($plugin->active_script_timer_count == 0,
            'plus de timer actif cote plugin');

        # Le fixture tente de replanifier depuis l'event timer: la chaine doit
        # avoir ete rejetee (sinon un slot mb525_chain serait en attente).
        $assert->ok(!$action_runner->timer_pending('mb525_chain'),
            'chaine de timers rejetee (timer_depth=1)');
        my $last = $plugin->{last_result};
        $assert->ok(ref($last) eq 'HASH' && ($last->{event} || '') eq 'timer',
            'last_result reflete l\'execution differee');
        $assert->ok(!$last->{action_plan}{applied_ok},
            'plan differe marque non applique a cause du timer refuse');
        $assert->like(($last->{action_plan}{apply_errors}[0]{error} || ''),
            qr/chaining is not allowed/, 'erreur de chaine exposee dans le plan differe');

        # Annulation au dechargement: replanifier puis unregister.
        my $again = $plugin->observe_public_command($ctx);
        $assert->ok(ref($again) eq 'HASH' && $again->{action_plan}{applied_ok},
            'second armement pour le test d\'annulation');
        $assert->ok($action_runner->pending_timer_count == 1,
            'timer de nouveau en attente');

        $plugin->unregister;

        $assert->ok($plugin->active_script_timer_count == 0,
            'unregister annule les timers actifs');
        $assert->ok($action_runner->pending_timer_count == 0,
            'unregister libere les slots pending');

        my $sent_before_wait = scalar @{ $irc->sent };
        $loop->delay_future(after => 1.4)->get;
        $assert->ok(scalar @{ $irc->sent } == $sent_before_wait,
            'aucun rappel differe apres annulation');
    }

    # ------------------------------------------------------------------
    # Gardes de source et de documentation
    # ------------------------------------------------------------------
    {
        my $runner_src = _slurp_725(File::Spec->catfile('.', 'Mediabot', 'ScriptActionRunner.pm'));
        $assert->like($runner_src, qr/mb525-B1/, 'marqueur mb525 present dans ScriptActionRunner');
        $assert->like($runner_src, qr/timer chaining is not allowed/, 'garde de chaine cablee');
        $assert->like($runner_src, qr/too many pending timers/, 'plafond cable');
        $assert->like($runner_src, qr/sub release_timer/, 'liberation de slot exposee');
        $assert->unlike($runner_src, qr/not implemented yet/, 'plus de stub not-implemented');

        my $plugin_src = _slurp_725(File::Spec->catfile('.', 'Mediabot', 'Plugin', 'ScriptDryRun.pm'));
        $assert->like($plugin_src, qr/IO::Async::Timer::Countdown/, 'plugin arme un timer IO::Async');
        $assert->like($plugin_src, qr/sub cancel_script_timers/, 'annulation au dechargement presente');
        $assert->like($plugin_src, qr/timer_depth => 1/, 'rappel differe execute en profondeur 1');

        my $sample_src = _slurp_725(File::Spec->catfile('.', 'mediabot.sample.conf'));
        $assert->like($sample_src, qr/timer re-runs the SAME script/, 'sample conf documente le comportement applique');
        $assert->unlike($sample_src, qr/is not applied yet/, 'sample conf ne pretend plus que timer est inapplique');

        my $readme_src = _slurp_725(File::Spec->catfile('.', 'plugins', 'scripts', 'README.md'));
        $assert->like($readme_src, qr/### Timer actions/, 'README documente les actions timer');
        $assert->unlike($readme_src, qr/not implemented for application yet/, 'README ne pretend plus que timer est inapplique');

        $assert->ok(!-e File::Spec->catfile('.', 't', 'tmp_mb525_scripts', 'timer_echo.pl'),
            'aucune fixture mb525 suivie sous t/tmp_mb*_scripts');
        my $test_src = _slurp_725(File::Spec->catfile('.', 't', 'cases', '725_mb525_script_timer_apply.t'));
        $assert->like($test_src, qr/tempdir\('mediabot_mb525_/, 'fixture mb525 creee dans un repertoire temporaire');

        # mb525-B2: les fallbacks de test doivent etre des assignations de
        # globs A L'EXECUTION. Un `sub` nomme dans un bloc `package` stub est
        # compile inconditionnellement et ecrasait les VRAIS
        # IO::Async::Timer::Countdown::new/start/stop pour toute la suite
        # partagee (ce qui tuait silencieusement les timers reels de mb525).
        for my $guarded (
            '606_mb388_release_version_identity.t',
            '607_mb389_local_startup_semantic_version_compare.t',
            '609_mb391_core_command_release_contract.t',
        ) {
            my $tsrc = _slurp_725(File::Spec->catfile('.', 't', 'cases', $guarded));
            $assert->unlike($tsrc, qr/package\s+IO::Async::Timer::Countdown;/,
                "$guarded: plus de package stub compile inconditionnellement");
            $assert->like($tsrc, qr/\Q*{'IO::Async::Timer::Countdown::new'}\E/,
                "$guarded: stub Countdown installe par glob a l'execution");
        }
    }
};
