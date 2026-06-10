# t/cases/395_mb144_no_orphan_claude_duplicate.t
use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;
use File::Find;

my $case = sub {
    my ($assert) = @_;

    my $root = File::Spec->catdir($Bin, '..', '..');
    my $mediabot_dir = File::Spec->catdir($root, 'Mediabot');

    my @claude_package_files;
    find(
        sub {
            return unless -f $_;
            return unless $_ =~ /\.pm\z/;

            my $path = $File::Find::name;
            open my $fh, '<', $path
                or do { $assert->(0, "cannot open $path: $!"); return; };
            my $first_chunk = do { local $/; <$fh> };
            close $fh;

            if ($first_chunk =~ /^\s*package\s+Mediabot::External::Claude\s*;/m) {
                my $rel = File::Spec->abs2rel($path, $root);
                $rel =~ s{\\}{/}g;
                push @claude_package_files, $rel;
            }
        },
        $mediabot_dir,
    );

    @claude_package_files = sort @claude_package_files;

    $assert->(@claude_package_files == 1,
        'exactly one file declares package Mediabot::External::Claude');
    $assert->((@claude_package_files && $claude_package_files[0] eq 'Mediabot/External/Claude.pm'),
        'Claude package lives only in Mediabot/External/Claude.pm');

    my $orphan = File::Spec->catfile($root, 'Mediabot', 'Claude.pm');
    $assert->(!-e $orphan,
        'orphan Mediabot/Claude.pm is absent');

    my $external_file = File::Spec->catfile($root, 'Mediabot', 'External.pm');
    open my $efh, '<', $external_file
        or do { $assert->(0, "cannot open External.pm: $!"); return; };
    my $external_src = do { local $/; <$efh> };
    close $efh;

    $assert->($external_src =~ /require\s+Mediabot::External::Claude\s*;/,
        'External.pm requires Mediabot::External::Claude canonically');
    $assert->($external_src !~ /require\s+Mediabot::Claude\s*;/,
        'External.pm does not require orphan Mediabot::Claude');
};

if (caller) { return $case; }

my $tests = 0;
my $fail  = 0;

my $assert = sub {
    my ($ok, $name) = @_;
    $tests++;
    $name = 'unnamed assertion' unless defined $name && $name ne '';

    if ($ok) {
        print "ok $tests - $name\n";
    }
    else {
        print "not ok $tests - $name\n";
        $fail++;
    }
};

$case->($assert);
print "1..$tests\n";
exit($fail ? 1 : 0);
