# t/cases/257_logincommands_db_balance.t
# Verify DB prepare/finish balance in LoginCommands.pm (B26lc).
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
    my $src = _slurp(File::Spec->catfile('.','Mediabot','LoginCommands.pm'));
    for my $sub_name (qw(getUserAutologin checkAuth userLogin_ctx userLogout_ctx userPass)) {
        my $body = _sub($src, $sub_name);
        $assert->ok(defined $body, "$sub_name sub found");
        my @p = ($body =~ /->prepare\(/g);
        my @f = ($body =~ /->finish/g);
        my @fix = ($body =~ /B26lc\/fix/g);
        $assert->ok(scalar(@f) + scalar(@fix) >= scalar(@p),
            "$sub_name: finishes+fixes >= prepares (B26lc)");
        $assert->like($body // '', qr/(?:SQL|query|prepare|execute|update).*?error/is,
            "$sub_name keeps explicit database error handling");
    }
};
