# MB745 — a v3 pilot may shadow one frozen adapter and restore it exactly.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

use Scalar::Util qw(refaddr);

{
    package T1076::Logger;
    sub new { bless { lines => [] }, shift }
    sub log { push @{ $_[0]{lines} }, $_[2]; 1 }
}

{
    package T1076::Scheduler;
    sub new { bless { tasks => {} }, shift }
    sub add { my ($s, %a) = @_; $s->{tasks}{$a{name}} = { %a }; $s }
    sub start { $_[0]{tasks}{$_[1]}{started} = 1; 1 }
    sub stop { $_[0]{tasks}{$_[1]}{started} = 0; 1 }
    sub remove { delete($_[0]{tasks}{$_[1]}) ? 1 : 0 }
}

{
    package T1076::Bot;
    sub new {
        require Mediabot::CommandRegistry;
        bless {
            registry => Mediabot::CommandRegistry->new,
            scheduler => T1076::Scheduler->new,
            logger => T1076::Logger->new,
            messages => [],
        }, shift;
    }
    sub command_registry { $_[0]{registry} }
    sub registry { $_[0]{registry} }
    sub plugin_channel_message { push @{ $_[0]{messages} }, [$_[1], $_[2]]; 1 }
}

{
    package T1076::Context;
    sub new { my ($c, %a) = @_; bless { %a, replies => [], notices => [] }, $c }
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

    my $bot = T1076::Bot->new;
    my %original;
    for my $name (qw(8ball abbrev choose flip morse roll)) {
        my $handler = sub { die "dispatcher-only $name" };
        $original{$name} = $handler;
        $bot->{registry}->register_command(
            name => $name, source => 'public', handler => $handler,
            category => 'builtin-adapter', metadata => {
                builtin => 1, dispatch => 'legacy-public', syntax => $name,
            });
    }

    my $manager = Mediabot::PluginManager->new(
        bot => $bot, plugin_dir => 'plugins');
    my $entry = $manager->load_package_v3('playful-v3', grants => [
        qw(irc.reply irc.notice irc.channel_message scheduler.jobs)
    ]);
    my $mounted = $bot->{registry}->command_for('abbrev', 'public');
    $assert->is($mounted->{metadata}{migration}, 'legacy-public-fallback',
        'pilot replaces only through the explicit migration bridge');

    my $legacy_calls = 0;
    my $ctx = T1076::Context->new(
        nick => 'Tangy', channel => '#development', command => 'abbrev',
        args => [qw(quiet little channel)]);
    $mounted->{handler}->($ctx, sub { $legacy_calls++; 1 });
    $assert->is($legacy_calls, 1,
        'disabled v3 package preserves the legacy command');

    $manager->set_v3_channel_policy('playful-v3', '#development',
        mode => 'observe');
    $manager->enable('playful-v3');
    $mounted->{handler}->($ctx, sub { $legacy_calls++; 1 });
    $assert->is($legacy_calls, 2,
        'observe executes a visible legacy fallback');
    $assert->is(scalar @{ $ctx->{replies} }, 0,
        'observe suppresses the v3 shadow reply');

    $manager->set_v3_channel_policy('playful-v3', '#development',
        mode => 'on');
    $mounted->{handler}->($ctx, sub { $legacy_calls++; 1 });
    $assert->is($legacy_calls, 2,
        'on makes the plugin authoritative for the pilot channel');
    $assert->is($ctx->{replies}[0], 'Tangy: QLC (3 word(s))',
        'on returns the migrated command result');

    $manager->unregister_plugin('playful-v3');
    my $restored = $bot->{registry}->command_for('abbrev', 'public');
    $assert->is(refaddr($restored->{handler}), refaddr($original{abbrev}),
        'unload restores the exact historical handler reference');
    $assert->is($restored->{metadata}{dispatch}, 'legacy-public',
        'unload restores historical dispatch metadata');
    $assert->ok(!$bot->{registry}->command_for('abbrev', 'public')->{plugin},
        'no plugin ownership remains after rollback');
};
