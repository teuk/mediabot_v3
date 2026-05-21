# t/cases/335_antiflood_chanflood_public_only.t
use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_335 {
    open my $fh, '<:encoding(UTF-8)', $_[0] or die $!;
    local $/;
    return <$fh>;
}

sub _sub_335 {
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

    my $helpers = _slurp_335(File::Spec->catfile('.', 'Mediabot', 'Helpers.pm'));
    my $mediabot = _slurp_335(File::Spec->catfile('.', 'Mediabot', 'Mediabot.pm'));

    my $chan = _sub_335($helpers, 'checkChanFlood');
    $assert->ok(defined $chan, 'checkChanFlood body found');
    $assert->like($chan // '', qr/CHANFLOOD_WINDOW/, 'checkChanFlood reads CHANFLOOD_WINDOW');
    $assert->like($chan // '', qr/CHANFLOOD_MAX_COMMANDS/, 'checkChanFlood reads CHANFLOOD_MAX_COMMANDS');
    $assert->like($chan // '', qr/CHANFLOOD_SILENCE/, 'checkChanFlood reads CHANFLOOD_SILENCE');
    $assert->like($chan // '', qr/CHANFLOOD_NOTIFY_COOLDOWN/, 'checkChanFlood reads CHANFLOOD_NOTIFY_COOLDOWN');
    $assert->like($chan // '', qr/_chan_flood/, 'checkChanFlood stores state in _chan_flood');
    $assert->like($chan // '', qr/noticeConsoleChan/, 'checkChanFlood notifies console on cooldown');
    $assert->like($chan // '', qr/mediabot_chanflood_blocks_total/, 'checkChanFlood increments metric');

    my $pub = _sub_335($mediabot, 'mbCommandPublic');
    $assert->ok(defined $pub, 'mbCommandPublic body found');
    $assert->like($pub // '', qr/checkChanFlood\(\$self,\s*\$sChannel\).*checkNickFlood\(\$self,\s*\$sNick,\s*\$sChannel\)/s,
        'mbCommandPublic calls checkChanFlood before checkNickFlood');

    my $priv = _sub_335($mediabot, 'mbCommandPrivate');
    $assert->ok(defined $priv, 'mbCommandPrivate body found');

    # Static test note:
    # mbCommandPrivate may contain explanatory comments mentioning the public
    # channel antiflood guard. For this assertion we care about executable code,
    # so strip full-line comments before checking for real calls/variables.
    my $priv_code = $priv // '';
    $priv_code =~ s/^\s*#.*$//mg;

    $assert->unlike($priv_code, qr/\bcheckChanFlood\s*\(/,
        'mbCommandPrivate does not call checkChanFlood');
    $assert->unlike($priv_code, qr/\$sChannel\b/,
        'mbCommandPrivate does not use undefined $sChannel');
};
