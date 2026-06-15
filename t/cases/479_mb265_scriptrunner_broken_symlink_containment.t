use strict;
use warnings;
use utf8;

use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd ();

use Mediabot::ScriptRunner;

my $tmp = tempdir(CLEANUP => 1);
my $script_dir = "$tmp/scripts";
make_path($script_dir);

my $runner = Mediabot::ScriptRunner->new(script_dir => $script_dir);

my ($ok, $err, $lang, $full_path) = $runner->validate_script_path('future.pl');
ok($ok, 'future top-level script path remains accepted');
is($err, undef, 'future top-level path has no validation error');
is($lang, 'perl', 'future top-level script resolves perl language');
like($full_path, qr{/scripts/future\.pl\z}, 'future top-level full path stays under script_dir');

make_path("$script_dir/examples");
($ok, $err, $lang, $full_path) = $runner->validate_script_path('examples/new_script.py');
ok($ok, 'future script under existing internal directory remains accepted');
is($lang, 'python', 'future nested script resolves python language');

my $outside_dir = "$tmp/outside";
make_path($outside_dir);
symlink($outside_dir, "$script_dir/evil_existing") or die "symlink existing outside failed: $!";
($ok, $err) = $runner->validate_script_path('evil_existing/new.pl');
ok(!$ok, 'symlinked existing directory ancestor is rejected');
is($err, 'script path escapes script directory', 'existing symlink escape reports containment error');

symlink("$tmp/target_that_does_not_exist_yet", "$script_dir/evil_broken") or die "symlink broken failed: $!";
($ok, $err) = $runner->validate_script_path('evil_broken/later.pl');
ok(!$ok, 'broken symlink directory ancestor is rejected');
like($err, qr/^(?:unable to resolve script path|script path escapes script directory)$/, 'broken symlink ancestor is not treated as a safe future path');

my $outside_file = "$outside_dir/outside.pl";
open my $ofh, '>', $outside_file or die "write outside script failed: $!";
print {$ofh} "print qq(outside\\n);\n";
close $ofh;
symlink($outside_file, "$script_dir/linked_file.pl") or die "symlink file failed: $!";
($ok, $err) = $runner->validate_script_path('linked_file.pl');
ok(!$ok, 'symlinked script file escaping script_dir is rejected');
is($err, 'script path escapes script directory', 'symlinked script file reports containment error');

my $inside_real_dir = "$script_dir/real_inside";
make_path($inside_real_dir);
symlink($inside_real_dir, "$script_dir/inside_link") or die "symlink inside failed: $!";
($ok, $err, $lang, $full_path) = $runner->validate_script_path('inside_link/future.tcl');
ok($ok, 'symlinked internal directory remains accepted');
is($err, undef, 'internal symlink directory has no validation error');
is($lang, 'tcl', 'internal symlink future path resolves tcl language');

my $source = do {
    open my $fh, '<', 'Mediabot/ScriptRunner.pm' or die $!;
    local $/;
    <$fh>;
};
like($source, qr/mb265-B1/, 'ScriptRunner source contains mb265 broken symlink marker');
unlike($source, qr/\bsystem\s*\(/, 'mb265 containment guard does not introduce system()');

done_testing();
