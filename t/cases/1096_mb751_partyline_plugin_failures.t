# MB751 — Partyline failure history stays read-only, bounded and non-sensitive.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

sub _slurp_1096 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;
    my $source = _slurp_1096('Mediabot/Partyline/Commands.pm');
    my ($plugins) = $source =~ /(sub _cmd_plugins \{.*?)(?=^sub _cmd_help)/ms;

    $assert->like($plugins, qr/\\Afailures\\s\+\(\\S\+\)\\z/,
        'failures accepts exactly one plugin name');
    $assert->like($plugins, qr/v3_failure_report\(\$target\)/,
        'Partyline consumes only the detached manager report');
    $assert->like($plugins, qr/reverse \@\{ \$report->\{recent\} \}/,
        'latest failure is rendered first');
    $assert->like($plugins, qr/splice\(\@recent, 5\)/,
        'Partyline output is capped at five records');
    $assert->like($plugins, qr/fingerprint=\$failure->\{fingerprint\}/,
        'failure records expose only their non-sensitive fingerprint');
    $assert->unlike($plugins, qr/\$failure->\{(?:error|message|exception)\}/,
        'failure rendering has no raw error field');
    $assert->unlike($plugins, qr/clear.*failure|reset.*failure/i,
        'read-only failure view has no remediation control');
};
