# MB763 — visible and quiet recall shadow, adopt and roll back exactly.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

use Scalar::Util qw(refaddr);

{
    package T1127::Logger;
    sub new { bless {}, shift }
    sub log { 1 }
}

{
    package T1127::Reads;
    sub new { bless { calls => [] }, shift }
    sub by_keyword {
        my ($self, %args) = @_;
        require Mediabot::Plugin::FactoidRecordV3;
        push @{ $self->{calls} }, { %args };
        return { ok => 1, record => undef }
            if $args{keyword} eq 'missing';
        return { ok => 1, record =>
            Mediabot::Plugin::FactoidRecordV3->new(
                id => 11, keyword => $args{keyword}, value => 'Lumos',
                author => 'Hermione', author_id => 2,
                created_at => '2026-09-22', updated_at => '2026-09-22',
                hits => 3) };
    }
    sub list { die 'list not expected' }
    sub top { die 'top not expected' }
}

{
    package T1127::Writes;
    sub new { bless { calls => [] }, shift }
    sub recall {
        my ($self, %args) = @_;
        push @{ $self->{calls} }, { %args };
        return { ok => 1, status => 'recalled', keyword => $args{keyword} };
    }
    sub upsert { die 'upsert not expected' }
    sub delete { die 'delete not expected' }
}

{
    package T1127::Bot;
    sub new {
        require Mediabot::CommandRegistry;
        bless { registry => Mediabot::CommandRegistry->new,
            logger => T1127::Logger->new }, shift;
    }
    sub command_registry { $_[0]{registry} }
    sub registry { $_[0]{registry} }
    sub getUserChannelLevel { 0 }
}

{
    package T1127::Context;
    sub new {
        my ($class, %args) = @_;
        bless { args => $args{args} || [], replies => [], notices => [] }, $class;
    }
    sub nick { 'Luna' }
    sub channel { '#test' }
    sub command { 'whatis' }
    sub args { $_[0]{args} }
    sub is_private { 0 }
    sub user { undef }
    sub reply { push @{ $_[0]{replies} }, $_[1]; 1 }
    sub reply_private { push @{ $_[0]{notices} }, $_[1]; 1 }
}

return sub {
    my ($assert) = @_;
    require Mediabot::PluginManager;

    my $bot = T1127::Bot->new;
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

    my $reads = T1127::Reads->new;
    my $writes = T1127::Writes->new;
    my $manager = Mediabot::PluginManager->new(
        bot => $bot, plugin_dir => 'plugins',
        v3_factoid_service => $reads,
        v3_factoid_write_service => $writes);
    $manager->load_package_v3('factoids-v3', grants => [
        qw(data.factoids.read data.factoids.write irc.reply irc.notice)
    ]);

    my $handler = $bot->{registry}->handler_for('whatis', 'public');
    my $visible = T1127::Context->new(args => ['spell']);
    $handler->($visible);
    $assert->is($legacy_calls{whatis}, 1,
        'disabled package preserves historical whatis');
    $assert->is(scalar @{ $reads->{calls} }, 0,
        'disabled package performs no recall read');

    $manager->set_v3_channel_policy(
        'factoids-v3', '#test', mode => 'observe');
    $manager->enable('factoids-v3');
    $handler->($visible);
    $assert->is($legacy_calls{whatis}, 2,
        'observe invokes the saved historical recall exactly once');
    $assert->is(scalar @{ $reads->{calls} }, 1,
        'observe permits one side-effect-free v3 lookup');
    $assert->is(scalar @{ $writes->{calls} }, 0,
        'observe suppresses v3 recall before the write service');
    $assert->is(scalar @{ $visible->{replies} }, 0,
        'observe suppresses the v3 channel reply');

    $manager->set_v3_channel_policy('factoids-v3', '#test', mode => 'on');
    $handler->($visible);
    $assert->is($legacy_calls{whatis}, 2,
        'on suppresses the historical recall path');
    $assert->is(scalar @{ $writes->{calls} }, 1,
        'on performs exactly one core-owned recall increment');
    $assert->is($visible->{replies}[-1], 'spell: Lumos',
        'on emits exactly one historical-format channel reply');

    my $quiet = T1127::Context->new(args => ['__quiet__', 'missing']);
    $handler->($quiet);
    $assert->is(scalar @{ $quiet->{replies} }, 0,
        'quiet missing shortcut emits no reply');
    $assert->is(scalar @{ $quiet->{notices} }, 0,
        'quiet missing shortcut emits no notice');
    $assert->is(scalar @{ $writes->{calls} }, 1,
        'quiet missing shortcut performs no recall mutation');

    $manager->set_v3_channel_policy('factoids-v3', '#test', mode => 'off');
    $handler->($visible);
    $assert->is($legacy_calls{whatis}, 3,
        'off immediately restores historical whatis behavior');

    $manager->unregister_plugin('factoids-v3');
    for my $name (qw(factoid factoids learn forget whatis)) {
        my $restored = $bot->{registry}->command_for($name, 'public');
        $assert->is(refaddr($restored->{handler}), refaddr($original{$name}),
            "unload restores the exact $name handler reference");
    }
};
