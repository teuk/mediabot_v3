#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../..";
use File::Temp qw(tempdir);
use Scalar::Util qw(refaddr);
use Test::More;
use Mediabot::Conf;

# Native Config::Simple and Conf, private disposable data, no bot/DB/IRC startup.
my $dir = tempdir(CLEANUP => 1);
my $path = "$dir/probe.conf";
sub write_config {
    my ($text) = @_;
    open my $fh, '>', $path or die "create fixture: $!";
    print {$fh} $text or die "write fixture: $!";
    close $fh or die "close fixture: $!";
}
write_config("[main]\nVALUE=old\nKEEP=yes\n");
my $conf = Mediabot::Conf->new(undef, $path);
is($conf->get('main.VALUE'), 'old', 'native parser loads INI configuration');
my $owner = refaddr($conf);
my $parser = refaddr($conf->{_cfg});
$conf->set('main.RUNTIME_ONLY', 'temporary');
write_config("[main]\nVALUE=new\nADDED=present\n");
ok($conf->reload(), 'native reload succeeds');
is(refaddr($conf), $owner, 'configuration owner identity is preserved');
isnt(refaddr($conf->{_cfg}), $parser, 'backing parser is replaced');
is($conf->get('main.VALUE'), 'new', 'new value is published');
is($conf->get('main.ADDED'), 'present', 'new key is published');
ok(!defined $conf->get('main.KEEP'), 'removed key does not survive reload');
ok(!defined $conf->get('main.RUNTIME_ONLY'), 'unsaved override does not survive reload');
$parser = refaddr($conf->{_cfg});
unlink $path or die "unlink fixture: $!";
my $ok = eval { $conf->reload(); 1 };
ok(!$ok, 'missing replacement is refused');
like($@, qr/does not exist/, 'failure remains explicit');
is(refaddr($conf->{_cfg}), $parser, 'failed reload retains backing parser');
is($conf->get('main.VALUE'), 'new', 'failed reload retains confirmed value');
done_testing;
