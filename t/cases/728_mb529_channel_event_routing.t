# t/cases/728_mb529_channel_event_routing.t
# =============================================================================
# mb529 — extension du protocole d'évènements : join/part/topic routés vers
# les scripts Perl/Python/Tcl (round « C » de l'arc plugins).
#
# Design contracté ici :
#   [1] cœur : Mediabot::observe_channel_event($type, %data) émet
#       channel_<type>_observed sur l'EventBus (contexte scalaire, is_self
#       normalisé, types inconnus refusés) ; les trois handlers de mediabot.pl
#       l'appellent sous eval (garde statique) ;
#   [2] plugin : clé EVENTS (whitelist join/part/topic, pas de fallback
#       SCRIPT), abonnement aux seuls évènements routés, unregister propre ;
#   [3] garde-fous : is_self ignoré ; cooldown par (évènement, canal)
#       (EVENT_COOLDOWN borné 1..3600, défaut 10, démarre à l'ACCEPTATION) ;
#   [4] pipeline : dry-run planifie sans appliquer ; apply applique avec
#       ALLOW_IRC + garde de scope mb524 (reply vers un autre canal rejetée) ;
#       un script d'évènement peut armer un timer (mb525) ;
#   [5] partyline : status expose event_routes/event_map/event_cooldown et les
#       compteurs ;
#   [6] docs : sample.conf + README.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;
use File::Temp qw(tempdir);

use Mediabot::EventBus;
use Mediabot::Partyline;
use Mediabot::ScriptRunner;
use Mediabot::ScriptActionRunner;
use Mediabot::Plugin::ScriptDryRun;

sub _slurp_728 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

{ package L728; sub new { bless {}, shift } sub log { 1 } }

{
    package IRC728;
    sub new { bless { sent => [] }, shift }
    sub send_message { my ($self, @args) = @_; push @{ $self->{sent} }, \@args; 1 }
    sub sent { $_[0]->{sent} }
}

{
    package PM728;
    sub new { my ($class, $plugin) = @_; bless { plugin => $plugin }, $class }
    sub object_for {
        my ($self, $name) = @_;
        return $self->{plugin} if $name eq 'Mediabot::Plugin::ScriptDryRun';
        return undef;
    }
}

{
    package Bot728;
    sub new { my ($class, %h) = @_; bless {%h, logger => L728->new}, $class }
    sub events               { $_[0]->{event_bus} }
    sub plugin_manager       { $_[0]->{pm} }
    sub script_runner        { $_[0]->{script_runner} }
    sub script_action_runner { $_[0]->{script_action_runner} }
    sub getLoop              { $_[0]->{loop} }
    sub run_script_actions_dry {
        my ($self, $script, $event, %data) = @_;
        my $script_result = $self->{script_runner}->run_script($script, $event, %data);
        my $action_plan   = $self->{script_action_runner}->apply_actions_dry(
            $script_result,
            { event => $event, channel => $data{channel}, target => $data{target},
              nick => $data{nick}, args => $data{args} },
        );
        return {
            ok            => ($script_result->{ok} && $action_plan->{ok}) ? 1 : 0,
            dry_run       => 1,
            script_result => $script_result,
            action_plan   => $action_plan,
        };
    }
}

# Fixture : greet.pl répond au join, topicwatch réagit au topic, et le script
# part tente une reply HORS canal pour prouver la garde de scope.
my $script_dir = tempdir('mediabot_mb529_XXXXXX', TMPDIR => 1, CLEANUP => 1);

sub _write_fixture {
    my ($name, $body) = @_;
    my $path = File::Spec->catfile($script_dir, $name);
    open my $fh, '>:encoding(UTF-8)', $path or die "cannot create $path: $!";
    print {$fh} $body;
    close $fh or die "cannot close $path: $!";
    return $path;
}

