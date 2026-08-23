# t/cases/910_mb696_node_dependency_hygiene.t
# MB696 — canonical mbweb manifests are tracked; node_modules is not.

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

use File::Spec;
use JSON::PP qw(decode_json);

sub _slurp_910 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path
        or die "$path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $root = File::Spec->rel2abs(
        File::Spec->catdir($Bin, '..', '..')
    );

    my $ignore = _slurp_910(
        File::Spec->catfile($root, '.gitignore')
    );

    $assert->like(
        $ignore,
        qr/^node_modules\/$/m,
        'mb696-910: node_modules is ignored'
    );

    $assert->like(
        $ignore,
        qr/^!contrib\/mbweb\/package\.json$/m,
        'mb696-910: mbweb package.json is explicitly publishable'
    );

    $assert->like(
        $ignore,
        qr/^!contrib\/mbweb\/package-lock\.json$/m,
        'mb696-910: mbweb lockfile is explicitly publishable'
    );

    my $package = decode_json(
        _slurp_910(
            File::Spec->catfile(
                $root, 'contrib', 'mbweb', 'package.json'
            )
        )
    );

    my $lock = decode_json(
        _slurp_910(
            File::Spec->catfile(
                $root, 'contrib', 'mbweb', 'package-lock.json'
            )
        )
    );

    my @expected = sort qw(
        bcryptjs
        dotenv
        express
        express-session
        helmet
        mysql2
    );

    my @package_deps =
        sort keys %{ $package->{dependencies} || {} };

    my @lock_deps =
        sort keys %{
            $lock->{packages}{''}{dependencies} || {}
        };

    $assert->is(
        join(',', @package_deps),
        join(',', @expected),
        'mb696-910: mbweb manifest has the canonical direct dependencies'
    );

    $assert->is(
        join(',', @lock_deps),
        join(',', @expected),
        'mb696-910: lockfile root matches the manifest dependencies'
    );

    open my $git, '-|',
        'git', '-C', $root, 'ls-files'
        or die "git ls-files: $!";

    my @tracked = <$git>;
    close $git;

    chomp @tracked;

    my @vendor = grep {
        m{\Anode_modules/}
    } @tracked;

    my %tracked = map {
        $_ => 1
    } @tracked;

    $assert->is(
        scalar(@vendor),
        0,
        'mb696-910: no root node_modules file is tracked'
    );

    $assert->ok(
        $tracked{'contrib/mbweb/package.json'},
        'mb696-910: canonical mbweb package.json is tracked'
    );

    $assert->ok(
        $tracked{'contrib/mbweb/package-lock.json'},
        'mb696-910: canonical mbweb lockfile is tracked'
    );

    $assert->ok(
        !$tracked{'package.json'}
            && !$tracked{'package-lock.json'},
        'mb696-910: local root npm residue is not published'
    );
};
