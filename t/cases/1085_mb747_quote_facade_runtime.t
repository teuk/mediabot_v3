# MB747 — capability and channel policy wiring for approved quote reads.

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
    package T1085::QuoteService;
    sub new { bless { calls => [] }, shift }
    sub by_id {
        my ($self, %args) = @_;
        push @{ $self->{calls} }, { %args };
        return { ok => 1, record => undef };
    }
}

{
    package T1085::Log;
    sub new { bless { lines => [] }, shift }
    sub log { push @{ $_[0]{lines} }, $_[2]; 1 }
}

{
    package T1085::Bot;
    sub new {
        require Mediabot::CommandRegistry;
        bless { registry => Mediabot::CommandRegistry->new,
                logger => T1085::Log->new }, shift;
    }
    sub command_registry { $_[0]{registry} }
    sub registry { $_[0]{registry} }
}

{
    package T1085::CommandContext;
    sub new { my ($class, %args) = @_; bless { %args }, $class }
    sub nick { 'Tangy' }
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
    my $package = "$root/quote-probe";
    make_path("$package/lib");
    open my $mf, '>:encoding(UTF-8)', "$package/plugin.json" or die $!;
    print {$mf} JSON::PP->new->canonical->encode({
        api => 3, name => 'quote-probe', version => '1.0.0',
        description => 'Quote facade test package.',
        runtime => { kind => 'perl', entrypoint => 'lib/QuoteProbe.pm',
                     class => 'T1085::QuoteProbe' },
        compatibility => {}, activation => { default => 'off' },
        capabilities => ['data.quotes.read'],
        commands => { quoteprobe => {
            source => 'public', help => 'Probe quote data.', level => 0,
            handler => 'probe', aliases => [],
        } },
        events => [], jobs => {}, config_schema => {},
    });
    close $mf;
    open my $pf, '>:encoding(UTF-8)', "$package/lib/QuoteProbe.pm" or die $!;
    print {$pf} <<'PLUGIN';
package T1085::QuoteProbe;
sub new { my ($class, %args) = @_; bless { %args }, $class }
sub probe {
    my ($self, $context, $invocation) = @_;
    return $context->quote_by_id($invocation, 7);
}
1;
PLUGIN
    close $pf;

    my $bot = T1085::Bot->new;
    my $quotes = T1085::QuoteService->new;
    my $manager = Mediabot::PluginManager->new(
        bot => $bot, plugin_dir => $root, v3_quote_service => $quotes);
    $manager->load_package_v3('quote-probe', grants => ['data.quotes.read']);
    $manager->set_v3_channel_policy(
        'quote-probe', '#Test', mode => 'observe', config => {});
    $manager->enable('quote-probe');

    my $handler = $bot->{registry}->handler_for('quoteprobe', 'public');
    $handler->(T1085::CommandContext->new(channel => '#test'));
    $assert->is(scalar @{ $quotes->{calls} }, 1,
        'observe may execute a read-only approved data call');
    $assert->is($quotes->{calls}[0]{channel}, '#Test',
        'core policy supplies the channel instead of plugin arguments');
    $assert->is($quotes->{calls}[0]{id}, 7,
        'only approved method arguments cross the facade');

    $manager->set_v3_channel_policy(
        'quote-probe', '#test', mode => 'off', config => {});
    $handler->(T1085::CommandContext->new(channel => '#test'));
    $assert->is(scalar @{ $quotes->{calls} }, 1,
        'off prevents the plugin and data service from running');

    my $context = $manager->plugin('quote-probe')->{metadata}{plugin_context};
    $assert->ok(!$context->can('database') && !$context->can('sql'),
        'quote capability adds no generic database or SQL escape hatch');
};
