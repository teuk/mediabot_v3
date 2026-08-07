# t/cases/787_mb604_plugin_storage_metrics.t
# =============================================================================
# mb604 — l'observabilite de la persistance mb601.
#   [1] les 4 metriques sont DECLAREES sur un vrai Mediabot::Metrics
#       (rappel mb598 : inc/set sur une metrique non declaree = no-op).
#   [2] une ecriture reelle incremente store_total{plugin} ET pose la
#       gauge storage_bytes{plugin} = taille du document canonique ; une
#       seconde ecriture REMPLACE la gauge (elle ne s'additionne pas).
#   [3] refus au PLAN (bornes du contrat) compte par RAISON, refus a
#       l'APPLICATION (second store du meme run) aussi ; vocabulaire
#       borne — aucune raison n'est un texte d'erreur libre.
#   [4] un fichier local abime compte read_invalid et reste ignore.
#   [5] best-effort : sans metrics, le dispatch fonctionne a l'identique.
#   [6] la classification des raisons est unitaire et exhaustive.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Temp qw(tempdir);
use JSON::PP ();

my $DIR  = tempdir(CLEANUP => 1);
my $DATA = tempdir(CLEANUP => 1);

{
    package Conf787;
    sub new { bless { kv => $_[1] || {} }, $_[0] }
    sub get { $_[0]{kv}{ $_[1] } }
}
{
    package Log787; sub new { bless {}, shift } sub log { 1 }
}
{
    package Irc787;
    sub new { bless {}, shift }
    sub can { my ($s,$m)=@_; return $m eq 'send_message' ? sub { 1 } : undef }
    sub send_message { 1 }
}
{
    package Bot787;
    sub new {
        require Mediabot::CommandRegistry;
        require Mediabot::ScriptRunner;
        require Mediabot::ScriptActionRunner;
        require Mediabot::EventBus;
        my ($class, %args) = @_;
        my $self = bless { registry => Mediabot::CommandRegistry->new,
                           bus => Mediabot::EventBus->new,
                           conf => Conf787->new({ 'plugins.DATA_DIR' => $DATA }),
                           logger => Log787->new, irc => Irc787->new,
                           metrics => $args{metrics} }, $class;
        $self->{runner} = Mediabot::ScriptRunner->new(bot => $self, script_dir => $DIR);
        $self->{ar} = Mediabot::ScriptActionRunner->new(bot => $self);
        return $self;
    }
    sub registry { $_[0]{registry} }
    sub events { $_[0]{bus} }
    sub script_runner { $_[0]{runner} }
    sub script_action_runner { $_[0]{ar} }
}
{
    package Ctx787;
    sub new { my ($c,%a)=@_; bless {%a}, $c }
    sub message { $_[0]{message} } sub nick { $_[0]{nick} }
    sub channel { $_[0]{channel} } sub args { $_[0]{args} || [] }
}

# Un script pilote par ses args : store normal, trop gros, ou deux stores.
sub _write_probe {
    open my $fh, '>', "$DIR/probe.py" or die $!;
    print $fh <<'PY';
import json, sys
env = json.load(sys.stdin)
data = env.get("data") or {}
args = data.get("args") or []
mode = str(args[0]) if args else "ok"
if mode == "big":
    payload = {"blob": "x" * 20000}
elif mode == "deep":
    payload = {"a": {"b": {"c": {"d": 1}}}}
elif mode == "twice":
    print(json.dumps({"ok": True, "protocol": "mediabot-script-v1", "actions": [
        {"type": "store", "data": {"n": 1}},
        {"type": "store", "data": {"n": 2}}]}))
    sys.exit(0)
else:
    payload = {"n": len(str(data.get("storage") or ""))}
print(json.dumps({"ok": True, "protocol": "mediabot-script-v1",
                  "actions": [{"type": "store", "data": payload}]}))
PY
    close $fh;
    open my $mf, '>', "$DIR/probe.py.manifest.json" or die $!;
    print $mf JSON::PP::encode_json({ api => 2, name => 'probe', version => '1.0',
        commands => { probe787 => { help => 'P.', level => 0 } } });
    close $mf;
}

