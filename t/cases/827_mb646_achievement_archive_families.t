# t/cases/827_mb646_achievement_archive_families.t
# =============================================================================
# mb646 — legacy achievement archive discovery follows the current deployment
# family only, including numeric releases and timestamped mediabot3.old
# production archives.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use Cwd qw(getcwd);
use File::Path qw(make_path);
use File::Spec ();
use File::Temp qw(tempdir);

sub write827 {
    my ($path, $text, $mtime) = @_;
    my (undef, $dir, undef) = File::Spec->splitpath($path);
    make_path($dir) unless -d $dir;
    open my $fh, '>:raw', $path or die "$path: $!";
    print {$fh} $text;
    close $fh or die "$path: $!";
    utime($mtime, $mtime, $path) or die "utime $path: $!";
}

return sub {
    my ($assert) = @_;
    require Mediabot::Achievements;

    my $tmp = tempdir(CLEANUP => 1);
    my $orig = getcwd();
    my $path = 'var/achievements.json';

    my $v3_live = File::Spec->catdir($tmp, 'mediabot_v3');
    my $u_live  = File::Spec->catdir($tmp, 'mediabot3');
    make_path($v3_live, $u_live);

    write827(File::Spec->catfile($tmp, 'mediabot_v3.189', 'var', 'achievements.json'),
        "v3-189\n", 1000);
    write827(File::Spec->catfile($tmp, 'mediabot_v3.190', 'var', 'achievements.json'),
        "v3-190\n", 2000);
    write827(File::Spec->catfile($tmp, 'mediabot3.old.20260814_203149', 'var', 'achievements.json'),
        "u-old\n", 3000);
    write827(File::Spec->catfile($tmp, 'mediabot3.old.20260814_204112', 'var', 'achievements.json'),
        "u-new\n", 4000);
    write827(File::Spec->catfile($tmp, 'mediabot3.old.bad', 'var', 'achievements.json'),
        "bad\n", 9000);

    my $a = bless { path => $path }, 'Mediabot::Achievements';

    chdir $v3_live or die "chdir $v3_live: $!";
    my @v3 = $a->_legacy_archive_json_sources($path);

    $assert->is(scalar(@v3), 2,
        'mb646-827: numeric mediabot_v3 family yields exactly two valid sources');
    $assert->like($v3[0], qr/mediabot_v3\.190\/var\/achievements\.json\z/,
        'mb646-827: newest numeric archive is first');
    $assert->ok(!grep(/mediabot3\.old/, @v3),
        'mb646-827: dev discovery never crosses into the Undernet family');

    chdir $u_live or die "chdir $u_live: $!";
    my @u = $a->_legacy_archive_json_sources($path);

    $assert->is(scalar(@u), 2,
        'mb646-827: timestamped mediabot3.old family yields exactly two valid sources');
    $assert->like($u[0], qr/mediabot3\.old\.20260814_204112\/var\/achievements\.json\z/,
        'mb646-827: newest Undernet archive is first');
    $assert->ok(!grep(/mediabot_v3/, @u),
        'mb646-827: Undernet discovery never crosses into the dev family');
    $assert->ok(!grep(/\.old\.bad\//, @u),
        'mb646-827: malformed timestamped archive names are rejected');

    my $live = File::Spec->catfile($u_live, 'var', 'achievements.json');
    write827($live, "u-live\n", 5000);
    my @all = $a->_legacy_json_sources(include_archives => 1);

    $assert->is(scalar(@all), 3,
        'mb646-827: Undernet import sees live JSON plus its two valid archives');
    $assert->is($all[0], $path,
        'mb646-827: live JSON remains the first one-time import source');

    unlink $live;
    $assert->ok($a->_restore_legacy_from_latest_archive,
        'mb646-827: Undernet fallback restores from timestamped archives');

    open my $fh, '<:raw', File::Spec->catfile($u_live, 'var', 'achievements.json')
        or die "restored achievements: $!";
    local $/;
    my $restored = <$fh>;
    close $fh;

    $assert->is($restored, "u-new\n",
        'mb646-827: fallback restored newest Undernet state, not another family');

    chdir $orig or die "restore cwd $orig: $!";
};
