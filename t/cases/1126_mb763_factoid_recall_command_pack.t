# MB763 — whatis and its quiet shortcut use only bounded v3 authorities.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..",
        "$Bin/../../plugins/factoids-v3/lib";
}

use Encode qw(encode);

return sub {
    my ($assert) = @_;
    require Mediabot::Plugin::ManifestV3;
    require Mediabot::PluginContext;
    require Mediabot::Plugin::InvocationV3;
    require Mediabot::Plugin::PrincipalV3;
    require Mediabot::Plugin::FactoidRecordV3;
    require Factoids;

    my $manifest = Mediabot::Plugin::ManifestV3->load_file(
        'plugins/factoids-v3/plugin.json', expected_name => 'factoids-v3');
    $assert->is($manifest->{version}, '1.2.0',
        'factoid package version records recall-command adoption');
    $assert->is(join(',', sort keys %{ $manifest->{commands} }),
        'factoid,factoids,forget,learn,whatis',
        'package adds only whatis to the four reviewed commands');

    my (@reads, @writes, @replies, @notices);
    my $authority = Mediabot::PluginContext->new(
        plugin => 'factoids-v3',
        requested => [qw(data.factoids.read data.factoids.write irc.reply irc.notice)],
        granted => [qw(data.factoids.read data.factoids.write irc.reply irc.notice)],
        factoids_read_sink => sub {
            my ($invocation, $operation, $args) = @_;
            push @reads, [$operation, { %$args }];
            return { ok => 1, record => undef }
                if $args->{keyword} eq 'missing';
            return { ok => 1, record =>
                Mediabot::Plugin::FactoidRecordV3->new(
                    id => 9, keyword => $args->{keyword},
                    value => $args->{keyword} eq 'wide'
                        ? ("é" x 250) : 'a guarded spell', author => 'Luna',
                    author_id => 7, created_at => '2026-09-22 08:00:00',
                    updated_at => '2026-09-22 08:00:00', hits => 4) };
        },
        factoids_write_sink => sub {
            my ($invocation, $operation, $args) = @_;
            push @writes, [$operation, { %$args }];
            return { ok => 1, status => 'recalled',
                keyword => $args->{keyword} };
        },
    );
    my $principal = Mediabot::Plugin::PrincipalV3->anonymous;
    my $invoke = sub {
        my ($args) = @_;
        return Mediabot::Plugin::InvocationV3->new(
            nick => 'Luna', channel => '#test', command => 'whatis',
            args => $args, source => 'public', is_private => 0,
            authority => $authority, activation => 'on', config => {},
            principal => $principal,
            reply_sink => sub { push @replies, $_[0]; 1 },
            notice_sink => sub { push @notices, $_[0]; 1 },
        );
    };
    my $plugin = Mediabot::Plugin::Factoids->new(context => $authority);

    $plugin->command_whatis($authority, $invoke->(['Spell']));
    $assert->is($reads[-1][0], 'by_keyword',
        'whatis performs one exact bounded read');
    $assert->is($reads[-1][1]{keyword}, 'spell',
        'whatis normalizes the keyword before crossing the facade');
    $assert->is($writes[-1][0], 'recall',
        'successful whatis requests only the recall mutation');
    $assert->is($writes[-1][1]{keyword}, 'spell',
        'recall uses the same normalized keyword');
    $assert->is($replies[-1], 'spell: a guarded spell',
        'successful whatis preserves the historical channel rendering');

    $plugin->command_whatis($authority, $invoke->(['wide']));
    $assert->ok(length(encode('UTF-8', $replies[-1])) <= 400,
        'public recall remains inside the complete IRC output budget');

    my ($write_count, $reply_count, $notice_count) =
        (scalar @writes, scalar @replies, scalar @notices);
    $plugin->command_whatis(
        $authority, $invoke->(['__quiet__', 'missing']));
    $assert->is(scalar @writes, $write_count,
        'quiet missing lookup never increments a counter');
    $assert->is(scalar @replies, $reply_count,
        'quiet missing lookup emits no channel reply');
    $assert->is(scalar @notices, $notice_count,
        'quiet missing lookup emits no notice');

    $plugin->command_whatis($authority, $invoke->(['missing']));
    $assert->is($notices[-1],
        "I don't know 'missing'. Teach me: learn missing = ...",
        'explicit missing lookup preserves the teaching notice');

    my $source = do {
        open my $fh, '<:raw', 'plugins/factoids-v3/lib/Factoids.pm'
            or die $!;
        local $/;
        <$fh>;
    };
    $assert->ok($source !~ /\b(?:DBI|prepare|execute|INSERT|UPDATE|DELETE)\b/,
        'adopted recall contains no database primitive or SQL');
};
