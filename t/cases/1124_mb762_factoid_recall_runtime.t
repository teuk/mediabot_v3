# MB762 — runtime provenance and policy gate the recall-counter authority.

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
    package T1124::Writes;
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
    package T1124::User;
    sub new { bless {}, shift }
    sub is_authenticated { 1 }
    sub id { 12 }
    sub nickname { 'Hermione' }
    sub has_level { $_[1] eq 'User' ? 1 : 0 }
}

{
    package T1124::Logger;
    sub new { bless {}, shift }
    sub log { 1 }
}

{
    package T1124::Bot;
    sub new {
        require Mediabot::CommandRegistry;
        bless {
            registry => Mediabot::CommandRegistry->new,
            logger => T1124::Logger->new,
        }, shift;
    }
    sub command_registry { $_[0]{registry} }
    sub registry { $_[0]{registry} }
    sub getUserChannelLevel { 0 }
}

{
    package T1124::Context;
    sub new { bless {}, shift }
    sub nick { 'Hermione_' }
    sub channel { '#library' }
    sub args { ['spell'] }
    sub is_private { 0 }
    sub reply { 1 }
    sub reply_private { 1 }
    sub user { T1124::User->new }
    sub message { bless {}, 'T1124::Message' }
}

return sub {
    my ($assert) = @_;
    require Mediabot::PluginManager;

    my $root = tempdir(CLEANUP => 1);
    my $package = "$root/factoid-recall-probe";
    make_path("$package/lib");
    open my $mf, '>:encoding(UTF-8)', "$package/plugin.json" or die $!;
    print {$mf} JSON::PP->new->canonical->encode({
        api => 3, name => 'factoid-recall-probe', version => '1.0.0',
        description => 'Factoid recall authority probe.',
        runtime => { kind => 'perl', entrypoint => 'lib/RecallProbe.pm',
                     class => 'T1124::RecallProbe' },
        compatibility => {}, activation => { default => 'off' },
        capabilities => ['data.factoids.write'],
        commands => { recallprobe => {
            source => 'public', help => 'Probe recall mutation.', level => 0,
            handler => 'probe', aliases => [],
        } },
        events => [], jobs => {}, config_schema => {},
    });
    close $mf;
    open my $pf, '>:encoding(UTF-8)', "$package/lib/RecallProbe.pm" or die $!;
    print {$pf} <<'PLUGIN';
package T1124::RecallProbe;
sub new { my ($class, %args) = @_; bless { %args }, $class }
sub probe {
    my ($self, $context, $invocation) = @_;
    return $context->factoid_recall($invocation, $invocation->args->[0]);
}
1;
PLUGIN
    close $pf;

    my $bot = T1124::Bot->new;
    my $writes = T1124::Writes->new;
    my $manager = Mediabot::PluginManager->new(
        bot => $bot, plugin_dir => $root,
        v3_factoid_write_service => $writes);
    $manager->load_package_v3(
        'factoid-recall-probe', grants => ['data.factoids.write']);
    $manager->set_v3_channel_policy(
        'factoid-recall-probe', '#library', mode => 'observe');
    $manager->enable('factoid-recall-probe');

    my $handler = $bot->{registry}->handler_for('recallprobe', 'public');
    $handler->(T1124::Context->new);
    $assert->is(scalar @{ $writes->{calls} }, 0,
        'observe suppresses recall before the mutation service');

    $manager->set_v3_channel_policy(
        'factoid-recall-probe', '#library', mode => 'on');
    $handler->(T1124::Context->new);
    $assert->is(scalar @{ $writes->{calls} }, 1,
        'on permits exactly one approved recall mutation');
    $assert->is($writes->{calls}[0]{channel}, '#library',
        'runtime policy supplies the recall channel');
    $assert->is($writes->{calls}[0]{keyword}, 'spell',
        'plugin supplies only the bounded keyword');
    $assert->is($writes->{calls}[0]{principal}->user_id, 12,
        'runtime still supplies detached principal provenance');

    require Mediabot::Plugin::InvocationV3;
    require Mediabot::Plugin::PrincipalV3;
    my $context = $manager->plugin('factoid-recall-probe')
        ->{metadata}{plugin_context};
    my $forged = Mediabot::Plugin::InvocationV3->new(
        nick => 'forged', channel => '#library', command => 'recallprobe',
        args => ['spell'], source => 'public', authority => $context,
        activation => 'on',
        principal => Mediabot::Plugin::PrincipalV3->anonymous,
        reply_sink => sub { 1 }, notice_sink => sub { 1 },
    );
    eval { $context->factoid_recall($forged, 'spell') };
    $assert->like($@ // '', qr/untrusted factoid write invocation/,
        'plugin-created invocation cannot forge recall authority');
    $assert->is(scalar @{ $writes->{calls} }, 1,
        'forged recall never reaches the service');

    $manager->set_v3_channel_policy(
        'factoid-recall-probe', '#library', mode => 'off');
    $handler->(T1124::Context->new);
    $assert->is(scalar @{ $writes->{calls} }, 1,
        'off prevents plugin and recall-service execution');
};
