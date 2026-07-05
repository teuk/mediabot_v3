# t/cases/669_mb456_precommit_audit_fixes.t
# =============================================================================
# mb456 — Independent pre-commit audit after mb455.
#
# Closes three gaps found in the fresh snapshot:
#   1. !note export/search did not load persisted notes after a restart.
#   2. The mb449 startup integrity guard could silently succeed after an
#      unreadable/empty self-scan ("0 methods resolved OK").
#   3. lifecycle_check.sh used plain `wait` under `set -e`; the expected
#      non-zero exit of the refused second instance aborted the test itself.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_669 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $uc = _slurp_669(File::Spec->catfile('.', 'Mediabot', 'UserCommands.pm'));
    my ($note) = $uc =~ /(sub mbNote_ctx \{.*?\n\}\n)/s;
    $note //= '';
    $assert->ok($note ne '', 'mbNote_ctx extracted');
    my $load_pos   = index($note, '_notes_ensure_loaded($self, $nick);');
    my $export_pos = index($note, q{if ($text =~ /^export$/i)});
    my $search_pos = index($note, q{if ($text =~ /^search\s+(.+)/i)});
    my $cap_pos    = index($note, q{>= 10});
    $assert->ok($load_pos >= 0, 'mbNote_ctx loads persisted notes');
    $assert->ok($load_pos < $export_pos, 'load occurs before export');
    $assert->ok($load_pos < $search_pos, 'load occurs before search');
    $assert->ok($load_pos < $cap_pos, 'load occurs before the add cap');
    my $load_count = () = $note =~ /_notes_ensure_loaded\(\$self, \$nick\);/g;
    $assert->is($load_count, 1, 'one shared load call covers all note branches');
    $assert->like($note, qr/mb456-B1/, 'notes audit tag present');

    my $main = _slurp_669('mediabot.pl');
    $assert->like($main, qr/my \$self_source = __FILE__;/,
        'integrity scan is anchored to the compiled source file');
    $assert->like($main, qr/my \$fh_self;\s+unless \(open \$fh_self, '<', \$self_source\)/s,
        'filehandle is declared in the enclosing scope before open');
    $assert->like($main, qr/unless \(open \$fh_self, '<', \$self_source\).*?exit 1;/s,
        'unreadable source fails closed');
    $assert->like($main, qr/unless \(keys %called_methods\).*?exit 1;/s,
        'empty method inventory fails closed');
    $assert->unlike($main, qr/if \(open my \$fh_self, '<', \$0\)/,
        'old fail-open $0 scan removed');
    $assert->unlike($main, qr/unless \(open my \$fh_self/,
        'filehandle is not scoped only to the open condition');
    $assert->like($main, qr/mb456-B2/, 'integrity audit tag present');

    my $life = _slurp_669(File::Spec->catfile('.', 't', 'live', 'lifecycle_check.sh'));
    $assert->like($life,
        qr/if wait "\$\{BOT2_PID\}" 2>\/dev\/null; then rc2=0; else rc2=\$\?; fi/,
        'double-instance exit code captured safely under set -e');
    $assert->like($life,
        qr/if wait "\$\{BOT_PID\}" 2>\/dev\/null; then rc1=0; else rc1=\$\?; fi/,
        'shutdown exit code captured safely under set -e');
    $assert->unlike($life, qr/wait "\$\{BOT2_PID\}" 2>\/dev\/null; local rc2=/,
        'unsafe plain wait pattern removed');
    $assert->like($life, qr/mb456-B3/, 'lifecycle audit tag present');
};
