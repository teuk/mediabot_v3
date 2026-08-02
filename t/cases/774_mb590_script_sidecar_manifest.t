# t/cases/774_mb590_script_sidecar_manifest.t
# =============================================================================
# mb590 — arc plugins v2, increment 5 : les scripts externes rejoignent le
# contrat (manifest sidecar JSON).
#   [1] chargement d'un script v2 : sidecar <script>.manifest.json valide,
#       chemin passe par validate_script_path du VRAI runner (traversal
#       refuse, extension inconnue refusee), sidecar absent/JSON invalide/
#       trop gros refuses, entry kind=script + commandes montees.
#   [2] dispatch : run_script recoit script_path/event/champs du ctx ; les
#       actions passent par apply_actions avec apply+allow_irc SEULEMENT ;
#       echec du run = notice sobre + PAS d'apply ; le pont d'autorisation
#       mb589 s'applique aux commandes de script.
#   [3] reload script (replace) relit le sidecar ; unload demonte.
#   [4] partyline : loadscript gate Owner, sortie annonce le chemin.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use JSON::PP ();

my $DIR = tempdir(CLEANUP => 1);

sub _write_774 {
    my ($rel, $content) = @_;
    my $abs = "$DIR/$rel";
    (my $parent = $abs) =~ s{/[^/]+\z}{};
    make_path($parent);
    open my $fh, '>', $abs or die $!;
    print $fh $content;
    close $fh;
    return $abs;
}

{
    package Bot774;
    sub new {
        require Mediabot::CommandRegistry;
        require Mediabot::ScriptRunner;
        my ($class, $dir) = @_;
        my $self = bless { registry => Mediabot::CommandRegistry->new,
                           logger => Log774->new, runs => [], applies => [] }, $class;
        $self->{runner} = Mediabot::ScriptRunner->new(bot => $self, script_dir => $dir);
        return $self;
    }
    sub registry { $_[0]{registry} }
    sub script_runner { $_[0]{runner} }
    sub script_action_runner { $_[0] }   # la fixture joue l'action runner
    sub apply_actions {
        my ($self, $result, $context, %opts) = @_;
        push @{ $self->{applies} }, { opts => {%opts}, context => $context };
        return { applied_ok => 1, apply_errors => [] };
    }
    sub events { undef }
    sub checkUserLevel {
        my ($self, $ulevel, $required) = @_;
        my %tbl = ( owner => 0, master => 1, user => 3 );
        my $req = $tbl{ lc $required };
        defined $ulevel && defined $req && $ulevel <= $req ? 1 : 0;
    }
    sub get_user_from_message { return $_[1]{user} }
}
{
    package Log774; sub new { bless {}, shift } sub log { 1 }
}
{
    package User774;
    sub new { my ($c,%a)=@_; bless {%a}, $c }
    sub level { $_[0]{level} } sub is_authenticated { $_[0]{auth} ? 1 : 0 }
}
{
    package Ctx774;
    sub new { my ($c,%a)=@_; bless {%a}, $c }
    sub message { $_[0]{message} } sub nick { $_[0]{nick} }
    sub channel { $_[0]{channel} } sub args { $_[0]{args} || [] }
}

my $MANIFEST = {
    api => 2, name => 'greet', version => '1.0',
    description => 'Greets from a script.',
    commands => { greet774 => { help => 'Greet.', level => 0 },
                  vip774   => { help => 'VIP.',   level => 'Master' } },
};

