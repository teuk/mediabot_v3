#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use File::Spec;

my $root = File::Spec->rel2abs(File::Spec->curdir());
my @fail;

sub ok {
    my ($cond, $msg) = @_;
    if ($cond) { print "ok - $msg\n"; }
    else { print "not ok - $msg\n"; push @fail, $msg; }
}

sub slurp {
    my ($file) = @_;
    open my $fh, '<:encoding(UTF-8)', $file or die "cannot open $file: $!";
    local $/;
    return <$fh>;
}

my $plugin = slurp(File::Spec->catfile($root, 'Mediabot', 'Plugin', 'ScriptDryRun.pm'));
ok($plugin =~ /mb196-B1: lightweight ScriptDryRun runtime logging/, 'ScriptDryRun has MB196 logging marker');
ok($plugin =~ /PUBLIC\(scriptdryrun\): accepted command=/, 'ScriptDryRun logs accepted route before execution');
ok($plugin =~ /PUBLIC\(scriptdryrun\): script_result command=/, 'ScriptDryRun logs script runner result');
ok($plugin =~ /PUBLIC\(scriptdryrun\): action_plan command=/, 'ScriptDryRun logs action runner plan');

my $py = slurp(File::Spec->catfile($root, 'plugins', 'scripts', 'examples', 'hello_python.py'));
ok($py =~ /"type"\s*:\s*"reply"/, 'Python demo replies visibly to channel by default');
ok($py !~ /"type"\s*:\s*"notice"/, 'Python demo no longer hides demo output in a notice');

my $pl = slurp(File::Spec->catfile($root, 'plugins', 'scripts', 'examples', 'hello_perl.pl'));
ok($pl =~ /reply/, 'Perl demo contains reply action');

my $tcl = slurp(File::Spec->catfile($root, 'plugins', 'scripts', 'examples', 'hello_tcl.tcl'));
ok($tcl =~ /reply/, 'Tcl demo contains reply action');

if (@fail) {
    print "FAILED: @fail\n";
    exit 1;
}

exit 0;
