# t/cases/881_mb678_partyline_boundary_closure.t
# =============================================================================
# MB678 closure: Partyline facade/core boundary contract.
#
# The parent keeps only construction, port access and runtime-status export.
# Historical methods are imported from dedicated owner modules.  This contract
# guards the final boundary without requiring Partyline.pm to become empty.
# =============================================================================
use strict;
use warnings;
use File::Spec;

sub _slurp_881 {
    my ($p) = @_;
    open my $fh, '<:encoding(UTF-8)', $p or die "$p: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $party = _slurp_881(File::Spec->catfile('.', 'Mediabot', 'Partyline.pm'));

    my %module = (
        Transport  => _slurp_881(File::Spec->catfile('.', 'Mediabot', 'Partyline', 'Transport.pm')),
        SessionAuth => _slurp_881(File::Spec->catfile('.', 'Mediabot', 'Partyline', 'SessionAuth.pm')),
        Dispatcher => _slurp_881(File::Spec->catfile('.', 'Mediabot', 'Partyline', 'Dispatcher.pm')),
        Privileged => _slurp_881(File::Spec->catfile('.', 'Mediabot', 'Partyline', 'Privileged.pm')),
        Commands   => _slurp_881(File::Spec->catfile('.', 'Mediabot', 'Partyline', 'Commands.pm')),
    );

    $assert->like($party, qr/MB678 closure: stable Partyline facade and runtime-state owner\./,
        'final Partyline facade/core role is documented');

    my @parent_subs = ($party =~ /^sub\s+(\w+)\s*\{/mg);
    $assert->is(
        join(',', @parent_subs),
        join(',', qw(new get_port _runtime_status_path _runtime_status_payload _write_runtime_status)),
        'Partyline.pm contains exactly the five final core implementations'
    );

    $assert->unlike($party, qr/^sub\s+_cmd_/m,
        'Partyline.pm contains no physical command implementation');

    for my $core (qw(new get_port _runtime_status_path _runtime_status_payload _write_runtime_status)) {
        for my $owner (sort keys %module) {
            $assert->unlike($module{$owner}, qr/^sub\s+\Q$core\E\s*\{/m,
                "$core is not duplicated in $owner");
        }
    }

    for my $owner (qw(Transport SessionAuth Dispatcher Privileged Commands)) {
        my $import_re = qr/use\s+Mediabot::Partyline::\Q$owner\E\s+qw\(\s*(.*?)\s*\);/s;
        $assert->like($party, $import_re, "$owner surface is imported into historical parent");

        $party =~ $import_re or next;
        my @symbols = grep { length } split /\s+/, $1;
        $assert->ok(scalar(@symbols) > 0, "$owner import surface is non-empty");

        for my $name (@symbols) {
            my $in_parent = () = $party =~ /^sub\s+\Q$name\E\s*\{/mg;
            my $in_owner  = () = $module{$owner} =~ /^sub\s+\Q$name\E\s*\{/mg;
            $assert->is($in_parent, 0, "$name is not physically implemented in Partyline.pm");
            $assert->is($in_owner, 1, "$name is implemented exactly once by $owner");
        }
    }

    $assert->like($party, qr/use constant MAX_PARTYLINE_LINE_BYTES => 4 \* 1024;/,
        'public Partyline line-size compatibility constant remains in parent');
    $assert->like($module{Transport}, qr/use bytes \(\);/,
        'Transport explicitly owns bytes::length dependency');
    $assert->like($module{Transport},
        qr/sub MAX_PARTYLINE_LINE_BYTES \{ Mediabot::Partyline::MAX_PARTYLINE_LINE_BYTES\(\) \}/,
        'Transport resolves line-size limit through historical public constant');

    for my $required (
        qr/use JSON qw\(encode_json\);/,
        qr/use File::Basename qw\(dirname\);/,
        qr/use File::Path qw\(make_path\);/,
        qr/use File::Temp qw\(tempfile\);/,
    ) {
        $assert->like($party, $required, 'runtime-status dependency remains in Partyline core');
    }

    for my $stale (
        'Time::HiRes', 'IO::Async::Listener', 'IO::Async::Stream',
        'IO::Async::Timer::Countdown', 'POSIX', 'Socket', 'Scalar::Util',
        'Encode', 'Mediabot::External', 'Mediabot::DCC', 'Mediabot::Helpers',
    ) {
        $assert->unlike($party, qr/^use\s+\Q$stale\E\b/m,
            "$stale is no longer a direct Partyline core dependency");
    }

    $assert->unlike($party, qr/^use\s+bytes\s+\(\);/m,
        'bytes dependency moved to Transport owner');
    $assert->unlike($party, qr/implementation moved to Mediabot::Partyline::/,
        'legacy extraction tombstones are removed from final parent');
};