_write_fixture('greet.pl', <<'FIX');
#!/usr/bin/env perl
use strict; use warnings;
use JSON::PP qw(decode_json encode_json);
my $p = eval { decode_json(do { local $/; <STDIN> } || '{}') } || {};
my $d = ref($p->{data}) eq 'HASH' ? $p->{data} : {};
my $nick = $d->{nick} // 'someone';
my $ev   = $p->{event} // 'unknown';
print encode_json({ protocol => 'mediabot-script-v1', ok => JSON::PP::true,
    actions => [
        { type => 'reply', text => "welcome $nick (event=$ev)" },
        { type => 'log', level => 'info', text => "greeted $nick" },
    ]});
FIX

_write_fixture('escape.pl', <<'FIX');
#!/usr/bin/env perl
use strict; use warnings;
use JSON::PP qw(decode_json encode_json);
my $p = eval { decode_json(do { local $/; <STDIN> } || '{}') } || {};
print encode_json({ protocol => 'mediabot-script-v1', ok => JSON::PP::true,
    actions => [ { type => 'reply', target => '#elsewhere', text => 'sneaky' } ]});
FIX

_write_fixture('topictimer.pl', <<'FIX');
#!/usr/bin/env perl
use strict; use warnings;
use JSON::PP qw(decode_json encode_json);
my $p = eval { decode_json(do { local $/; <STDIN> } || '{}') } || {};
my $d = ref($p->{data}) eq 'HASH' ? $p->{data} : {};
my $ev = $p->{event} // 'unknown';
my @actions;
if ($ev eq 'timer') {
    @actions = ( { type => 'reply', text => 'topic settled' } );
}
else {
    my $topic = $d->{topic} // '';
    @actions = (
        { type => 'reply', text => "topic seen: $topic" },
        { type => 'timer', name => 'topic_settle', delay => 1 },
    );
}
print encode_json({ protocol => 'mediabot-script-v1', ok => JSON::PP::true, actions => \@actions });
FIX

my $mk_bot = sub {
    my (%conf_extra) = @_;
    my $bus = Mediabot::EventBus->new;
    my $irc = IRC728->new;
    my $conf = {
        'plugins.ScriptDryRun.ACTION_MODE' => 'apply',
        'plugins.ScriptDryRun.ALLOW_IRC'   => 'yes',
        %conf_extra,
    };
    my $bot = Bot728->new(irc => $irc, conf => $conf, event_bus => $bus);
    $bot->{script_runner} = Mediabot::ScriptRunner->new(
        bot => $bot, script_dir => $script_dir, timeout => 5, max_stdout_bytes => 65536);
    $bot->{script_action_runner} = Mediabot::ScriptActionRunner->new(bot => $bot);
    return ($bot, $bus, $irc);
};

