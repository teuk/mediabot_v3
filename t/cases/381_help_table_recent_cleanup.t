# t/cases/381_help_table_recent_cleanup.t
use strict;
use warnings;
use File::Spec;

sub _slurp_381 {
    open my $fh, '<:encoding(UTF-8)', $_[0] or die $!;
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_381(File::Spec->catfile('.', 'Mediabot', 'Mediabot.pm'));

    $assert->unlike(
        $src,
        qr/^remindlist\|remindsnooze\|/m,
        'help table has no malformed remindlist/remindsnooze row'
    );

    $assert->unlike(
        $src,
        qr/^pollstatus\|pollvoters\|/m,
        'help table has no malformed pollstatus/pollvoters row'
    );

    $assert->like(
        $src,
        qr/^remindsnooze\|remindsnooze <id> <delay>\|public\|/m,
        'remindsnooze help row is present and well formed'
    );

    $assert->like(
        $src,
        qr/^remindlist\|public\|List your pending reminders/m,
        'remindlist help row remains present'
    );

    $assert->like(
        $src,
        qr/^pollvoters\|pollvoters\|master\|Show who voted/m,
        'pollvoters help row is present and well formed'
    );

    $assert->like(
        $src,
        qr/^pollstatus\|public\|Show the current poll status/m,
        'pollstatus help row remains present'
    );

    $assert->like(
        $src,
        qr/ai persona/,
        'ai help still mentions ai persona'
    );

    $assert->like(
        $src,
        qr/^quote\|quote \[nick\]/m,
        'quote command has a help row'
    );

    $assert->like(
        $src,
        qr/^spike\|spike\|public\|/m,
        'spike command has a help row'
    );
};
