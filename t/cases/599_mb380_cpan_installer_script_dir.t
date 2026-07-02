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

like($cpan_src, qr/SCRIPT_DIR=.*BASH_SOURCE/, 'installer resolves its own directory');
like($cpan_src, qr/INSTALL_HELPER="\$SCRIPT_DIR\/install_perl_module\.sh"/, 'helper path is anchored to installer directory');
like($cpan_src, qr/SCRIPT_LOGFILE="\$SCRIPT_DIR\/cpan_install\.log"/, 'summary log path is anchored');
like($cpan_src, qr/CPAN_LOGFILE="\$SCRIPT_DIR\/cpan_install_details\.log"/, 'detail log path is anchored');
like($cpan_src, qr/wait_for_cmd "\$INSTALL_HELPER" "\$perl_module"/, 'module install invokes anchored helper');
unlike($cpan_src, qr/wait_for_cmd \.[\/]install_perl_module\.sh/, 'no caller-cwd helper path remains');
unlike($cpan_src, qr/\b(?:apt|apt-get|dpkg|dnf|yum)\b/, 'Perl installer does not use system packages');

for my $cmd (qw(cpan make gcc)) {
    like($configure_src, qr/need_cmd \Q$cmd\E\b/, "configure checks $cmd before fresh install");
}
like($configure_src, qr/command -v curl.*command -v wget/s, 'configure accepts curl or wget as download tool');
like($configure_src, qr/mb380-B1/, 'MB380 marker is present in configure');
like($cpan_src, qr/mb380-B1/, 'MB380 marker is present in CPAN installer');

my $tmp = tempdir(CLEANUP => 1);
my $install = "$tmp/install";
my $outside = "$tmp/outside";
my $fakebin = "$tmp/fakebin";
make_path($install, $outside, $fakebin);
copy($cpan_script, "$install/cpan_install.sh") or die $!;
chmod 0755, "$install/cpan_install.sh";

open my $helper, '>', "$install/install_perl_module.sh" or die $!;
print {$helper} <<'SH';
#!/usr/bin/env bash
set -eu
printf '%s\n' "$PWD" > "$(dirname "$0")/helper.cwd"
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
    if [ ! -f "${MB380_INSTALL_DIR}/io_async.installed" ]; then
      exit 1
    fi
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

# The real fresh installer invokes cpan_install.sh through sudo.  This dynamic
# test deliberately runs as the repository owner, so emulate only the root UID
# check while leaving every CPAN/helper operation inside the temporary tree.
open my $id, '>', "$fakebin/id" or die $!;
print {$id} <<'SH';
#!/usr/bin/env bash
if [ "${1:-}" = "-u" ]; then
    printf '0\n'
    exit 0
fi
exit 1
SH
close $id;
chmod 0755, "$fakebin/id";

ok(-x "$fakebin/id", 'dynamic test provides a fake root uid command');
my $fake_uid = qx{PATH=\Q$fakebin\E:\$PATH id -u};
is($fake_uid, "0\n", 'dynamic test models the sudo invocation used by configure');

my $cmd = join ' ',
    'cd', quotemeta($outside), '&&',
    'PATH=' . quotemeta($fakebin) . ':$PATH',
    'MB380_INSTALL_DIR=' . quotemeta($install),
    quotemeta("$install/cpan_install.sh"),
    '>', quotemeta("$tmp/stdout.log"), '2>&1';
my $rc = system('bash', '-c', $cmd);
is($rc, 0, 'CPAN installer succeeds when invoked outside its own directory');

ok(-f "$install/helper.modules", 'anchored helper was executed');
if (-f "$install/helper.modules") {
    open my $fh, '<', "$install/helper.modules" or die $!;
    my $mods = do { local $/; <$fh> };
    like($mods, qr/^IO::Async::Loop$/m, 'first missing module reached helper successfully');
}

ok(-f "$install/helper.cwd", 'helper recorded its working directory');
if (-f "$install/helper.cwd") {
    open my $fh, '<', "$install/helper.cwd" or die $!;
    chomp(my $cwd = <$fh> // '');
    is($cwd, $install, 'installer changes to its own install directory');
}

ok(-f "$install/cpan_install.log", 'summary log is written under install directory');
ok(-f "$install/cpan_install_details.log", 'detail log is written under install directory');
ok(!-e "$outside/cpan_install.log", 'no summary log leaks into caller directory');
ok(!-e "$outside/cpan_install_details.log", 'no detail log leaks into caller directory');

done_testing();
