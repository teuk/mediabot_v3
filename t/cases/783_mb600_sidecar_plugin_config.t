# t/cases/783_mb600_sidecar_plugin_config.t
# =============================================================================
# mb600 — chantier B : config par plugin dans le sidecar.
#   [1] validation FAIL-CLOSED du bloc config : cle minuscule, valeur ref,
#       valeur >512 octets, >32 cles — refus avec raison ; bloc valide passe.
#   [2] fusion : defaults du sidecar + surcharges plugins.<name>.<KEY> de la
#       conf ; surcharge invalide (>512) ignoree avec defaut conserve.
#   [3] transmission : data.config present au dispatch COMMANDE et EVENT ;
#       plugin sans bloc config = aucune cle config transmise.
#   [4] reload relit les surcharges (la conf change -> replace -> nouvelle
#       valeur effective).
#   [5] greeter du depot : sidecar declare GREETING ; EXECUTION REELLE
#       tclsh avec config -> la formule configuree sert, %s recoit le nick.
#   [6] .plugins info affiche la config effective ; cookbook regle 7.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Temp qw(tempdir);
use JSON::PP ();

my $DIR = tempdir(CLEANUP => 1);

{
    package Conf783;
    sub new { bless { kv => $_[1] || {} }, $_[0] }
    sub get { $_[0]{kv}{ $_[1] } }
    sub set783 { $_[0]{kv}{ $_[1] } = $_[2] }
}
{
    package Bot783;
    sub new {
        require Mediabot::CommandRegistry;
        require Mediabot::ScriptRunner;
        require Mediabot::EventBus;
        my ($class, $dir, $conf) = @_;
        my $self = bless { registry => Mediabot::CommandRegistry->new,
                           bus => Mediabot::EventBus->new,
                           conf => $conf, logger => Log783->new,
                           runs => [] }, $class;
        $self->{runner} = Mediabot::ScriptRunner->new(bot => $self, script_dir => $dir);
        return $self;
    }
    sub registry { $_[0]{registry} }
    sub events { $_[0]{bus} }
    sub script_runner { $_[0]{runner} }
    sub script_action_runner { $_[0] }
    sub apply_actions { return { applied_ok => 1 } }
}
{
    package Log783; sub new { bless {}, shift } sub log { 1 }
}
{
    package Ctx783;
    sub new { my ($c,%a)=@_; bless {%a}, $c }
    sub message { $_[0]{message} } sub nick { $_[0]{nick} }
    sub channel { $_[0]{channel} } sub args { $_[0]{args} || [] }
}
{
    package Stream783;
    sub new { bless { out => '' }, shift }
    sub write { $_[0]{out} .= $_[1]; 1 }
}

sub _sidecar_783 {
    my ($config, $version) = @_;
    open my $fh, '>', "$DIR/cfg.py.manifest.json" or die $!;
    print $fh JSON::PP::encode_json({
        api => 2, name => 'cfg', version => $version // '1.0',
        commands => { hello783 => { help => 'H.', level => 0 } },
        events => ['channel_join_observed'],
        (defined $config ? (config => $config) : ()) });
    close $fh;
}

