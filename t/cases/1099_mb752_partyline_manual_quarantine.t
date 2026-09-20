# MB752 — Partyline quarantine controls are explicit, Owner-only and bounded.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

sub _slurp_1099 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;
    my $source = _slurp_1099('Mediabot/Partyline/Commands.pm');
    my ($plugins) = $source =~ /(sub _cmd_plugins \{.*?)(?=^sub _cmd_help)/ms;

    $assert->like($plugins,
        qr/loadv3\|policy\|resetpolicy\|quarantine\|unquarantine/,
        'quarantine mutations share the explicit API v3 Owner gate');
    $assert->like($plugins,
        qr/if \(\$verb eq 'quarantine' \|\| \$verb eq 'unquarantine'\)/,
        'quarantine and release use one exact bounded parser');
    $assert->like($plugins,
        qr/set_v3_quarantine\(\s*\$target, lc\(\$kind\), \$resource, \$channel\)/s,
        'quarantine delegates to the core-owned manager registry');
    $assert->like($plugins,
        qr/reset_v3_quarantine\(\s*\$target, lc\(\$kind\), \$resource, \$channel\)/s,
        'release delegates to the core-owned manager registry');
    $assert->like($plugins, qr/\\Aquarantines\\s\+\(\\S\+\)\\z/,
        'quarantines is a separate read-only report');
    $assert->like($plugins, qr/v3_quarantine_report\(\$target\)/,
        'read-only view consumes only the detached quarantine report');
    $assert->like($plugins, qr/splice\(\@entries, 10\)/,
        'Partyline quarantine listing is capped at ten entries');
    $assert->unlike($plugins,
        qr/(?:total_failures|active_streaks).*set_v3_quarantine/s,
        'failure counters never trigger quarantine automatically');
    $assert->like($source,
        qr/\.plugins \[quarantine\|unquarantine\] - Owner-only API v3 resource isolation/,
        'Partyline help separates mutation from read-only diagnostics');
    $assert->like($source,
        qr/doctor\|failures\|quarantines\|permissions\|why/,
        'Partyline help includes the read-only quarantine view');
};
