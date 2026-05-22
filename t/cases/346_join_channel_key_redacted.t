# t/cases/346_join_channel_key_redacted.t
use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_346 {
    open my $fh, '<:encoding(UTF-8)', $_[0] or die $!;
    local $/;
    return <$fh>;
}

sub _sub_346 {
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

    my $helpers = _slurp_346(File::Spec->catfile('.', 'Mediabot', 'Helpers.pm'));
    my $party   = _slurp_346(File::Spec->catfile('.', 'Mediabot', 'Partyline.pm'));

    my $join_body = _sub_346($helpers, 'joinChannel');
    my $cmd_body  = _sub_346($party, '_cmd_join');

    $assert->ok(defined $join_body, 'joinChannel body found');
    $assert->ok(defined $cmd_body, '_cmd_join body found');

    $assert->like(
        $join_body // '',
        qr/send_message\("JOIN",\s*undef,\s*\(\$channel,\s*\$key\)\)/,
        'joinChannel still sends the real key to IRC JOIN'
    );

    $assert->like(
        $join_body // '',
        qr/Trying to join \$channel with key \[redacted\]/,
        'joinChannel logs redacted channel key'
    );

    $assert->unlike(
        $join_body // '',
        qr/with key \$key/,
        'joinChannel no longer logs raw channel key'
    );

    $assert->like(
        $cmd_body // '',
        qr/key: \[redacted\]/,
        'Partyline .join logs redacted key'
    );

    $assert->like(
        $cmd_body // '',
        qr/with key \[redacted\]/,
        'Partyline .join echoes redacted key'
    );

    $assert->unlike(
        $cmd_body // '',
        qr/key: \$key|with key \$key/,
        'Partyline .join does not expose raw key'
    );

    $assert->like(
        $cmd_body // '',
        qr/joinChannel\(\$chan,\s*\$key\)/,
        'Partyline .join still passes real key to joinChannel'
    );
};
