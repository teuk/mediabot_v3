package ConsolidatedCases;
use strict;
use warnings;
use Exporter 'import';
use File::Basename qw(dirname basename);
use File::Spec;
use JSON::PP qw(decode_json);
our @EXPORT_OK=qw(case_aliases run_suite);
my $folder=File::Spec->rel2abs(File::Spec->catdir(dirname(__FILE__),'..','scenarios'));
my $catalog;
sub _catalog {
    return $catalog if $catalog;
    open my $fh,'<:raw',File::Spec->catfile($folder,'consolidated.json') or die "Missing scenario catalog: $!";
    local $/;my $data=decode_json(<$fh>);
    die 'Invalid scenario catalog' unless ref($data) eq 'HASH';
    my %seen;
    for my $suite (keys %$data) {
        die 'Invalid suite name' unless $suite =~ /\A[0-9]+_[a-z0-9_]+[.]t\z/;
        die 'Empty suite' unless ref($data->{$suite}) eq 'ARRAY' && @{$data->{$suite}};
        for my $path (@{$data->{$suite}}) {
            die 'Invalid or duplicate scenario' unless !ref($path)
                && $path =~ /\A[a-z0-9_]+\/[0-9]+_[a-z0-9_]+[.]pl\z/ && !$seen{$path}++;
            die "Missing scenario $path" unless -f File::Spec->catfile($folder,$path);
        }
    }
    return $catalog=$data;
}
sub case_aliases {
    my ($name)=@_;
    return map {my $n=basename($_);$n =~ s/[.]pl$/.t/;$n} @{_catalog()->{$name}//[]};
}
sub run_suite {
    my ($name)=@_;
    my $paths=_catalog()->{$name} or die "Unknown suite $name";
    for my $path (@$paths) {
        Test::More::note("Scenario: $path");
        my $loaded=do File::Spec->catfile($folder,$path);
        die "Scenario $path did not complete: ".($@ || $! || 'false return') unless $loaded;
    }
    return 1;
}
1;
