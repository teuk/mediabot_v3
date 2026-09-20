# MB748 — first-party quote reads preserve their bounded public rendering.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..", "$Bin/../../plugins/quotes-v3/lib";
}

use Encode qw(encode);

return sub {
    my ($assert) = @_;
    require Mediabot::PluginContext;
    require Mediabot::Plugin::InvocationV3;
    require Mediabot::Plugin::QuoteRecordV3;
    require Quotes;

    my (@calls, @replies, @notices);
    my $mode = 'normal';
    my $authority = Mediabot::PluginContext->new(
        plugin => 'quotes-v3',
        requested => [qw(data.quotes.read irc.reply irc.notice)],
        granted => [qw(data.quotes.read irc.reply irc.notice)],
        quotes_read_sink => sub {
            my ($invocation, $operation, $args) = @_;
            push @calls, [$operation, { %$args }];
            return { ok => 0, error => 'unavailable' }
                if $mode eq 'unavailable';
            return { ok => 1, records => [] }
                if $mode eq 'empty' && $operation eq 'top';
            return { ok => 1, count => defined($args->{author}) ? 2 : 7 }
                if $operation eq 'count';
            return { ok => 1, records => [
                Mediabot::Plugin::QuoteRecordV3->new(
                    id => 9, text => 'A memorable line', author => 'Alice',
                    author_id => 12, created_at => '2026-09-20 10:00:00',
                    hits => 1),
                Mediabot::Plugin::QuoteRecordV3->new(
                    id => 4, text => ('é' x 180), author => 'Bob',
                    author_id => 13, created_at => '2026-09-20 09:00:00',
                    hits => 8),
            ] } if $operation eq 'top';
            die "unexpected quote operation $operation";
        },
    );
    my $plugin = Mediabot::Plugin::Quotes->new(context => $authority);
    my $invoke = sub {
        my ($command, $args) = @_;
        return Mediabot::Plugin::InvocationV3->new(
            nick => 'Tangy', channel => '#development', command => $command,
            args => $args, source => 'public', is_private => 0,
            authority => $authority, activation => 'on', config => {},
            reply_sink => sub { push @replies, $_[0]; 1 },
            notice_sink => sub { push @notices, $_[0]; 1 },
        );
    };

    $plugin->command_quotecount(
        $authority, $invoke->('quotecount', []));
    $assert->is($replies[-1], '#development: 7 quote(s) total',
        'quotecount preserves the channel-total rendering');

    $plugin->command_quotecount(
        $authority, $invoke->('quotecount', ['Ta%_']));
    $assert->is($replies[-1], 'Ta%_: 2 quote(s) on #development',
        'author count preserves the caller spelling in its rendering');
    $assert->is($calls[-1][0], 'count',
        'author count uses only the approved count operation');
    $assert->is($calls[-1][1]{author_match}, 'prefix',
        'author count explicitly requests the historical prefix mode');

    $plugin->command_topquote(
        $authority, $invoke->('halloffame', ['99']));
    $assert->is($calls[-1][1]{limit}, 10,
        'halloffame keeps the historical ten-result ceiling');
    $assert->like($replies[-3], qr/^\x02Hall of fame\x02 #development/,
        'topquote emits the historical heading');
    $assert->like($replies[-2],
        qr/^1\. \[id:9\] <Alice> A memorable line \(1 recall\)\z/,
        'topquote keeps identifier, author and singular recall rendering');
    $assert->like($replies[-1], qr/\(8 recalls\)\z/,
        'topquote keeps plural recall rendering');
    $assert->ok(length(encode('UTF-8', $replies[-1])) <= 400,
        'long multibyte quote output remains inside the facade budget');

    $mode = 'empty';
    $plugin->command_topquote(
        $authority, $invoke->('topquote', []));
    $assert->like($replies[-1], qr/^No quotes yet on #development/,
        'empty channels retain the historical guidance');

    $mode = 'unavailable';
    $plugin->command_topquote(
        $authority, $invoke->('topquote', []));
    $assert->is($notices[-1], 'topquote: database unavailable.',
        'service failures remain private and neutral');
};
