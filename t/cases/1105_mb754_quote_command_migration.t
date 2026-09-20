# MB754 — q and quote shadow safely, adopt per channel and roll back exactly.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

use Scalar::Util qw(refaddr);

{
    package T1105::Logger;
    sub new { bless {}, shift }
    sub log { 1 }
}

{
    package T1105::Writes;
    sub new { bless { calls => [] }, shift }
    sub add {
        my ($self, %args) = @_;
        push @{ $self->{calls} }, [add => { %args }];
        return { ok => 1, status => 'created', id => 73 };
    }
    sub delete { die 'delete not expected' }
    sub recall { die 'recall not expected' }
}

{
    package T1105::Reads;
    sub new { bless {}, shift }
}

{
    package T1105::User;
    sub new { bless {}, shift }
    sub is_authenticated { 1 }
    sub id { 7 }
    sub nickname { 'Luna' }
    sub has_level { 1 }
}

{
    package T1105::Bot;
    sub new {
        require Mediabot::CommandRegistry;
        bless {
            registry => Mediabot::CommandRegistry->new,
            logger => T1105::Logger->new,
        }, shift;
    }
    sub command_registry { $_[0]{registry} }
    sub registry { $_[0]{registry} }
    sub getUserChannelLevel { 0 }
}

{
    package T1105::Context;
    sub new { my ($class, %args) = @_; bless { %args, replies => [], notices => [] }, $class }
    sub nick { 'Luna_' }
    sub channel { '#development' }
    sub command { 'q' }
    sub args { ['add', 'Expecto', 'Patronum'] }
    sub is_private { 0 }
    sub user { T1105::User->new }
    sub message { bless {}, 'T1105::Message' }
    sub reply { push @{ $_[0]{replies} }, $_[1]; 1 }
    sub reply_private { push @{ $_[0]{notices} }, $_[1]; 1 }
}

return sub {
    my ($assert) = @_;
    require Mediabot::PluginManager;

    my $bot = T1105::Bot->new;
    my (%original, %legacy_calls);
    for my $name (qw(q quote quotecount topquote halloffame)) {
        my $handler = sub { $legacy_calls{$name}++; 1 };
        $original{$name} = $handler;
        $bot->{registry}->register_command(
            name => $name, source => 'public', handler => $handler,
            category => 'core', metadata => {
                builtin => 1, dispatch => 'registry', syntax => $name,
                migration_fallback => 1,
            });
    }
    my $writes = T1105::Writes->new;
    my $manager = Mediabot::PluginManager->new(
        bot => $bot, plugin_dir => 'plugins',
        v3_quote_service => T1105::Reads->new,
        v3_quote_write_service => $writes);
    $manager->load_package_v3('quotes-v3', grants => [
        qw(data.quotes.read data.quotes.write irc.reply irc.notice)
    ]);
    my $handler = $bot->{registry}->handler_for('q', 'public');
    my $ctx = T1105::Context->new;

    $handler->($ctx);
    $assert->is($legacy_calls{q}, 1,
        'disabled package preserves the q built-in');
    $assert->is(scalar @{ $writes->{calls} }, 0,
        'disabled package cannot mutate quotes');

    $manager->set_v3_channel_policy(
        'quotes-v3', '#development', mode => 'observe');
    $manager->enable('quotes-v3');
    $handler->($ctx);
    $assert->is($legacy_calls{q}, 2,
        'observe keeps the historical q answer and mutation path visible');
    $assert->is(scalar @{ $writes->{calls} }, 0,
        'observe suppresses the shadow add before the write service');

    $manager->set_v3_channel_policy(
        'quotes-v3', '#development', mode => 'on');
    $handler->($ctx);
    $assert->is($legacy_calls{q}, 2,
        'on makes q authoritative only for the opted-in channel');
    $assert->is(scalar @{ $writes->{calls} }, 1,
        'on permits exactly one approved add');
    $assert->is($writes->{calls}[0][1]{text}, 'Expecto Patronum',
        'the adopted command passes bounded text through the core service');
    $assert->is($ctx->{replies}[-1], "(Luna) done. (id: \x0273\x02)",
        'on returns the v3 quote result');

    $manager->set_v3_channel_policy(
        'quotes-v3', '#development', mode => 'off');
    $handler->($ctx);
    $assert->is($legacy_calls{q}, 3,
        'off immediately restores historical q behavior');

    $manager->unregister_plugin('quotes-v3');
    for my $name (qw(q quote quotecount topquote halloffame)) {
        my $restored = $bot->{registry}->command_for($name, 'public');
        $assert->is(refaddr($restored->{handler}), refaddr($original{$name}),
            "unload restores the exact $name handler reference");
    }
};
