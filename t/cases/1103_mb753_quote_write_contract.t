# MB753 — machine contract records an inert, separately authorized write gate.

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
    $assert->is($contract->{milestone}, 'MB753',
        'machine contract records the quote authorization gate');
    $assert->ok(grep($_ eq 'data.quotes.write',
        @{ $contract->{implemented_capabilities} }),
        'write capability is distinct from quote reads');
    $assert->is(join(',', @{ $contract->{quote_write_limits}{operations} }),
        'add,delete', 'only the two approved mutations are exposed');
    $assert->is($contract->{quote_write_limits}{activation}, 'on only',
        'observe can never mutate quote data');
    $assert->is($contract->{quote_write_limits}{plugin_adoption}, 'none',
        'foundation does not migrate a command or activate a plugin');
    $assert->is($contract->{quote_write_limits}{channel_source},
        'core invocation policy', 'plugin cannot select a write channel');
    $assert->is($contract->{quote_write_limits}{principal_source},
        'core command context', 'plugin cannot supply its authorization');
    $assert->is($contract->{quote_write_limits}{invocation_origin},
        'opaque runtime authority required',
        'plugin-created invocation lookalikes cannot reach writes');

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
    $assert->ok(!grep($_ eq 'data.quotes.write',
        @{ $quote_manifest->{capabilities} }),
        'official quote package remains read-only in MB753');
    $assert->ok(!exists($quote_manifest->{commands}{q})
        && !exists($quote_manifest->{commands}{quote}),
        'mixed commands remain core-owned');
};
