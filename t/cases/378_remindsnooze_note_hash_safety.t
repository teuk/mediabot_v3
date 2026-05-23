# t/cases/378_remindsnooze_note_hash_safety.t
use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_378 {
    open my $fh, '<:encoding(UTF-8)', $_[0] or die $!;
    local $/;
    return <$fh>;
}

sub _sub_378 {
    my ($src, $name) = @_;

    my $re = qr/^[ \t]*sub[ \t]+\Q$name\E\b[^{]*\{/m;
    return undef unless $src =~ /$re/g;

    my ($start, $pos, $depth) = ($-[0], pos($src), 1);

    while ($pos < length($src)) {
        my $ch = substr($src, $pos, 1);
        $depth++ if $ch eq '{';
        $depth-- if $ch eq '}';

        return substr($src, $start, $pos + 1 - $start)
            if $depth == 0;

        $pos++;
    }

    return undef;
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_378(File::Spec->catfile('.', 'Mediabot', 'UserCommands.pm'));

    my $snooze = _sub_378($src, 'mbRemindSnooze_ctx');
    my $note   = _sub_378($src, 'mbNote_ctx');

    $assert->ok(defined $snooze, 'mbRemindSnooze_ctx body found');
    $assert->ok(defined $note, 'mbNote_ctx body found');

    $assert->unlike($snooze // '', qr/CONCAT\('\[at:\?, \]'/,
        'remindsnooze no longer prepares invalid CONCAT [at:?] SQL');

    $assert->like($snooze // '', qr/SELECT message FROM REMINDERS/,
        'remindsnooze fetches existing reminder message');

    $assert->like($snooze // '', qr/UPDATE REMINDERS SET message = \?/,
        'remindsnooze updates rewritten message through a placeholder');

    $assert->like($note // '', qr/ref\(\$n\) eq 'HASH'.*?\$n->\{text\}/s,
        'note export handles hash-backed notes');

    $assert->like($note // '', qr/ref\(\$_\) eq 'HASH'.*?\$_->\{text\}/s,
        'note search handles hash-backed notes');
};
