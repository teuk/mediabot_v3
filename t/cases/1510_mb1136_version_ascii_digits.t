use strict;
use warnings;
use utf8;
use Test::More;
use Encode qw(encode);
use Mediabot::Version::Format qw(_version_parts _compare_mediabot_versions getDetailedVersion);

# Every numeric field must use the same alphabet as Perl numeric conversion.
my @invalid;
for my $digit ("\x{0663}", "\x{06f3}", "\x{ff13}", "\x{0969}") {
    push @invalid, "$digit.8", "3.$digit", "3.8dev-$digit",
        "3.8dev-20261107_23${digit}827", "3${digit}.8", "3.8${digit}";
}
for my $value (@invalid) {
    my $original = $value;
    my (@warnings, $parts, $left, $right, @detail);
    {
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        $parts = _version_parts($value);
        $left = _compare_mediabot_versions($value, '3.8');
        $right = _compare_mediabot_versions('3.8', $value);
        @detail = getDetailedVersion(undef, $value);
    }
    ok(!defined($parts), 'non-ASCII numeric field is rejected');
    ok(!defined($left) && !defined($right), 'invalid version cannot be ordered in either direction');
    is_deeply(\@detail, [(undef) x 4], 'detail API reports invalid input');
    is_deeply(\@warnings, [], 'no numeric conversion warning');
    is($value, $original, 'caller input preserved');
    ok(!defined(_version_parts(encode('UTF-8', $value))), 'raw UTF-8 input also rejected');
}
for my $case (
    ['3.8', [3,8,'stable',undef]],
    [' 03.008 ', [3,8,'stable',undef]],
    ['3.8dev-20261107_235827', [3,8,'devel','20261107235827']],
    ['3.8dev_000123', [3,8,'devel','123']],
    ['3.8dev000', [3,8,'devel','0']],
    ['3.8dev-'.('9' x 40), [3,8,'devel','9' x 40]],
) {
    is_deeply([getDetailedVersion(undef,$case->[0])], $case->[1], 'ASCII version compatibility');
}
for my $case (
    ['3.8', '3.8dev-99999999', 1],
    ['3.8dev-20261107_235827', '3.8dev-20261107_225806', 1],
    ['03.008dev-0001_23', '3.8dev123', 0],
    ['3.8', '3.9dev-1', -1],
    ['3.8dev-'.('9' x 40), '3.8dev-1'.('0' x 40), -1],
) {
    is(_compare_mediabot_versions($case->[0],$case->[1]) <=> 0,$case->[2], 'ASCII ordering retained');
}

# MB1176: major/minor components must not round to equal floating values.
{
 my @warnings;
 local $SIG{__WARN__}=sub {push @warnings,@_};
 for my $pair (
  ['18446744073709551616','18446744073709551617'],
  [('9'x80), '1'.('0'x80)],
  ['1'.('0'x399).'1','1'.('0'x399).'2'],
 ) {
  for my $minor (0,1) {
   my ($a,$b)=map {$minor ? "3.$_" : "$_.8"} @$pair;
   for my $suffix ('','dev-20261109_120000') {
    is(_compare_mediabot_versions($a.$suffix,$b.$suffix)<=>0,-1,'large component orders exactly');
    is(_compare_mediabot_versions($b.$suffix,$a.$suffix)<=>0,1,'reverse comparison remains antisymmetric');
    is(_compare_mediabot_versions($a.$suffix,$a.$suffix),0,'large component is equal to itself');
   }
  }
 }
 my $large='1'.('0'x399).'1';
 is_deeply([getDetailedVersion(undef,"000$large.000$large")],[$large,$large,'stable',undef],
   'detail API preserves exact canonical digits without scientific notation or infinity');
 is(_compare_mediabot_versions("000$large.0008dev-000123","$large.8dev123"),0,
   'leading-zero equivalence also holds for large components');
 is(_compare_mediabot_versions("$large.8","$large.8dev999")<=>0,1,
   'stable still follows development at the same exact base');
 is_deeply(\@warnings,[],'very large ASCII components never trigger numeric warnings');
}
done_testing;
