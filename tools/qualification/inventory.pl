#!/usr/bin/env perl
use strict;
use warnings;
use Config;
use JSON::PP;
use Digest::SHA qw(sha256_hex);

# Read the authoritative installer inventory; fail closed if its format changes.
open my $in, '<', 'install/cpan_install.sh' or die "Cannot read installer: $!\n";
my $installer = do { local $/; <$in> };
close $in;
my ($body) = $installer =~ /^PERL_MODULES=\(\n(.*?)^\)/ms;
die "Unrecognized installer inventory\n" unless defined $body;
my @modules;
for my $line (split /\n/, $body) {
    next if $line =~ /^\s*$/;
    $line =~ /^\s*"([A-Za-z_]\w*(?:::\w+)*)"\s*$/
        or die "Unrecognized installer module entry\n";
    push @modules, $1;
}
die "Empty installer inventory\n" unless @modules;
push @modules, 'Module::Build', 'DBD::SQLite';
my @required;
my $failed = 0;
for my $module (@modules) {
    (my $file = "$module.pm") =~ s{::}{/}g;
    my $ok = eval { require $file; 1 };
    my $version;
    if ($ok) {
        no strict 'refs';
        $version = ${"${module}::VERSION"};
    } else {
        $failed = 1;
    }
    push @required, {module => $module, status => $ok ? 'loaded' : 'unavailable',
                    version => defined $version ? "$version" : undef};
}
# Fingerprint all loaded Perl files, including transitive dependencies. XS shared
# objects and operating-system packages are outside this inventory's scope.
my @loaded;
my @generated;
for my $name (sort keys %INC) {
    my $path = $INC{$name};
    next unless defined $path && !ref $path;
    # Class::MOP::Package::create records an in-memory package with this exact
    # marker. It is not a path; retain it as evidence without inventing a hash.
    # Do not skip arbitrary missing paths: a real unreadable file remains fatal.
    if ($path eq '(set by Moose)') {
        push @generated, {file => $name, origin => $path};
        next;
    }
    open my $fh, '<:raw', $path or die "Cannot fingerprint loaded module $name\n";
    my $hash = Digest::SHA->new(256)->addfile($fh)->hexdigest;
    close $fh;
    push @loaded, {file => $name, path => $path, sha256 => $hash};
}
my $report = {schema => 2, perl => "$^V", executable => $^X,
              archname => $Config{archname}, osname => $Config{osname},
              required => \@required, loaded_files => \@loaded,
              generated_modules => \@generated,
              scope => 'Observed Perl environment, not a dependency lock or XS/system inventory'};
my $dest = shift @ARGV or die "Usage: inventory.pl OUTPUT\n";
open my $out, '>', $dest or die "Cannot write inventory: $!\n";
print {$out} JSON::PP->new->canonical->pretty->encode($report);
close $out or die "Cannot close inventory: $!\n";
exit($failed ? 1 : 0);
