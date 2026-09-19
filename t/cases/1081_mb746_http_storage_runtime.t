# MB746 — runtime wiring, observe suppression, on persistence and disable revocation.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

use File::Temp qw(tempdir);

{
    package T1081::HTTP;
    sub new { bless { pending => [], cancelled => 0 }, shift }
    sub fetch {
        my ($self, $plugin, $request, $callback) = @_;
        push @{ $self->{pending} }, { plugin => $plugin, request => $request, callback => $callback };
        return { accepted => 1, request_id => scalar @{ $self->{pending} } };
    }
    sub complete {
        my ($self, $response) = @_;
        my $pending = shift @{ $self->{pending} } or return;
        return $pending->{callback}->($response);
    }
    sub cancel_plugin { $_[0]{cancelled}++; scalar @{ $_[0]{pending} } }
}

{
    package T1081::Conf;
    sub new { my ($class, $dir) = @_; bless { dir => $dir }, $class }
    sub get { $_[1] eq 'plugins.DATA_DIR' ? $_[0]{dir} : undef }
}

{
    package T1081::Log;
    sub new { bless { lines => [] }, shift }
    sub log { push @{ $_[0]{lines} }, $_[2]; 1 }
}

{
    package T1081::Bot;
    sub new {
        my ($class, $dir) = @_;
        require Mediabot::CommandRegistry;
        return bless {
            registry => Mediabot::CommandRegistry->new,
            conf => T1081::Conf->new($dir),
            logger => T1081::Log->new,
        }, $class;
    }
    sub command_registry { $_[0]{registry} }
    sub registry { $_[0]{registry} }
}

{
    package T1081::CommandContext;
    sub new { my ($class, %args) = @_; bless { replies => [], %args }, $class }
    sub nick { $_[0]{nick} }
    sub channel { $_[0]{channel} }
    sub command { 'short' }
    sub args { [] }
    sub is_private { 0 }
    sub reply { push @{ $_[0]{replies} }, $_[1]; 1 }
    sub reply_private { 1 }
}

return sub {
    my ($assert) = @_;
    require Mediabot::PluginManager;
    require Mediabot::Plugin::HTTPResponseV3;

    my $dir = tempdir(CLEANUP => 1);
    my $http = T1081::HTTP->new;
    my $bot = T1081::Bot->new($dir);
    my $manager = Mediabot::PluginManager->new(
        bot => $bot, plugin_dir => 'plugins', v3_http_service => $http);
    my $entry = $manager->load_package_v3('short-content-v3', grants => [
        qw(http.fetch irc.reply storage.kv)
    ]);
    $assert->is($manager->is_enabled('short-content-v3'), 0,
        'proof package loads disabled');
    $manager->enable('short-content-v3');
    my $handler = $bot->{registry}->handler_for('short', 'public');
    my $ctx = T1081::CommandContext->new(
        nick => 'Tangy', channel => '#test');

    my %config = (
        endpoint => 'https://example.net/item.json',
        json_path => 'slip.advice', prefix => '✨ ', language => 'fr',
        cache_ttl_seconds => 300, max_chars => 280,
    );
    $manager->set_v3_channel_policy('short-content-v3', '#test',
        mode => 'observe', config => \%config);
    $handler->($ctx);
    $assert->is($http->{pending}[0]{request}{url}, $config{endpoint},
        'plugin sends endpoint only through the shared HTTP service');
    $http->complete(Mediabot::Plugin::HTTPResponseV3->new(
        ok => 1, status => 200, url => $config{endpoint},
        content_type => 'application/json',
        body => '{"slip":{"advice":"Observe first."}}',
    ));
    $assert->is(scalar @{ $ctx->{replies} }, 0,
        'observe executes callback but suppresses IRC output');
    $assert->ok(!-e "$dir/v3-short-content-v3.json",
        'observe suppresses repository writes');

    $manager->set_v3_channel_policy('short-content-v3', '#test',
        mode => 'on', config => \%config);
    $handler->($ctx);
    $http->complete(Mediabot::Plugin::HTTPResponseV3->new(
        ok => 1, status => 200, url => $config{endpoint},
        content_type => 'application/json',
        body => '{"slip":{"advice":"On is deliberate."}}',
    ));
    $assert->is($ctx->{replies}[-1], '✨ On is deliberate.',
        'on emits one bounded parsed line');
    $assert->ok(-f "$dir/v3-short-content-v3.json",
        'on persists through the namespaced core repository');

    $handler->($ctx);
    $manager->disable('short-content-v3');
    $http->complete(Mediabot::Plugin::HTTPResponseV3->new(
        ok => 1, status => 200, url => $config{endpoint},
        content_type => 'application/json', body => '{"slip":{"advice":"late"}}',
    ));
    $assert->is($ctx->{replies}[-1], '✨ On is deliberate.',
        'disable revokes an already pending completion');
    $assert->ok($http->{cancelled} >= 1,
        'disable requests cancellation from the shared service');

    $manager->unregister_plugin('short-content-v3');
    $assert->is($bot->{registry}->has_command('short', 'public'), 0,
        'unload removes the proof command completely');
};
