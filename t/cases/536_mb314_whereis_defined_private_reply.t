# t/cases/536_mb314_whereis_defined_private_reply.t
# =============================================================================
# The WHOIS callback must reply to the caller when issued privately.
# The lookup behavior is covered by the native socket/HTTP fixture in 139.
# =============================================================================

use strict;
use warnings;

sub _slurp_mb314 {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;
    my $main = _slurp_mb314('mediabot.pl');

    my ($branch) = $main =~ /(elsif\s*\(\$WHOIS_VARS\{'sub'\}\s+eq\s+"mbWhereis"\).*?\n\s*}\n\s*elsif\s*\(\$WHOIS_VARS\{'sub'\}\s+eq\s+"statPartyline")/s;
    $assert->ok(defined $branch, 'mbWhereis WHOIS branch found');

    $assert->like(
        $branch // '',
        qr/my\s+\$whereis_caller\s*=\s*\$WHOIS_VARS\{'caller'\}.*?my\s+\$reply_target\s*=.*?\?\s*\$WHOIS_VARS\{'channel'\}.*?:\s*\$whereis_caller/s,
        'private whereis replies fall back to the captured original caller'
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
