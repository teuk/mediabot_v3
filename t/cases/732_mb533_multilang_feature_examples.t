# t/cases/732_mb533_multilang_feature_examples.t
# =============================================================================
# mb533 — « more examples » : la matrice langages × features de l'arc était
# borgne. Les trois références de l'arc (remind/greet/topicwatch) étaient
# toutes en Perl alors que le bridge est vendu multi-langage, et `part` était
# le seul évènement sans exemple. Deux références livrées :
#
#   countdown.py  (Python) — timers + config par route, routé `pcountdown` ;
#   partwatch.tcl (Tcl)    — évènement part + champ dédié `message`.
#
# Matrice après mb533 : timers Perl+Python ; évènements join(Perl),
# topic(Perl), part(Tcl) ; config Perl+Python. Le protocole est neutre en
# langage — ces tests le prouvent en faisant tourner les VRAIS interpréteurs
# à travers le VRAI pipeline.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

use Mediabot::EventBus;
use Mediabot::ScriptRunner;
use Mediabot::ScriptActionRunner;
use Mediabot::Plugin::ScriptDryRun;

sub _slurp_732 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }
sub _which_732 { my ($bin)=@_; for my $d (split /:/, ($ENV{PATH}||'')) { return 1 if -x File::Spec->catfile($d,$bin) } return 0 }

{ package L732; sub new { bless {}, shift } sub log { 1 } }

{
    package IRC732;
    sub new { bless { sent => [] }, shift }
    sub send_message { my ($self, @args) = @_; push @{ $self->{sent} }, \@args; 1 }
    sub sent { $_[0]->{sent} }
}

{
    package Bot732;
    sub new { my ($class, %h) = @_; bless {%h, logger => L732->new}, $class }
    sub events               { $_[0]->{event_bus} }
    sub script_runner        { $_[0]->{script_runner} }
    sub script_action_runner { $_[0]->{script_action_runner} }
    sub getLoop              { $_[0]->{loop} }
    sub run_script_actions_dry { die "dry path must not run in apply mode" }
}

my $examples = File::Spec->catdir('plugins', 'scripts', 'examples');
my $have_python = _which_732('python3');
my $have_tclsh  = _which_732('tclsh');

