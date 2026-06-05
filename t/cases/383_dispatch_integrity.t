#!/usr/bin/env perl
use strict;
use warnings;
use feature qw(say);

use File::Find;
use File::Spec;
use FindBin qw($Bin);

my $root = File::Spec->catdir($Bin, '..', '..');

my $mediabot_pm = File::Spec->catfile($root, 'Mediabot', 'Mediabot.pm');
my $usercmd_pm  = File::Spec->catfile($root, 'Mediabot', 'UserCommands.pm');
my $modules_dir = File::Spec->catdir($root, 'Mediabot');

sub slurp {
    my ($file) = @_;
    open my $fh, '<', $file or die "Cannot open $file: $!";
    local $/;
    return <$fh>;
}

my $mb = slurp($mediabot_pm);
my $uc = slurp($usercmd_pm);

my @module_files;
find(
    sub {
        return unless -f $_;
        return unless $_ =~ /\.pm\z/;
        push @module_files, $File::Find::name;
    },
    $modules_dir
);

my $all_modules_code = '';
for my $file (@module_files) {
    $all_modules_code .= "\n# FILE: $file\n";
    $all_modules_code .= slurp($file);
}

my @important_cmds = qw(
    achievements
    profil
    radar
    dashboard
    duel
    horoscope
    compat
    quotegame
    mood
    leaderboard
    chronos
    features
    capabilities
    caps
    observatory
    obs
);

my $planned = 13 + scalar(@important_cmds);
say "1..$planned";

my $tests = 0;
my $fail  = 0;

sub ok {
    my ($cond, $name) = @_;
    $tests++;

    $name = 'unnamed test' unless defined $name && $name ne '';

    if ($cond) {
        say "ok $tests - $name";
    } else {
        say "not ok $tests - $name";
        $fail++;
    }
}

# ---------------------------------------------------------------------------
# 1. Extract the public command dispatch hash.
# ---------------------------------------------------------------------------
my ($dispatch_body) = $mb =~ /my\s+%command_map\s*=\s*\((.*?)\n\s*\);/s;

ok(defined $dispatch_body, 'public command_map found in Mediabot.pm');

$dispatch_body //= '';

my @keys = $dispatch_body =~ /^\s*'?([A-Za-z0-9_]+)'?\s*=>/gm;

ok(@keys > 20, 'public command_map contains command entries');

# ---------------------------------------------------------------------------
# 2. No duplicate keys.
# ---------------------------------------------------------------------------
my %seen;
my @dups;

for my $k (@keys) {
    push @dups, $k if $seen{$k}++;
}

ok(!@dups, 'no duplicate public command keys');

if (@dups) {
    say "# duplicate keys: " . join(', ', sort @dups);
}

# ---------------------------------------------------------------------------
# 3. Historical !top must remain mapped to mbTop_ctx.
# ---------------------------------------------------------------------------
ok(
    $dispatch_body =~ /^\s*top\s*=>\s*sub\s*\{\s*mbTop_ctx\(\$ctx\)\s*\}/m,
    'historical !top maps to mbTop_ctx'
);

ok(
    $dispatch_body !~ /^\s*top\s*=>\s*sub\s*\{\s*mbLeaderboard_ctx\(\$ctx\)\s*\}/m,
    '!top is not stolen by leaderboard'
);

# ---------------------------------------------------------------------------
# 4. Leaderboard / Chronos aliases.
# ---------------------------------------------------------------------------
ok(
    $dispatch_body =~ /^\s*leaderboard\s*=>\s*sub\s*\{\s*mbLeaderboard_ctx\(\$ctx\)\s*\}/m,
    '!leaderboard maps to mbLeaderboard_ctx'
);

ok(
    $dispatch_body =~ /^\s*lb\s*=>\s*sub\s*\{\s*mbLeaderboard_ctx\(\$ctx\)\s*\}/m,
    '!lb maps to mbLeaderboard_ctx'
);

