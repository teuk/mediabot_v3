# t/cases/631_mb416_precommit_audit_contracts.t
# =============================================================================
# mb416 — Independent pre-commit audit guards.
#
# 1. Facebook and X/Twitter routing is anchored to the URL host, just like the
#    mb406 Instagram/Spotify/Apple/YouTube fixes.
# 2. "ai summary public" accepts every standard IRC channel prefix.
# 3. logBotAction no longer performs a channel-id SELECT before every event;
#    the central helper owns the single SQL fallback and refreshes its DB handle.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_631 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $url = _slurp_631(File::Spec->catfile('.', 'Mediabot', 'External', 'URL.pm'));
    my ($dispatcher) = $url =~ /(sub displayUrlTitle \{.*?\n\}\n)/s;
    $dispatcher //= '';

    $assert->like($dispatcher,
        qr/m\{\\Ahttps\?:\/\/(?:\(\?:www\\\.\)\?)?facebook\\\.com/,
        'Facebook dispatcher route starts at the URL beginning');
    $assert->like($dispatcher,
        qr/m\{\\Ahttps\?:\/\/(?:\(\?:www\\\.\)\?)?\(\?:x\|twitter\)\\\.com/,
        'X/Twitter dispatcher route starts at the URL beginning');
    $assert->unlike($dispatcher,
        qr/m\{https\?:\/\/(?:\(\?:www\\\.\)\?)?facebook\\\.com/,
        'no unanchored Facebook dispatcher route remains');
    $assert->unlike($dispatcher,
        qr/m\{https\?:\/\/(?:\(\?:www\\\.\)\?)?\(\?:x\|twitter\)\\\.com/,
        'no unanchored X/Twitter dispatcher route remains');

    my $claude = _slurp_631(File::Spec->catfile('.', 'Mediabot', 'External', 'Claude.pm'));
    $assert->like($claude,
        qr/\$can_public\s*=\s*\$public_out\s*&&\s*Mediabot::Helpers::isIrcChannelTarget\(\$channel\)/,
        'summary public routing uses the shared IRC channel predicate');
    $assert->unlike($claude,
        qr/\$can_public\s*=.*?\$channel\s*=~\s*\/\^#\//,
        'summary public routing is not limited to hash channels');

    my $helpers = _slurp_631(File::Spec->catfile('.', 'Mediabot', 'Helpers.pm'));
    my ($cached) = $helpers =~ /(sub channel_id_cached \{.*?\n\}\n)/s;
    my ($log)    = $helpers =~ /(sub logBotAction \{.*?\n\}\n)/s;
    $cached //= '';
    $log    //= '';

    $assert->like($cached, qr/ensure_connected/,
        'channel-id fallback asks the DB wrapper for its current handle');
    $assert->like($cached, qr/SELECT id_channel FROM CHANNEL WHERE name = \?/,
        'central helper retains one SQL fallback');
    $assert->like($log, qr/channel_id_cached\(\$self, \$sChannel\)/,
        'logBotAction resolves the id through the central cache helper');
    $assert->unlike($log, qr/SELECT id_channel FROM CHANNEL WHERE name/,
        'logBotAction no longer selects the channel id per event');

    (my $code = $helpers) =~ s/^\s*#.*$//mg;
    my $selects = () = $code =~ /SELECT id_channel FROM CHANNEL WHERE name/g;
    $assert->is($selects, 1,
        'Helpers contains exactly one channel-name SELECT: the central fallback');

    $assert->like($url . $claude . $helpers, qr/mb416-B[123]/,
        'mb416 audit markers are present');
};
