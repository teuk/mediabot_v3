# MB765 — operator contract freezes the dev and production boundaries.

use strict;
use warnings;
use utf8;

sub slurp_1134 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $sample = slurp_1134('mediabot.sample.conf');
    $assert->like($sample,
        qr/^\[conversation\]\s*$/m,
        'sample exposes the central conversation section');
    $assert->like($sample,
        qr/^CHANNEL_BOTS=\s*$/m,
        'bot exclusion remains empty by default');
    $assert->like($sample,
        qr/^CHANNEL_COMMANDS=\s*$/m,
        'external command exclusion remains empty by default');

    my $guide = slurp_1134('docs/CONVERSATION_EXCLUSIONS.md');
    $assert->like($guide,
        qr/CHANNEL_BOTS=radiocapsule:Balibalo\+mediacaps\+WarHawk/,
        'development channel declaration is exact');
    $assert->like($guide,
        qr/CHANNEL_BOTS=i\/o:Coin/,
        'production Coin declaration is exact');
    $assert->like($guide,
        qr/CHANNEL_COMMANDS=i\/o:!bang\+!pan\+!reload\+!shop\+!inventory\+!duckstats\+!lastduck\+!duckrank/,
        'documented pyDuckHunt namespace matches its reviewed public commands');
    $assert->like($guide,
        qr/before user-seen updates, achievements, reminders, trivia,/,
        'operator contract states the early shared boundary');
    $assert->like($guide,
        qr/Removing the two\s+values and reloading is the immediate rollback/s,
        'operator guide includes a config-only rollback');

    my $changelog = slurp_1134('CHANGELOG.md');
    $assert->like($changelog,
        qr/### mb765 — place a Quietus ward/,
        'changelog records the central barrier milestone');
};
