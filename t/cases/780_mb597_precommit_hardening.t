# t/cases/780_mb597_precommit_hardening.t
# =============================================================================
# mb597 — garde pre-commit de la serie mb592-mb596.
#   [1] public_command_observed accepte un Mediabot::Context (HASH beni) et
#       transmet channel/target/nick/command/args au script.
#   [2] events dupliques refuses ; EventBus absent = load fail-closed.
#   [3] erreurs runner/action conservees dans le journal sans crash.
#   [4] gardes structurelles : 4e fallback CommandAsync et fermeture du
#       transport au flood boot partyline.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Temp qw(tempdir);
use JSON::PP ();

my $DIR = tempdir(CLEANUP => 1);

sub _fixture_780 {
    my ($name, $events, $version) = @_;
    $version //= '1.0';
    open my $sf, '>', "$DIR/$name.py" or die $!;
    print {$sf} "# fixture\n";
    close $sf;
    open my $mf, '>', "$DIR/$name.py.manifest.json" or die $!;
    print {$mf} JSON::PP::encode_json({
        api => 2, name => $name, version => $version, events => $events,
    });
    close $mf;
}

{
    package Runner780;
    sub new { bless { dir => $_[1], calls => [], result => { ok => 1, response => { actions => [] } } }, $_[0] }
    sub script_dir { $_[0]{dir} }
    sub validate_script_path {
        my ($self, $rel) = @_;
        return (1, undef, 'python', "$self->{dir}/$rel");
    }
    sub _path_within_script_dir { return (1, undef) }
    sub run_script {
        my ($self, $path, $event, %data) = @_;
        push @{ $self->{calls} }, { path => $path, event => $event, data => { %data } };
        return $self->{result};
    }
}
{
    package Actions780;
    sub new { bless { plan => { applied_ok => 1 } }, shift }
    sub apply_actions { $_[0]{last} = [ @_[1..$#_] ]; return $_[0]{plan} }
}
{
    package Logger780;
    sub new { bless { lines => [] }, shift }
    sub log { push @{ $_[0]{lines} }, $_[2]; 1 }
}
{
    package FailBus780;
    our @ISA = ('Mediabot::EventBus');
    sub on {
        my ($self, $event, @rest) = @_;
        die "forced subscribe failure\n"
            if defined($self->{fail_event}) && $event eq $self->{fail_event};
        return $self->SUPER::on($event, @rest);
    }
}
{
    package Bot780;
    sub new {
        require Mediabot::EventBus;
        my ($class, $dir, $with_bus, $bus) = @_;
        my $self = bless {
            runner => Runner780->new($dir),
            actions => Actions780->new,
            logger => Logger780->new,
        }, $class;
        $self->{bus} = $bus || Mediabot::EventBus->new if $with_bus;
        return $self;
    }
    sub script_runner { $_[0]{runner} }
    sub script_action_runner { $_[0]{actions} }
    sub events { $_[0]{bus} }
    sub registry { undef }
}
return sub {
    my ($assert) = @_;
    require Mediabot::PluginManager;
    require Mediabot::Context;

    my $ctx = Mediabot::Context->new(
        bot => undef, message => undef, channel => '#i/o', nick => 'Teuk',
        command => 'coin', args => [ '3', 'fast' ],
    );

    _fixture_780('publicwatch', ['public_command_observed']);
    my $bot = Bot780->new($DIR, 1);
    my $pm = Mediabot::PluginManager->new(bot => $bot);
    my $entry = eval { $pm->load_script_v2('publicwatch.py') };
    $assert->ok($entry, 'mb597-780: event plugin charge avec EventBus');
    $bot->events->emit('public_command_observed', $ctx);
    $assert->is(scalar @{ $bot->{runner}{calls} }, 1,
        'mb597-780: le contexte beni declenche le script');
    my $call = $bot->{runner}{calls}[0];
    $assert->is($call->{data}{channel}, '#i/o', 'mb597-780: channel transmis');
    $assert->is($call->{data}{target}, '#i/o', 'mb597-780: target derive du channel');
    $assert->is($call->{data}{nick}, 'Teuk', 'mb597-780: nick transmis');
    $assert->is($call->{data}{command}, 'coin', 'mb597-780: command transmis');
    $assert->is(join(',', @{ $call->{data}{args} || [] }), '3,fast',
        'mb597-780: args scalaires transmis');

    _fixture_780('duplicate', ['channel_join_observed', 'channel_join_observed']);
    my $ok = eval { $pm->load_script_v2('duplicate.py'); 1 };
    $assert->ok(!$ok, 'mb597-780: event duplique refuse');
    $assert->like($@ // '', qr/declared more than once/,
        'mb597-780: raison du doublon explicite');
    $assert->ok(!$pm->is_registered('duplicate'),
        'mb597-780: doublon ne laisse aucun demi-etat');

    _fixture_780('nobus', ['channel_join_observed']);
    my $bot_no_bus = Bot780->new($DIR, 0);
    my $pm_no_bus = Mediabot::PluginManager->new(bot => $bot_no_bus);
    $ok = eval { $pm_no_bus->load_script_v2('nobus.py'); 1 };
    $assert->ok(!$ok, 'mb597-780: EventBus absent refuse le plugin event');
    $assert->like($@ // '', qr/event bus unavailable/,
        'mb597-780: EventBus absent explique');
    $assert->ok(!$pm_no_bus->is_registered('nobus'),
        'mb597-780: EventBus absent ne laisse aucun demi-etat');

    # Echec APRES desabonnement de l'ancienne entry : le rollback doit
    # remonter exactement son abonnement precedent, sans doublon.
    require Mediabot::EventBus;
    my $fail_bus = FailBus780->new;
    my $bot_rb = Bot780->new($DIR, 1, $fail_bus);
    my $pm_rb = Mediabot::PluginManager->new(bot => $bot_rb);
    _fixture_780('rollback', ['channel_join_observed'], '1.0');
    my $old = $pm_rb->load_script_v2('rollback.py');
    $assert->ok($old, 'mb597-780: fixture rollback initiale chargee');
    $fail_bus->{fail_event} = 'channel_part_observed';
    _fixture_780('rollback',
        ['channel_join_observed', 'channel_part_observed'], '2.0');
    $ok = eval {
        $pm_rb->load_script_v2('rollback.py', name => 'rollback', replace => 1);
        1;
    };
    $assert->ok(!$ok, 'mb597-780: echec d abonnement pendant replace remonte');
    $assert->like($@ // '', qr/forced subscribe failure/,
        'mb597-780: raison du replace conservee');
    $assert->is($pm_rb->plugin('rollback')->{version}, '1.0',
        'mb597-780: ancienne entry restauree');
    $assert->is($fail_bus->listener_count('channel_join_observed'), 1,
        'mb597-780: ancien listener restaure une fois');
    $assert->is($fail_bus->listener_count('channel_part_observed'), 0,
        'mb597-780: listener partiel du candidat retire');

    $bot->{runner}{result} = { ok => 0, errors => [ 'bounded runner failure' ] };
    $bot->events->emit('public_command_observed', $ctx);
    $assert->ok((grep { /bounded runner failure/ } @{ $bot->{logger}{lines} }),
        'mb597-780: diagnostic runner conserve au journal');

    $bot->{runner}{result} = { ok => 1, response => { actions => [] } };
    $bot->{actions}{plan} = { applied_ok => 0,
        apply_errors => [ { error => 'bounded apply failure' } ] };
    $bot->events->emit('public_command_observed', $ctx);
    $assert->ok((grep { /bounded apply failure/ } @{ $bot->{logger}{lines} }),
        'mb597-780: diagnostic action conserve au journal');

    $pm->unregister_plugin('publicwatch');
    $assert->is($bot->events->listener_count('public_command_observed'), 0,
        'mb597-780: unload retire le listener');

    my $async_src = do {
        open my $fh, '<:encoding(UTF-8)', 'Mediabot/CommandAsync.pm' or die $!;
        local $/; <$fh>;
    };
    my $fallbacks = () = $async_src =~ /\{fallback_sync\}\+\+/g;
    $assert->is($fallbacks, 4,
        'mb597-780: les quatre replis synchrones sont comptes');
    $assert->like($async_src,
        qr/unless \(\$watch_ok\) \{\s*\$self->\{_cmd_async_stats\}\{fallback_sync\}\+\+/s,
        'mb597-780: le repli watch_process incremente le compteur');

    my $party_src = do {
        open my $fh, '<:encoding(UTF-8)', 'Mediabot/Partyline.pm' or die $!;
        local $/; <$fh>;
    };
    $assert->like($party_src,
        qr/Flood protection: disconnecting.*?close_when_empty.*?_close_session/s,
        'mb597-780: flood boot ferme le stream avant le nettoyage');
};
