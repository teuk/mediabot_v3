# MB747 — machine contract and documented read-only boundary stay aligned.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

use JSON::PP ();

sub slurp {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die $!;
    local $/;
    my $text = <$fh>;
    close $fh;
    return $text;
}

return sub {
    my ($assert) = @_;
    my $contract = JSON::PP->new->decode(slurp('plugins/API_V3_CONTRACT.json'));
    $assert->is($contract->{milestone}, 'MB786',
        'machine contract names the current platform milestone');
    $assert->ok(grep($_ eq 'data.quotes.read',
        @{ $contract->{implemented_capabilities} }),
        'machine contract implements the exact quote read capability');
    $assert->is(join(',', @{ $contract->{quote_read_limits}{operations} }),
        'by_id,random,search,by_author,random_by_author,count,top,stats',
        'machine contract freezes the eight approved operations');
    $assert->is($contract->{quote_read_limits}{writes},
        'separate data.quotes.write capability',
        'machine contract keeps reads physically separate from writes');
    $assert->is($contract->{quote_read_limits}{channel_source},
        'invocation policy', 'machine contract makes channel authority explicit');
    $assert->is(join(',',
        @{ $contract->{quote_read_limits}{author_count_match_modes} }),
        'exact,prefix', 'machine contract bounds author count matching');
    $assert->is(join(',', @{ $contract->{quote_read_migration}{commands} }),
        'q,quote,quotecount,topquote,halloffame',
        'machine contract names the complete quote migration');

    my $context = slurp('Mediabot/PluginContext.pm');
    my $service = slurp('Mediabot/Plugin/QuoteServiceV3.pm');
    $assert->like($context, qr/require_capability\('data\.quotes\.read'\)/,
        'runtime requires the exact capability before every facade call');
    $assert->like($context, qr/require_capability\('data\.quotes\.write'\)/,
        'runtime requires a distinct capability before every mutation');
    $assert->ok($service !~ /\b(?:INSERT|UPDATE|DELETE)\b/i,
        'quote service source has no mutating SQL verb');

    my $guide = slurp('docs/PLUGIN_API_V3.md');
    $assert->like($guide, qr/merely reading a record does not\s+change its `hits` value/,
        'author guide records the no-side-effect read guarantee');
};
