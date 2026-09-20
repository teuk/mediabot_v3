# MB748 — quote-read adapters move reversibly and restore exact handlers.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

use Scalar::Util qw(refaddr);

{
    package T1088::Logger;
    sub new { bless { lines => [] }, shift }
    sub log { push @{ $_[0]{lines} }, $_[2]; 1 }
}

{
    package T1088::QuoteService;
    sub new { bless { calls => [] }, shift }
    sub count {
        my ($self, %args) = @_;
        push @{ $self->{calls} }, [count => { %args }];
        return { ok => 1, count => defined($args{author}) ? 2 : 7 };
    }
    sub top {
        my ($self, %args) = @_;
        push @{ $self->{calls} }, [top => { %args }];
        require Mediabot::Plugin::QuoteRecordV3;
        return { ok => 1, records => [
            Mediabot::Plugin::QuoteRecordV3->new(
                id => 3, text => 'Remember this', author => 'Alice',
                author_id => 8, created_at => '', hits => 5),
        ] };
    }
}

{
    package T1088::Bot;
    sub new {
        require Mediabot::CommandRegistry;
        bless {
            registry => Mediabot::CommandRegistry->new,
            logger => T1088::Logger->new,
        }, shift;
    }
    sub command_registry { $_[0]{registry} }
    sub registry { $_[0]{registry} }
}

{
    package T1088::Context;
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

    my $bot = T1088::Bot->new;
    my %original;
    my $legacy_calls = 0;
    for my $name (qw(q quote quotecount topquote halloffame)) {
        my $handler = sub { $legacy_calls++; 1 };
        $original{$name} = $handler;
        $bot->{registry}->register_command(
            name => $name, source => 'public', handler => $handler,
            category => 'core', metadata => {
                builtin => 1, dispatch => 'registry', syntax => $name,
                migration_fallback => 1,
            });
    }
    my $quotes = T1088::QuoteService->new;
    my $manager = Mediabot::PluginManager->new(
        bot => $bot, plugin_dir => 'plugins', v3_quote_service => $quotes);
    $manager->load_package_v3('quotes-v3', grants => [
        qw(data.quotes.read data.quotes.write irc.reply irc.notice)
    ]);

    my $mounted = $bot->{registry}->command_for('quotecount', 'public');
    $assert->is($mounted->{metadata}{migration}, 'legacy-public-fallback',
        'quote reads mount only through the explicit fallback bridge');
    my $ctx = T1088::Context->new(
        nick => 'Tangy', channel => '#development', command => 'quotecount',
        args => []);
    $mounted->{handler}->($ctx);
    $assert->is($legacy_calls, 1,
        'disabled package preserves the legacy quote counter');
    $assert->is(scalar @{ $quotes->{calls} }, 0,
        'disabled package performs no data read');

    $manager->set_v3_channel_policy('quotes-v3', '#development',
        mode => 'observe');
    $manager->enable('quotes-v3');
    $mounted->{handler}->($ctx);
    $assert->is($legacy_calls, 2,
        'observe keeps the historical output path visible');
    $assert->is(scalar @{ $quotes->{calls} }, 1,
        'observe executes one silent v3 parity read');
    $assert->is(scalar @{ $ctx->{replies} }, 0,
        'observe suppresses the v3 quote reply');

    $manager->set_v3_channel_policy('quotes-v3', '#development', mode => 'on');
    $mounted->{handler}->($ctx);
    $assert->is($legacy_calls, 2,
        'on makes v3 authoritative for the opted-in channel');
    $assert->is($ctx->{replies}[0], '#development: 7 quote(s) total',
        'on returns the migrated count result');

    my $top = $bot->{registry}->command_for('halloffame', 'public');
    my $top_ctx = T1088::Context->new(
        nick => 'Tangy', channel => '#development', command => 'halloffame',
        args => ['5']);
    $top->{handler}->($top_ctx);
    $assert->like($top_ctx->{replies}[1], qr/Remember this \(5 recalls\)/,
        'the alias uses the same approved ranking path');

    $manager->set_v3_channel_policy('quotes-v3', '#development', mode => 'off');
    $mounted->{handler}->($ctx);
    $assert->is($legacy_calls, 3,
        'off immediately restores visible legacy behavior');

    $manager->unregister_plugin('quotes-v3');
    for my $name (qw(quotecount topquote halloffame)) {
        my $restored = $bot->{registry}->command_for($name, 'public');
        $assert->is(refaddr($restored->{handler}), refaddr($original{$name}),
            "unload restores the exact $name handler reference");
        $assert->is($restored->{metadata}{dispatch}, 'registry',
            "unload restores $name dispatch metadata");
    }
};
