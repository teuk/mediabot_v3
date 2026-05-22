# t/cases/341_partyline_no_duplicate_dispatch.t
use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_341 {
    open my $fh, '<:encoding(UTF-8)', $_[0] or die $!;
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_341(File::Spec->catfile('.', 'Mediabot', 'Partyline.pm'));

    for my $cmd (qw(kick unmute floodset cmdcooldown netsplit floodstatus flushcooldown)) {
        my @hits = ($src =~ /^    elsif \(\$line =~ \/\^\\\.$cmd\b/mg);
        $assert->ok(scalar(@hits) == 1, "Partyline .$cmd dispatch appears exactly once");
    }
};
