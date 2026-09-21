# MB761 — learn and forget use only the bounded factoid write facade.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..", "$Bin/../../plugins/factoids-v3/lib";
}

use Encode qw(encode);

return sub {
    my ($assert) = @_;
    require Mediabot::PluginContext;
    require Mediabot::Plugin::InvocationV3;
    require Mediabot::Plugin::PrincipalV3;
    require Factoids;

    my (@writes, @notices);
    my $authority = Mediabot::PluginContext->new(
        plugin => 'factoids-v3',
        requested => [qw(data.factoids.read data.factoids.write irc.notice)],
        granted => [qw(data.factoids.read data.factoids.write irc.notice)],
        factoids_write_sink => sub {
            my ($invocation, $operation, $args) = @_;
            push @writes, [$operation, { %$args }];
            return { ok => 0, error => 'forbidden' }
                if $args->{keyword} eq 'sealed';
            return { ok => 1, status => 'not_found', keyword => 'missing' }
                if $args->{keyword} eq 'missing';
            return { ok => 1, status => $operation eq 'upsert'
                ? 'stored' : 'deleted', keyword => $args->{keyword} };
        },
    );
    my $principal = Mediabot::Plugin::PrincipalV3->new(
        authenticated => 1, user_id => 7, account => 'Luna',
        global_level => 'user', channel_level => 0);
    my $invoke = sub {
        my ($command, $args) = @_;
        return Mediabot::Plugin::InvocationV3->new(
            nick => 'Luna_', channel => '#test', command => $command,
            args => $args, source => 'public', is_private => 0,
            authority => $authority, activation => 'on', config => {},
            principal => $principal,
            reply_sink => sub { die 'factoid writers use notices' },
            notice_sink => sub { push @notices, $_[0]; 1 },
        );
    };
    my $plugin = Mediabot::Plugin::Factoids->new(context => $authority);

    $plugin->command_learn(
        $authority, $invoke->('learn', ['Spell', '=', 'Expecto', 'Patronum']));
    $assert->is($writes[-1][0], 'upsert',
        'learn crosses only the approved upsert operation');
    $assert->is($writes[-1][1]{keyword}, 'spell',
        'learn normalizes the bounded keyword');
    $assert->is($writes[-1][1]{value}, 'Expecto Patronum',
        'learn passes the parsed value only');
    $assert->is($notices[-1], "Learned 'spell' for #test.",
        'learn preserves the historical success notice');

    my $long = "é" x 250;
    $plugin->command_learn(
        $authority, $invoke->('learn', ['unicode', '=', $long]));
    $assert->ok(length(encode('UTF-8', $writes[-1][1]{value})) <= 400,
        'learn truncates a Unicode value to the write-service byte budget');
    $assert->ok(length($writes[-1][1]{value}) <= 400,
        'learn also respects the character ceiling');

    my $before = scalar @writes;
    $plugin->command_learn(
        $authority, $invoke->('learn', ['bad keyword', '=', 'value']));
    $assert->is(scalar @writes, $before,
        'invalid learn syntax never reaches the write facade');
    $assert->is($notices[-1],
        'learn: keyword must be 1-64 chars of letters/digits/_.- (no spaces).',
        'invalid keyword preserves the historical notice');

    $plugin->command_forget(
        $authority, $invoke->('forget', ['spell']));
    $assert->is($writes[-1][0], 'delete',
        'forget crosses only the approved delete operation');
    $assert->is($writes[-1][1]{keyword}, 'spell',
        'forget passes only the normalized keyword');
    $assert->is($notices[-1], "Forgot 'spell' on #test.",
        'forget preserves the historical success notice');

    $plugin->command_forget(
        $authority, $invoke->('forget', ['missing']));
    $assert->is($notices[-1], "I don't know 'missing'.",
        'forget preserves the missing-key notice');

    $plugin->command_forget(
        $authority, $invoke->('forget', ['sealed']));
    $assert->is($notices[-1],
        "forget: only the author or a channel op can forget 'sealed'.",
        'forget renders the bounded core authorization refusal');

    my $source = do {
        open my $fh, '<:raw', 'plugins/factoids-v3/lib/Factoids.pm'
            or die $!;
        local $/;
        <$fh>;
    };
    $assert->ok($source !~ /\b(?:DBI|prepare|execute|INSERT|UPDATE|DELETE)\b/,
        'adopted writers contain no database primitive or SQL verb');
};
