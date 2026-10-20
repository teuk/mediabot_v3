use strict;
use warnings;
use utf8;
use lib '.', 't/lib';
use Test::More;
use POSIX ();
use Mediabot::Convert;

sub result_number {
    my ($text)=@_;
    return undef unless defined($text) && $text=~/=\s*([-+]?[0-9]*\.?[0-9]+(?:[eE][-+]?[0-9]+)?)/;
    return 0+$1;
}
for my $case (
    ['1e300','tb','tb',1e300],
    ['1e300','tb','gb',1e303],
    ['1e300','km','m',1e303],
    ['1e308','km','km',1e308],
    ['2e307','c','f',3.6e307],
    ['1e308','f','c',1e308*(5/9)],
    ['1e308','f','f',1e308],
    ['-1e308','f','c',-1e308*(5/9)],
) {
    my ($value,$from,$to,$expected)=@$case;
    my ($ok,$out)=Mediabot::Convert::convert($value,$from,$to);
    ok($ok,"$value $from to $to: representable conversion succeeds");
    my $n=result_number($out);
    ok(defined($n) && POSIX::isfinite($n) && abs($n/$expected-1)<0.0002,
        "$value $from to $to: finite result agrees with the scale without intermediate overflow");
}
{
    my ($ok,$out)=Mediabot::Convert::convert('1e-320','mg','mg');
    ok($ok,'representable subnormal identity remains supported');
    my $n=result_number($out);
    ok(defined($n) && $n>0 && $n<1e-319,'identity does not underflow through the base-unit intermediate');
}
for my $case (
    ['1e9999','m','km'],['-1e9999','c','f'],['9'x400,'kg','g'],
    ['1e308','tb','b'],['1e308','km','mm'],['1e308','c','f'],['-1e308','c','f'],
) {
    my ($ok,$out);my @warnings;
    {local $SIG{__WARN__}=sub {push @warnings,@_};($ok,$out)=Mediabot::Convert::convert(@$case)}
    ok(!$ok,'overflowing input or result is refused rather than reported as successful');
    like($out,qr/outside the supported numeric range/,'overflow has a bounded useful error');
    unlike($out,qr/\b(?:Inf|NaN)\b| at .* line \d+/i,'overflow does not expose a pseudo-result or stack location');
    is(scalar @warnings,0,'overflow produces no uncontrolled diagnostic');
}
for my $bad (undef,{},[],"١٢",'NaN','Inf',"12\n",'1.2.3','--1') {
    my ($ok,$out);my @warnings;
    {local $SIG{__WARN__}=sub {push @warnings,@_};($ok,$out)=Mediabot::Convert::convert($bad,'m','cm')}
    ok(!$ok && $out eq 'value must be a number','invalid or non-ASCII numeric syntax is refused');
    is(scalar @warnings,0,'invalid numeric syntax produces no arithmetic warning');
}
for my $case (
    [100,'km','mi',62.1371],[1,'kg','lb',2.20462],[1,'l','ml',1000],
    [36,'km/h','m/s',10],[1,'gb','mib',953.674],[-40,'c','f',-40],
    [0,'c','k',273.15],[32,'f','c',0],['+.5','m','cm',50],
) {
    my ($v,$from,$to,$expected)=@$case;
    my ($ok,$out)=Mediabot::Convert::convert($v,$from,$to);my $n=result_number($out);
    ok($ok && defined($n) && abs($n-$expected)<0.001,"ordinary $from to $to conversion retains its value and formatting");
}
my ($ok,$out)=Mediabot::Convert::convert(1,'m','kg');
ok(!$ok && $out=~/different families/,'different-family refusal remains');
($ok,$out)=Mediabot::Convert::convert(1,'unknown','m');
ok(!$ok && $out=~/unknown unit/,'unknown-unit refusal remains');
done_testing;
