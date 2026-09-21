# MB759 — factoid and factoids render only detached read-facade results.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..",
        "$Bin/../../plugins/factoids-v3/lib";
}

use JSON::PP ();

sub slurp_1114 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

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
    $assert->is($manifest->{activation}{default}, 'off',
        'factoid package is inert by default');
    $assert->is(join(',', @{ $manifest->{capabilities} }),
        'data.factoids.read,data.factoids.write,irc.notice',
        'factoid package requests bounded read/write data and private notices');
    $assert->is(join(',', sort keys %{ $manifest->{commands} }),
        'factoid,factoids,forget,learn',
        'package contains the two readers and two authorized writers');

    my (@reads, @notices, @replies);
    my $authority = Mediabot::PluginContext->new(
        plugin => 'factoids-v3',
        requested => [qw(data.factoids.read data.factoids.write irc.notice)],
        granted => [qw(data.factoids.read data.factoids.write irc.notice)],
        factoids_read_sink => sub {
            my ($invocation, $operation, $args) = @_;
            push @reads, [$operation, { %$args }];
            if ($operation eq 'by_keyword') {
                return { ok => 1, record => undef }
                    if $args->{keyword} eq 'missing';
                return { ok => 1, record =>
                    Mediabot::Plugin::FactoidRecordV3->new(
                        id => 7, keyword => $args->{keyword},
                        value => 'a language', author => 'Bob', author_id => 4,
                        created_at => '2026-07-02 10:00:00',
                        updated_at => '2026-07-05 11:00:00', hits => 3) };
            }
            return { ok => 1, keywords => [qw(coffee perl)] }
                if $operation eq 'list';
            return { ok => 1, items => [
                { keyword => 'coffee', hits => 7 },
                { keyword => 'perl', hits => 3 },
            ] } if $operation eq 'top';
            die "unexpected read $operation";
        },
    );
    my $principal = Mediabot::Plugin::PrincipalV3->new(
        authenticated => 0, user_id => 0, account => '',
        global_level => '', channel_level => 0);
    my $invoke = sub {
        my ($command, $args, $channel) = @_;
        return Mediabot::Plugin::InvocationV3->new(
            nick => 'Luna', channel => ($channel // '#test'),
            command => $command, args => $args, source => 'public',
            is_private => 0, authority => $authority, activation => 'on',
            config => {}, principal => $principal,
            reply_sink => sub { push @replies, $_[0]; 1 },
            notice_sink => sub { push @notices, $_[0]; 1 },
        );
    };
    my $plugin = Mediabot::Plugin::Factoids->new(context => $authority);

    $plugin->command_factoid(
        $authority, $invoke->('factoid', ['Perl']));
    $assert->is($reads[-1][0], 'by_keyword',
        'factoid crosses only the exact lookup operation');
    $assert->is($reads[-1][1]{keyword}, 'perl',
        'factoid normalizes the bounded keyword before lookup');
    $assert->is($notices[-2],
        "factoid 'perl': created 2026-07-02 by Bob, updated 2026-07-05, 3 recall(s).",
        'factoid preserves the historical metadata rendering');
    $assert->is($notices[-1], 'value: a language',
        'factoid preserves the historical value rendering');

    $plugin->command_factoids(
        $authority, $invoke->('factoids', ['p*']));
    $assert->is($reads[-1][0], 'list',
        'factoids crosses only the bounded list operation');
    $assert->is($reads[-1][1]{pattern}, 'p*',
        'validated glob reaches the core facade');
    $assert->is($reads[-1][1]{limit}, 60,
        'factoid listing keeps the historical sixty-item ceiling');
    $assert->is($notices[-1],
        '2 factoid(s) on #test: coffee, perl',
        'factoid listing preserves the historical rendering');

    $plugin->command_factoids(
        $authority, $invoke->('factoids', ['top']));
    $assert->is($reads[-1][0], 'top',
        'factoids top crosses only the bounded ranking operation');
    $assert->is($reads[-1][1]{limit}, 10,
        'factoid ranking keeps the historical ten-item ceiling');
    $assert->is($notices[-1],
        'Top factoids on #test: coffee (7), perl (3)',
        'top ranking preserves the historical rendering');

    $plugin->command_factoids(
        $authority, $invoke->('factoids', ['bad/pattern']));
    $assert->is($reads[-1][0], 'list',
        'invalid historical pattern still performs an unfiltered list');
    $assert->ok(!defined($reads[-1][1]{pattern}),
        'invalid pattern never crosses the factoid facade');

    $plugin->command_factoid(
        $authority, $invoke->('factoid', ['missing']));
    $assert->is($notices[-1], "I don't know 'missing'.",
        'missing factoid preserves the historical notice');
    $assert->is(scalar @replies, 0,
        'both adopted readers remain private-notice commands');

    my $source = slurp_1114('plugins/factoids-v3/lib/Factoids.pm');
    $assert->ok($source !~ /\b(?:DBI|prepare|execute|INSERT|UPDATE|DELETE)\b/,
        'factoid package contains no database primitive or mutating SQL');
};