return sub {
    my ($assert) = @_;

    require Mediabot::PluginManager;
    require Mediabot::ScriptRunner;
    no warnings 'redefine';
    my $real_run = \&Mediabot::ScriptRunner::run_script;
    local *Mediabot::ScriptRunner::run_script = sub {
        my ($self2, $path, $event, %data) = @_;
        push @{ $self2->{bot}{runs} }, { path => $path, event => $event, data => {%data} };
        return { ok => 1, response => { ok => 1, actions => [] } };
    };

    open my $sf, '>', "$DIR/cfg.py" or die $!; print $sf "1\n"; close $sf;

    # [1] validation fail-closed
    my $mk = sub { Mediabot::PluginManager->new(bot => Bot783->new($DIR, Conf783->new)) };
    for my $case (
        [ { bad_key => 'x' },            qr/must match \[A-Z\]/,        'cle minuscule' ],
        [ { KEY => { nested => 1 } },    qr/must be a scalar/,          'valeur ref' ],
        [ { KEY => ('x' x 513) },        qr/exceeds 512 bytes/,         'valeur trop longue' ],
        [ { map { ("K$_" => 1) } 1..33 }, qr/at most 32 keys/,          'trop de cles' ],
    ) {
        my ($cfg, $re, $label) = @$case;
        _sidecar_783($cfg);
        my $ok = eval { $mk->()->load_script_v2('cfg.py'); 1 };
        $assert->like($@ // '', $re, "mb600-783: refus — $label");
    }

    # [2] fusion defaults + surcharges
    _sidecar_783({ GREETING => 'default %s', LIMIT => '5' });
    my $conf = Conf783->new({ 'plugins.cfg.GREETING' => 'salut %s',
                              'plugins.cfg.LIMIT'    => ('y' x 600) });
    my $bot = Bot783->new($DIR, $conf);
    my $pm  = Mediabot::PluginManager->new(bot => $bot);
    my $entry = $pm->load_script_v2('cfg.py');
    $assert->is($entry->{plugin_config}{GREETING}, 'salut %s',
        'mb600-783: surcharge conf appliquee');
    $assert->is($entry->{plugin_config}{LIMIT}, '5',
        'mb600-783: surcharge invalide (>512) ignoree, defaut conserve');

    # [3] transmission commande + event
    my $h = $bot->registry->handler_for('hello783', 'public');
    $h->(Ctx783->new(nick => 'a', channel => '#c', args => [], message => {}));
    my $run = $bot->{runs}[-1];
    $assert->is($run->{data}{config}{GREETING}, 'salut %s',
        'mb600-783: data.config transmis au dispatch commande');
    $bot->events->emit('channel_join_observed',
        { event_type => 'join', channel => '#c', nick => 'x', is_self => 0 });
    $run = $bot->{runs}[-1];
    $assert->is($run->{data}{config}{LIMIT}, '5',
        'mb600-783: data.config transmis au dispatch event');

    # plugin sans bloc config : aucune cle transmise
    _sidecar_783(undef, '1.1');
    my $bot2 = Bot783->new($DIR, Conf783->new);
    my $pm2 = Mediabot::PluginManager->new(bot => $bot2);
    $pm2->load_script_v2('cfg.py');
    $bot2->registry->handler_for('hello783', 'public')
        ->(Ctx783->new(nick => 'a', channel => '#c', args => [], message => {}));
    $assert->ok(!exists $bot2->{runs}[-1]{data}{config},
        'mb600-783: sans bloc config, rien n est transmis');

    # [4] reload relit les surcharges
    _sidecar_783({ GREETING => 'default %s' }, '2.0');
    $conf->set783('plugins.cfg.GREETING', 'hop %s');
    my $e2 = $pm->load_script_v2('cfg.py', name => 'cfg', replace => 1);
    $assert->is($e2->{plugin_config}{GREETING}, 'hop %s',
        'mb600-783: reload relit sidecar ET surcharges');

    # [5] greeter du depot en execution reelle (vrai run_script)
    {
        local *Mediabot::ScriptRunner::run_script = $real_run;
        my $scripts_dir = "$Bin/../../plugins/scripts";
        my $gbot = Bot783->new($scripts_dir, Conf783->new(
            { 'plugins.greeter.GREETING' => 'Bienvenue %s, le cidre est au frais.' }));
        my $gpm = Mediabot::PluginManager->new(bot => $gbot);
        my $gentry = $gpm->load_script_v2('examples-v2/greeter.tcl');
        $assert->is($gentry->{plugin_config}{GREETING},
            'Bienvenue %s, le cidre est au frais.',
            'mb600-783: greeter — surcharge conf chargee');
        my $result = $gbot->script_runner->run_script(
            'examples-v2/greeter.tcl', 'channel_join_observed',
            event_type => 'join', channel => '#t', nick => 'Canard',
            is_self => '0', config => $gentry->{plugin_config});
        my $resp = ref($result->{response}) eq 'HASH' ? $result->{response} : {};
        my ($reply) = grep { ($_->{type} // '') eq 'reply' } @{ $resp->{actions} || [] };
        $assert->like($reply->{text} // '', qr/Bienvenue Canard, le cidre est au frais\./,
            'mb600-783: greeter reel sert la formule configuree');
    }

    # [6] .plugins info + cookbook
    require Mediabot::Partyline;
    { no strict 'refs';
      *Bot783::plugin_manager = sub { $_[0]{pm} };
      *Bot783::plugin_autoload_enabled = sub { 0 }; }
    $bot->{pm} = $pm;
    my $pl = bless { bot => $bot, users => { 7 => { level => 1 } },
                     streams => {} }, 'Mediabot::Partyline';
    my $stream = Stream783->new;
    $pl->_cmd_plugins($stream, 7, 'info cfg');
    $assert->like($stream->{out}, qr/config: GREETING=hop %s/,
        'mb600-783: info affiche la config effective');
    my $cb = do { open my $fh, '<:encoding(UTF-8)', 'plugins/scripts/COOKBOOK.md' or die $!; local $/; <$fh> };
    $assert->like($cb, qr/Sidecar config: defaults declared, conf overrides \(mb600\)/,
        'mb600-783: regle 7 documentee');
};
