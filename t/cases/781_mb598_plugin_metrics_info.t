# t/cases/781_mb598_plugin_metrics_info.t
# =============================================================================
# mb598 — observabilite du sous-systeme plugins v2.
#   [1] les 4 metriques sont DECLAREES dans Metrics (un inc sans declare est
#       un no-op silencieux — la declaration est le contrat).
#   [2] compteurs en conditions reelles avec le VRAI Mediabot::Metrics :
#       dispatch commande autorise -> command_total{plugin,command} ;
#       refus d'auth -> denied_total ; event route -> event_total ;
#       echec de script (commande ET event) -> failure_total{kind}.
#   [3] best-effort : sans objet metrics, les dispatchs continuent (aucun
#       die) — garanti par _pm_metric.
#   [4] .plugins info <name> : fiche complete (etat/kind/api/source,
#       commandes avec niveau+calls+help, events avec routed), inconnu
#       explique, mode LECTURE (parseur de verbes gated intact).
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use JSON::PP ();

my $DIR = tempdir(CLEANUP => 1);

{
    package Bot781;
    sub new {
        require Mediabot::CommandRegistry;
        require Mediabot::ScriptRunner;
        require Mediabot::EventBus;
        require Mediabot::Metrics;
        my ($class, $dir, %opt) = @_;
        my $self = bless { registry => Mediabot::CommandRegistry->new,
                           bus => Mediabot::EventBus->new,
                           logger => Log781->new, runs => [] }, $class;
        $self->{metrics} = Mediabot::Metrics->new(enabled => 1)
            unless $opt{no_metrics};
        $self->{runner} = Mediabot::ScriptRunner->new(bot => $self, script_dir => $dir);
        return $self;
    }
    sub registry { $_[0]{registry} }
    sub events { $_[0]{bus} }
    sub script_runner { $_[0]{runner} }
    sub script_action_runner { $_[0] }
    sub apply_actions { return { applied_ok => 1 } }
    sub checkUserLevel {
        my ($self, $ulevel, $required) = @_;
        my %tbl = ( owner => 0, master => 1, user => 3 );
        my $req = $tbl{ lc $required };
        defined $ulevel && defined $req && $ulevel <= $req ? 1 : 0;
    }
    sub get_user_from_message { return $_[1]{user} }
}
{
    package Log781; sub new { bless {}, shift } sub log { 1 }
}
{
    package User781;
    sub new { my ($c,%a)=@_; bless {%a}, $c }
    sub level { $_[0]{level} } sub is_authenticated { $_[0]{auth} ? 1 : 0 }
}
{
    package Ctx781;
    sub new { my ($c,%a)=@_; bless {%a}, $c }
    sub message { $_[0]{message} } sub nick { $_[0]{nick} }
    sub channel { $_[0]{channel} } sub args { $_[0]{args} || [] }
}
{
    package Stream781;
    sub new { bless { out => '' }, shift }
    sub write { $_[0]{out} .= $_[1]; 1 }
}

