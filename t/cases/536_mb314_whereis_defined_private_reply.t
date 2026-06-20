# t/cases/536_mb314_whereis_defined_private_reply.t
# =============================================================================
# MB314: whereis must always return a defined printable result and the WHOIS
# callback must reply to the caller when the command was issued privately.
# =============================================================================

use strict;
use warnings;

use File::Spec;

sub _slurp_mb314 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_mb314 {
    my ($src, $name) = @_;
    my $re = qr/^sub\s+\Q$name\E\s*\{/m;
    return undef unless $src =~ /$re/g;

    my $start = $-[0];
    my $pos   = pos($src);
    my $depth = 1;

    while ($pos < length($src)) {
        my $ch = substr($src, $pos, 1);
        $depth++ if $ch eq '{';
        $depth-- if $ch eq '}';
        return substr($src, $start, $pos + 1 - $start) if $depth == 0;
        $pos++;
    }

    return undef;
}

return sub {
    my ($assert) = @_;

    my $helpers = _slurp_mb314(
        File::Spec->catfile('.', 'Mediabot', 'Helpers.pm')
    );
    my $main = _slurp_mb314('mediabot.pl');

    my $whereis = _extract_sub_mb314($helpers, 'whereis');

    $assert->ok(defined $whereis, 'whereis helper found');

    $assert->like(
        $whereis // '',
        qr/return\s+'N\/A'\s+unless\s+defined\(\$sHostname\)\s+&&\s+!ref\(\$sHostname\)/,
        'whereis rejects undefined and reference host values'
    );

    $assert->like(
        $whereis // '',
        qr/\(\?:\^\|\\\.\)users\\\.undernet\\\.org\\z\/i/,
        'Undernet hidden-host suffix is escaped and end anchored'
    );

    $assert->like(
        $whereis // '',
        qr/my\s+\$packed_ip\s*=\s*inet_aton\(\$sHostname\)/,
        'literal IPv4 input is validated with inet_aton'
    );

    $assert->like(
        $whereis // '',
        qr/return\s+\"N\/A\"\s+unless\s+ref\(\$response\)\s+eq\s+'HASH'/,
        'HTTP response shape is validated before success dereference'
    );

    $assert->like(
        $whereis // '',
        qr/return\s+'N\/A'\s+if\s+\$@\s+\|\|\s+!defined\(\$json\)\s+\|\|\s+ref\(\$json\)\s+ne\s+'HASH'/,
        'invalid country.is JSON returns N/A'
    );

    $assert->like(
        $whereis // '',
        qr/return\s+'N\/A'\s+unless\s+defined\(\$country\)\s+&&\s+!ref\(\$country\)/,
        'missing or structured country values return N/A'
    );

    $assert->unlike(
        $whereis // '',
        qr/return\s+undef/,
        'whereis no longer returns undef to its IRC caller'
    );

    my ($branch) = $main =~ /(elsif\s*\(\$WHOIS_VARS\{'sub'\}\s+eq\s+"mbWhereis"\).*?\n\s*}\n\s*elsif\s*\(\$WHOIS_VARS\{'sub'\}\s+eq\s+"statPartyline")/s;
    $assert->ok(defined $branch, 'mbWhereis WHOIS branch found');

    $assert->like(
        $branch // '',
        qr/my\s+\$reply_target\s*=.*?\?\s*\$WHOIS_VARS\{'channel'\}.*?:\s*\$WHOIS_VARS\{'caller'\}/s,
        'private whereis replies fall back to the original caller'
    );

    $assert->like(
        $branch // '',
        qr/\$country\s*=\s*'N\/A'\s+unless\s+defined\(\$country\)/,
        'WHOIS callback protects against legacy undefined results'
    );

    my $country_lines = () = ($branch // '') =~ /Country\s*:\s*\$country/g;
    $assert->is(
        $country_lines,
        1,
        'WHOIS callback has one defined country reply path'
    );
};
