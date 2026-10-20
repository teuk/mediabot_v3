use strict;
use warnings;
use lib '.', 't/lib';
use Test::More;
use File::Temp qw(tempdir);
use Mediabot::PluginManager;
use Mediabot::Plugin::HTTPServiceV3;

# Reuse only the existing offline bot/command-context fixture. The HTTP service,
# manager, invocation policy and short-content package below are production code.
my $fixture = do './t/cases/1081_mb746_http_storage_runtime.t';
ok(ref($fixture) eq 'CODE', 'existing offline plugin fixture loads');
my $dir = tempdir(CLEANUP => 1);
my ($calls, $now) = (0, 100);
my $service = Mediabot::Plugin::HTTPServiceV3->new(
    clock => sub { $now }, resolver => sub { ['93.184.216.34'] },
    requester => sub {
        $calls++; return {status => 200, headers => {'content-type' => 'application/json'},
            content => '{"text":"message'.$calls.'"}'};
    },
    worker_factory => sub {
        my %args = @_;
        $args{on_done}->({ok => 1, value => $args{child}->()});
        return bless {}, 'MB861PluginWorker';
    },
);
my $bot = T1081::Bot->new($dir);
my $manager = Mediabot::PluginManager->new(bot => $bot, plugin_dir => 'plugins', v3_http_service => $service);
$manager->load_package_v3('short-content-v3', grants => [qw(http.fetch irc.reply storage.kv)]);
$manager->enable('short-content-v3');
my $handler = $bot->{registry}->handler_for('short', 'public');
my %config = (endpoint => 'https://example.net/item.json', json_path => 'text', language => 'en', prefix => '', max_chars => 280);
my $cached = T1081::CommandContext->new(nick => 'alice', channel => '#test');
my $fresh = T1081::CommandContext->new(nick => 'bob', channel => '#i/o');
$manager->set_v3_channel_policy('short-content-v3', '#test', mode => 'on', config => {%config, cache_ttl_seconds => 60});
$manager->set_v3_channel_policy('short-content-v3', '#i/o', mode => 'on', config => {%config, cache_ttl_seconds => 0});
$handler->($cached); $handler->($cached);
is_deeply($cached->{replies}, ['message1', 'message1'], 'cached channel retains its own reusable response');
is($calls, 1, 'positive channel policy starts only the first transport request');
$handler->($fresh); $handler->($fresh);
is_deeply($fresh->{replies}, ['message2', 'message3'], 'zero-TTL channel receives fresh content for each invocation');
is($calls, 3, 'zero-TTL channel does not inherit the other channel cache');
$handler->($cached);
is($cached->{replies}[-1], 'message1', 'uncached invocations preserve the cached channel policy');
is($calls, 3, 'cached channel still avoids an extra outbound request');

# Apply an ordinary policy edit on the already-warmed channel.
$manager->set_v3_channel_policy('short-content-v3', '#test', mode => 'on', config => {%config, cache_ttl_seconds => 0});
$handler->($cached);
is($cached->{replies}[-1], 'message4', 'changing a warm channel policy to zero takes effect immediately');
is($calls, 4, 'policy edit obtains a new response rather than a stale cached result');
$manager->set_v3_channel_policy('short-content-v3', '#test', mode => 'observe', config => {%config, cache_ttl_seconds => 0});
my $before = scalar @{$cached->{replies}};
$handler->($cached);
is($calls, 5, 'observe mode still exercises the uncached fetch and parse path');
is(scalar @{$cached->{replies}}, $before, 'observe mode still suppresses public delivery');
$manager->set_v3_channel_policy('short-content-v3', '#test', mode => 'off', config => {%config, cache_ttl_seconds => 0});
$handler->($cached);
is($calls, 5, 'off policy blocks HTTP admission');
$manager->disable('short-content-v3');
$handler->($fresh);
is($calls, 5, 'disable continues to block uncached work');
$manager->unregister_plugin('short-content-v3');
ok(!$bot->{registry}->has_command('short', 'public'), 'normal unload removes the command');
done_testing;