return sub {
    my ($assert) = @_;

    require Mediabot::PluginManager;
    require Mediabot::Helpers;
    # le stub run_script doit etre pose APRES le chargement du vrai module —
    # sinon le require (declenche par Bot774->new) redefinit la sub reelle
    # PAR-DESSUS le stub et le dispatch executerait vraiment python.
    require Mediabot::ScriptRunner;
    require Mediabot::CommandRegistry;
    my @notices;
    no warnings 'redefine';
    local *Mediabot::Helpers::get_user_from_message =
        sub { my ($bot, $msg) = @_; return $bot->get_user_from_message($msg) };
    local *Mediabot::Helpers::botNotice =
        sub { my (undef, $nick, $text) = @_; push @notices, "$nick: $text"; 1 };
    # run_script stubbe sur la CLASSE : on capture l'appel, le vrai chemin de
    # validation (validate_script_path/language_for) reste le vrai code.
    my $run_ret = { ok => 1, actions => [ { type => 'reply', text => 'hi' } ] };
    local *Mediabot::ScriptRunner::run_script = sub {
        my ($self2, $path, $event, %data) = @_;
        push @{ $self2->{bot}{runs} }, { path => $path, event => $event, data => {%data} };
        return $run_ret;
    };

    _write_774('greet.py', "print('hi')\n");
    _write_774('greet.py.manifest.json', JSON::PP::encode_json($MANIFEST));

    my $bot = Bot774->new($DIR);
    my $pm  = Mediabot::PluginManager->new(bot => $bot);

    # [1] chargement
    my $entry = $pm->load_script_v2('greet.py');
    $assert->ok($entry, 'mb590-774: script v2 charge depuis le sidecar');
    $assert->is($entry->{metadata}{kind}, 'script', 'mb590-774: entry kind=script');
    $assert->is($entry->{metadata}{api}, 2, 'mb590-774: api 2');
    $assert->is($bot->registry->has_command('greet774', 'public'), 1,
        'mb590-774: commande du script montee');
    $assert->is($bot->registry->has_command('vip774', 'public'), 1,
        'mb590-774: commande a niveau montee aussi');

    # refus : traversal, extension, sidecar absent, JSON invalide, trop gros
    my $mk_pm = sub { Mediabot::PluginManager->new(bot => Bot774->new($DIR)) };
    my $ok = eval { $mk_pm->()->load_script_v2('../evil.py'); 1 };
    $assert->like($@ // '', qr/invalid script path/, 'mb590-774: traversal refuse');
    $ok = eval { $mk_pm->()->load_script_v2('greet.txt'); 1 };
    $assert->like($@ // '', qr/invalid script path|unsupported script language/,
        'mb590-774: extension inconnue refusee');
    _write_774('lone.py', "1\n");
    $ok = eval { $mk_pm->()->load_script_v2('lone.py'); 1 };
    $assert->like($@ // '', qr/sidecar manifest not found/, 'mb590-774: sidecar obligatoire');
    _write_774('bad.py', "1\n");
    _write_774('bad.py.manifest.json', '{ not json');
    $ok = eval { $mk_pm->()->load_script_v2('bad.py'); 1 };
    $assert->like($@ // '', qr/not valid JSON/, 'mb590-774: JSON invalide refuse');
    _write_774('fat.py', "1\n");
    _write_774('fat.py.manifest.json', '[' . ('1,' x 6000) . '1]');
    $ok = eval { $mk_pm->()->load_script_v2('fat.py'); 1 };
    $assert->like($@ // '', qr/larger than/, 'mb590-774: sidecar borne en taille');

    # [2] dispatch public
    my $h = $bot->registry->handler_for('greet774', 'public');
    my $ctx = Ctx774->new(nick => 'SlaY', channel => '#quebec',
        args => ['a','b'], message => { user => User774->new(level=>3, auth=>0) });
    @notices = ();
    $h->($ctx);
    $assert->is(scalar @{ $bot->{runs} }, 1, 'mb590-774: run_script invoque');
    my $run = $bot->{runs}[0];
    $assert->is($run->{path}, 'greet.py', 'mb590-774: chemin relatif transmis');
    $assert->is($run->{event}, 'public_command', 'mb590-774: event public_command');
    $assert->is($run->{data}{nick}, 'SlaY', 'mb590-774: nick du ctx transmis');
    $assert->is(join(',', @{ $run->{data}{args} }), 'a,b', 'mb590-774: args transmis');
    my $ap = $bot->{applies}[0];
    $assert->ok($ap, 'mb590-774: actions appliquees via apply_actions');
    $assert->is($ap->{opts}{apply}, 1, 'mb590-774: apply=1');
    $assert->is($ap->{opts}{allow_irc}, 1, 'mb590-774: allow_irc=1');
    $assert->ok(!$ap->{opts}{allow_topic} && !$ap->{opts}{allow_kick} && !$ap->{opts}{allow_ban},
        'mb590-774: gates intrusives fermees');

    # echec du run : notice sobre, PAS d'apply
    $run_ret = { ok => 0, error => 'boom' };
    @notices = (); my $n_applies = scalar @{ $bot->{applies} };
    $h->($ctx);
    $assert->is(scalar @{ $bot->{applies} }, $n_applies,
        'mb590-774: echec du run = aucune action appliquee');
    $assert->like($notices[0] // '', qr/SlaY: Command 'greet774' failed \(script error\)\./,
        'mb590-774: notice sobre en echec');
    $run_ret = { ok => 1, actions => [] };

    # pont d'autorisation sur la commande de script
    my $vip = $bot->registry->handler_for('vip774', 'public');
    @notices = (); my $n_runs = scalar @{ $bot->{runs} };
    $vip->(Ctx774->new(nick => 'rando', channel => '#quebec',
        message => { user => User774->new(level=>3, auth=>1) }));
    $assert->is(scalar @{ $bot->{runs} }, $n_runs,
        'mb590-774: niveau insuffisant — le script ne tourne PAS');
    $assert->like($notices[0] // '', qr/rando: Access denied: 'vip774' requires Master level\./,
        'mb590-774: refus notifie (pont mb589 partage)');
    $vip->(Ctx774->new(nick => 'teuk', channel => '#quebec',
        message => { user => User774->new(level=>0, auth=>1) }));
    $assert->is(scalar @{ $bot->{runs} }, $n_runs + 1,
        'mb590-774: Owner passe — le script tourne');

    # [3] reload script (replace) relit le sidecar
    my $m2 = { %$MANIFEST, version => '2.0' };
    _write_774('greet.py.manifest.json', JSON::PP::encode_json($m2));
    my $e2 = $pm->load_script_v2('greet.py', name => 'greet', replace => 1);
    $assert->is($e2->{version}, '2.0', 'mb590-774: replace relit le sidecar');
    $assert->is($bot->registry->has_command('greet774', 'public'), 1,
        'mb590-774: commandes remontees apres replace');

    # unload demonte
    $pm->unregister_plugin('greet');
    $assert->is($bot->registry->has_command('greet774', 'public'), 0,
        'mb590-774: unload demonte les commandes du script');

    # [4] partyline : loadscript gate + sortie
    my $src = do { open my $fh, '<:encoding(UTF-8)', 'Mediabot/Partyline.pm' or die $!; local $/; <$fh> };
    $assert->like($src, qr/\Qload|loadscript|unload|reload|enable|disable|cleardata\E/,
        'mb590-774: loadscript dans le parseur de verbes');
    # mb601: cleardata rejoint la gate Owner.
    $assert->like($src, qr/\Qload|loadscript|unload|reload|cleardata)\E/,
        'mb590-774: loadscript exige Owner');
    $assert->like($src, qr/Loaded script plugin/,
        'mb590-774: sortie partyline annonce le script');
    $assert->like($src, qr/le reload d'un plugin SCRIPT relit le sidecar/i,
        'mb590-774: reload conscient du kind script');
};
