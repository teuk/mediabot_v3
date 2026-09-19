# MB746 — direct proof-plugin parsing, bounds, errors and storage transaction.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..", "$Bin/../../plugins/short-content-v3/lib";
}

return sub {
    my ($assert) = @_;
    require Mediabot::Plugin::ManifestV3;
    require Mediabot::PluginContext;
    require Mediabot::Plugin::InvocationV3;
    require Mediabot::Plugin::HTTPResponseV3;
    require ShortContent;

    my $manifest = Mediabot::Plugin::ManifestV3->load_file(
        'plugins/short-content-v3/plugin.json',
        expected_name => 'short-content-v3');
    $assert->is($manifest->{activation}{default}, 'off',
        'proof package is inert by manifest contract');
    $assert->is(join(',', @{ $manifest->{capabilities} }),
        'http.fetch,irc.reply,storage.kv',
        'proof package requests only HTTP, reply and repository facades');

    my (@replies, @requests, @commits);
    my $http_callback;
    my $context = Mediabot::PluginContext->new(
        plugin => 'short-content-v3',
        requested => [qw(http.fetch irc.reply storage.kv)],
        granted => [qw(http.fetch irc.reply storage.kv)],
        http_fetch_sink => sub {
            my ($invocation, $request, $callback) = @_;
            push @requests, $request;
            $http_callback = $callback;
            return { accepted => 1 };
        },
        storage_snapshot_sink => sub {
            return { revision => 4, values => { served => '9' } };
        },
        storage_commit_sink => sub {
            my ($invocation, %args) = @_;
            push @commits, \%args;
            return { ok => 1, revision => 5 };
        },
    );
    my $invocation = Mediabot::Plugin::InvocationV3->new(
        nick => 'Tangy', channel => '#test', command => 'short', args => [],
        source => 'public', is_private => 0, authority => $context,
        activation => 'on',
        config => {
            endpoint => 'https://example.net/item.json',
            json_path => 'payload.text', prefix => '✨ ', language => 'en',
            cache_ttl_seconds => 120, max_chars => 80,
        },
        reply_sink => sub { push @replies, $_[0]; 1 },
        notice_sink => sub { 1 },
    );
    my $plugin = Mediabot::Plugin::ShortContent->new(context => $context);
    $plugin->command_short($context, $invocation);
    $assert->is($requests[-1]{cache_ttl_seconds}, 120,
        'typed channel TTL reaches the shared service request');
    $http_callback->(Mediabot::Plugin::HTTPResponseV3->new(
        ok => 1, status => 200, url => $requests[-1]{url},
        body => '{"payload":{"text":"A tiny useful message."}}',
    ));
    $assert->is($replies[-1], '✨ A tiny useful message.',
        'configured JSON path yields one short response');
    $assert->is($commits[-1]{expected_revision}, 4,
        'plugin commits against the snapshot revision');
    $assert->is($commits[-1]{changes}{served}, '10',
        'successful item increments repository count atomically');

    $plugin->command_short($context, $invocation);
    $http_callback->(Mediabot::Plugin::HTTPResponseV3->new(
        ok => 1, status => 200, url => $requests[-1]{url},
        body => '{"payload":{"other":"missing"}}',
    ));
    $assert->like($replies[-1], qr/not usable/,
        'missing configured field returns a bounded neutral error');

    $plugin->command_short($context, $invocation);
    $http_callback->(Mediabot::Plugin::HTTPResponseV3->new(
        ok => 0, status => 503, url => $requests[-1]{url}, error => 'http_503',
    ));
    $assert->like($replies[-1], qr/unavailable/,
        'HTTP failure does not expose transport details to IRC');
};
