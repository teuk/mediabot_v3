# t/cases/556_mb335_test_runner_contract_isolation.t
use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;

return sub {
    my ($assert) = @_;

    my $root   = File::Spec->rel2abs("$Bin/../..");
    my $runner = File::Spec->catfile($root, 't', 'test_commands.pl');

    my $filter = join('|', qw(
        412_mb173_partyline_plugins_status
        413_mb174_script_runner_foundation
        434_mb196_scriptdryrun_observability_examples
        472_mb224_action_runner_generic_error_fallback
        530_mb308_chromium_reap_status
        532_mb310_radio_cancel_reap
        542_mb320_youtube_search_async_nonblocking
    ));
    $filter = '^(?:' . $filter . ')\\.t$';

    my $pid = open(my $fh, '-|', $^X, $runner, '--filter', $filter, '--verbose');
    if (!defined $pid) {
        $assert->fail('MB335 can launch the mixed-contract runner probe');
        return;
    }

    local $/;
    my $output = <$fh> // '';
    close $fh;
    my $rc = $? >> 8;

    $assert->is($rc, 0,
        'mixed closure and standalone TAP contracts complete successfully');
    my ($passed, $total) = $output =~ /PASSED\s*:\s*(\d+)\/(\d+)/;
    $assert->ok(defined($passed) && defined($total),
        'mixed-contract probe emits a PASSED summary');
    $assert->is($passed, $total,
        'mixed-contract probe reports every assertion as passed');
    $assert->unlike($output, qr/done_testing\(\) was already called/,
        'Test::Builder state cannot leak from test 412');
    $assert->unlike($output, qr/434_mb196_scriptdryrun_observability_examples\.t: isolated TAP parse/,
        'legacy planless TAP remains accepted when assertions are present');
    $assert->unlike($output, qr/530_mb308_chromium_reap_status\.t: isolated/,
        'test 530 remains on the native closure path');
    $assert->unlike($output, qr/532_mb310_radio_cancel_reap\.t: isolated/,
        'test 532 remains on the native closure path');
    $assert->unlike($output, qr/production fallback is documented.*\[FAIL\]/s,
        'YouTube fallback marker accepts the active MB323 restoration');

    open my $src_fh, '<:encoding(UTF-8)', $runner
        or die "cannot read $runner: $!";
    local $/;
    my $src = <$src_fh>;
    close $src_fh;

    $assert->like($src, qr/use TAP::Parser;/,
        'standalone TAP output is parsed with TAP::Parser');
    $assert->like($src, qr/MB335: classify by the file contract/,
        'runner documents contract-based classification');
    $assert->like($src, qr/Native runner cases return a closure directly/,
        'runner recognizes native return-sub contracts');
    $assert->like($src, qr/standalone TAP contract/,
        'all non-closure files are isolated as standalone TAP');
};
