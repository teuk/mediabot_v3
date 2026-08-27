use strict;
use warnings;
use utf8;

sub _slurp_977 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $mainmod = _slurp_977('Mediabot/Mediabot.pm');
    my $runtime = _slurp_977('Mediabot/VDM/Runtime.pm');
    my $source  = _slurp_977('Mediabot/VDM/Source.pm');
    my $async   = _slurp_977('Mediabot/VDM/AsyncFetcher.pm');

    $assert->like($mainmod, qr/use Mediabot::VDM::Runtime \(\);/,
        'mb704-977: core command runtime imports the VDM facade explicitly');
    $assert->like($mainmod, qr/\bvdm\s*=>\s*sub\s*\{\s*Mediabot::VDM::Runtime::mbVdm_ctx\(\$ctx\)/s,
        'mb704-977: public command map wires vdm to the dedicated runtime');
    $assert->like($mainmod, qr/^vdm\|vdm\|public\|Post one VDM/m,
        'mb704-977: internal help exposes the manual VDM command');

    $assert->like($runtime, qr/chanset_enabled\([^\n]*'VDM',\s*default\s*=>\s*0/s,
        'mb704-977: runtime uses default-off +VDM authorization');
    $assert->like($runtime, qr/my \$late_gate = \$self->_manual_gate\(\$channel\)/,
        'mb704-977: completion revalidates authorization and IRC truth');
    $assert->like($runtime, qr/vdm_repeat_window_seconds\(\)/,
        'mb704-977: runtime consumes canonical anti-repeat duration');
    $assert->unlike($runtime, qr/HTTP::Tiny|LWP::|curl\b|wget\b/i,
        'mb704-977: command runtime contains no synchronous/direct HTTP client');
    $assert->unlike($runtime, qr/\b(?:SELECT\s+.+?\s+FROM|INSERT\s+INTO|UPDATE\s+\w+\s+SET|DELETE\s+FROM)\b/is,
        'mb704-977: command runtime performs no ad-hoc SQL');

    $assert->unlike($source, qr/botPrivmsg|botNotice|do_PRIVMSG/,
        'mb704-977: source parser/fetch boundary cannot emit IRC');
    $assert->unlike($async, qr/botPrivmsg|botNotice|do_PRIVMSG/,
        'mb704-977: async worker boundary cannot emit IRC');

    my $top = _slurp_977('mediabot.pl');
    $assert->unlike($top, qr/VDM::(?:Source|AsyncFetcher)/,
        'mb704-977: top-level executable does not bypass the VDM runtime facade');
};
