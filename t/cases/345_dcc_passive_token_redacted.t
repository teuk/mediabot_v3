# t/cases/345_dcc_passive_token_redacted.t
use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_345 {
    open my $fh, '<:encoding(UTF-8)', $_[0] or die $!;
    local $/;
    return <$fh>;
}

sub _sub_345 {
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

    my $mediabot = _slurp_345(File::Spec->catfile('.', 'Mediabot', 'Mediabot.pm'));
    my $party    = _slurp_345(File::Spec->catfile('.', 'Mediabot', 'Partyline.pm'));

    my $dcc_body = _sub_345($mediabot, '_handle_dcc_chat_request');
    my $pl_body  = _sub_345($party, 'accept_dcc_chat_passive');

    $assert->ok(defined $dcc_body, '_handle_dcc_chat_request body found');
    $assert->ok(defined $pl_body, 'accept_dcc_chat_passive body found');

    $assert->like($mediabot, qr/sub _dcc_token_hint\b/,
        'Mediabot.pm has DCC token redaction helper');
    $assert->like($party, qr/sub _dcc_token_hint\b/,
        'Partyline.pm has DCC token redaction helper');

    $assert->like($dcc_body // '', qr/_dcc_token_hint\(\$token\)/,
        'Mediabot passive DCC log uses token hint');

    $assert->like($pl_body // '', qr/_dcc_token_hint\(\$token\)/,
        'Partyline passive DCC logs use token hint');

    $assert->unlike($dcc_body // '', qr/token=%s",\s*\$nick,\s*\$row->\{description\},\s*\$token\b/s,
        'Mediabot does not pass raw token to passive DCC log formatter');

    $assert->like($dcc_body // '', qr/token=%s",\s*\$nick,\s*\$row->\{description\},\s*\$token_hint\b/s,
        'Mediabot passes redacted token hint to passive DCC log formatter');

    $assert->unlike($pl_body // '', qr/token=\$token/,
        'Partyline does not interpolate raw token in passive DCC logs');

    $assert->like($pl_body // '', qr/my \$ctcp = "\\001DCC CHAT chat \$ip_int \$listen_port \$token\\001"/,
        'Partyline still sends real token in CTCP reply');
};
