# t/cases/555_mb333_test_runner_isolates_exit_cases.t
# =============================================================================
# MB333 — standalone TAP files that call exit() must not terminate the shared
# test runner before later cases and the final summary are reached.
# =============================================================================

use strict;
use warnings;
use FindBin qw($Bin);
use File::Basename qw(basename);
use File::Spec;
use File::Temp qw(tempfile);

sub _run_mb333_runner {
    my ($runner, $filter) = @_;

    my $pipe = open my $fh, '-|', $^X, $runner, '--filter', $filter;
    return (255, "cannot launch runner: $!") unless $pipe;

    local $/;
    my $output = <$fh> // '';
    close $fh;

    return ($? >> 8, $output);
}

my $case = sub {
    my ($assert) = @_;

    my $root      = File::Spec->catdir($Bin, '..', '..');
    my $runner    = File::Spec->catfile($root, 't', 'test_commands.pl');
    my $cases_dir = File::Spec->catdir($root, 't', 'cases');

    my ($real_rc, $real_out) = _run_mb333_runner(
        $runner,
        '^(383_dispatch_integrity|495_mb281_scriptdryrun_command_token_contract|496_mb282_plugin_autoload_config_scalar_contract)\\.t$',
    );

    $assert->is($real_rc, 0,
        'three historical unguarded-exit cases complete successfully');
    $assert->like($real_out, qr/\[ 383_dispatch_integrity\.t \].*?\[ 495_mb281_scriptdryrun_command_token_contract\.t \].*?\[ 496_mb282_plugin_autoload_config_scalar_contract\.t \]/s,
        'runner continues past the first standalone exit case');
    $assert->like($real_out, qr/PASSED\s*:\s*57\/57/,
        'standalone TAP assertions are merged into the final summary');

    my ($pass_fh, $pass_path) = tempfile(
        'mb333_isolated_pass_XXXX',
        SUFFIX => '.t',
        DIR    => $cases_dir,
        UNLINK => 1,
    );
    print {$pass_fh} <<'PASS_CASE';
use strict;
use warnings;
print "1..2\n";
print "ok 1 - synthetic isolated pass one\n";
print "ok 2 - synthetic isolated pass two\n";
exit(0);
PASS_CASE
    close $pass_fh;

    my $pass_name = basename($pass_path);
    my ($pass_rc, $pass_out) = _run_mb333_runner(
        $runner,
        '^' . quotemeta($pass_name) . '$',
    );
    unlink $pass_path;

    $assert->is($pass_rc, 0,
        'synthetic standalone passing case returns runner success');
    $assert->like($pass_out, qr/PASSED\s*:\s*2\/2/,
        'synthetic standalone pass contributes both TAP assertions');

    my ($fail_fh, $fail_path) = tempfile(
        'mb333_isolated_fail_XXXX',
        SUFFIX => '.t',
        DIR    => $cases_dir,
        UNLINK => 1,
    );
    print {$fail_fh} <<'FAIL_CASE';
use strict;
use warnings;
print "1..2\n";
print "ok 1 - synthetic isolated pass\n";
print "not ok 2 - synthetic isolated failure\n";
exit(1);
FAIL_CASE
    close $fail_fh;

    my $fail_name = basename($fail_path);
    my ($fail_rc, $fail_out) = _run_mb333_runner(
        $runner,
        '^' . quotemeta($fail_name) . '$',
    );
    unlink $fail_path;

    $assert->is($fail_rc, 1,
        'synthetic standalone failing case propagates non-zero runner status');
    $assert->like($fail_out, qr/not ok 2 - synthetic isolated failure/,
        'standalone failure remains visible in runner output');
    $assert->like($fail_out, qr/FAILED\s*:\s*1\/2/,
        'standalone failure is included in the final failure summary');
    $assert->unlike($fail_out, qr/PASSED\s*:/,
        'failing standalone case can never produce a successful summary');

    open my $src_fh, '<:encoding(UTF-8)', $runner
        or die "cannot read $runner: $!";
    local $/;
    my $src = <$src_fh>;
    close $src_fh;

    $assert->like($src, qr/sub _case_requires_isolation \{/,
        'runner contains the standalone-exit detector');
    $assert->like($src, qr/sub _run_isolated_tap_case \{/,
        'runner contains the isolated TAP subprocess path');
    $assert->like($src, qr/_case_requires_isolation\(\$file\).*?_run_isolated_tap_case\(\$file, \$name, \$assert\).*?next;/s,
        'isolation happens before the in-process do() loader');
};

if (caller) {
    return $case;
}

# Minimal standalone harness for direct execution.
{
    package MB333::Assert;
    sub new { bless { count => 0, fail => 0 }, shift }
    sub _emit {
        my ($self, $ok, $desc, $diag) = @_;
        $self->{count}++;
        print(($ok ? 'ok ' : 'not ok ') . $self->{count} . " - $desc\n");
        print "# $diag\n" if !$ok && defined $diag && $diag ne '';
        $self->{fail}++ unless $ok;
    }
    sub is {
        my ($self, $got, $want, $desc) = @_;
        $self->_emit(defined($got) && defined($want) && $got eq $want, $desc,
            "got=" . (defined($got) ? $got : 'undef') . " expected=" . (defined($want) ? $want : 'undef'));
    }
    sub like {
        my ($self, $got, $rx, $desc) = @_;
        $self->_emit(defined($got) && $got =~ $rx, $desc, 'pattern did not match');
    }
    sub unlike {
        my ($self, $got, $rx, $desc) = @_;
        $self->_emit(!defined($got) || $got !~ $rx, $desc, 'unexpected pattern match');
    }
}

my $assert = MB333::Assert->new;
$case->($assert);
print '1..' . $assert->{count} . "\n";
exit($assert->{fail} ? 1 : 0);
