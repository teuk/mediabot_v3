# MB758 — capability and channel-policy wiring for approved factoid reads.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

use File::Path qw(make_path);
use File::Temp qw(tempdir);
use JSON::PP ();

{
    package T1112::FactoidService;
    sub new { bless { calls => [] }, shift }
    sub by_keyword {
        my ($self, %args) = @_;
        push @{ $self->{calls} }, { %args };
        return { ok => 1, record => undef };
    }
}

{
    package T1112::Log;
    sub new { bless { lines => [] }, shift }
    sub log { push @{ $_[0]{lines} }, $_[2]; 1 }
}

{
    package T1112::Bot;
    sub new {
        require Mediabot::CommandRegistry;
        bless {
            registry => Mediabot::CommandRegistry->new,
            logger => T1112::Log->new,
        }, shift;
    }
    sub command_registry { $_[0]{registry} }
    sub registry { $_[0]{registry} }
}

{
    package T1112::CommandContext;
    sub new { my ($class, %args) = @_; bless { %args }, $class }
    sub nick { 'Luna' }
    sub channel { $_[0]{channel} }
    sub args { [] }
    sub is_private { 0 }
    sub reply { 1 }
    sub reply_private { 1 }
}

return sub {
    my ($assert) = @_;
    require Mediabot::PluginManager;

    my $root = tempdir(CLEANUP => 1);
    my $package = "$root/factoid-probe";
    make_path("$package/lib");
    open my $manifest_fh, '>:encoding(UTF-8)', "$package/plugin.json"
        or die $!;
    print {$manifest_fh} JSON::PP->new->canonical->encode({
        api => 3,
        name => 'factoid-probe',
        version => '1.0.0',
        description => 'Factoid facade test package.',
        runtime => {
            kind => 'perl',
            entrypoint => 'lib/FactoidProbe.pm',
            class => 'T1112::FactoidProbe',
        },
        compatibility => {},
        activation => { default => 'off' },
        capabilities => ['data.factoids.read'],
        commands => {
            factprobe => {
                source => 'public',
                help => 'Probe factoid data.',
                level => 0,
                handler => 'probe',
                aliases => [],
            },
        },
        events => [], jobs => {}, config_schema => {},
    });
    close $manifest_fh;

    open my $plugin_fh, '>:encoding(UTF-8)',
        "$package/lib/FactoidProbe.pm" or die $!;
    print {$plugin_fh} <<'PLUGIN';
package T1112::FactoidProbe;
sub new { my ($class, %args) = @_; bless { %args }, $class }
sub probe {
    my ($self, $context, $invocation) = @_;
    return $context->factoid_by_keyword($invocation, 'spell');
}
1;
PLUGIN
    close $plugin_fh;

    my $bot = T1112::Bot->new;
    my $factoids = T1112::FactoidService->new;
    my $manager = Mediabot::PluginManager->new(
        bot => $bot,
        plugin_dir => $root,
        v3_factoid_service => $factoids,
    );
    $manager->load_package_v3(
        'factoid-probe', grants => ['data.factoids.read']);
    $manager->set_v3_channel_policy(
        'factoid-probe', '#Test', mode => 'observe', config => {});
    $manager->enable('factoid-probe');

    my $handler = $bot->{registry}->handler_for('factprobe', 'public');
    $handler->(T1112::CommandContext->new(channel => '#test'));
    $assert->is(scalar @{ $factoids->{calls} }, 1,
        'observe may execute a side-effect-free approved factoid read');
    $assert->is($factoids->{calls}[0]{channel}, '#Test',
        'core policy supplies the channel instead of plugin arguments');
    $assert->is($factoids->{calls}[0]{keyword}, 'spell',
        'only approved method arguments cross the facade');

    $manager->set_v3_channel_policy(
        'factoid-probe', '#test', mode => 'off', config => {});
    $handler->(T1112::CommandContext->new(channel => '#test'));
    $assert->is(scalar @{ $factoids->{calls} }, 1,
        'off prevents both plugin and factoid service from running');

    my $context = $manager->plugin('factoid-probe')
        ->{metadata}{plugin_context};
    $assert->ok(!$context->can('database') && !$context->can('sql'),
        'factoid capability adds no generic database or SQL escape hatch');
    $assert->ok(!$context->has_capability('data.factoids.write'),
        'read capability does not imply a factoid mutation capability');

    my $denied_bot = T1112::Bot->new;
    my $denied_factoids = T1112::FactoidService->new;
    my $denied_manager = Mediabot::PluginManager->new(
        bot => $denied_bot,
        plugin_dir => $root,
        v3_factoid_service => $denied_factoids,
    );
    $denied_manager->load_package_v3('factoid-probe', grants => []);
    $denied_manager->set_v3_channel_policy(
        'factoid-probe', '#test', mode => 'observe', config => {});
    $denied_manager->enable('factoid-probe');

    my $denied_handler = $denied_bot->{registry}
        ->handler_for('factprobe', 'public');
    my $ok = eval {
        $denied_handler->(T1112::CommandContext->new(channel => '#test'));
        1;
    };
    $assert->ok($ok && !$@,
        'ungranted factoid capability failure is contained by the core');
    $assert->is(scalar @{ $denied_factoids->{calls} }, 0,
        'ungranted factoid capability never reaches the core service');
    $assert->like($denied_bot->{logger}{lines}[-1] // '',
        qr/capability 'data\.factoids\.read' was not granted/,
        'contained factoid capability failure remains operator-visible');
};
