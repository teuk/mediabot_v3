# t/cases/337_antiflood_output_cache_and_metrics.t
use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_337 {
    open my $fh, '<:encoding(UTF-8)', $_[0] or die $!;
    local $/;
    return <$fh>;
}

sub _sub_337 {
    my ($src, $name) = @_;
    my $re = qr/^[ \t]*sub[ \t]+\Q$name\E\b[^{]*\{/m;
    return undef unless $src =~ /$re/g;
    my ($start, $pos, $depth) = ($-[0], pos($src), 1);
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

    my $helpers = _slurp_337(File::Spec->catfile('.', 'Mediabot', 'Helpers.pm'));
    my $metrics = _slurp_337(File::Spec->catfile('.', 'Mediabot', 'Metrics.pm'));
    my $body = _sub_337($helpers, 'checkAntiFlood');

    $assert->ok(defined $body, 'checkAntiFlood body found');
    $assert->like($body // '', qr/OUTPUT_PARAMS_CACHE_TTL/,
        'checkAntiFlood uses configurable params cache TTL');
    $assert->like($body // '', qr/_af_params/,
        'checkAntiFlood caches CHANNEL_FLOOD params in _af_params');
    $assert->like($body // '', qr/_af\b/,
        'checkAntiFlood stores output flood state in _af');
    $assert->like($body // '', qr/SELECT\s+nbmsg_max,\s*duration,\s*timetowait\s+FROM\s+CHANNEL_FLOOD/s,
        'checkAntiFlood still reads existing CHANNEL_FLOOD schema');
    $assert->like($body // '', qr/mediabot_antiflood_blocks_total/,
        'checkAntiFlood increments output antiflood metric');

    for my $metric (qw(
        mediabot_antiflood_blocks_total
        mediabot_nickflood_blocks_total
        mediabot_chanflood_blocks_total
    )) {
        $assert->like($metrics, qr/\Q$metric\E/, "Metrics.pm declares $metric");
    }
};
