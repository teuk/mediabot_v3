#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use FindBin qw($Bin);
use lib "$Bin/../..";
use Test::More;

use Mediabot::ScriptActionRunner;

{
    package MB270::TargetContext;
    sub new { my $class = shift; bless { @_ }, $class }
    sub channel { return $_[0]->{channel} }
    sub target { return $_[0]->{target} }
    sub reply_target { return $_[0]->{reply_target} }
}

my $runner = Mediabot::ScriptActionRunner->new;

sub first_error_text {
    my ($plan) = @_;
    my $err = $plan->{errors}[0];
    return ref($err) eq 'HASH' ? ($err->{error} || '') : ($err || '');
}

sub plan_reply_without_target {
    my ($ctx) = @_;
    return $runner->plan_actions([
        { type => 'reply', text => 'hello from context' },
    ], $ctx);
}

my $hash_target_fallback = plan_reply_without_target({
    channel => [],
    target  => '#fallback',
});
ok($hash_target_fallback->{ok}, 'hash context ignores non-scalar channel and uses scalar target fallback');
is($hash_target_fallback->{planned}[0]{target}, '#fallback', 'hash target fallback is preserved');

my $hash_channel_preferred = plan_reply_without_target({
    channel => '#channel',
    target  => '#fallback',
});
ok($hash_channel_preferred->{ok}, 'hash context keeps scalar channel as preferred default target');
is($hash_channel_preferred->{planned}[0]{target}, '#channel', 'hash scalar channel stays preferred over target');

my $hash_no_scalar = plan_reply_without_target({
    channel => { bad => 1 },
    target  => [ '#bad' ],
});
ok(!$hash_no_scalar->{ok}, 'hash context with only non-scalar targets is rejected');
like(first_error_text($hash_no_scalar), qr/missing target/, 'non-scalar context targets do not become ARRAY/HASH target errors');
unlike(first_error_text($hash_no_scalar), qr/ARRAY|HASH/, 'non-scalar context target diagnostics are not stringified');

my $object_target_fallback = plan_reply_without_target(
    MB270::TargetContext->new(
        channel => [ '#bad' ],
        target  => '#object-target',
    )
);
ok($object_target_fallback->{ok}, 'object context ignores ref-returning channel method and uses target method');
is($object_target_fallback->{planned}[0]{target}, '#object-target', 'object target method fallback is preserved');

my $object_reply_target_fallback = plan_reply_without_target(
    MB270::TargetContext->new(
        channel      => { bad => 1 },
        target       => [],
        reply_target => 'Teuk',
    )
);
ok($object_reply_target_fallback->{ok}, 'object context can fall back to scalar reply_target method');
is($object_reply_target_fallback->{planned}[0]{target}, 'Teuk', 'reply_target method fallback is preserved');

# mb524: a nick target is never channel-scoped, so it still demonstrates that an
# explicit action target is preserved over a (malformed) context default.
my $explicit_target_wins = $runner->plan_actions([
    { type => 'reply', text => 'explicit target', target => 'ExplicitNick' },
], { channel => [], target => '#fallback' });
ok($explicit_target_wins->{ok}, 'explicit action target still wins over malformed context');
is($explicit_target_wins->{planned}[0]{target}, 'ExplicitNick', 'explicit action target is unchanged');

my $notice_default = $runner->plan_actions([
    { type => 'notice', text => 'notice through context' },
], { channel => [], target => 'Teuk' });
ok($notice_default->{ok}, 'notice action also uses scalar context fallback');
is($notice_default->{planned}[0]{target}, 'Teuk', 'notice target fallback is preserved');

my $source = do {
    open my $fh, '<', 'Mediabot/ScriptActionRunner.pm' or die $!;
    local $/;
    <$fh>;
};
like($source, qr/mb270-B1/, 'ScriptActionRunner source contains mb270 context-target marker');
unlike($source, qr/`[^`]+`|\bqx\s*(?:\/|\(|\{)|\bsystem\s*(?:\(| )/, 'mb270 context target guard does not introduce shell execution');

done_testing();