return sub {
    my ($assert) = @_;

    # ------------------------------------------------------------------
    # Contrats statiques (style mb284) — indépendants des interpréteurs
    # ------------------------------------------------------------------
    for my $pair ([ 'countdown.py', qr/"ok": True|"ok":\s*True/ ],
                  [ 'partwatch.tcl', qr/\\"ok\\": true/ ]) {
        my ($name, $ok_re) = @$pair;
        my $src = _slurp_732(File::Spec->catfile($examples, $name));
        $assert->like($src, qr/mediabot-script-v1/, "$name declare le protocole");
        $assert->like($src, $ok_re, "$name emet ok explicitement");
        $assert->unlike($src, qr/`[^`]+`\n/, "$name: pas de backticks executables");
    }
    {
        my $tcl_src = _slurp_732(File::Spec->catfile($examples, 'partwatch.tcl'));
        $assert->like($tcl_src, qr/unexpected event/, 'partwatch gere le mauvais routage');
        my $py_src = _slurp_732(File::Spec->catfile($examples, 'countdown.py'));
        $assert->like($py_src, qr/max_seconds/, 'countdown lit config.max_seconds');
        my $py_code = join "\n", grep { !/^\s*#/ } split /\n/, $py_src;
        $assert->unlike($py_code, qr/[\x{2014}\x{2013}]/,
            'countdown: sorties ASCII (lecon mb528, commentaires exclus)');
    }

    # ------------------------------------------------------------------
    # countdown.py — exécution réelle (Python)
    # ------------------------------------------------------------------
    if (!$have_python) {
        $assert->ok(1, 'SKIP countdown: python3 indisponible');
    }
    else {
        my $runner = Mediabot::ScriptRunner->new(script_dir => $examples, timeout => 5);
        my $ar     = Mediabot::ScriptActionRunner->new;

        my $r = $runner->run_script('countdown.py', 'public_command',
            channel => '#mb533', target => '#mb533', nick => 'Te[u]K',
            command => 'pcountdown', args => [ '60', 'pizza' ]);
        my $actions = $r->{response}{actions} || [];
        my ($reply) = grep { $_->{type} eq 'reply' } @$actions;
        my ($timer) = grep { $_->{type} eq 'timer' } @$actions;
        $assert->ok($r->{ok} && @$actions == 3, 'countdown: trois actions (reply, timer, log)');
        $assert->like(($reply->{text} || ''), qr/pizza: 60s, starting now/,
            'countdown: annonce avec le label');
        $assert->ok($timer && $timer->{delay} == 60 && $timer->{name} eq 'countdown_Te_u_K',
            'countdown: timer avec nom sanitize (protocole neutre en langage)');
        my $plan = $ar->apply_actions_dry($r, { channel => '#mb533' });
        $assert->ok($plan->{ok} && @{ $plan->{planned} } == 3, 'countdown: plan valide');

        # Config par route: resserre, jamais n'assouplit.
        my $r_cfg = $runner->run_script('countdown.py', 'public_command',
            channel => '#mb533', target => '#mb533', nick => 'poyan',
            command => 'pcountdown', args => [ '300', 'tea' ],
            config => { max_seconds => '120' });
        my @t_cfg = grep { ($_->{type} || '') eq 'timer' } @{ $r_cfg->{response}{actions} || [] };
        my ($u_cfg) = grep { $_->{type} eq 'reply' } @{ $r_cfg->{response}{actions} || [] };
        $assert->ok(!@t_cfg, 'countdown config 120: 300s refuse');
        $assert->like(($u_cfg->{text} || ''), qr/usage: pcountdown <seconds 1-120>/,
            'countdown config 120: usage a la borne effective');

        my $r_abuse = $runner->run_script('countdown.py', 'public_command',
            channel => '#mb533', target => '#mb533', nick => 'poyan',
            command => 'pcountdown', args => [ '4000', 'x' ],
            config => { max_seconds => '9999' });
        my @t_abuse = grep { ($_->{type} || '') eq 'timer' } @{ $r_abuse->{response}{actions} || [] };
        $assert->ok(!@t_abuse, 'countdown config 9999: le plafond protocolaire gagne');

        # Event timer: livraison reconstruite depuis les args d'origine.
        my $r_t = $runner->run_script('countdown.py', 'timer',
            channel => '#mb533', target => '#mb533', nick => 'Te[u]K',
            command => 'pcountdown', args => [ '60', 'pizza' ],
            timer_name => 'countdown_Te_u_K', timer_delay => 60);
        my ($reply_t) = grep { $_->{type} eq 'reply' } @{ $r_t->{response}{actions} || [] };
        my @t_t = grep { ($_->{type} || '') eq 'timer' } @{ $r_t->{response}{actions} || [] };
        $assert->like(($reply_t->{text} || ''), qr/time! pizza is up/,
            'countdown timer: label reconstruit depuis les args');
        $assert->ok(!@t_t, 'countdown timer: aucun nouveau timer (chaines interdites)');
    }

    # ------------------------------------------------------------------
    # partwatch.tcl — exécution réelle (Tcl)
    # ------------------------------------------------------------------
    if (!$have_tclsh) {
        $assert->ok(1, 'SKIP partwatch: tclsh indisponible');
    }
    else {
        my $runner = Mediabot::ScriptRunner->new(script_dir => $examples, timeout => 5);
        my $ar     = Mediabot::ScriptActionRunner->new;

        my $r = $runner->run_script('partwatch.tcl', 'part',
            channel => '#mb533', target => '#mb533', nick => 'poyan',
            message => 'see you tomorrow', args => []);
        my ($reply) = grep { $_->{type} eq 'reply' } @{ $r->{response}{actions} || [] };
        $assert->like(($reply->{text} || ''), qr/goodbye poyan \("see you tomorrow"\)/,
            'partwatch: raison de depart citee (champ message)');
        my $plan = $ar->apply_actions_dry($r, { event => 'part', channel => '#mb533' });
        $assert->ok($plan->{ok}, 'partwatch: plan valide');

        my $r_bare = $runner->run_script('partwatch.tcl', 'part',
            channel => '#mb533', target => '#mb533', nick => 'poyan', args => []);
        my ($reply_b) = grep { $_->{type} eq 'reply' } @{ $r_bare->{response}{actions} || [] };
        $assert->ok(($reply_b->{text} || '') eq 'goodbye poyan',
            'partwatch: sans raison, pas de parenthese');

        my $r_wrong = $runner->run_script('partwatch.tcl', 'join',
            channel => '#mb533', target => '#mb533', nick => 'poyan', args => []);
        my $actions_w = $r_wrong->{response}{actions} || [];
        my @replies_w = grep { ($_->{type} || '') eq 'reply' } @$actions_w;
        $assert->ok($r_wrong->{ok} && @$actions_w == 1 && !@replies_w
            && ($actions_w->[0]{level} || '') eq 'warning',
            'partwatch mal route: log warning, silence IRC');
    }

    # ------------------------------------------------------------------
    # Bout-en-bout pipeline : Python arme un vrai timer, Tcl répond au part
    # ------------------------------------------------------------------
    my $have_loop = eval { require IO::Async::Loop; 1 };
    if (!$have_loop || !$have_python || !$have_tclsh) {
        $assert->ok(1, 'SKIP bout-en-bout: interprete ou boucle indisponible');
    }
    else {
        my $loop = IO::Async::Loop->new;
        my $bus  = Mediabot::EventBus->new;
        my $irc  = IRC732->new;
        my $conf = {
            'plugins.ScriptDryRun.ACTION_MODE'      => 'apply',
            'plugins.ScriptDryRun.ALLOW_IRC'        => 'yes',
            'plugins.ScriptDryRun.COMMANDS'         => 'pcountdown',
            'plugins.ScriptDryRun.ROUTES'           => 'pcountdown=countdown.py',
            'plugins.ScriptDryRun.EVENTS'           => 'part=partwatch.tcl',
        };
        my $bot = Bot732->new(irc => $irc, conf => $conf, event_bus => $bus, loop => $loop);
        $bot->{script_runner} = Mediabot::ScriptRunner->new(
            bot => $bot, script_dir => $examples, timeout => 5, max_stdout_bytes => 65536);
        $bot->{script_action_runner} = Mediabot::ScriptActionRunner->new(bot => $bot);
        my $plugin = Mediabot::Plugin::ScriptDryRun->register($bot);

        $plugin->observe_public_command({
            channel => '#mb533', target => '#mb533', nick => 'poyan',
            command => 'pcountdown', args => [ '1', 'tea' ],
        });
        $assert->ok(@{ $irc->sent } == 1
            && ($irc->sent->[0][3] || '') =~ /tea: 1s, starting now/,
            'pipeline: annonce Python appliquee');
        $assert->ok($bot->script_action_runner->pending_timer_count == 1,
            'pipeline: timer Python arme');

        $loop->delay_future(after => 1.6)->get;
        $assert->ok(@{ $irc->sent } == 2
            && ($irc->sent->[1][3] || '') =~ /time! tea is up/
            && ($irc->sent->[1][2] || '') eq '#mb533',
            'pipeline: livraison differee Python dans le canal d\'origine');

        $bus->emit_report('channel_part_observed',
            { event_type => 'part', channel => '#mb533b', nick => 'teuk2',
              message => 'brb', is_self => 0 });
        $assert->ok(@{ $irc->sent } == 3
            && ($irc->sent->[2][2] || '') eq '#mb533b'
            && ($irc->sent->[2][3] || '') =~ /goodbye teuk2 \("brb"\)/,
            'pipeline: evenement part traite en Tcl dans son canal');

        $plugin->unregister;
    }

    # ------------------------------------------------------------------
    # Gardes de documentation (la garde 729 couvre déjà l'existence)
    # ------------------------------------------------------------------
    {
        my $sample = _slurp_732('mediabot.sample.conf');
        $assert->like($sample, qr/pcountdown=examples\/countdown\.py/, 'sample: route pcountdown');
        $assert->like($sample, qr/part=examples\/partwatch\.tcl/, 'sample: route part');

        my $readme = _slurp_732(File::Spec->catfile('.', 'plugins', 'scripts', 'README.md'));
        $assert->like($readme, qr/`pcountdown`\s*\|\s*Python/, 'README: pcountdown dans la table');
        $assert->like($readme, qr/partwatch\.tcl.*message/s, 'README: partwatch et le champ message');
    }
};
