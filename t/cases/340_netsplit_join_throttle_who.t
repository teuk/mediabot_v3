# t/cases/340_netsplit_join_throttle_who.t
use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_340 {
    open my $fh, '<:encoding(UTF-8)', $_[0] or die $!;
    local $/;
    return <$fh>;
}

sub _sub_340 {
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

    my $src  = _slurp_340(File::Spec->catfile('.', 'Mediabot', 'Mediabot.pm'));
    my $body = _sub_340($src, 'joinChannels');

    $assert->ok(defined $body, 'joinChannels body found');
    $assert->like($src, qr/use IO::Async::Timer::Countdown;/,
        'Mediabot.pm imports IO::Async::Timer::Countdown');

    $assert->like($body // '', qr/my\s+\$join_step\s*=\s*1\.5/,
        'joinChannels throttles JOINs with 1.5s step');
    $assert->like($body // '', qr/IO::Async::Timer::Countdown->new/s,
        'joinChannels schedules JOIN/WHO timers');
    $assert->like($body // '', qr/joinChannel\(\$self,\s*\$name,\s*\$key\)/,
        'joinChannels still uses joinChannel helper');
    $assert->like($body // '', qr/send_message\('WHO',\s*undef,\s*\$name\)/,
        'joinChannels schedules WHO after JOIN');
    $assert->like($body // '', qr/mediabot_netsplit_rejoins_total/,
        'joinChannels increments netsplit rejoin metric');
};
