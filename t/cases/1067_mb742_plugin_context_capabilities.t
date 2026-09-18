# MB742 — bounded invocation and requested-intersect-granted capabilities.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

return sub {
    my ($assert) = @_;

    require Mediabot::PluginContext;
    require Mediabot::Plugin::InvocationV3;

    my (@replies, @notices);
    my @source_args = ('one', 'two');
    my $context = Mediabot::PluginContext->new(
        plugin    => 'hello-v3',
        requested => [qw(irc.reply irc.notice)],
        granted   => [qw(irc.reply http.fetch)],
    );
    my $invocation = Mediabot::Plugin::InvocationV3->new(
        nick        => "Tangy\r\n",
        channel     => '#i/o',
        command     => 'v3hello',
        args        => \@source_args,
        source      => 'public',
        is_private  => 0,
        authority   => $context,
        reply_sink  => sub { push @replies, $_[0]; 1 },
        notice_sink => sub { push @notices, $_[0]; 1 },
    );

    $assert->is(join(',', $context->requested_capabilities),
        'irc.notice,irc.reply', 'requested capabilities are deterministic');
    $assert->is(join(',', $context->effective_capabilities),
        'irc.reply', 'effective capability is the strict intersection');
    $assert->is($context->has_capability('http.fetch'), 0,
        'an unrequested grant never becomes effective');
    $assert->is($invocation->nick, 'Tangy ',
        'invocation sanitizes line breaks in copied identity');

    $context->reply($invocation, "  hello\nworld  ");
    $assert->is($replies[0], 'hello world',
        'reply crosses the bounded capability-checked sink');
    $assert->is(scalar @notices, 0, 'reply does not cross notice sink');

    my $ok = eval { $context->notice($invocation, 'secret'); 1 };
    $assert->like($@ // '', qr/capability 'irc\.notice' was not granted/,
        'missing capability fails closed');
    $assert->is(scalar @notices, 0, 'failed notice emits nothing');

    push @source_args, 'late';
    my $copied = $invocation->args;
    push @$copied, 'local';
    $assert->is(join(',', @{ $invocation->args }), 'one,two',
        'invocation arguments are copied on input and output');
    $assert->ok(!$context->can('bot') && !$context->can('database')
            && !$invocation->can('message'),
        'v3 surfaces expose no bot, database or raw message accessor');

    $ok = eval { $context->reply($invocation, 'x' x 401); 1 };
    $assert->like($@ // '', qr/exceeds 400 bytes/,
        'output remains bounded before it reaches IRC');
};
