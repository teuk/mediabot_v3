# MB697 — mbweb dependency security contract.

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

use File::Spec;
use JSON::PP qw(decode_json);

sub slurp_911 {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path
        or die "$path: $!";

    local $/;
    return <$fh>;
}

sub semver_911 {
    my ($v) = @_;
    my @n = ($v =~ /^(\d+)\.(\d+)\.(\d+)/);

    die "Unsupported semantic version: $v"
        unless @n == 3;

    return @n;
}

sub at_least_911 {
    my ($actual, $minimum) = @_;

    my @a = semver_911($actual);
    my @m = semver_911($minimum);

    for my $i (0 .. 2) {
        return 1 if $a[$i] > $m[$i];
        return 0 if $a[$i] < $m[$i];
    }

    return 1;
}

return sub {
    my ($assert) = @_;

    my $root = File::Spec->rel2abs(
        File::Spec->catdir($Bin, '..', '..')
    );

    my $lock = decode_json(
        slurp_911(
            File::Spec->catfile(
                $root,
                'contrib',
                'mbweb',
                'package-lock.json'
            )
        )
    );

    my $packages = $lock->{packages} || {};

    my $body =
        $packages->{'node_modules/body-parser'}{version} || '';

    my $qs =
        $packages->{'node_modules/qs'}{version} || '';

    $assert->ok(
        $body && at_least_911($body, '2.3.0'),
        "mb697-911: body-parser $body is outside audited vulnerable range"
    );

    $assert->ok(
        $qs && at_least_911($qs, '6.15.2'),
        "mb697-911: qs $qs is outside audited vulnerable range"
    );

    $assert->ok(
        !exists $packages->{'node_modules/express-rate-limit'},
        'mb697-911: stale express-rate-limit package is absent from canonical lock'
    );
};
