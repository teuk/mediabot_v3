# MB754 — mixed quote commands use only detached read/write facades.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..", "$Bin/../../plugins/quotes-v3/lib";
}

return sub {
    my ($assert) = @_;
    require Mediabot::PluginContext;
    require Mediabot::Plugin::InvocationV3;
    require Mediabot::Plugin::PrincipalV3;
    require Mediabot::Plugin::QuoteRecordV3;
    require Quotes;

    my (@reads, @writes, @replies, @notices);
    my $authority = Mediabot::PluginContext->new(
        plugin => 'quotes-v3',
        requested => [qw(data.quotes.read data.quotes.write irc.reply irc.notice)],
        granted => [qw(data.quotes.read data.quotes.write irc.reply irc.notice)],
        quotes_read_sink => sub {
            my ($invocation, $operation, $args) = @_;
            push @reads, [$operation, { %$args }];
            return { ok => 1, record =>
                Mediabot::Plugin::QuoteRecordV3->new(
                    id => 41, text => 'Alohomora', author => 'Luna',
                    author_id => 7, created_at => '2026-09-20 20:00:00', hits => 3) }
                if $operation eq 'by_id';
            return { ok => 1, count => 4 } if $operation eq 'count';
            die "unexpected read $operation";
        },
        quotes_write_sink => sub {
            my ($invocation, $operation, $args) = @_;
            push @writes, [$operation, { %$args }];
            return { ok => 1, status => 'created', id => 91 }
                if $operation eq 'add';
            return { ok => 1, status => 'deleted', id => $args->{id} }
                if $operation eq 'delete';
            return { ok => 1, status => 'recalled', id => $args->{id} }
                if $operation eq 'recall';
            die "unexpected write $operation";
        },
    );
    my $principal = Mediabot::Plugin::PrincipalV3->new(
        authenticated => 1, user_id => 7, account => 'Luna',
        global_level => 'user', channel_level => 0);
    my $invoke = sub {
        my ($command, $args) = @_;
        return Mediabot::Plugin::InvocationV3->new(
            nick => 'Luna_', channel => '#development', command => $command,
            args => $args, source => 'public', is_private => 0,
            authority => $authority, activation => 'on', config => {},
            principal => $principal,
            reply_sink => sub { push @replies, $_[0]; 1 },
            notice_sink => sub { push @notices, $_[0]; 1 },
        );
    };
    my $plugin = Mediabot::Plugin::Quotes->new(context => $authority);

    $plugin->command_q($authority,
        $invoke->('q', ['add', 'Alohomora']));
    $assert->is($writes[-1][0], 'add',
        'q add crosses only the approved add operation');
    $assert->is($writes[-1][1]{text}, 'Alohomora',
        'q add passes only bounded quote text');
    $assert->is($replies[-1], "(Luna) done. (id: \x0291\x02)",
        'created rendering preserves account attribution and bold id');

    $plugin->command_q($authority,
        $invoke->('q', ['view', '41']));
    $assert->is($reads[-1][0], 'by_id',
        'q view crosses the detached read facade');
    $assert->is($writes[-1][0], 'recall',
        'a visible q view records one authorized recall');
    $assert->is($writes[-1][1]{id}, 41,
        'recall is bound to the returned quote id');
    $assert->is($replies[-1], "(Luna) [id: \x0241\x02] Alohomora",
        'q view preserves the historical public rendering');

    $plugin->command_q($authority,
        $invoke->('q', ['del', '41']));
    $assert->is($writes[-1][0], 'delete',
        'q del crosses only the approved delete operation');
    $assert->is($replies[-1], "(Luna) deleted. (id: \x0241\x02)",
        'delete success preserves the historical public rendering');

    $plugin->command_quote($authority,
        $invoke->('quote', ['count']));
    $assert->is($reads[-1][0], 'count',
        'quote count remains a bounded read');
    $assert->is($replies[-1], '#development: 4 quote(s) total',
        'quote count without an author does not count the literal word count');

    $assert->ok(!grep { /(?:DBI|prepare|execute)/ } @replies, @notices,
        'the command surface leaks no database primitive');
};
