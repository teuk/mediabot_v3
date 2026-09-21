# MB754 — machine contract records adoption of the separately authorized gate.

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

use JSON::PP ();

sub slurp_1103 {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;
    my $contract = JSON::PP->new->decode(
        slurp_1103('plugins/API_V3_CONTRACT.json'));
    $assert->is($contract->{milestone}, 'MB758',
        'machine contract records the current platform milestone');
    $assert->ok(grep($_ eq 'data.quotes.write',
        @{ $contract->{implemented_capabilities} }),
        'write capability is distinct from quote reads');
    $assert->is(join(',', @{ $contract->{quote_write_limits}{operations} }),
        'add,delete,recall', 'only the three approved mutations are exposed');
    $assert->is($contract->{quote_write_limits}{activation}, 'on only',
        'observe can never mutate quote data');
    $assert->is($contract->{quote_write_limits}{plugin_adoption},
        'quotes-v3 q and quote, inactive by default',
        'official adoption remains inactive until an operator opts in');
    $assert->is($contract->{quote_write_limits}{channel_source},
        'core invocation policy', 'plugin cannot select a write channel');
    $assert->is($contract->{quote_write_limits}{principal_source},
        'core command context', 'plugin cannot supply its authorization');
    $assert->is($contract->{quote_write_limits}{invocation_origin},
        'opaque runtime authority required',
        'plugin-created invocation lookalikes cannot reach writes');
    $assert->is($contract->{quote_write_limits}{add_attribution},
        'authenticated user id or SQL NULL for anonymous',
        'anonymous write attribution uses the nullable foreign-key value');

    my $read = slurp_1103('Mediabot/Plugin/QuoteServiceV3.pm');
    my $write = slurp_1103('Mediabot/Plugin/QuoteWriteServiceV3.pm');
    $assert->unlike($read, qr/\b(?:INSERT|UPDATE|DELETE)\b/i,
        'read facade remains physically read-only');
    $assert->like($write, qr/INSERT INTO QUOTES/,
        'mutating SQL lives only in the dedicated service');
    $assert->like($write, qr/DELETE FROM QUOTES/,
        'delete uses the dedicated authorized service');
    $assert->unlike($write, qr/\b(?:DROP|ALTER|CREATE)\b/i,
        'write facade has no schema administration');

    my $quote_manifest = JSON::PP->new->decode(
        slurp_1103('plugins/quotes-v3/plugin.json'));
    $assert->ok(grep($_ eq 'data.quotes.write',
        @{ $quote_manifest->{capabilities} }),
        'official quote package requests the separate write capability');
    $assert->ok(exists($quote_manifest->{commands}{q})
        && exists($quote_manifest->{commands}{quote}),
        'mixed commands are reversibly declared by the package');
};