return sub {
    my ($assert) = @_;

    # ------------------------------------------------------------------
    # [1] Cœur : observe_channel_event + gardes statiques mediabot.pl
    # ------------------------------------------------------------------
    {
        my $core_ok = eval { require Mediabot::Mediabot; 1 };
        if ($core_ok) {
            my $bus = Mediabot::EventBus->new;
            my @seen;
            $bus->on(channel_join_observed => sub { push @seen, $_[0]; 1 }, name => 'mb529-probe');

            my $core = bless { event_bus => $bus, logger => L728->new }, 'Mediabot';
            my $report = $core->observe_channel_event('join',
                channel => '#mb529', nick => 'poyan', ident => 'p', host => 'h',
                is_self => 0, junk => { evil => 1 });

            $assert->ok(ref($report) eq 'HASH', 'coeur: emission retourne un rapport');
            $assert->ok(@seen == 1, 'coeur: listener join notifie');
            my $ctx = $seen[0] || {};
            $assert->ok(($ctx->{event_type} || '') eq 'join' && ($ctx->{channel} || '') eq '#mb529'
                && ($ctx->{nick} || '') eq 'poyan' && $ctx->{is_self} == 0,
                'coeur: contexte scalaire complet');
            $assert->ok(!exists $ctx->{junk}, 'coeur: cles non prevues filtrees');
            $assert->ok(!defined $core->observe_channel_event('quit', channel => '#x'),
                'coeur: type non supporte refuse');
        }
        else {
            $assert->ok(1, 'SKIP coeur: Mediabot::Mediabot non chargeable ici');
        }

        my $main_src = _slurp_728('mediabot.pl');
        for my $ev (qw(join part topic kick)) {
            $assert->like($main_src, qr/eval \{ \$mediabot->observe_channel_event\('$ev',/,
                "mediabot.pl: emission $ev cablee sous eval");
        }
        my @hooks = $main_src =~ /observe_channel_event\('(\w+)'/g;
        $assert->ok(@hooks == 4, 'mediabot.pl: exactement quatre points d\'emission (mb535: +kick)');
    }

    # ------------------------------------------------------------------
    # [2] Routage : whitelist, opt-in strict, abonnements, unregister
    # ------------------------------------------------------------------
    {
        my ($bot, $bus) = $mk_bot->(
            # mb535-B1: kick est desormais supporte; la whitelist se teste avec un
            # evenement reellement invalide (quit).
            'plugins.ScriptDryRun.EVENTS' => 'join=greet.pl, quit=evil.pl, topic=topictimer.pl',
        );
        my $plugin = Mediabot::Plugin::ScriptDryRun->register($bot);

        $assert->ok($plugin->event_routes_enabled, 'routes d\'evenements actives');
        $assert->ok(join(',', $plugin->event_route_list) eq 'join,topic',
            'whitelist: quit ignore, join/topic conserves');
        $assert->ok(($plugin->event_routes->{join} || '') eq 'greet.pl',
            'route join -> greet.pl');

        my $report = $bus->emit_report('channel_part_observed', { channel => '#x', nick => 'a' });
        $assert->ok(($report->{ran} || 0) == 0, 'part non route: aucun listener abonne');

        $plugin->unregister;
        my $after = $bus->emit_report('channel_join_observed', { channel => '#x', nick => 'a' });
        $assert->ok(($after->{ran} || 0) == 0, 'unregister retire les listeners d\'evenements');
    }

    # ------------------------------------------------------------------
    # [3] + [4] Pipeline apply : join reel, is_self, cooldown, scope
    # ------------------------------------------------------------------
    {
        my ($bot, $bus, $irc) = $mk_bot->(
            'plugins.ScriptDryRun.EVENTS'         => 'join=greet.pl, part=escape.pl',
            'plugins.ScriptDryRun.EVENT_COOLDOWN' => '2',
        );
        my $plugin = Mediabot::Plugin::ScriptDryRun->register($bot);
        $bot->{pm} = PM728->new($plugin);

        $assert->ok($plugin->event_cooldown == 2, 'cooldown lu depuis la conf');

        # join accepte -> reply dans le canal d'origine.
        $bus->emit_report('channel_join_observed',
            { event_type => 'join', channel => '#mb529', nick => 'poyan', is_self => 0 });
        $assert->ok(@{ $irc->sent } == 1
            && ($irc->sent->[0][2] || '') eq '#mb529'
            && ($irc->sent->[0][3] || '') =~ /welcome poyan \(event=join\)/,
            'join route: reply appliquee dans le canal, event transmis au script');
        $assert->ok($plugin->observed_events == 1 && $plugin->skipped_events == 0,
            'compteurs: 1 observe, 0 saute');

        # Rafale: le second join du meme canal tombe dans le cooldown.
        $bus->emit_report('channel_join_observed',
            { event_type => 'join', channel => '#mb529', nick => 'teuk2', is_self => 0 });
        $assert->ok(@{ $irc->sent } == 1, 'cooldown: pas de second run');
        $assert->ok($plugin->event_cooldown_skips == 1
            && ($plugin->{last_error} || '') =~ /cooling down/,
            'cooldown: compte et explique');

        # Autre canal: fenetre independante.
        $bus->emit_report('channel_join_observed',
            { event_type => 'join', channel => '#autre', nick => 'poyan', is_self => 0 });
        $assert->ok(@{ $irc->sent } == 2 && ($irc->sent->[1][2] || '') eq '#autre',
            'cooldown par canal: #autre tourne immediatement');

        # is_self: jamais execute.
        $bus->emit_report('channel_join_observed',
            { event_type => 'join', channel => '#mb529b', nick => 'mediabot', is_self => 1 });
        $assert->ok(@{ $irc->sent } == 2 && ($plugin->{last_error} || '') =~ /self join event/,
            'is_self: ignore avec raison explicite');

        # Garde de scope mb524: le script part vise #elsewhere depuis #mb529.
        $bus->emit_report('channel_part_observed',
            { event_type => 'part', channel => '#mb529', nick => 'poyan', is_self => 0 });
        $assert->ok(@{ $irc->sent } == 2, 'scope: la reply hors canal n\'est PAS envoyee');
        my $lr = $plugin->last_result || {};
        $assert->ok(!$lr->{ok} && ref($lr->{action_plan}) eq 'HASH',
            'scope: le run est marque non ok');
        # mb524 rejette la cible hors canal a la VALIDATION: le plan est
        # invalide (errors), et l'application refuse le plan en bloc.
        my $verrs = $lr->{action_plan}{errors} || [];
        $assert->ok(scalar(@$verrs) >= 1
            && ($verrs->[0]{error} || '') =~ /out of scope/,
            'scope: erreur de validation mb524 exposee');
        my $errs = $lr->{action_plan}{apply_errors} || [];
        $assert->like((@$errs ? $errs->[0]{error} : ''), qr/invalid/i,
            'scope: application refusee en bloc');
        $assert->ok(scalar(@$errs) >= 1, 'scope: au moins une erreur d\'application');

        $plugin->unregister;
    }

    # Timer arme depuis un script d'evenement (topic), livre apres expiration.
    my $have_loop = eval { require IO::Async::Loop; 1 };
    if (!$have_loop) {
        $assert->ok(1, 'SKIP timer evenement: IO::Async::Loop indisponible');
    }
    else {
        my $loop = IO::Async::Loop->new;
        my ($bot, $bus, $irc) = $mk_bot->(
            'plugins.ScriptDryRun.EVENTS' => 'topic=topictimer.pl',
        );
        $bot->{loop} = $loop;
        my $plugin = Mediabot::Plugin::ScriptDryRun->register($bot);

        $bus->emit_report('channel_topic_observed',
            { event_type => 'topic', channel => '#mb529', nick => 'poyan',
              topic => 'nouveau sujet', is_self => 0 });

        $assert->ok(@{ $irc->sent } == 1
            && ($irc->sent->[0][3] || '') =~ /topic seen: nouveau sujet/,
            'topic: reply immediate avec le topic transmis');
        $assert->ok($bot->script_action_runner->pending_timer_count == 1,
            'topic: timer arme depuis un script d\'evenement');

        $loop->delay_future(after => 1.6)->get;

        $assert->ok(@{ $irc->sent } == 2
            && ($irc->sent->[1][3] || '') =~ /topic settled/
            && ($irc->sent->[1][2] || '') eq '#mb529',
            'topic: livraison differee dans le canal d\'origine');
        $assert->ok($bot->script_action_runner->pending_timer_count == 0,
            'topic: slot libere');

        $plugin->unregister;
    }

    # Dry-run : planifie sans appliquer.
    {
        my ($bot, $bus, $irc) = $mk_bot->(
            'plugins.ScriptDryRun.EVENTS'      => 'join=greet.pl',
            'plugins.ScriptDryRun.ACTION_MODE' => 'dry-run',
        );
        my $plugin = Mediabot::Plugin::ScriptDryRun->register($bot);

        $bus->emit_report('channel_join_observed',
            { event_type => 'join', channel => '#mb529', nick => 'poyan', is_self => 0 });

        my $lr = $plugin->last_result || {};
        $assert->ok($lr->{dry_run} && ($lr->{event} || '') eq 'join',
            'dry-run: run marque dry avec l\'evenement');
        $assert->ok(ref($lr->{action_plan}) eq 'HASH'
            && @{ $lr->{action_plan}{planned} || [] } == 2,
            'dry-run: deux actions planifiees');
        $assert->ok(@{ $irc->sent } == 0, 'dry-run: rien d\'applique');

        $plugin->unregister;
    }

    # ------------------------------------------------------------------
    # [5] Partyline : status expose l'etat des evenements
    # ------------------------------------------------------------------
    {
        my ($bot, $bus, $irc) = $mk_bot->(
            'plugins.ScriptDryRun.EVENTS'         => 'join=greet.pl, topic=topictimer.pl',
            'plugins.ScriptDryRun.EVENT_COOLDOWN' => '30',
        );
        my $plugin = Mediabot::Plugin::ScriptDryRun->register($bot);
        $bot->{pm} = PM728->new($plugin);

        {
            package Stream728;
            sub new { bless { out => '' }, shift }
            sub write { $_[0]->{out} .= $_[1]; 1 }
            sub out { $_[0]->{out} }
        }
        my $party = bless { bot => $bot }, 'Mediabot::Partyline';
        my $s = Stream728->new;
        $party->_cmd_scriptdryrun($s, 1, 'status');
        my $out = $s->out;

        $assert->like($out, qr/event_routes: enabled/, 'status: event_routes enabled');
        $assert->like($out, qr/event_map: join=greet\.pl,topic=topictimer\.pl/,
            'status: event_map trie et complet');
        $assert->like($out, qr/event_cooldown: 30s/, 'status: cooldown expose');
        $assert->like($out, qr/observed_events: 0/, 'status: compteur observe');
        $assert->like($out, qr/skipped_events: 0 \(cooldown: 0\)/, 'status: compteurs de skip');

        $plugin->unregister;

        # Sans routes: une seule ligne, pas de details.
        my ($bot2) = $mk_bot->();
        my $plugin2 = Mediabot::Plugin::ScriptDryRun->register($bot2);
        $bot2->{pm} = PM728->new($plugin2);
        my $party2 = bless { bot => $bot2 }, 'Mediabot::Partyline';
        my $s2 = Stream728->new;
        $party2->_cmd_scriptdryrun($s2, 1, 'status');
        $assert->like($s2->out, qr/event_routes: disabled/, 'status: disabled sans routes');
        $assert->unlike($s2->out, qr/event_map:/, 'status: pas de details sans routes');
        $plugin2->unregister;
    }

    # ------------------------------------------------------------------
    # [6] Gardes de documentation et de source
    # ------------------------------------------------------------------
    {
        my $core_src = _slurp_728(File::Spec->catfile('.', 'Mediabot', 'Mediabot.pm'));
        $assert->like($core_src, qr/mb529-B1/, 'marqueur mb529 dans Mediabot.pm');
        $assert->like($core_src, qr/sub observe_channel_event/, 'point d\'entree coeur present');

        my $plugin_src = _slurp_728(File::Spec->catfile('.', 'Mediabot', 'Plugin', 'ScriptDryRun.pm'));
        $assert->like($plugin_src, qr/mb529-B1/, 'marqueur mb529 dans ScriptDryRun');
        $assert->unlike($plugin_src, qr/`[^`]+`/, 'aucun backtick apparie (garde mb203)');

        my $sample = _slurp_728(File::Spec->catfile('.', 'mediabot.sample.conf'));
        $assert->like($sample, qr/^## EVENTS=join=examples\/greet\.pl/m, 'sample conf documente EVENTS');
        $assert->like($sample, qr/^## EVENT_COOLDOWN=10/m, 'sample conf documente EVENT_COOLDOWN');

        my $readme = _slurp_728(File::Spec->catfile('.', 'plugins', 'scripts', 'README.md'));
        $assert->like($readme, qr/## Channel events \(join\/part\/topic\/kick\)/, 'README: section evenements');
        $assert->like($readme, qr/no `SCRIPT` fallback/, 'README: opt-in strict documente');
        $assert->like($readme, qr/EVENT_COOLDOWN/, 'README: cooldown documente');
    }
};
