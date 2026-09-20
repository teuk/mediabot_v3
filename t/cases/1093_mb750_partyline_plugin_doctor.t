# MB750 — Partyline exposes bounded, read-only API v3 diagnostic views.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

sub _slurp_1093 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;
    my $source = _slurp_1093('Mediabot/Partyline/Commands.pm');
    my ($plugins) = $source =~ /(sub _cmd_plugins \{.*?)(?=^sub _cmd_help)/ms;

    $assert->ok(defined($plugins) && length($plugins),
        'Partyline plugin command body is available');
    $assert->like($plugins, qr/\\Adoctor\\s\+\(\\S\+\)\\z/,
        'doctor is parsed as a bounded read-only view');
    $assert->like($plugins, qr/v3_diagnostic_report\(\$target\)/,
        'doctor consumes the core-owned detached report');
    $assert->like($plugins, qr/\\Apermissions\\s\+\(\\S\+\)\\z/,
        'permissions has its own read-only parser');
    $assert->like($plugins, qr/v3_permissions_report\(\$target\)/,
        'permissions consumes the effective capability intersection');
    $assert->like($plugins, qr/\\Awhy\\s\+\(\\S\+\)\\s\+\(\\S\+\)\\z/,
        'why requires exactly one plugin and one channel');
    $assert->like($plugins,
        qr/v3_channel_explanation\(\$target, \$channel\)/,
        'why consumes the core-owned channel decision');
    $assert->like($plugins, qr/plugin: runs=\$runs output=\$output/,
        'Partyline separates plugin execution from output permission');
    $assert->like($plugins, qr/migration fallback: \$fallback/,
        'Partyline renders saved-handler visibility');
    $assert->unlike($plugins, qr/\$policy->\{config\}|plugin_context/,
        'diagnostic rendering does not access config values or PluginContext');
    $assert->like($source,
        qr/\.plugins \[doctor\|permissions\|why\] - API v3 read-only diagnostics/,
        'Partyline help documents the non-mutating diagnostic surface');
};
