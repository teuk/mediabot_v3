# t/cases/237_partyline_quota_cmd.t
# Verify Partyline .quota command structure (I1).
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
    my $src  = _slurp(File::Spec->catfile('.','Mediabot','Partyline.pm'));
    my $body = _sub($src, '_cmd_quota');
    $assert->ok(defined $body, '_cmd_quota sub found');
    $assert->like($body // '', qr/_claude_ratelimit/,
        '_cmd_quota reads _claude_ratelimit');
    $assert->like($body // '', qr/split.*x00.*2|, 2/,
        'B20/fix: split uses limit 2');
    $assert->like($body // '', qr/No active rate limit/,
        '_cmd_quota handles empty case');
    $assert->like($body // '', qr/remaining/,
        '_cmd_quota shows remaining requests');
    $assert->like($body // '', qr/60/,
        '_cmd_quota uses 60s window expiry');
    $assert->like($src, qr/\.quota/,
        'Partyline help has .quota entry');
    $assert->like($src, qr/elsif.*\.quota/i,
        'Partyline dispatch handles .quota');
};
