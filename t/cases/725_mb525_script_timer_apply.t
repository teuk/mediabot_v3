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
use TestLoopWait qw(wait_for);
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
        wait_for($loop,sub {!$action_runner->pending_timer_count && !$plugin->active_script_timer_count});

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

    # Native lifecycle regressions replace redundant production-source pins.
    if ($have_loop) {
        require Scalar::Util;
        require IO::Async::Timer::Countdown;
        my $native_new=IO::Async::Timer::Countdown->can('new');
        my $native_start=IO::Async::Timer::Countdown->can('start');
        my $native_add=IO::Async::Loop->can('add');
        my @fired;
        require JSON::PP;
        my $json=JSON::PP->new->canonical;
        my $deep=sub {my ($got,$want,$desc)=@_;$assert->is($json->encode($got),$json->encode($want),$desc)};
        no warnings qw(redefine once);
        local *Mediabot::Plugin::ScriptDryRun::_fire_script_timer=sub {
            my ($p,$path,$planned,$data)=@_;
            push @fired,$path;
            return 1;
        };
        my $fresh=sub {
            my $loop=IO::Async::Loop->really_new;
            my $runner=Mediabot::ScriptActionRunner->new;
            my $bot=Bot725->new(loop=>$loop,script_action_runner=>$runner);
            my $p=bless {bot=>$bot,active_timers=>{}},'Mediabot::Plugin::ScriptDryRun';
            return ($p,$runner,$loop,$bot);
        };
        my $arm=sub {
            my ($p,$runner,$path,$name,$data)=@_;
            $data//={channel=>'#mb525',nick=>'teuk',command=>'timer',args=>['original']};
            return $runner->apply_actions($timer_result->(name=>$name,delay=>60),{channel=>'#mb525'},
                apply=>1,schedule_timer=>sub {$p->_schedule_script_timer($path,$data,@_)});
        };
        my $same=sub {Scalar::Util::refaddr($_[0])==Scalar::Util::refaddr($_[1])};
        {
            @fired=();my ($p,$r,$loop)=$fresh->();
            $arm->($p,$r,'cancelled','same');my $old=$p->{active_timers}{same}{timer};
            my $cancel=$p->cancel_script_timer('same');
            $arm->($p,$r,'replacement','same');my $next=$p->{active_timers}{same}{timer};
            $old->invoke_event('on_expire') for 1..2;
            my $held=$p->active_script_timer_count==1 && $r->pending_timer_count==1
                && $p->{active_timers}{same} && $same->($p->{active_timers}{same}{timer},$next);
            $next->invoke_event('on_expire') for 1..2;
            $deep->([$cancel,$held?1:0,[@fired],$p->active_script_timer_count,
                $r->pending_timer_count,scalar($loop->notifiers)],
                [1,1,['replacement'],0,0,0],
                'cancel/reuse: retained old callbacks cannot fire or remove their successor; live expiry runs once');
        }
        {
            my (@got,@want);
            for my $stage (qw(constructor add start)) {
                @fired=();my ($p,$r,$loop)=$fresh->();my @retained;
                my $failed;
                {
                    local *IO::Async::Timer::Countdown::new=sub {
                        die "fixture constructor failure\n" if $stage eq 'constructor';
                        my $t=$native_new->(@_);push @retained,$t;return $t;
                    };
                    local *IO::Async::Loop::add=sub {
                        my $rv=$native_add->(@_);
                        die "fixture add failure after native add\n" if $stage eq 'add';return $rv;
                    };
                    local *IO::Async::Timer::Countdown::start=sub {
                        my $rv=$native_start->(@_);
                        die "fixture start failure after native start\n" if $stage eq 'start';return $rv;
                    };
                    $failed=$arm->($p,$r,'failed','recover');
                }
                my $empty=[$p->active_script_timer_count,$r->pending_timer_count,scalar($loop->notifiers)];
                $arm->($p,$r,'recovered','recover');my $next=$p->{active_timers}{recover}{timer};
                $_->invoke_event('on_expire') for @retained;
                my $held=$p->active_script_timer_count==1 && $r->pending_timer_count==1;
                $next->invoke_event('on_expire');
                push @got,[$stage,$failed->{applied_ok}?1:0,$empty,$held?1:0,[@fired],
                    $p->active_script_timer_count,$r->pending_timer_count,scalar($loop->notifiers)];
                push @want,[$stage,0,[0,0,0],1,['recovered'],0,0,0];
            }
            $deep->(\@got,\@want,
                'native constructor/add/start failures leave no ownership or notifier and cannot fire after retry');
        }
        {
            @fired=();my ($p,$r,$loop)=$fresh->();my ($retained,$once);
            my $plan;
            {
                local *IO::Async::Timer::Countdown::start=sub {
                    my $rv=$native_start->(@_);
                    unless ($once++) {$retained=$_[0];$retained->invoke_event('on_expire')}
                    return $rv;
                };
                $plan=$arm->($p,$r,'inline','inline');
            }
            my $immediate=[$p->active_script_timer_count,$r->pending_timer_count,scalar($loop->notifiers)];
            $retained->invoke_event('on_expire');
            $deep->([$plan->{applied_ok}?1:0,$immediate,[@fired],$p->active_script_timer_count,
                $r->pending_timer_count,scalar($loop->notifiers)], [1,[0,0,0],['inline'],0,0,0],
                'inline native expiry is already owned and cannot be republished as a phantom active timer');
        }
        {
            @fired=();my ($p,$r,$loop)=$fresh->();my ($old,$next,$once,$successor);
            my $plan;
            {
                local *IO::Async::Timer::Countdown::start=sub {
                    my $rv=$native_start->(@_);
                    unless ($once++) {
                        $old=$_[0];$old->invoke_event('on_expire');
                        $successor=$arm->($p,$r,'second','reentrant');
                        $next=$p->{active_timers}{reentrant}{timer};
                        die "fixture start failure after inline expiry and replacement\n";
                    }
                    return $rv;
                };
                $plan=$arm->($p,$r,'first','reentrant');
            }
            $old->invoke_event('on_expire');
            my $held=$p->{active_timers}{reentrant} && $same->($p->{active_timers}{reentrant}{timer},$next)
                && $r->pending_timer_count==1;
            $next->invoke_event('on_expire');
            $deep->([$plan->{applied_ok}?1:0,$successor->{applied_ok}?1:0,$held?1:0,
                [@fired],$p->active_script_timer_count,$r->pending_timer_count,scalar($loop->notifiers)],
                [0,1,1,['first','second'],0,0,0],
                'an old start failure and runner rollback cannot remove a reentrantly armed same-name reservation');
        }
        {
            @fired=();my ($p,$old,$loop,$bot)=$fresh->();
            $arm->($p,$old,'original runner','owned');my $timer=$p->{active_timers}{owned}{timer};
            my $new=Mediabot::ScriptActionRunner->new;
            $new->apply_actions($timer_result->(name=>'owned'),{},apply=>1,schedule_timer=>sub {(1,undef)});
            $bot->{script_action_runner}=$new;
            $timer->invoke_event('on_expire');
            $deep->([$old->pending_timer_count,$new->pending_timer_count,[@fired],
                $p->active_script_timer_count,scalar($loop->notifiers)],
                [0,1,['original runner'],0,0],
                'expiry releases its captured runner reservation while a replacement runner retains its own name');
            $new->release_timer('owned');
        }
        {
            @fired=();my ($p,$r,$loop,$bot)=$fresh->();
            my $payload={private_payload=>'original context'};my $weak_payload=$payload;
            Scalar::Util::weaken($weak_payload);
            my $data={channel=>'#mb525',args=>[],config=>$payload};
            $arm->($p,$r,'discarded','lifetime',$data);
            my $retained=$p->{active_timers}{lifetime}{timer};
            undef $data;undef $payload;
            $p->cancel_script_timer('lifetime');
            my $weak_plugin=$p;Scalar::Util::weaken($weak_plugin);
            my $weak_loop=$loop;Scalar::Util::weaken($weak_loop);
            undef $p;delete $bot->{loop};undef $loop;undef $bot;
            $retained->invoke_event('on_expire');
            $deep->([defined($weak_payload)?1:0,defined($weak_plugin)?1:0,
                defined($weak_loop)?1:0,[@fired],$r->pending_timer_count], [0,0,0,[],0],
                'a retained cancelled timer owns neither its payload, plugin nor loop and remains harmless');
        }
        {
            @fired=();my ($p,$r,$loop)=$fresh->();my @retained;
            for my $name (qw(first second)) {
                $arm->($p,$r,$name,$name);push @retained,$p->{active_timers}{$name}{timer};
            }
            my $count=$p->cancel_script_timers;
            $_->invoke_event('on_expire') for @retained;
            $deep->([$count,[@fired],$p->active_script_timer_count,
                $r->pending_timer_count,scalar($loop->notifiers)], [2,[],0,0,0],
                'bulk cancellation revokes each native occurrence before retained callbacks can execute');
        }
        {
            my ($p,$r,$loop)=$fresh->();
            my $timer=IO::Async::Timer::Countdown->new(delay=>60,on_expire=>sub {});
            $loop->add($timer);$timer->start;
            $p->{active_timers}{legacy}=$timer;$r->{pending_timers}{legacy}=1;
            my $cancel=$p->cancel_script_timer('legacy');
            $deep->([$cancel,$p->active_script_timer_count,$r->pending_timer_count,
                scalar($loop->notifiers)], [1,0,0,0],
                'legacy raw-timer records and scalar reservations remain cancellable');
        }
    }

    # Keep user-facing docs and fixture hygiene in compact checks. Native
    # policy and lifecycle tests above replace the former production-source pins.
    {
        my $sample=_slurp_725('mediabot.sample.conf');
        my $readme=_slurp_725('plugins/scripts/README.md');
        $assert->ok($sample=~/timer re-runs the SAME script/ && $sample!~/is not applied yet/
            && $readme=~/### Timer actions/ && $readme!~/not implemented for application yet/,
            'sample and script documentation retain the applied same-script timer contract');
        $assert->ok(!-e File::Spec->catfile('.', 't', 'tmp_mb525_scripts', 'timer_echo.pl'),
            'the executable fixture remains temporary rather than tracked generated state');
    }
};
