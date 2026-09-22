# MB759 — pure factoid readers shadow, adopt and roll back exactly.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

use Scalar::Util qw(refaddr);

{
    package T1115::Logger;
    sub new { bless { lines => [] }, shift }
    sub log { push @{ $_[0]{lines} }, $_[2]; 1 }
}

{
    package T1115::Factoids;
    sub new { bless { calls => [] }, shift }
    sub by_keyword {
        my ($self, %args) = @_;
        require Mediabot::Plugin::FactoidRecordV3;
        push @{ $self->{calls} }, [by_keyword => { %args }];
        return { ok => 1, record =>
            Mediabot::Plugin::FactoidRecordV3->new(
                id => 4, keyword => $args{keyword}, value => 'Alohomora',
                author => 'Hermione', author_id => 7,
                created_at => '2026-09-21 10:00:00',
                updated_at => '2026-09-21 10:00:00', hits => 2) };
    }
    sub list {
        my ($self, %args) = @_;
        push @{ $self->{calls} }, [list => { %args }];
        return { ok => 1, keywords => [qw(spell wand)] };
    }
    sub top { die 'top not expected' }
}

{
    package T1115::Bot;
    sub new {
        require Mediabot::CommandRegistry;
        bless {
            registry => Mediabot::CommandRegistry->new,
            logger => T1115::Logger->new,
        }, shift;
    }
    sub command_registry { $_[0]{registry} }
    sub registry { $_[0]{registry} }
    sub getUserChannelLevel { 0 }
}

{
    package T1115::Context;
    sub new {
        my ($class, %args) = @_;
        bless { command => $args{command}, args => $args{args} || [],
            replies => [], notices => [] }, $class;
    }
    sub nick { 'Luna' }
    sub channel { '#development' }
    sub command { $_[0]{command} }
    sub args { $_[0]{args} }
    sub is_private { 0 }
    sub user { undef }
    sub reply { push @{ $_[0]{replies} }, $_[1]; 1 }
    sub reply_private { push @{ $_[0]{notices} }, $_[1]; 1 }
}

return sub {
    my ($assert) = @_;
    require Mediabot::PluginManager;

    my $bot = T1115::Bot->new;
    my (%original, %legacy_calls);
    for my $name (qw(factoid factoids learn forget whatis)) {
        my $handler = sub { $legacy_calls{$name}++; 1 };
        $original{$name} = $handler;
        $bot->{registry}->register_command(
            name => $name, source => 'public', handler => $handler,
            category => 'core', metadata => {
                builtin => 1, dispatch => 'registry', syntax => $name,
                migration_fallback => 1,
            });
    }

    my $factoids = T1115::Factoids->new;
    my $manager = Mediabot::PluginManager->new(
        bot => $bot, plugin_dir => 'plugins',
        v3_factoid_service => $factoids);
    $manager->load_package_v3('factoids-v3', grants => [
        qw(data.factoids.read data.factoids.write irc.reply irc.notice)
    ]);

    my $factoid = $bot->{registry}->handler_for('factoid', 'public');
    my $detail_ctx = T1115::Context->new(
        command => 'factoid', args => ['spell']);
    $factoid->($detail_ctx);
    $assert->is($legacy_calls{factoid}, 1,
        'disabled package preserves the factoid built-in');
    $assert->is(scalar @{ $factoids->{calls} }, 0,
        'disabled package performs no factoid read');

    $manager->set_v3_channel_policy(
        'factoids-v3', '#development', mode => 'observe');
    $manager->enable('factoids-v3');
    $factoid->($detail_ctx);
    $assert->is($legacy_calls{factoid}, 2,
        'observe keeps the historical factoid answer visible');
    $assert->is(scalar @{ $factoids->{calls} }, 1,
        'observe executes one side-effect-free shadow read');
    $assert->is(scalar @{ $detail_ctx->{notices} }, 0,
        'observe suppresses every v3 notice');

    $manager->set_v3_channel_policy(
        'factoids-v3', '#development', mode => 'on');
    $factoid->($detail_ctx);
    $assert->is($legacy_calls{factoid}, 2,
        'on makes factoid authoritative only for the opted-in channel');
    $assert->is($factoids->{calls}[-1][0], 'by_keyword',
        'authoritative factoid uses the approved exact read');
    $assert->is($detail_ctx->{notices}[-1], 'value: Alohomora',
        'on returns the v3 factoid result');

    my $factoid_list = $bot->{registry}->handler_for('factoids', 'public');
    my $list_ctx = T1115::Context->new(
        command => 'factoids', args => []);
    $factoid_list->($list_ctx);
    $assert->is($factoids->{calls}[-1][0], 'list',
        'authoritative factoids uses the approved bounded list');
    $assert->is($list_ctx->{notices}[-1],
        '2 factoid(s) on #development: spell, wand',
        'on returns the v3 factoid list');

    $manager->set_v3_channel_policy(
        'factoids-v3', '#development', mode => 'off');
    $factoid->($detail_ctx);
    $factoid_list->($list_ctx);
    $assert->is($legacy_calls{factoid}, 3,
        'off immediately restores historical factoid behavior');
    $assert->is($legacy_calls{factoids}, 1,
        'off immediately restores historical factoids behavior');

    $manager->unregister_plugin('factoids-v3');
    for my $name (qw(factoid factoids learn forget whatis)) {
        my $restored = $bot->{registry}->command_for($name, 'public');
        $assert->is(refaddr($restored->{handler}), refaddr($original{$name}),
            "unload restores the exact $name handler reference");
    }
};
