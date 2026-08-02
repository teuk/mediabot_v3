# t/cases/784_mb601_plugin_kv_storage.t
# =============================================================================
# mb601 — chantier D : persistance KV par plugin.
#   [1] validate_action store : bornes (pas un objet, profondeur >3, >256
#       cles, >16K, target/text interdits) ; objet valide passe.
#   [2] apply : sans gate/sink = erreur explicite ; UN SEUL store par run
#       (le 2e = erreur) ; sink appele avec data.
#   [3] _store_plugin_data : ecrit ATOMIQUEMENT (temp+rename structurel),
#       re-verifie la borne ; _read_plugin_data : fichier invalide =
#       journal + undef, jamais die.
#   [4] ROUNDTRIP REEL : run 1 emet store -> fichier ecrit ; run 2 recoit
#       data.storage FRAIS dans l'enveloppe (commande ET event).
#   [5] partyline : cleardata Owner (gate, purge, inconnu) ; info affiche
#       la ligne storage.
#   [6] cookbook regle 8 documentee.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use Cwd qw(getcwd);
use File::Temp qw(tempdir);
use JSON::PP ();

my $DIR = tempdir(CLEANUP => 1);
my $DATA = tempdir(CLEANUP => 1);

{
    package Conf784;
    sub new { bless { kv => $_[1] || {} }, $_[0] }
    sub get { $_[0]{kv}{ $_[1] } }
}
{
    package Bot784;
    sub new {
        require Mediabot::CommandRegistry;
        require Mediabot::ScriptRunner;
        require Mediabot::ScriptActionRunner;
        require Mediabot::EventBus;
        my ($class, $dir, $data_dir) = @_;
        my $self = bless { registry => Mediabot::CommandRegistry->new,
                           bus => Mediabot::EventBus->new,
                           conf => Conf784->new({ 'plugins.DATA_DIR' => $data_dir }),
                           logger => Log784->new, runs => [] }, $class;
        $self->{runner} = Mediabot::ScriptRunner->new(bot => $self, script_dir => $dir);
        $self->{ar} = Mediabot::ScriptActionRunner->new(bot => $self);
        return $self;
    }
    sub registry { $_[0]{registry} }
    sub events { $_[0]{bus} }
    sub script_runner { $_[0]{runner} }
    sub script_action_runner { $_[0]{ar} }
}
{
    package Log784; sub new { bless { lines => [] }, shift }
    sub log { push @{ $_[0]{lines} }, [ $_[1], $_[2] ]; 1 }
}
{
    package Ctx784;
    sub new { my ($c,%a)=@_; bless {%a}, $c }
    sub message { $_[0]{message} } sub nick { $_[0]{nick} }
    sub channel { $_[0]{channel} } sub args { $_[0]{args} || [] }
}
{
    package Stream784;
    sub new { bless { out => '' }, shift }
    sub write { $_[0]{out} .= $_[1]; 1 }
}

