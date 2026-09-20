# MB753 — write capability is separate, on-only and supplied a core principal.

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
    package T1102::QuoteWrites;
    sub new { bless { calls => [] }, shift }
    sub add {
        my ($self, %args) = @_;
        push @{ $self->{calls} }, { %args };
        return { ok => 1, status => 'created', id => 73 };
    }
    sub delete { die 'delete not expected' }
}

{
    package T1102::User;
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
    package T1102::Log;
    sub new { bless { lines => [] }, shift }
    sub log { push @{ $_[0]{lines} }, $_[2]; 1 }
}

{
    package T1102::Bot;
    sub new {
        require Mediabot::CommandRegistry;
        bless {
            registry => Mediabot::CommandRegistry->new,
            logger => T1102::Log->new,
        }, shift;
    }
    sub command_registry { $_[0]{registry} }
    sub registry { $_[0]{registry} }
    sub getUserChannelLevel { 125 }
}

{
    package T1102::CommandContext;
    sub new { my ($class, %args) = @_; bless { %args }, $class }
    sub nick { 'Luna_' }
    sub channel { $_[0]{channel} }
    sub args { ['Wingardium Leviosa'] }
    sub is_private { 0 }
    sub reply { 1 }
    sub reply_private { 1 }
    sub user { T1102::User->new }
    sub message { bless {}, 'T1102::Message' }
}

return sub {
    my ($assert) = @_;
    require Mediabot::PluginManager;

    my $root = tempdir(CLEANUP => 1);
    my $package = "$root/quote-write-probe";
    make_path("$package/lib");
    open my $mf, '>:encoding(UTF-8)', "$package/plugin.json" or die $!;
    print {$mf} JSON::PP->new->canonical->encode({
        api => 3, name => 'quote-write-probe', version => '1.0.0',
        description => 'Quote write facade probe.',
        runtime => { kind => 'perl', entrypoint => 'lib/QuoteWriteProbe.pm',
                     class => 'T1102::QuoteWriteProbe' },
        compatibility => {}, activation => { default => 'off' },
        capabilities => ['data.quotes.write'],
        commands => { quotewriteprobe => {
            source => 'public', help => 'Probe quote mutation.', level => 0,
            handler => 'probe', aliases => [],
        } },
        events => [], jobs => {}, config_schema => {},
    });
    close $mf;
    open my $pf, '>:encoding(UTF-8)', "$package/lib/QuoteWriteProbe.pm" or die $!;
    print {$pf} <<'PLUGIN';
package T1102::QuoteWriteProbe;
sub new { my ($class, %args) = @_; bless { %args }, $class }
sub probe {
    my ($self, $context, $invocation) = @_;
    return $context->quote_add($invocation, join(' ', @{ $invocation->args }));
}
1;
PLUGIN
    close $pf;

    my $bot = T1102::Bot->new;
    my $writes = T1102::QuoteWrites->new;
    my $manager = Mediabot::PluginManager->new(
        bot => $bot, plugin_dir => $root,
        v3_quote_write_service => $writes);
    $manager->load_package_v3(
        'quote-write-probe', grants => ['data.quotes.write']);
    $manager->set_v3_channel_policy(
        'quote-write-probe', '#Test', mode => 'observe', config => {});
    $manager->enable('quote-write-probe');

    my $handler = $bot->{registry}->handler_for('quotewriteprobe', 'public');
    $handler->(T1102::CommandContext->new(channel => '#test'));
    $assert->is(scalar @{ $writes->{calls} }, 0,
        'observe executes plugin code but suppresses every data write');

    $manager->set_v3_channel_policy(
        'quote-write-probe', '#test', mode => 'on', config => {});
    $handler->(T1102::CommandContext->new(channel => '#test'));
    $assert->is(scalar @{ $writes->{calls} }, 1,
        'explicit on policy permits the approved mutation');
    my $call = $writes->{calls}[0];
    $assert->is($call->{channel}, '#test',
        'policy supplies the channel instead of plugin arguments');
    $assert->is($call->{text}, 'Wingardium Leviosa',
        'only the approved bounded argument crosses the facade');
    $assert->is($call->{principal}->user_id, 7,
        'core supplies the authenticated account identity');
    $assert->is($call->{principal}->global_level, 'master',
        'core derives the normalized global authorization level');
    $assert->is($call->{principal}->channel_level, 125,
        'core derives the current channel authorization level');

    require Mediabot::Plugin::InvocationV3;
    require Mediabot::Plugin::PrincipalV3;
    my $forged = Mediabot::Plugin::InvocationV3->new(
        nick => 'forged', channel => '#test', command => 'quotewriteprobe',
        args => [], source => 'public', authority => $manager->plugin(
            'quote-write-probe')->{metadata}{plugin_context},
        activation => 'on',
        principal => Mediabot::Plugin::PrincipalV3->new(
            authenticated => 1, user_id => 999, account => 'Forged',
            global_level => 'owner', channel_level => 500),
        reply_sink => sub { 1 }, notice_sink => sub { 1 },
    );
    eval {
        $manager->plugin('quote-write-probe')->{metadata}{plugin_context}
            ->quote_add($forged, 'Forged authority');
    };
    $assert->like($@ // '', qr/untrusted quote write invocation/,
        'plugin-created invocations cannot forge channel or principal authority');
    $assert->is(scalar @{ $writes->{calls} }, 1,
        'forged invocation never reaches the mutation service');

    $manager->set_v3_channel_policy(
        'quote-write-probe', '#test', mode => 'off', config => {});
    $handler->(T1102::CommandContext->new(channel => '#test'));
    $assert->is(scalar @{ $writes->{calls} }, 1,
        'off policy prevents plugin and write service execution');

    my $context = $manager->plugin('quote-write-probe')
        ->{metadata}{plugin_context};
    $assert->ok(!$context->can('database') && !$context->can('sql')
        && !$context->can('user_object'),
        'write capability exposes no database, SQL or mutable user object');
};
