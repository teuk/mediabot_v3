use strict;
use warnings;

return sub {
    my ($assert) = @_;
    for my $imported_clock (0, 1) {
        # Run the real historical throttle case in a fresh interpreter. The
        # second run imports an offset clock into main, as a shared legacy
        # case can do; the real Dispatcher must retain its native clock.
        my $program = q{
use strict;
use warnings;
BEGIN {
    if (IMPORTED_CLOCK) {
        require Time::HiRes;
        no warnings qw(redefine once);
        *Time::HiRes::time = sub () { CORE::time() + 60 };
        Time::HiRes->import('time');
    }
}
use lib '.', 't/lib';
{
    package ThrottleClockAssert;
    sub new { bless { failed => 0, total => 0 }, shift }
    sub ok {
        my ($self, $ok, $name) = @_;
        $self->{total}++;
        unless ($ok) { $self->{failed}++; print "FAIL: $name\n"; }
        return $ok;
    }
    sub is {
        my ($self, $got, $expected, $name) = @_;
        return $self->ok(defined($got) && defined($expected)
            && "$got" eq "$expected", $name);
    }
    sub like {
        my ($self, $got, $pattern, $name) = @_;
        return $self->ok($got =~ $pattern, $name);
    }
}
my $case = do './t/cases/779_mb596_partyline_throttle_hardening.t';
die $@ if $@;
die "Cannot load throttle regression case\n" unless ref($case) eq 'CODE';
my $checks = ThrottleClockAssert->new;
$case->($checks);
print "THROTTLE_CLOCK total=$checks->{total} failed=$checks->{failed}\n";
exit($checks->{failed} ? 1 : 0);
};
        $program =~ s/IMPORTED_CLOCK/$imported_clock/g;
        open my $fh, '-|', $^X, '-e', $program
            or die 'Cannot start isolated throttle clock regression';
        local $/;
        my $out = <$fh> // '';
        close $fh;
        my $exit = $? >> 8;
        my $label = $imported_clock ? 'imported shared clock' : 'native clock';
        $assert->is($exit, 0, "mb832: throttle case passes with $label");
        $assert->like($out, qr/THROTTLE_CLOCK total=18 failed=0/,
            "mb832: all throttle and anti-flood assertions run with $label");
        print $out if $exit;
    }
};
