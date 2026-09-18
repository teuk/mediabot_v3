# MB742 — explicit API v3 loading, lifecycle and registry integration.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

{
    package T1068::Log;
    sub new { bless { lines => [] }, shift }
    sub log { push @{ $_[0]{lines} }, $_[2]; 1 }
}

{
    package T1068::Bot;
    sub new {
        require Mediabot::CommandRegistry;
        return bless {
            registry => Mediabot::CommandRegistry->new,
            logger   => T1068::Log->new,
        }, shift;
    }
    sub command_registry { $_[0]{registry} }
    sub registry { $_[0]{registry} }
}

{
    package T1068::Context;
    sub new { my ($class, %args) = @_; bless { %args, replies => [], notices => [] }, $class }
    sub nick { $_[0]{nick} }
    sub channel { $_[0]{channel} }
    sub command { $_[0]{command} }
    sub args { $_[0]{args} || [] }
    sub is_private { 0 }
    sub reply { push @{ $_[0]{replies} }, $_[1]; 1 }
    sub reply_private { push @{ $_[0]{notices} }, $_[1]; 1 }
}

return sub {
    my ($assert) = @_;

    require Mediabot::PluginManager;
    my $bot = T1068::Bot->new;
    my $manager = Mediabot::PluginManager->new(
        bot => $bot, plugin_dir => 'plugins');

    my @packages = $manager->discover_v3_packages;
    $assert->ok(grep($_->{name} eq 'hello-v3', @packages),
        'manager exposes read-only v3 discovery');
    $assert->is($manager->count, 0,
        'discovery neither registers nor activates a package');

    my $entry = $manager->load_package_v3(
        'hello-v3', grants => ['irc.reply']);
    $assert->is($entry->{metadata}{api}, 3,
        'explicit load registers API v3 metadata');
    $assert->is($manager->is_enabled('hello-v3'), 0,
        'explicit load still leaves package disabled');
    $assert->is($bot->{registry}->has_command('v3hello', 'public'), 1,
        'declared command is mounted through CommandRegistry');
    $assert->is($entry->{metadata}{effective_capabilities}[0], 'irc.reply',
        'entry records the effective capability set');
    $assert->ok(!exists($entry->{object}{bot})
            && !$entry->{metadata}{plugin_context}->can('bot'),
        'plugin object and PluginContext contain no bot reference');

    my $handler = $bot->{registry}->handler_for('v3hello', 'public');
    my $ctx = T1068::Context->new(
        nick => 'Tangy', channel => '#i/o', command => 'v3hello', args => []);
    $handler->($ctx);
    $assert->is(scalar @{ $ctx->{replies} }, 0,
        'loaded but disabled command stays silent');

    $manager->enable('hello-v3');
    $assert->is($entry->{object}{started}, 1,
        'explicit enable invokes start');
    $handler->($ctx);
    $assert->like($ctx->{replies}[0] // '', qr/capability-scoped API v3 plugin/,
        'enabled witness replies through its granted facade');

    $manager->disable('hello-v3');
    $assert->is($entry->{object}{started}, 0,
        'disable invokes stop before leaving the plugin silent');
    $handler->($ctx);
    $assert->is(scalar @{ $ctx->{replies} }, 1,
        'disabled command remains mounted but emits nothing');

    $manager->unregister_plugin('hello-v3');
    $assert->is($bot->{registry}->has_command('v3hello', 'public'), 0,
        'unregister transactionally unmounts v3 command');

    my $no_grant = $manager->load_package_v3('hello-v3', grants => []);
    $manager->enable('hello-v3');
    my $denied = $bot->{registry}->handler_for('v3hello', 'public');
    my $ok = eval { $denied->($ctx); 1 };
    $assert->ok($ok && !$@,
        'ungranted output capability is contained by the core');
    $assert->is(scalar @{ $ctx->{replies} }, 1,
        'capability failure emits no IRC line');
    $assert->like($bot->{logger}{lines}[-1] // '',
        qr/capability 'irc\.reply' was not granted/,
        'contained capability failure remains operator-visible');
    $manager->unregister_plugin('hello-v3');

    $ok = eval {
        $manager->load_package_v3('hello-v3', grants => ['http.fetch']);
        1;
    };
    $assert->like($@ // '', qr/was not requested/,
        'operator cannot grant a capability absent from manifest');
    $assert->is($manager->count, 0,
        'failed grant validation leaves no registered plugin');
};
