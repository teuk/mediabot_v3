# t/cases/551_mb329_calc_eval_allowlist.t
# =============================================================================
# mb329 originally added a default-deny identifier gate in front of string
# eval. MB330 supersedes that interim mitigation with Mediabot::SafeCalc, a
# parser that performs no string eval at all. This historical regression now
# verifies that every mb329 attack remains rejected after the migration.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use Mediabot::SafeCalc qw(evaluate_expression);
use File::Spec;

sub _rejected_551 {
    my ($expression) = @_;
    my $ok = eval { evaluate_expression($expression); 1 };
    return $ok ? 0 : 1;
}

sub _slurp_551 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    for my $bad (
        'kill(9,-1)', 'sleep(99999999)', 'fork()', 'unlink(passwd)',
        '9x999999', 'system(ls)', 'chr(65)', 'exec(sh)', 'rmdir(foo)',
        'chdir(bar)', 'eval(2)',
    ) {
        $assert->ok(_rejected_551($bad), "mb329 attack remains rejected: $bad");
    }

    my $db = _slurp_551(File::Spec->catfile('.', 'Mediabot', 'DBCommands.pm'));
    my $safe = _slurp_551(File::Spec->catfile('.', 'Mediabot', 'SafeCalc.pm'));

    $assert->like($db, qr/use Mediabot::SafeCalc/, 'DBCommands imports SafeCalc');
    $assert->unlike($db, qr/eval\s+\$expr\b/, 'DBCommands no longer string-evals calc input');
    $assert->unlike($safe, qr/eval\s+\$\w+\b/, 'SafeCalc contains no string eval');
    $assert->like($db, qr/mb330-B1/, 'mb330 migration marker is present');
};
