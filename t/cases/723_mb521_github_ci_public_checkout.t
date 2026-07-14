# t/cases/723_mb521_github_ci_public_checkout.t
use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;

my $root = File::Spec->rel2abs("$Bin/../..");

sub _mb521_read {
    my ($rel) = @_;
    my $path = File::Spec->catfile($root, split m{/}, $rel);
    open my $fh, '<', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $runner = _mb521_read('t/test_commands.pl');
    my $t519   = _mb521_read('t/cases/519_mb297_commit_secret_scanner_precision.t');
    my $t521   = _mb521_read('t/cases/521_mb299_calc_route_config_contract.t');
    my $t702   = _mb521_read('t/cases/702_mb492_url_rich_badges.t');

    $assert->like(
        $runner,
        qr/local \$SIG\{__WARN__\} = \\&_filter_case_load_warning;\s*\$code = do \$file;/s,
        'runner suppresses known helper redefinitions before do() loads a case',
    );
    $assert->like(
        $t519,
        qr/unless \(-f \$commit\).*commit\.sh is local-only and absent from the public checkout/s,
        'secret-scanner maintainer test accepts a public checkout without commit.sh',
    );
    $assert->like(
        $t521,
        qr/my \$commit = -f \$commit_path \? slurp\('commit\.sh'\) : undef;/,
        'calc contract loads local commit.sh only when it exists',
    );
    $assert->like(
        $t521,
        qr/SKIP:\s*\{\s*skip 'commit\.sh is a local-only maintainer tool', 2 unless defined \$commit;/s,
        'calc contract skips only the two private maintainer assertions',
    );
    $assert->like(
        $t702,
        qr/package F702;.*status => 503, reason => 'offline fixture'/s,
        'X regression has an explicit offline HTTP failure fixture',
    );
    my $offline_mocks = () = $t702 =~ /local \*Mediabot::External::_make_http = sub \{ F702->new \};/g;
    $assert->is($offline_mocks, 3, 'all three X fixtures block live fxtwitter access');
};
