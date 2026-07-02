#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Copy qw(copy);
use Cwd qw(abs_path);

my $root = abs_path('.') || '.';
my $cpan_script = "$root/install/cpan_install.sh";
my $configure = "$root/configure";

ok(-f $cpan_script, 'cpan installer exists');
ok(-f $configure, 'configure exists');

my $cpan_src = do {
    open my $fh, '<', $cpan_script or die $!;
    local $/;
    <$fh>;
};
my $configure_src = do {
    open my $fh, '<', $configure or die $!;
    local $/;
    <$fh>;
};

like($cpan_src, qr/^umask 022$/m,
    'CPAN installer forces readable module-install permissions');
like($cpan_src, qr/chmod 0600 "\$SCRIPT_LOGFILE" "\$CPAN_LOGFILE"/,
    'CPAN logs remain private despite the module-install umask');
like($cpan_src, qr/--verify-only/,
    'CPAN installer exposes a non-root verification mode');
like($cpan_src, qr/for perl_module in strict warnings "\$\{PERL_MODULES\[@\]\}"/,
    'runtime verification includes core pragmas and the complete module list');
unlike($cpan_src, qr/\b(?:apt|apt-get|dpkg|dnf|yum)\b/,
    'CPAN installer still contains no system-package command');

like($configure_src,
    qr/sudo "\$INSTALL_DIR\/cpan_install\.sh".*?"\$INSTALL_DIR\/cpan_install\.sh" --verify-only/s,
    'configure verifies modules again as the non-root caller after sudo CPAN');
like($configure_src, qr/mb381-B1/,
    'configure carries the MB381 runtime-user verification marker');
like($cpan_src, qr/mb381-B1/,
    'CPAN installer carries the MB381 permission marker');

my $tmp = tempdir(CLEANUP => 1);
my $install = "$tmp/install";
my $outside = "$tmp/outside";
my $fakebin = "$tmp/fakebin";
my $fake_lib = "$tmp/site-lib";
make_path($install, $outside, $fakebin, $fake_lib);
copy($cpan_script, "$install/cpan_install.sh") or die $!;
chmod 0755, "$install/cpan_install.sh";

open my $helper, '>', "$install/install_perl_module.sh" or die $!;
print {$helper} <<'SH';
#!/usr/bin/env bash
set -eu
mkdir -p "$MB381_FAKE_LIB/IO/Async"
: > "$MB381_FAKE_LIB/IO/Async/Loop.pm"
printf '%s\n' "$1" >> "$(dirname "$0")/helper.modules"
touch "$(dirname "$0")/io_async.installed"
SH
close $helper;
chmod 0755, "$install/install_perl_module.sh";

open my $perl, '>', "$fakebin/perl" or die $!;
print {$perl} <<'SH';
#!/usr/bin/env bash
set -eu
case "$*" in
  *'-MIO::Async::Loop'*)
    [ -f "${MB381_INSTALL_DIR}/io_async.installed" ] || exit 1
    ;;
esac
exit 0
SH
close $perl;
chmod 0755, "$fakebin/perl";

for my $name (qw(cpan wget tar chown make)) {
    open my $fh, '>', "$fakebin/$name" or die $!;
    print {$fh} "#!/usr/bin/env bash\nexit 0\n";
    close $fh;
    chmod 0755, "$fakebin/$name";
}

open my $id, '>', "$fakebin/id" or die $!;
print {$id} <<'SH';
#!/usr/bin/env bash
set -eu
case "${1:-}" in
  -u)  printf '%s\n' "${MB381_FAKE_UID:-0}" ;;
  -un) printf '%s\n' "${MB381_FAKE_USER:-root}" ;;
  *)   exit 1 ;;
esac
SH
close $id;
chmod 0755, "$fakebin/id";

my $old_umask = umask 0077;
my $cmd = join ' ',
    'cd', quotemeta($outside), '&&',
    'PATH=' . quotemeta($fakebin) . ':$PATH',
    'MB381_FAKE_UID=0',
    'MB381_FAKE_USER=root',
    'MB381_INSTALL_DIR=' . quotemeta($install),
    'MB381_FAKE_LIB=' . quotemeta($fake_lib),
    quotemeta("$install/cpan_install.sh"),
    '>', quotemeta("$tmp/install.stdout"), '2>&1';
my $rc = system('bash', '-c', $cmd);
umask $old_umask;

is($rc, 0, 'CPAN installation succeeds under an inherited umask 077');
ok(-f "$fake_lib/IO/Async/Loop.pm", 'fake CPAN helper created a module file');

my $dir_mode = (stat("$fake_lib/IO/Async"))[2] & 07777;
my $file_mode = (stat("$fake_lib/IO/Async/Loop.pm"))[2] & 07777;
is(sprintf('%04o', $dir_mode), '0755',
    'CPAN-created module directory remains traversable by runtime users');
is(sprintf('%04o', $file_mode), '0644',
    'CPAN-created module file remains readable by runtime users');

my $helper_before = 0;
if (open my $fh, '<', "$install/helper.modules") {
    $helper_before++ while <$fh>;
    close $fh;
}

my $verify_cmd = join ' ',
    'cd', quotemeta($outside), '&&',
    'PATH=' . quotemeta($fakebin) . ':$PATH',
    'MB381_FAKE_UID=1000',
    'MB381_FAKE_USER=mediabot',
    'MB381_INSTALL_DIR=' . quotemeta($install),
    'MB381_FAKE_LIB=' . quotemeta($fake_lib),
    quotemeta("$install/cpan_install.sh"), '--verify-only',
    '>', quotemeta("$tmp/verify.stdout"), '2>&1';
my $verify_rc = system('bash', '-c', $verify_cmd);
is($verify_rc, 0, 'verify-only mode succeeds without root');

my $helper_after = 0;
if (open my $fh, '<', "$install/helper.modules") {
    $helper_after++ while <$fh>;
    close $fh;
}
is($helper_after, $helper_before,
    'verify-only mode never invokes the installation helper');

my $verify_output = do {
    open my $fh, '<', "$tmp/verify.stdout" or die $!;
    local $/;
    <$fh>;
};
like($verify_output, qr/Verify Perl modules as user mediabot/,
    'runtime verification identifies the non-root Mediabot user');
like($verify_output, qr/Perl modules are readable by the current user/,
    'runtime verification reports successful readability');

done_testing();
