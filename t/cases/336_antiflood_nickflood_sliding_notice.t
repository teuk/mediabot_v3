# t/cases/336_antiflood_nickflood_sliding_notice.t
use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_336 {
    open my $fh, '<:encoding(UTF-8)', $_[0] or die $!;
    local $/;
    return <$fh>;
}

sub _sub_336 {
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

    my $helpers = _slurp_336(File::Spec->catfile('.', 'Mediabot', 'Helpers.pm'));
    my $body = _sub_336($helpers, 'checkNickFlood');

    $assert->ok(defined $body, 'checkNickFlood body found');
    $assert->like($body // '', qr/NICKFLOOD_WINDOW/, 'checkNickFlood reads NICKFLOOD_WINDOW');
    $assert->like($body // '', qr/NICKFLOOD_MAX_COMMANDS/, 'checkNickFlood reads NICKFLOOD_MAX_COMMANDS');
    $assert->like($body // '', qr/NICKFLOOD_NOTIFY_COOLDOWN/, 'checkNickFlood reads NICKFLOOD_NOTIFY_COOLDOWN');
    $assert->like($body // '', qr/NICKFLOOD_STATE_TTL/, 'checkNickFlood reads NICKFLOOD_STATE_TTL');
    $assert->like($body // '', qr/push\s+\@\{\s*\$state->\{hits\}\s*\},\s*\$now/s,
        'checkNickFlood pushes timestamps into sliding window');
    $assert->like($body // '', qr/grep\s*\{\s*\(\$now\s*-\s*\$_\)\s*<\s*\$window\s*\}/s,
        'checkNickFlood prunes timestamps outside sliding window');
    $assert->like($body // '', qr/botNotice\(\$self,\s*\$nick/s,
        'checkNickFlood notifies user on cooldown');
    $assert->like($body // '', qr/mediabot_nickflood_blocks_total/,
        'checkNickFlood increments metric');
};