return sub {
    my ($assert) = @_;

    require Mediabot::PluginManager;
    require Mediabot::ScriptActionRunner;
    require Mediabot::Helpers;
    no warnings 'redefine';
    local *Mediabot::Helpers::botNotice = sub { 1 };
    local *Mediabot::Helpers::botPrivmsg = sub { 1 };

    my $bot = Bot784->new($DIR, $DATA);
    my $ar  = $bot->{ar};

    # [1] validation
    my ($ok, $err) = $ar->validate_action({ type => 'store', data => 'nope' }, {});
    $assert->ok(!$ok && $err =~ /must be an object/, 'mb601-784: data non-objet refuse');
    ($ok, $err) = $ar->validate_action({ type => 'store',
        data => { a => { b => { c => { d => 1 } } } } }, {});
    $assert->ok(!$ok && $err =~ /deeper than 3/, 'mb601-784: profondeur >3 refusee');
    ($ok, $err) = $ar->validate_action({ type => 'store',
        data => { map { ("k$_" => 1) } 1..257 } }, {});
    $assert->ok(!$ok && $err =~ /more than 256 keys/, 'mb601-784: >256 cles refuse');
    ($ok, $err) = $ar->validate_action({ type => 'store',
        data => { blob => ('x' x 17000) } }, {});
    $assert->ok(!$ok && $err =~ /exceeds 16384/, 'mb601-784: >16K refuse');
    ($ok, $err) = $ar->validate_action({ type => 'store',
        data => { n => 1 }, target => '#x' }, {});
    $assert->ok(!$ok && $err =~ /no target/, 'mb601-784: target interdit');
    ($ok, $err) = $ar->validate_action({ type => 'store',
        data => { counts => { SlaY => 3 }, total => 3 } }, {});
    $assert->ok($ok, 'mb601-784: objet valide passe');

    # [2] gates apply
    my $mk_result = sub { { ok => 1, response => { ok => 1, actions => [ @_ ] } } };
    my $plan = $ar->apply_actions(
        $mk_result->({ type => 'store', data => { n => 1 } }), {}, apply => 1);
    $assert->like(($plan->{apply_errors}[0]{error} // ''), qr/require allow_store and a store sink/,
        'mb601-784: sans gate/sink = erreur explicite');
    my @sunk;
    my $sink = sub { push @sunk, $_[0]; (1, undef) };
    $plan = $ar->apply_actions(
        $mk_result->({ type => 'store', data => { n => 1 } },
                     { type => 'store', data => { n => 2 } }),
        {}, apply => 1, allow_store => 1, store_sink => $sink);
    $assert->is(scalar @sunk, 1, 'mb601-784: un seul store applique par run');
    $assert->is($sunk[0]{n}, 1, 'mb601-784: le PREMIER store gagne');
    $assert->like(($plan->{apply_errors}[0]{error} // ''), qr/only one store action per run/,
        'mb601-784: le second est une erreur');

    # [3] ecriture atomique + lecture defensive
    my $pm = Mediabot::PluginManager->new(bot => $bot);
    ($ok, $err) = $pm->_store_plugin_data('probe', { hello => 'world' });
    $assert->ok($ok, 'mb601-784: store ecrit');
    $assert->ok(-f "$DATA/probe.json", 'mb601-784: fichier au bon endroit (DATA_DIR conf)');
    my $back = $pm->_read_plugin_data('probe');
    $assert->is($back->{hello}, 'world', 'mb601-784: relecture fidele');
    ($ok, $err) = $pm->_store_plugin_data('probe', { blob => ('x' x 17000) });
    $assert->ok(!$ok && $err =~ /exceeds 16384/,
        'mb601-784: la borne est re-verifiee a l ecriture');
    open my $bad, '>', "$DATA/broken.json"; print $bad '{not json'; close $bad;
    $assert->ok(!defined $pm->_read_plugin_data('broken'),
        'mb601-784: storage invalide ignore (undef)');
    $assert->ok((grep { $_->[1] =~ /invalid storage file for 'broken'/ }
        @{ $bot->{logger}{lines} }), 'mb601-784: ... et journalise');
    my $src_pm = do { open my $fh, '<:encoding(UTF-8)', 'Mediabot/PluginManager.pm' or die $!; local $/; <$fh> };
    $assert->like($src_pm, qr/\.tmp\.\$\$.*?\n.*rename \$tmp, \$path/s,
        'mb601-784: ecriture temp + rename (atomique)');

    # [4] roundtrip reel : un script python qui compte
    open my $sf, '>', "$DIR/counter.py" or die $!;
    print $sf <<'PY';
import json, sys
env = json.load(sys.stdin)
data = env.get("data", {})
st = data.get("storage") or {}
n = int(st.get("n", 0)) + 1
print(json.dumps({"ok": True, "protocol": "mediabot-script-v1", "actions": [
    {"type": "store", "data": {"n": n}},
    {"type": "reply", "text": "count=%d" % n}]}))
PY
    close $sf;
    open my $mf, '>', "$DIR/counter.py.manifest.json" or die $!;
    print $mf JSON::PP::encode_json({ api => 2, name => 'counter',
        version => '1.0',
        commands => { count784 => { help => 'C.', level => 0 } },
        events => ['channel_join_observed'] });
    close $mf;
    $pm->load_script_v2('counter.py');
    my $h = $bot->registry->handler_for('count784', 'public');
    $h->(Ctx784->new(nick => 'a', channel => '#c', args => [], message => {}));
    my $st1 = $pm->_read_plugin_data('counter');
    $assert->is($st1->{n}, 1, 'mb601-784: run 1 — store applique via le vrai pipeline');
    $h->(Ctx784->new(nick => 'a', channel => '#c', args => [], message => {}));
    $assert->is($pm->_read_plugin_data('counter')->{n}, 2,
        'mb601-784: run 2 — data.storage frais relu, le compteur avance');
    $bot->events->emit('channel_join_observed',
        { event_type => 'join', channel => '#c', nick => 'x', is_self => 0 });
    $assert->is($pm->_read_plugin_data('counter')->{n}, 3,
        'mb601-784: le chemin EVENT stocke aussi (meme sink)');

    # [5] partyline
    require Mediabot::Partyline;
    { no strict 'refs';
      *Bot784::plugin_manager = sub { $_[0]{pm} };
      *Bot784::plugin_autoload_enabled = sub { 0 }; }
    $bot->{pm} = $pm;
    my $pl = bless { bot => $bot, users => { 7 => { level => 0 },
                                             8 => { level => 1 } },
                     streams => {} }, 'Mediabot::Partyline';
    my $stream = Stream784->new;
    $pl->_cmd_plugins($stream, 7, 'info counter');
    $assert->like($stream->{out}, qr/storage: \d+ bytes/,
        'mb601-784: info affiche la ligne storage');
    $stream = Stream784->new;
    $pl->_cmd_plugins($stream, 8, 'cleardata counter');
    $assert->like($stream->{out}, qr/requires Owner level/,
        'mb601-784: cleardata gate Owner (Master refuse)');
    $stream = Stream784->new;
    $pl->_cmd_plugins($stream, 7, 'cleardata counter');
    $assert->like($stream->{out}, qr/cleared/, 'mb601-784: cleardata purge');
    $assert->ok(!-f "$DATA/counter.json", 'mb601-784: fichier disparu');
    $stream = Stream784->new;
    $pl->_cmd_plugins($stream, 7, 'cleardata counter');
    $assert->like($stream->{out}, qr/No stored data/, 'mb601-784: purge sans fichier expliquee');

    # [6] cookbook
    my $cb = do { open my $fh, '<:encoding(UTF-8)', 'plugins/scripts/COOKBOOK.md' or die $!; local $/; <$fh> };
    $assert->like($cb, qr/Persistent storage: the bot writes, your script asks \(mb601\)/,
        'mb601-784: regle 8 documentee');
};
