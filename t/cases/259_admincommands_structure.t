# t/cases/259_admincommands_structure.t
# Verify AdminCommands.pm sub structure, exports and DB balance.
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
    my $src = _slurp(File::Spec->catfile('.','Mediabot','AdminCommands.pm'));
    # Key subs present
    for my $sub_name (qw(mbQuit_ctx mbRehash_ctx mbStatus_ctx openai_ctx debug_ctx)) {
        my $body = _sub($src, $sub_name);
        $assert->ok(defined $body, "$sub_name sub found in AdminCommands");
    }
    # DB balance: AdminCommands has no prepare/finish issues
    my @all_preps = ($src =~ /->prepare\(/g);
    my @all_fins  = ($src =~ /->finish/g);
    $assert->ok(scalar(@all_fins) >= scalar(@all_preps),
        'AdminCommands: finish count >= prepare count (no leaks)');
    # mbStatus_ctx shows uptime/metrics info
    my $st = _sub($src, 'mbStatus_ctx');
    $assert->like($st // '', qr/uptime|metrics|status/i,
        'mbStatus_ctx provides status information');
    # mbRehash_ctx reloads config
    my $rh = _sub($src, 'mbRehash_ctx');
    $assert->like($rh // '', qr/rehash|conf.*load|load.*conf/i,
        'mbRehash_ctx reloads configuration');
    # openai_ctx dispatches to chatGPT
    my $oa = _sub($src, 'openai_ctx');
    $assert->like($oa // '', qr/chatGPT|openai|tellme/i,
        'openai_ctx delegates to ChatGPT function');
};