return sub {
    my ($assert) = @_;

    require Mediabot::PluginManager;
    require Mediabot::Helpers;
    require Mediabot::ScriptRunner;
    my @notices;
    no warnings 'redefine';
    local *Mediabot::Helpers::botNotice = sub { push @notices, $_[2]; 1 };
    my $run_ret = { ok => 1, response => { ok => 1, actions => [] } };
    local *Mediabot::ScriptRunner::run_script = sub {
        push @{ $_[0]{bot}{runs} }, $_[1];
        return $run_ret;
    };

    # fixtures depot : un script avec commande publique + Master + un event
    open my $sf, '>', "$DIR/mix.py" or die $!; print $sf "1\n"; close $sf;
    open my $mf, '>', "$DIR/mix.py.manifest.json" or die $!;
    print $mf JSON::PP::encode_json({
        api => 2, name => 'mix', version => '1.0',
        description => 'Metrics fixture.',
        commands => { pub781 => { help => 'Public.', level => 0 },
                      vip781 => { help => 'VIP.', level => 'Master' } },
        events => ['channel_join_observed'] });
    close $mf;

    # [1] declarations
    my $bot = Bot781->new($DIR);
    for my $name (qw(mediabot_plugin_command_total
                     mediabot_plugin_command_denied_total
                     mediabot_plugin_event_total
                     mediabot_plugin_script_failure_total)) {
        my $before = $bot->{metrics}->get($name, { probe => 'x' });
        $bot->{metrics}->inc($name, { probe => 'x' });
        my $after = $bot->{metrics}->get($name, { probe => 'x' });
        $assert->is(($after // 0) - ($before // 0), 1,
            "mb598-781: metrique declaree et incrementable — $name");
    }

    my $pm = Mediabot::PluginManager->new(bot => $bot);
    $pm->load_script_v2('mix.py');
    my $pub = $bot->registry->handler_for('pub781', 'public');
    my $vip = $bot->registry->handler_for('vip781', 'public');
    my $owner = { user => User781->new(level => 0, auth => 1) };
    my $rando = { user => User781->new(level => 3, auth => 1) };

    # [2] command_total
    $pub->(Ctx781->new(nick => 'a', channel => '#c', message => $owner));
    $pub->(Ctx781->new(nick => 'a', channel => '#c', message => $owner));
    $assert->is($bot->{metrics}->get('mediabot_plugin_command_total',
        { plugin => 'mix', command => 'pub781' }), 2,
        'mb598-781: command_total compte les dispatchs autorises');

    # denied_total : refus d auth, la commande ne compte PAS
    $vip->(Ctx781->new(nick => 'r', channel => '#c', message => $rando));
    $assert->is($bot->{metrics}->get('mediabot_plugin_command_denied_total',
        { plugin => 'mix', command => 'vip781' }), 1,
        'mb598-781: denied_total au refus du pont d auth');
    $assert->ok(!$bot->{metrics}->get('mediabot_plugin_command_total',
        { plugin => 'mix', command => 'vip781' }),
        'mb598-781: un refus ne compte pas comme dispatch');

    # event_total
    $bot->events->emit('channel_join_observed', { channel => '#c', nick => 'x' });
    $assert->is($bot->{metrics}->get('mediabot_plugin_event_total',
        { plugin => 'mix', event => 'channel_join_observed' }), 1,
        'mb598-781: event_total au routage');

    # failure_total kind=command puis kind=event
    $run_ret = { ok => 0, error => 'boom' };
    $pub->(Ctx781->new(nick => 'a', channel => '#c', message => $owner));
    $assert->is($bot->{metrics}->get('mediabot_plugin_script_failure_total',
        { plugin => 'mix', kind => 'command' }), 1,
        'mb598-781: failure_total kind=command');
    $bot->events->emit('channel_join_observed', { channel => '#c', nick => 'x' });
    $assert->is($bot->{metrics}->get('mediabot_plugin_script_failure_total',
        { plugin => 'mix', kind => 'event' }), 1,
        'mb598-781: failure_total kind=event');
    $run_ret = { ok => 1, response => { ok => 1, actions => [] } };

    # [3] best-effort sans metrics
    my $bare = Bot781->new($DIR, no_metrics => 1);
    my $pm2 = Mediabot::PluginManager->new(bot => $bare);
    $pm2->load_script_v2('mix.py');
    my $h2 = $bare->registry->handler_for('pub781', 'public');
    my $ok = eval { $h2->(Ctx781->new(nick => 'a', channel => '#c',
        message => $owner)); 1 };
    $assert->ok($ok, 'mb598-781: sans metrics le dispatch continue (best-effort)');

    # [4] .plugins info
    require Mediabot::Partyline;
    my $pl = bless { bot => $bot, users => { 7 => { level => 1 } },
                     streams => {} }, 'Mediabot::Partyline';
    $bot->{pm} = $pm;
    { no strict 'refs'; no warnings 'redefine';
      *Bot781::plugin_manager = sub { $_[0]{pm} };
      *Bot781::plugin_autoload_enabled = sub { 0 }; }
    my $stream = Stream781->new;
    $pl->_cmd_plugins($stream, 7, 'info mix');
    $assert->like($stream->{out}, qr/Plugin 'mix' \[enabled\] kind=script api=2 version=1\.0/,
        'mb598-781: fiche — identite complete');
    $assert->like($stream->{out}, qr/source: mix\.py/, 'mb598-781: fiche — source');
    # calls=3 : les 2 succes + le dispatch AUTORISE dont le script a echoue
    # (command_total compte les dispatchs passes par le pont, pas les succes).
    $assert->like($stream->{out}, qr/pub781\s+level=public\s+calls=3/,
        'mb598-781: fiche — commande publique avec compteur');
    $assert->like($stream->{out}, qr/vip781\s+level=Master\s+calls=0/,
        'mb598-781: fiche — commande Master jamais servie = 0');
    $assert->like($stream->{out}, qr/event: channel_join_observed routed=2/,
        'mb598-781: fiche — event avec compteur de routage (succes + echec routes)');
    $stream = Stream781->new;
    $pl->_cmd_plugins($stream, 7, 'info nope');
    $assert->like($stream->{out}, qr/Unknown plugin 'nope'/,
        'mb598-781: inconnu explique');

    # le parseur de verbes gated est reste intact (info = mode lecture)
    my $src = do { open my $fh, '<:encoding(UTF-8)', 'Mediabot/Partyline.pm' or die $!; local $/; <$fh> };
    $assert->like($src, qr/\Qload|loadscript|unload|reload|enable|disable|cleardata\E/,
        'mb598-781: parseur de verbes gated inchange — info hors gate');
};
