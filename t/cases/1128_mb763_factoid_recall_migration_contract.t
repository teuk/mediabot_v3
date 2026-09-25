# MB763 — machine, parser and guides freeze complete recall adoption.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

use JSON::PP ();

sub slurp_1128 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;
    my $contract = JSON::PP->new->decode(
        slurp_1128('plugins/API_V3_CONTRACT.json'));
    $assert->is($contract->{milestone}, 'MB786',
        'machine contract records recall-command adoption');
    $assert->is($contract->{factoid_recall_migration}{manifest_command},
        'whatis', 'manifest owns the canonical recall command');
    $assert->is($contract->{factoid_recall_migration}{shortcut_route},
        '?keyword -> whatis __quiet__ <keyword>',
        'machine contract preserves the parser-level shortcut route');
    $assert->is($contract->{factoid_recall_migration}{quiet_missing},
        'no output for ?keyword', 'quiet missing behavior is explicit');
    $assert->is($contract->{factoid_recall_migration}{successful_mutation},
        'one on-only core recall increment',
        'successful recall has one bounded mutation');

    my $manifest = JSON::PP->new->decode(
        slurp_1128('plugins/factoids-v3/plugin.json'));
    $assert->is($manifest->{version}, '1.2.0',
        'package version advances for recall adoption');
    $assert->ok(grep($_ eq 'irc.reply', @{ $manifest->{capabilities} }),
        'public recall output requests the bounded reply capability');
    $assert->is($manifest->{commands}{whatis}{handler}, 'command_whatis',
        'manifest maps whatis to its dedicated handler');
    $assert->is(scalar keys %{ $manifest->{commands} }, 5,
        'package exposes exactly five reviewed commands');

    my $main = slurp_1128('mediabot.pl');
    $assert->like($main,
        qr/mbCommandPublic\([^)]*'whatis','__quiet__',\$keyword\)/,
        'existing shortcut enters the canonical registry command');

    my $source = slurp_1128('plugins/factoids-v3/lib/Factoids.pm');
    $assert->like($source,
        qr/sub command_whatis.*?factoid_by_keyword\(.*?factoid_recall\(.*?reply\(/s,
        'handler performs bounded read, recall and channel reply in order');

    my $guide = slurp_1128('docs/FACTOID_COMMAND_V3_PILOT.md');
    $assert->like($guide,
        qr/Explicit\s+missing lookup must teach; quiet missing lookup must emit nothing/s,
        'pilot requires visible and quiet missing parity');
    $assert->like($guide,
        qr/advance the stored counter by exactly one/,
        'pilot requires exact recall-counter evidence');
    $assert->like($guide,
        qr/\.plugins policy factoids-v3 #test off/,
        'pilot retains immediate channel rollback');
};
