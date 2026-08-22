# t/cases/884_mb682_public_docs_architecture_sync.t
# =============================================================================
# mb682 — public docs must describe the current 3.4dev architecture/workflows.
#
# This is intentionally documentation-only. It locks the pieces that changed
# materially after mb671 so README/CHANGELOG cannot silently fall behind again.
# =============================================================================

use strict;
use warnings;
use utf8;

return sub {
    my ($assert) = @_;

    sub slurp884 {
        my ($path) = @_;
        open my $fh, '<:raw', $path or die "$path: $!";
        local $/;
        return <$fh>;
    }

    my $readme = slurp884('README.md');
    my $change = slurp884('CHANGELOG.md');
    my $arch   = slurp884('docs/PARTYLINE_ARCHITECTURE.md');

    for my $mb (qw(672 673 675 676 677 678 679 680 681)) {
        $assert->like(
            $change,
            qr/^###\s+mb\Q$mb\E\b/m,
            "mb682-884: CHANGELOG documents mb$mb"
        );
    }

    $assert->like(
        $readme,
        qr/test_commands\.pl\s+--fast\s+--progress/,
        'mb682-884: README documents fast progress mode'
    );
    $assert->like(
        $readme,
        qr/test_commands\.pl\s+--progress/,
        'mb682-884: README documents full progress mode'
    );
    $assert->like(
        $readme,
        qr/update status.*local-only/is,
        'mb682-884: README documents local-only update status'
    );
    $assert->like(
        $readme,
        qr/\.mediabot_v3\.update-status\.json/,
        'mb682-884: README documents durable updater record location'
    );
    $assert->like(
        $readme,
        qr/Partyline architecture.*docs\/PARTYLINE_ARCHITECTURE\.md/is,
        'mb682-884: README links the Partyline architecture document'
    );

    for my $module (qw(
        Mediabot::Partyline
        Mediabot::Partyline::Transport
        Mediabot::Partyline::SessionAuth
        Mediabot::Partyline::Dispatcher
        Mediabot::Partyline::Commands
        Mediabot::Partyline::Privileged
    )) {
        $assert->like(
            $arch,
            qr/\Q$module\E/,
            "mb682-884: Partyline architecture documents $module"
        );
    }

    $assert->like(
        $arch,
        qr/No physical `_cmd_\*` implementation belongs in the parent/,
        'mb682-884: architecture locks command-free Partyline parent'
    );
    $assert->like(
        $arch,
        qr/881_mb678_partyline_boundary_closure\.t/,
        'mb682-884: architecture links final MB678 boundary contract'
    );
    $assert->like(
        $arch,
        qr/mediabot\.log/,
        'mb682-884: Partyline validation documents application-log first'
    );
};
