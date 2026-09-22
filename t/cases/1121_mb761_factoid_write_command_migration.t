# MB761 — learn and forget shadow, adopt and roll back without double writes.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

use Scalar::Util qw(refaddr);

{
    package T1121::Logger;
    sub new { bless {}, shift }
    sub log { 1 }
}

{
    package T1121::Writes;
    sub new { bless { calls => [] }, shift }
    sub upsert {
        my ($self, %args) = @_;
        push @{ $self->{calls} }, [upsert => { %args }];
        return { ok => 1, status => 'stored', keyword => $args{keyword} };
    }
    sub delete {
        my ($self, %args) = @_;
        push @{ $self->{calls} }, [delete => { %args }];
        return { ok => 1, status => 'deleted', keyword => $args{keyword}, id => 9 };
    }
}

{
    package T1121::Reads;
    sub new { bless {}, shift }
}

{
    package T1121::User;
    sub new { bless {}, shift }
    sub is_authenticated { 1 }
    sub id { 7 }
    sub nickname { 'Luna' }
    sub has_level { $_[1] eq 'User' ? 1 : 0 }
}

{
    package T1121::Bot;
    sub new {
        require Mediabot::CommandRegistry;
        bless {
            registry => Mediabot::CommandRegistry->new,
            logger => T1121::Logger->new,
        }, shift;
    }
    sub command_registry { $_[0]{registry} }
    sub registry { $_[0]{registry} }
    sub getUserChannelLevel { 0 }
}

{
    package T1121::Context;
    sub new {
        my ($class, %args) = @_;
        bless { %args, notices => [], replies => [] }, $class;
    }
    sub nick { 'Luna_' }
    sub channel { '#development' }
    sub command { $_[0]{command} }
    sub args { $_[0]{args} }
    sub is_private { 0 }
    sub user { T1121::User->new }
    sub message { bless {}, 'T1121::Message' }
    sub reply { push @{ $_[0]{replies} }, $_[1]; 1 }
    sub reply_private { push @{ $_[0]{notices} }, $_[1]; 1 }
}

return sub {
    my ($assert) = @_;
    require Mediabot::PluginManager;

    my $bot = T1121::Bot->new;
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

    my $writes = T1121::Writes->new;
    my $manager = Mediabot::PluginManager->new(
        bot => $bot, plugin_dir => 'plugins',
        v3_factoid_service => T1121::Reads->new,
        v3_factoid_write_service => $writes);
    $manager->load_package_v3('factoids-v3', grants => [
        qw(data.factoids.read data.factoids.write irc.reply irc.notice)
    ]);

    my $learn = $bot->{registry}->handler_for('learn', 'public');
    my $learn_ctx = T1121::Context->new(
        command => 'learn', args => ['spell', '=', 'Alohomora']);
    $learn->($learn_ctx);
    $assert->is($legacy_calls{learn}, 1,
        'disabled package preserves the historical learn handler');
    $assert->is(scalar @{ $writes->{calls} }, 0,
        'disabled package cannot mutate factoids');

    $manager->set_v3_channel_policy(
        'factoids-v3', '#development', mode => 'observe');
    $manager->enable('factoids-v3');
    $learn->($learn_ctx);
    $assert->is($legacy_calls{learn}, 2,
        'observe leaves the historical learn mutation authoritative');
    $assert->is(scalar @{ $writes->{calls} }, 0,
        'observe suppresses the shadow upsert before the service');
    $assert->is(scalar @{ $learn_ctx->{notices} }, 0,
        'observe emits no second learn answer');

    $manager->set_v3_channel_policy(
        'factoids-v3', '#development', mode => 'on');
    $learn->($learn_ctx);
    $assert->is($legacy_calls{learn}, 2,
        'on makes learn authoritative only for the selected channel');
    $assert->is(scalar @{ $writes->{calls} }, 1,
        'on permits exactly one approved upsert');
    $assert->is($writes->{calls}[0][1]{keyword}, 'spell',
        'adopted learn passes the bounded keyword');
    $assert->is($writes->{calls}[0][1]{value}, 'Alohomora',
        'adopted learn passes the bounded value');
    $assert->is($learn_ctx->{notices}[-1],
        "Learned 'spell' for #development.",
        'on returns the v3 learn notice');

    my $forget = $bot->{registry}->handler_for('forget', 'public');
    my $forget_ctx = T1121::Context->new(
        command => 'forget', args => ['spell']);
    $forget->($forget_ctx);
    $assert->is($writes->{calls}[-1][0], 'delete',
        'on routes forget through the approved delete operation');
    $assert->is($forget_ctx->{notices}[-1],
        "Forgot 'spell' on #development.",
        'on returns the v3 forget notice');

    $manager->set_v3_channel_policy(
        'factoids-v3', '#development', mode => 'off');
    $learn->($learn_ctx);
    $forget->($forget_ctx);
    $assert->is($legacy_calls{learn}, 3,
        'off immediately restores historical learn behavior');
    $assert->is($legacy_calls{forget}, 1,
        'off immediately restores historical forget behavior');

    $manager->unregister_plugin('factoids-v3');
    for my $name (qw(factoid factoids learn forget whatis)) {
        my $restored = $bot->{registry}->command_for($name, 'public');
        $assert->is(refaddr($restored->{handler}), refaddr($original{$name}),
            "unload restores the exact $name handler reference");
    }
};
