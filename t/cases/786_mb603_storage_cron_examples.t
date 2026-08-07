# t/cases/786_mb603_storage_cron_examples.t
# =============================================================================
# mb603 — la galerie prend vie : karma.py (storage) et daily.tcl (cron +
# config + storage), les deux mecanismes mb599/mb601 enfin en vitrine.
#   [1] sidecars du DEPOT valides et charges par le vrai PluginManager
#       (karma = 2 commandes sans event ; daily = 1 event cron, 0 commande).
#   [2] karma.py en EXECUTION REELLE via le pipeline complet : thanks
#       persiste (fichier ecrit par le BOT), un 2e thanks relit et
#       incremente, karma <nick> lit sans ecrire, le podium trie.
#   [3] anti-abus : se remercier soi-meme ne stocke RIEN.
#   [4] karma reste sous les bornes du bot : plafond MAX_TRACKED documente,
#       un document de 200 nicks passe validate_action sans reserve.
#   [5] daily.tcl reel : minute cible = annonce avec target EXPLICITE (un
#       cron n'a pas de canal) + store du jour ; meme minute deja annoncee
#       = silence ; autre minute = silence ; non configure = silence.
#   [6] cookbook : galerie a jour, lecon du target cron, nuance stateless.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Temp qw(tempdir);
use JSON::PP ();

my $DATA = tempdir(CLEANUP => 1);

