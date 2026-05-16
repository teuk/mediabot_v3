# t/cases/244_usercommands_poll_ops.t
# Verify mbPollResult_ctx and mbPollStop_ctx structure.
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

    my $pr = _sub($src, 'mbPollResult_ctx');
    $assert->ok(defined $pr, 'mbPollResult_ctx sub found');
    $assert->like($pr // '', qr/_poll/,
        'mbPollResult_ctx reads from _poll hash');
    $assert->like($pr // '', qr/pct|percent|vote/i,
        'mbPollResult_ctx shows vote percentages');
    $assert->like($pr // '', qr/logBot/,
        'mbPollResult_ctx calls logBot');

    my $ps = _sub($src, 'mbPollStop_ctx');
    $assert->ok(defined $ps, 'mbPollStop_ctx sub found');
    $assert->like($ps // '', qr/active.*0|active\s*=\s*0/,
        'mbPollStop_ctx sets poll active=0');
    $assert->like($ps // '', qr/Poll closed/,
        'mbPollStop_ctx sends closed notice');
    $assert->like($ps // '', qr/logBot/,
        'mbPollStop_ctx calls logBot');
};
