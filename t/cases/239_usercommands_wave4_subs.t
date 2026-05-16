# t/cases/239_usercommands_wave4_subs.t
# =============================================================================
# Verify Wave IV subs structure: _seconds_to_human, flip, morse, roll,
# streak, when — all previously untested.
# =============================================================================
use strict; use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;
sub _slurp { open my $fh,'<:encoding(UTF-8)',$_[0] or die $!; local $/; <$fh> }
sub _sub { my($s,$n)=@_; my $re=qr/^[ \t]*sub[ \t]+\Q$n\E\b[^{]*\{/m;
    return undef unless $s=~/$re/g; my($st,$p,$d)=($-[0],pos($s),1);
    while($p<length($s)){my $c=substr($s,$p,1);$d++ if $c eq '{';$d-- if $c eq '}';
    return substr($s,$st,$p+1-$st) if $d==0; $p++} undef }
return sub {
    my ($assert) = @_;
    my $src = _slurp(File::Spec->catfile('.','Mediabot','UserCommands.pm'));

    # _seconds_to_human (B19 fix)
    my $s2h = _sub($src, '_seconds_to_human');
    $assert->ok(defined $s2h, '_seconds_to_human sub found (B19/fix)');
    $assert->like($s2h // '', qr/86400/, '_seconds_to_human handles days');
    $assert->like($s2h // '', qr/3600/,  '_seconds_to_human handles hours');
    $assert->like($s2h // '', qr/return.*0s/, '_seconds_to_human returns 0s for zero input');

    # mbFlip_ctx
    my $flip = _sub($src, 'mbFlip_ctx');
    $assert->ok(defined $flip, 'mbFlip_ctx found');
    $assert->like($flip // '', qr/heads|tails/i, 'mbFlip_ctx has heads/tails outcomes');
    $assert->like($flip // '', qr/logBot/, 'mbFlip_ctx calls logBot');

    # mbMorse_ctx
    my $morse = _sub($src, 'mbMorse_ctx');
    $assert->ok(defined $morse, 'mbMorse_ctx found');
    $assert->like($morse // '', qr/\.|-/, 'mbMorse_ctx has dot/dash encoding');

    # mbRoll_ctx
    my $roll = _sub($src, 'mbRoll_ctx');
    $assert->ok(defined $roll, 'mbRoll_ctx found');
    $assert->like($roll // '', qr/rand|int.*rand/, 'mbRoll_ctx uses rand for dice');
    $assert->like($roll // '', qr/logBot/, 'mbRoll_ctx calls logBot');

    # mbStreak_ctx
    my $streak = _sub($src, 'mbStreak_ctx');
    $assert->ok(defined $streak, 'mbStreak_ctx found');
    $assert->like($streak // '', qr/consecutive|streak/i, 'mbStreak_ctx tracks consecutive days');
    $assert->like($streak // '', qr/logBot/, 'mbStreak_ctx calls logBot');

    # mbWhen_ctx
    my $when = _sub($src, 'mbWhen_ctx');
    $assert->ok(defined $when, 'mbWhen_ctx found');
    $assert->like($when // '', qr/first.seen|first_seen/i, 'mbWhen_ctx shows first seen date');
    $assert->like($when // '', qr/logBot/, 'mbWhen_ctx calls logBot');
};
