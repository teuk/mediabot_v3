# MB342 / MB937 — exercise actual quote authorization and persistence.
use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use JSON::PP;
return sub {
    my ($assert) = @_;
    open my $probe, '-|', $^X, '-I.', '-It/lib',
        't/lib/MB937QuoteDeleteFixture.pm' or die "quote deletion probe: $!";
    my $raw = do { local $/; <$probe> };
    my $closed = close $probe;
    my $results = eval { JSON::PP->new->utf8->decode($raw // '') };
    $assert->ok($closed && ref($results) eq 'ARRAY' && @$results == 7,
        'MB937: native quote deletion probe completed');
    for my $result (@{ref($results) eq 'ARRAY' ? $results : []}) {
        $assert->ok($result->{ok}, 'MB937: ' . $result->{name}
            . ($result->{detail} ? ': ' . $result->{detail} : ''));
    }
};
