# MB760 — factoid write capability is separate, on-only and core-sourced.

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
    package T1118::FactoidWrites;
    sub new { bless { calls => [] }, shift }
    sub upsert {
        my ($self, %args) = @_;
        push @{ $self->{calls} }, { %args };
        return { ok => 1, status => 'stored', keyword => $args{keyword} };
    }
    sub delete { die 'delete not expected' }
}

{
    package T1118::User;
    sub new { bless {}, shift }
    sub is_authenticated { 1 }
    sub id { 7 }
    sub nickname { 'Luna' }
    sub has_level {
        my ($self, $level) = @_;
        return $level =~ /\A(?:Master|Administrator|User)\z/ ? 1 : 0;
    }
}

{
    package T1118::Log;
    sub new { bless { lines => [] }, shift }
    sub log { push @{ $_[0]{lines} }, $_[2]; 1 }
}

{
    package T1118::Bot;
    sub new {
        require Mediabot::CommandRegistry;
        bless {
            registry => Mediabot::CommandRegistry->new,
            logger => T1118::Log->new,
        }, shift;
    }
    sub command_registry { $_[0]{registry} }
    sub registry { $_[0]{registry} }
    sub getUserChannelLevel { 125 }
}

{
    package T1118::CommandContext;
    sub new { my ($class, %args) = @_; bless { %args }, $class }
    sub nick { 'Luna_' }
    sub channel { $_[0]{channel} }
    sub args { ['Lumos'] }
    sub is_private { 0 }
    sub reply { 1 }
    sub reply_private { 1 }
    sub user { T1118::User->new }
    sub message { bless {}, 'T1118::Message' }
}

return sub {
    my ($assert) = @_;
    require Mediabot::PluginManager;

    my $root = tempdir(CLEANUP => 1);
    my $package = "$root/factoid-write-probe";
    make_path("$package/lib");
    open my $mf, '>:encoding(UTF-8)', "$package/plugin.json" or die $!;
    print {$mf} JSON::PP->new->canonical->encode({
        api => 3, name => 'factoid-write-probe', version => '1.0.0',
        description => 'Factoid write facade probe.',
        runtime => { kind => 'perl', entrypoint => 'lib/FactoidWriteProbe.pm',
                     class => 'T1118::FactoidWriteProbe' },
        compatibility => {}, activation => { default => 'off' },
        capabilities => ['data.factoids.write'],
        commands => { factoidwriteprobe => {
            source => 'public', help => 'Probe factoid mutation.', level => 0,
            handler => 'probe', aliases => [],
        } },
        events => [], jobs => {}, config_schema => {},
    });
    close $mf;
    open my $pf, '>:encoding(UTF-8)', "$package/lib/FactoidWriteProbe.pm"
        or die $!;
    print {$pf} <<'PLUGIN';
package T1118::FactoidWriteProbe;
sub new { my ($class, %args) = @_; bless { %args }, $class }
sub probe {
    my ($self, $context, $invocation) = @_;
    return $context->factoid_upsert(
        $invocation, 'spell', join(' ', @{ $invocation->args }));
}
1;
PLUGIN
    close $pf;

    my $bot = T1118::Bot->new;
    my $writes = T1118::FactoidWrites->new;
    my $manager = Mediabot::PluginManager->new(
        bot => $bot, plugin_dir => $root,
        v3_factoid_write_service => $writes);
    $manager->load_package_v3(
        'factoid-write-probe', grants => ['data.factoids.write']);
    $manager->set_v3_channel_policy(
        'factoid-write-probe', '#Test', mode => 'observe', config => {});
    $manager->enable('factoid-write-probe');

    my $handler = $bot->{registry}->handler_for(
        'factoidwriteprobe', 'public');
    $handler->(T1118::CommandContext->new(channel => '#test'));
    $assert->is(scalar @{ $writes->{calls} }, 0,
        'observe executes plugin code but suppresses every factoid write');

    $manager->set_v3_channel_policy(
        'factoid-write-probe', '#test', mode => 'on', config => {});
    $handler->(T1118::CommandContext->new(channel => '#test'));
    $assert->is(scalar @{ $writes->{calls} }, 1,
        'explicit on policy permits the approved mutation');
    my $call = $writes->{calls}[0];
    $assert->is($call->{channel}, '#test',
        'policy supplies the channel instead of plugin arguments');
    $assert->is($call->{keyword}, 'spell',
        'only the approved keyword crosses the facade');
    $assert->is($call->{value}, 'Lumos',
        'only the approved value crosses the facade');
    $assert->is($call->{actor_nick}, 'Luna_',
        'core invocation supplies the display attribution');
    $assert->is($call->{principal}->user_id, 7,
        'core supplies the authenticated account identity');
    $assert->is($call->{principal}->global_level, 'master',
        'core derives the normalized global authorization level');
    $assert->is($call->{principal}->channel_level, 125,
        'core derives the current channel authorization level');

    require Mediabot::Plugin::InvocationV3;
    require Mediabot::Plugin::PrincipalV3;
    my $forged = Mediabot::Plugin::InvocationV3->new(
        nick => 'forged', channel => '#test', command => 'factoidwriteprobe',
        args => [], source => 'public', authority => $manager->plugin(
            'factoid-write-probe')->{metadata}{plugin_context},
        activation => 'on',
        principal => Mediabot::Plugin::PrincipalV3->new(
            authenticated => 1, user_id => 999, account => 'Forged',
            global_level => 'owner', channel_level => 500),
        reply_sink => sub { 1 }, notice_sink => sub { 1 },
    );
    eval {
        $manager->plugin('factoid-write-probe')->{metadata}{plugin_context}
            ->factoid_upsert($forged, 'forged', 'authority');
    };
    $assert->like($@ // '', qr/untrusted factoid write invocation/,
        'plugin-created invocations cannot forge channel or principal authority');
    $assert->is(scalar @{ $writes->{calls} }, 1,
        'forged invocation never reaches the mutation service');

    $manager->set_v3_channel_policy(
        'factoid-write-probe', '#test', mode => 'off', config => {});
    $handler->(T1118::CommandContext->new(channel => '#test'));
    $assert->is(scalar @{ $writes->{calls} }, 1,
        'off policy prevents plugin and write service execution');

    my $context = $manager->plugin('factoid-write-probe')
        ->{metadata}{plugin_context};
    $assert->ok(!$context->can('database') && !$context->can('sql')
        && !$context->can('user_object'),
        'write capability exposes no database, SQL or mutable user object');
};