{
    package Conf786;
    sub new { bless { kv => $_[1] || {} }, $_[0] }
    sub get { $_[0]{kv}{ $_[1] } }
}
{
    package Bot786;
    sub new {
        require Mediabot::CommandRegistry;
        require Mediabot::ScriptRunner;
        require Mediabot::ScriptActionRunner;
        require Mediabot::EventBus;
        my ($class, $dir, $conf) = @_;
        my $self = bless { registry => Mediabot::CommandRegistry->new,
                           bus => Mediabot::EventBus->new,
                           conf => $conf, logger => Log786->new,
                           sent => [] }, $class;
        $self->{irc} = Irc786->new($self->{sent});
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
    package Log786; sub new { bless { lines => [] }, shift }
    sub log { push @{ $_[0]{lines} }, [ $_[1], $_[2] ]; 1 }
}
{
    # Les actions reply/notice passent par $bot->{irc}->send_message :
    # un faux IRC suffit a capturer ce qui part vraiment sur le reseau.
    package Irc786;
    sub new { bless { sent => $_[1] }, $_[0] }
    sub can { my ($s,$m)=@_; return $m eq 'send_message' ? sub { 1 } : undef }
    sub send_message { my ($s,$cmd,undef,$target,$text)=@_;
        push @{ $s->{sent} }, [ $cmd, $target, $text ]; 1 }
}
{
    package Ctx786;
    sub new { my ($c,%a)=@_; bless {%a}, $c }
    sub message { $_[0]{message} } sub nick { $_[0]{nick} }
    sub channel { $_[0]{channel} } sub args { $_[0]{args} || [] }
}

return sub {
    my ($assert) = @_;

    require Mediabot::PluginManager;
    require Mediabot::Helpers;
    no warnings 'redefine';
    local *Mediabot::Helpers::botPrivmsg = sub { 1 };
    local *Mediabot::Helpers::botNotice  = sub { 1 };

    my $scripts = "$Bin/../../plugins/scripts";
    my $conf = Conf786->new({
        'plugins.DATA_DIR'    => $DATA,
        'plugins.daily.CHANNEL' => '#quebec',
        'plugins.daily.TEXT'    => 'Good morning! The cider is cold.',
    });
    my $bot = Bot786->new($scripts, $conf);
    my $sent = $bot->{sent};   # [ cmd, target, text ] de chaque envoi reel
    my $pm  = Mediabot::PluginManager->new(bot => $bot);

    # [1] les deux sidecars du depot chargent
    my $karma = $pm->load_script_v2('examples-v2/karma.py');
    $assert->is($karma->{manifest}{name}, 'karma', 'mb603-786: karma charge');
    $assert->ok($bot->registry->handler_for('karma', 'public')
             && $bot->registry->handler_for('thanks', 'public'),
        'mb603-786: karma monte ses 2 commandes');
    $assert->ok(!@{ $karma->{event_listeners} || [] },
        'mb603-786: karma ne declare aucun event');
    my $daily = $pm->load_script_v2('examples-v2/daily.tcl');
    $assert->is(scalar @{ $daily->{event_listeners} || [] }, 1,
        'mb603-786: daily abonne son event cron');
    $assert->is($daily->{plugin_config}{CHANNEL}, '#quebec',
        'mb603-786: daily recoit la config operateur');

    # [2] karma en execution reelle
    my $thanks = $bot->registry->handler_for('thanks', 'public');
    my $show   = $bot->registry->handler_for('karma', 'public');
    $thanks->(Ctx786->new(nick => 'aur', channel => '#c', args => ['SlaY'], message => {}));
    my $st = $pm->_read_plugin_data('karma');
    $assert->is($st->{scores}{slay}, 1, 'mb603-786: thanks persiste (le BOT a ecrit)');
    $thanks->(Ctx786->new(nick => 'bob', channel => '#c', args => ['SlaY'], message => {}));
    $assert->is($pm->_read_plugin_data('karma')->{scores}{slay}, 2,
        'mb603-786: 2e thanks relit data.storage frais et incremente');
    @$sent = ();
    $show->(Ctx786->new(nick => 'aur', channel => '#c', args => ['slay'], message => {}));
    $assert->like(($sent->[-1][2] // ''), qr/slay has 2 karma/i,
        'mb603-786: karma <nick> rapporte le score');
    $assert->is($pm->_read_plugin_data('karma')->{scores}{slay}, 2,
        'mb603-786: une lecture n ecrit rien');
    $thanks->(Ctx786->new(nick => 'aur', channel => '#c', args => ['bob'], message => {}));
    $thanks->(Ctx786->new(nick => 'aur', channel => '#c', args => ['bob'], message => {}));
    $thanks->(Ctx786->new(nick => 'aur', channel => '#c', args => ['bob'], message => {}));
    @$sent = ();
    $show->(Ctx786->new(nick => 'aur', channel => '#c', args => [], message => {}));
    $assert->like(($sent->[-1][2] // ''), qr/Top karma: bob \(3\), slay \(2\)/,
        'mb603-786: le podium trie par score');

    # [3] anti-abus : rien de stocke
    my $before = $pm->_read_plugin_data('karma')->{scores}{aur};
    @$sent = ();
    $thanks->(Ctx786->new(nick => 'aur', channel => '#c', args => ['aur'], message => {}));
    $assert->like(($sent->[-1][2] // ''), qr/thanking yourself/,
        'mb603-786: se remercier soi-meme est refuse');
    $assert->ok(!defined $pm->_read_plugin_data('karma')->{scores}{aur},
        'mb603-786: ... et rien n est stocke');

    # [4] le plafond du script reste sous celui du bot
    my $src = do { open my $fh, '<:encoding(UTF-8)',
        "$scripts/examples-v2/karma.py" or die $!; local $/; <$fh> };
    $assert->like($src, qr/MAX_TRACKED\s*=\s*200/,
        'mb603-786: karma documente son propre plafond');
    my ($ok_big) = $bot->{ar}->validate_action({ type => 'store',
        data => { scores => { map { ("n$_" => $_) } 1..200 } } }, {});
    $assert->ok($ok_big, 'mb603-786: 200 nicks passent les bornes du bot');

    # mb605: le 201e nick doit REMPLACER une entree, pas devenir une 201e.
    my %full = map { (sprintf('u%03d', $_) => 2) } 1..200;
    my ($seed_ok) = $pm->_store_plugin_data('karma', { scores => \%full });
    $assert->ok($seed_ok, 'mb605-786: fixture karma 200 entrees stockee');
    $thanks->(Ctx786->new(nick => 'aur', channel => '#c',
                           args => ['newbie'], message => {}));
    my $pruned = $pm->_read_plugin_data('karma')->{scores};
    $assert->is(scalar(keys %$pruned), 200,
        'mb605-786: le plafond karma reste exactement a 200');
    $assert->is($pruned->{newbie}, 1,
        'mb605-786: le nick tout juste remercie survit a la taille');

    # [5] daily.tcl reel, les quatre chemins
    @$sent = ();
    my $emit = sub {
        my (%ctx) = @_;
        $bot->events->emit('plugin_cron_observed',
            { event_type => 'cron', minute => 0, hour => 9,
              dow => 1, mday => 4, month => 8, year => 2026, %ctx });
    };
    $emit->();
    $assert->is(scalar @$sent, 1, 'mb603-786: daily annonce a la minute cible');
    $assert->is($sent->[-1][1], '#quebec',
        'mb603-786: cible EXPLICITE — un cron n a pas de canal');
    $assert->like(($sent->[-1][2] // ''), qr/cider is cold/,
        'mb603-786: la ligne configuree par l operateur est envoyee');
    $assert->is($pm->_read_plugin_data('daily')->{last}, '2026-8-4',
        'mb603-786: le jour annonce est memorise');
    @$sent = ();
    $emit->();
    $assert->is(scalar @$sent, 0,
        'mb603-786: deuxieme tick le meme jour = silence (restart-safe)');
    @$sent = ();
    $emit->(year => 2027);
    $assert->is(scalar @$sent, 1,
        'mb605-786: la meme date civile l annee suivante annonce a nouveau');
    $assert->is($pm->_read_plugin_data('daily')->{last}, '2027-8-4',
        'mb605-786: la cle d idempotence inclut l annee');
    @$sent = ();
    $emit->(minute => 37, hour => 14);
    $assert->is(scalar @$sent, 0, 'mb603-786: une autre minute = silence');
    {
        my $bot2 = Bot786->new($scripts, Conf786->new({ 'plugins.DATA_DIR' => $DATA }));
        my $pm2  = Mediabot::PluginManager->new(bot => $bot2);
        $pm2->load_script_v2('examples-v2/daily.tcl');
        my $sent2 = $bot2->{sent};
        $bot2->events->emit('plugin_cron_observed',
            { event_type => 'cron', minute => 0, hour => 9,
              dow => 1, mday => 5, month => 8, year => 2026 });
        $assert->is(scalar @$sent2, 0,
            'mb603-786: sans CHANNEL/TEXT configures = silence');
    }

    # [6] cookbook
    my $cb = do { open my $fh, '<:encoding(UTF-8)',
        "$scripts/COOKBOOK.md" or die $!; local $/; <$fh> };
    $assert->like($cb, qr/karma\.py.*the stateful one/s,
        'mb603-786: galerie du cookbook a jour');
    $assert->like($cb, qr/A cron event\s+belongs to no channel/s,
        'mb603-786: lecon du target explicite documentee');
    $assert->like($cb, qr/storage is for what outlives the run/,
        'mb603-786: nuance stateless corrigee');
};
