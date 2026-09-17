use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

use Mediabot::Spark::Identity qw(is_known_bot_nick);

return sub {
    my ($assert) = @_;

    $assert->ok(is_known_bot_nick(
        nick => 'cOiN', configured_bot_nicks => 'Coin,RelayBot',
    ), 'mb739-1063: Coin ignore matching is case-insensitive');
    $assert->ok(is_known_bot_nick(
        nick => 'Game{Bot}', configured_bot_nicks => 'Game[Bot]',
    ), 'mb739-1063: dedicated ignore matching follows the IRC casemap');
    $assert->ok(!is_known_bot_nick(
        nick => 'Alice', configured_bot_nicks => 'Coin,RelayBot',
    ), 'mb739-1063: a human nick is not swallowed by the ignore list');

    my $read = sub {
        my ($path) = @_;
        open my $fh, '<:encoding(UTF-8)', "$Bin/../../$path"
            or die "open $path: $!";
        local $/;
        return <$fh>;
    };
    my $main = $read->('mediabot.pl');
    my $sample = $read->('mediabot.sample.conf');
    my $doc = $read->('docs/WIT_QUIP.md');

    $assert->like($main,
        qr/my \$wit_ignore_nicks\s*=.*?main\.WIT_IGNORE_NICKS.*?my \$from_wit_ignored\s*=.*?from_bot\s*=>\s*\$from_wit_ignored/s,
        'mb739-1063: one ignored-bot decision covers Wit and Quip observation');
    $assert->like($main, qr/\$wit_ignore_nicks\s*=\s*'Coin'/,
        'mb739-1063: upgraded private configs default safely to Coin');
    $assert->is(scalar(() = $sample =~ /^WIT_IGNORE_NICKS=Coin$/mg), 1,
        'mb739-1063: sample configuration excludes Coin exactly once');
    $assert->like($doc, qr/Coin.*cannot trigger.*context/is,
        'mb739-1063: operator documentation explains the no-trigger/no-context boundary');
};
