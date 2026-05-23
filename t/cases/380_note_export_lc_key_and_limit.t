# t/cases/380_note_export_lc_key_and_limit.t
use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_380 {
    open my $fh, '<:encoding(UTF-8)', $_[0] or die $!;
    local $/;
    return <$fh>;
}

sub _sub_380 {
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

    my $src  = _slurp_380(File::Spec->catfile('.', 'Mediabot', 'UserCommands.pm'));
    my $body = _sub_380($src, 'mbNote_ctx');

    $assert->ok(defined $body, 'mbNote_ctx body found');

    $assert->like(
        $body // '',
        qr/my\s+\$notes\s*=\s*\$self->\{_notes\}\{lc \$nick\}\s*\/\/\s*\[\];/,
        '!note export reads notes using lc nick key'
    );

    $assert->unlike(
        $body // '',
        qr/\$self->\{_notes\}\{\$nick\}/,
        '!note no longer reads raw-case nick key'
    );

    $assert->like(
        $body // '',
        qr/Note too long \(%d chars, max 200\)/,
        '!note enforces documented 200-char limit'
    );

    $assert->unlike(
        $body // '',
        qr/max 256 chars/,
        'stale 256-char note limit removed'
    );

    $assert->like(
        $body // '',
        qr/push\s+\@\{\s*\$self->\{_notes\}\{lc \$nick\}\s*\}/,
        '!note still stores notes using lc nick key'
    );
};