return sub {
    my ($assert) = @_;

    require Mediabot::PluginManager;
    require Mediabot::Metrics;
    require Mediabot::Helpers;
    no warnings 'redefine';
    local *Mediabot::Helpers::botNotice  = sub { 1 };
    local *Mediabot::Helpers::botPrivmsg = sub { 1 };

    _write_probe();
    my $metrics = Mediabot::Metrics->new(enabled => 1);
    my $bot = Bot787->new(metrics => $metrics);
    my $pm  = Mediabot::PluginManager->new(bot => $bot);
    $pm->load_script_v2('probe.py');
    my $run = $bot->registry->handler_for('probe787', 'public');
    my $call = sub {
        $run->(Ctx787->new(nick => 'a', channel => '#c',
                           args => [ @_ ], message => {}));
    };

    # [1] declaration
    for my $name (qw(mediabot_plugin_storage_bytes mediabot_plugin_store_total
                     mediabot_plugin_store_rejected_total
                     mediabot_plugin_storage_read_invalid_total)) {
        $assert->ok(exists $metrics->{metrics}{$name},
            "mb604-787: $name est declaree");
    }

    # [2] ecriture reelle : compteur + gauge
    $call->('ok');
    $assert->is($metrics->get('mediabot_plugin_store_total', { plugin => 'probe' }), 1,
        'mb604-787: une ecriture appliquee incremente store_total');
    my $bytes = $metrics->get('mediabot_plugin_storage_bytes', { plugin => 'probe' });
    my $real  = -s "$DATA/probe.json";
    $assert->is($bytes, $real, 'mb604-787: la gauge = la taille reelle du document');
    $call->('ok');
    $assert->is($metrics->get('mediabot_plugin_store_total', { plugin => 'probe' }), 2,
        'mb604-787: le compteur s additionne');
    my $bytes2 = $metrics->get('mediabot_plugin_storage_bytes', { plugin => 'probe' });
    $assert->is($bytes2, (-s "$DATA/probe.json"),
        'mb604-787: la gauge REMPLACE (elle ne s additionne pas)');

    # [3] refus au plan, par raison
    $call->('big');
    $assert->is($metrics->get('mediabot_plugin_store_rejected_total',
        { plugin => 'probe', reason => 'too_large' }), 1,
        'mb604-787: refus de borne compte comme too_large');
    $call->('deep');
    $assert->is($metrics->get('mediabot_plugin_store_rejected_total',
        { plugin => 'probe', reason => 'too_deep' }), 1,
        'mb604-787: profondeur refusee compte comme too_deep');
    $assert->is($metrics->get('mediabot_plugin_store_total', { plugin => 'probe' }), 2,
        'mb604-787: un refus n incremente PAS les ecritures');
    # refus a l'application : le second store du meme run
    $call->('twice');
    $assert->is($metrics->get('mediabot_plugin_store_rejected_total',
        { plugin => 'probe', reason => 'duplicate' }), 1,
        'mb604-787: le second store d un run compte comme duplicate');
    $assert->is($metrics->get('mediabot_plugin_store_total', { plugin => 'probe' }), 3,
        'mb604-787: ... et le PREMIER a bien ete ecrit');

    # [4] fichier local abime
    open my $bad, '>', "$DATA/probe.json" or die $!;
    print $bad '{"a": {"b": {"c": {"d": 1}}}}';   # profondeur hors contrat
    close $bad;
    $assert->ok(!defined $pm->_read_plugin_data('probe'),
        'mb604-787: fichier hors contrat ignore a la lecture');
    $assert->is($metrics->get('mediabot_plugin_storage_read_invalid_total',
        { plugin => 'probe' }), 1,
        'mb604-787: ... et compte read_invalid');
    $assert->is($metrics->get('mediabot_plugin_storage_bytes', { plugin => 'probe' }), 0,
        'mb605-787: un document invalide remet la gauge a zero');

    # mb605: une lecture apres restart initialise la gauge depuis le fichier.
    my ($seed_ok) = $pm->_store_plugin_data('probe', { n => 42 });
    $assert->ok($seed_ok, 'mb605-787: document valide reseme');
    my $metrics_restart = Mediabot::Metrics->new(enabled => 1);
    my $bot_restart = Bot787->new(metrics => $metrics_restart);
    my $pm_restart = Mediabot::PluginManager->new(bot => $bot_restart);
    $assert->ok(ref($pm_restart->_read_plugin_data('probe')) eq 'HASH',
        'mb605-787: document existant relu apres restart');
    $assert->is($metrics_restart->get('mediabot_plugin_storage_bytes',
        { plugin => 'probe' }), (-s "$DATA/probe.json"),
        'mb605-787: la lecture initialise la gauge a la taille courante');
    my ($clear_ok, $removed) = $pm_restart->clear_plugin_data('probe');
    $assert->ok($clear_ok && $removed, 'mb605-787: clear supprime le document');
    $assert->is($metrics_restart->get('mediabot_plugin_storage_bytes',
        { plugin => 'probe' }), 0,
        'mb605-787: clear remet immediatement la gauge a zero');

    # Oversize et symlink sont aussi des fichiers invalides ignores.
    open my $huge, '>:raw', "$DATA/probe.json" or die $!;
    print {$huge} 'x' x 18000;
    close $huge;
    $assert->ok(!defined $pm_restart->_read_plugin_data('probe'),
        'mb605-787: fichier brut surdimensionne ignore');
    $assert->is($metrics_restart->get('mediabot_plugin_storage_read_invalid_total',
        { plugin => 'probe' }), 1,
        'mb605-787: oversize compte read_invalid');
    unlink "$DATA/probe.json";
    open my $target, '>', "$DATA/target.json" or die $!;
    print {$target} '{"n":1}'; close $target;
    symlink "$DATA/target.json", "$DATA/probe.json" or die $!;
    $assert->ok(!defined $pm_restart->_read_plugin_data('probe'),
        'mb605-787: symlink storage ignore');
    $assert->is($metrics_restart->get('mediabot_plugin_storage_read_invalid_total',
        { plugin => 'probe' }), 2,
        'mb605-787: symlink compte read_invalid');
    unlink "$DATA/probe.json";

    # Le collecteur best-effort ne doit jamais dereferencer des diagnostics
    # mal formes renvoyes par un runner ancien ou personnalise.
    my $collector_ok = eval {
        Mediabot::PluginManager::_pm_store_rejections($bot_restart, 'probe',
            { errors => 'not-an-array', apply_errors => {} });
        1;
    };
    $assert->ok($collector_ok,
        'mb605-787: diagnostics mal formes ne cassent pas le dispatch');

    my $pm_source = do { open my $fh, '<:encoding(UTF-8)',
        'Mediabot/PluginManager.pm' or die $!; local $/; <$fh> };
    $assert->like($pm_source, qr/unless \(chmod 0600, \$tmp\)/,
        'mb605-787: chmod 0600 est verifie avant rename');

    # [5] best-effort : sans metrics, tout fonctionne
    unlink "$DATA/probe.json";
    my $bot2 = Bot787->new(metrics => undef);
    my $pm2  = Mediabot::PluginManager->new(bot => $bot2);
    $pm2->load_script_v2('probe.py');
    my $ok = eval {
        $bot2->registry->handler_for('probe787', 'public')
            ->(Ctx787->new(nick => 'a', channel => '#c', args => ['ok'], message => {}));
        1;
    };
    $assert->ok($ok, 'mb604-787: sans metrics, le dispatch ne meurt pas');
    $assert->ok(-f "$DATA/probe.json",
        'mb604-787: ... et l ecriture a bien eu lieu');

    # [6] classification unitaire
    my %expect = (
        'store action rejected: store data exceeds 16384 bytes' => 'too_large',
        'store action rejected: storage nesting deeper than 3 levels' => 'too_deep',
        'store action rejected: storage holds more than 256 keys' => 'too_many_keys',
        'store action rejected: storage key longer than 64 chars' => 'key_too_long',
        'store action rejected: store data must be an object' => 'not_an_object',
        'only one store action per run' => 'duplicate',
        'store actions require allow_store and a store sink' => 'no_sink',
        'invalid plugin storage name' => 'invalid_name',
        "cannot rename into '/x/y.json': nope" => 'write_failed',
        "cannot chmod '/x/y.tmp': nope" => 'write_failed',
        'something entirely new' => 'other',
    );
    my $classified = 0;
    for my $text (sort keys %expect) {
        $classified++ if Mediabot::PluginManager::_store_rejection_reason($text)
                         eq $expect{$text};
    }
    $assert->is($classified, scalar(keys %expect),
        'mb604-787: chaque message connu tombe dans la bonne raison bornee');
    $assert->is(Mediabot::PluginManager::_store_rejection_reason(undef), 'other',
        'mb604-787: une erreur absente reste bornee');
};
