# t/cases/338_antiflood_partyline_floodstatus.t
use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_338 {
    open my $fh, '<:encoding(UTF-8)', $_[0] or die $!;
    local $/;
    return <$fh>;
}

sub _sub_338 {
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

    my $partyline = _slurp_338(File::Spec->catfile('.', 'Mediabot', 'Partyline.pm'));
    my $body = _sub_338($partyline, '_cmd_floodstatus');

    $assert->ok(defined $body, '_cmd_floodstatus body found');
    $assert->like($partyline, qr/\.floodstatus/, 'Partyline dispatches .floodstatus');
    $assert->like($body // '', qr/_af/, '.floodstatus displays AF1 output state');
    $assert->like($body // '', qr/_chan_flood/, '.floodstatus displays AF4 channel state');
    $assert->like($body // '', qr/_nick_flood/, '.floodstatus displays AF3 nick state');
    $assert->like($body // '', qr/Channel antiflood.*output guard/s, '.floodstatus labels output guard');
    $assert->like($body // '', qr/Channel flood.*input guard/s, '.floodstatus labels input guard');
    $assert->like($body // '', qr/Per-nick flood/s, '.floodstatus labels nick guard');
};