ok(
    $dispatch_body =~ /^\s*chronos\s*=>\s*sub\s*\{\s*mbChronos_ctx\(\$ctx\)\s*\}/m,
    '!chronos maps to mbChronos_ctx'
);

ok(
    $dispatch_body =~ /^\s*chrono\s*=>\s*sub\s*\{\s*mbChronos_ctx\(\$ctx\)\s*\}/m,
    '!chrono maps to mbChronos_ctx'
);

ok(
    $dispatch_body =~ /^\s*timeline\s*=>\s*sub\s*\{\s*mbChronos_ctx\(\$ctx\)\s*\}/m,
    '!timeline maps to mbChronos_ctx'
);

ok(
    $dispatch_body =~ /^\s*features\s*=>\s*sub\s*\{\s*mbFeatures_ctx\(\$ctx\)\s*\}/m,
    '!features maps to mbFeatures_ctx'
);

ok(
    $dispatch_body =~ /^\s*capabilities\s*=>\s*sub\s*\{\s*mbFeatures_ctx\(\$ctx\)\s*\}/m,
    '!capabilities maps to mbFeatures_ctx'
);

ok(
    $dispatch_body =~ /^\s*caps\s*=>\s*sub\s*\{\s*mbFeatures_ctx\(\$ctx\)\s*\}/m,
    '!caps maps to mbFeatures_ctx'
);

ok(
    $dispatch_body =~ /^\s*observatory\s*=>\s*sub\s*\{\s*mbObservatory_ctx\(\$ctx\)\s*\}/m,
    '!observatory maps to mbObservatory_ctx'
);

ok(
    $dispatch_body =~ /^\s*obs\s*=>\s*sub\s*\{\s*mbObservatory_ctx\(\$ctx\)\s*\}/m,
    '!obs maps to mbObservatory_ctx'
);

# ---------------------------------------------------------------------------
# 5. Required UserCommands handlers are exported.
# ---------------------------------------------------------------------------
my ($export_body) = $uc =~ /our\s+\@EXPORT\s*=\s*qw\((.*?)\n\);/s;

ok(defined $export_body, '@EXPORT block found in UserCommands.pm');

$export_body //= '';

my %exports = map { $_ => 1 } ($export_body =~ /\b([A-Za-z0-9_]+)\b/g);

my @required_exports = qw(
    mbAchievements_ctx
    mbProfil_ctx
    mbRadar_ctx
    mbDashboard_ctx
    mbDuel_ctx
    mbHoroscope_ctx
    mbCompat_ctx
    mbQuotegame_ctx
    checkQuotegameAnswer
    mbMood_ctx
    mbLeaderboard_ctx
    mbChronos_ctx
    mbFeatures_ctx
    mbObservatory_ctx
);

my @missing_exports = grep { !$exports{$_} } @required_exports;

ok(!@missing_exports, 'all mb115-mb118 UserCommands handlers are exported');

if (@missing_exports) {
    say "# missing exports: " . join(', ', @missing_exports);
}

# ---------------------------------------------------------------------------
# 6. Every mb*_ctx call in public dispatch has a visible sub definition in
#    one of the Mediabot/*.pm modules.
# ---------------------------------------------------------------------------
my @called_ctx = $dispatch_body =~ /\b(mb[A-Za-z0-9_]+_ctx)\s*\(\$ctx\)/g;
my %called_ctx = map { $_ => 1 } @called_ctx;

my @missing_subs = grep {
    my $fn = $_;
    $all_modules_code !~ /sub\s+\Q$fn\E\b/
} sort keys %called_ctx;

ok(!@missing_subs, 'all public dispatch mb*_ctx handlers have visible sub definitions in Mediabot modules');

if (@missing_subs) {
    say "# missing sub definitions in Mediabot/*.pm: " . join(', ', @missing_subs);
}

# ---------------------------------------------------------------------------
# 7. Important social commands are present.
# ---------------------------------------------------------------------------
for my $cmd (@important_cmds) {
    ok(
        scalar(grep { $_ eq $cmd } @keys),
        "public command '$cmd' exists"
    );
}

exit($fail ? 1 : 0);
