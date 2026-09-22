# MB764 — Partyline renders the bounded API v3 portfolio read-only.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

sub slurp_1130 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;
    my $commands = slurp_1130('Mediabot/Partyline/Commands.pm');
    my ($plugins) = $commands =~
        /(sub _cmd_plugins \{.*?)(?=^sub _cmd_help)/ms;
    my ($help) = $commands =~ /(sub _cmd_help \{.*?^\})/ms;
    my ($overview) = $plugins =~
        /(if \(\$mode eq 'overviewv3'\).*?)(?=^    if \(\$mode =~ \/\\Adoctor)/ms;

    $assert->ok(defined($plugins), 'plugins command block is present');
    $assert->ok(defined($overview), 'overview branch is present');
    $assert->like($plugins, qr/\$mode eq 'overviewv3'/,
        'overviewv3 has a dedicated read-only branch');
    $assert->like($plugins, qr/\$pm->v3_portfolio_report/,
        'Partyline delegates portfolio truth to PluginManager');
    $assert->like($plugins,
        qr/API v3 overview: discovered=.*?active_channels=/s,
        'overview prints one compact aggregate line');
    $assert->like($plugins,
        qr/source=.*?lifecycle=.*?status=.*?reason=.*?policies=/s,
        'each package line explains source, state and policy counts');
    $assert->like($plugins, qr/additional package\(s\) omitted/,
        'Partyline reports bounded truncation explicitly');
    $assert->unlike($overview,
        qr/(?:package_dir|channel_policy|config)/,
        'overview branch does not render paths or policy configuration');
    $assert->like($plugins, qr/\|overviewv3\]/,
        'usage advertises the consolidated view');
    $assert->like($help,
        qr/\.plugins \[overviewv3\] - bounded API v3 installed\/active portfolio/,
        'Partyline help advertises the read-only overview');
};
