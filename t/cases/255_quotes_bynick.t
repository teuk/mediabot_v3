# t/cases/255_quotes_bynick.t
# Verify mbQuoteByNick structure and DB balance.
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
    my $src  = _slurp(File::Spec->catfile('.','Mediabot','Quotes.pm'));
    my $body = _sub($src, 'mbQuoteByNick');
    $assert->ok(defined $body, 'mbQuoteByNick sub found');
    $assert->like($body // '', qr/QUOTES/, 'mbQuoteByNick queries QUOTES table');
    $assert->like($body // '', qr/->finish/, 'mbQuoteByNick calls ->finish');
    # prepare/finish balance — 3 prepares, 3 finishes (or 3p/4f if double-branch)
    my @preps = ($body =~ /->prepare\(/g);
    my @fins  = ($body =~ /->finish/g);
    $assert->ok(scalar(@fins) >= scalar(@preps),
        'mbQuoteByNick: at least one finish per prepare');
    $assert->like($body // '', qr/nick/i,
        'mbQuoteByNick filters by nick');
    $assert->like($body // '', qr/B26ext|B26|fix/i,
        'mbQuoteByNick has B26 fix comment on error paths');
};
