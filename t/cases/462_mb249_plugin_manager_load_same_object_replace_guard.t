#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Spec;
use lib '.';

use Mediabot::PluginManager;

my $tmp = tempdir(CLEANUP => 1);
my $module_dir = File::Spec->catdir($tmp, qw(Mediabot Plugin));
make_path($module_dir);

my $module_file = File::Spec->catfile($module_dir, 'SingletonLoad.pm');
open my $fh, '>', $module_file or die "cannot write $module_file: $!";
print {$fh} <<'PLUGIN';
package Mediabot::Plugin::SingletonLoad;
use strict;
use warnings;

our $REGISTER_COUNT = 0;
our $UNREGISTER_COUNT = 0;
our $OBJECT;

sub register {
    my ($class, $bot, %opts) = @_;
    $REGISTER_COUNT++;
    $OBJECT ||= bless { bot => $bot, manager => $opts{manager} }, $class;
    return $OBJECT;
}

sub unregister {
    my ($self, %opts) = @_;
    $UNREGISTER_COUNT++;
    $self->{unregistered} = 1;
    return 1;
}

1;
PLUGIN
close $fh or die "cannot close $module_file: $!";

local @INC = ($tmp, @INC);

my $pm = Mediabot::PluginManager->new(bot => {});

my $first = $pm->load_perl_module('Mediabot::Plugin::SingletonLoad');
ok($first, 'first singleton plugin load succeeds');
is($Mediabot::Plugin::SingletonLoad::REGISTER_COUNT, 1, 'first load calls register once');
is($Mediabot::Plugin::SingletonLoad::UNREGISTER_COUNT, 0, 'first load does not unregister');

my $first_object = $first->{object};
ok($first_object, 'first load stores plugin object');

my $second = $pm->load_perl_module('Mediabot::Plugin::SingletonLoad', replace => 1);
ok($second, 'replace load with singleton object succeeds');
is($Mediabot::Plugin::SingletonLoad::REGISTER_COUNT, 2, 'replace load still calls register');
is($second->{object}, $first_object, 'replace load returned the same singleton object');
is($Mediabot::Plugin::SingletonLoad::UNREGISTER_COUNT, 0, 'same-object load replace does not unregister current plugin');
ok(!$first_object->{unregistered}, 'same-object load replace keeps current plugin hooks alive');
ok($pm->is_registered('Mediabot::Plugin::SingletonLoad'), 'plugin remains registered after same-object replace');

my $source = do {
    open my $sfh, '<', 'Mediabot/PluginManager.pm' or die $!;
    local $/;
    <$sfh>;
};
like($source, qr/mb249-B1/, 'PluginManager source contains mb249 load same-object guard marker');
unlike($source, qr/\b(?:system|exec)\s*\(|`[^`]+`|\bqx\s*(?:\/|\(|\{)/, 'PluginManager load same-object guard does not introduce shell execution');

done_testing();
