# t/cases/379_usercommands_export_dedup.t
use strict;
use warnings;
use File::Spec;

sub _slurp_379 {
    open my $fh, '<:encoding(UTF-8)', $_[0] or die $!;
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_379(File::Spec->catfile('.', 'Mediabot', 'UserCommands.pm'));

    my ($body) = $src =~ /\@EXPORT\s*=\s*qw\((.*?)\);/s;
    $assert->ok(defined $body, 'UserCommands @EXPORT block found');

    my @items = split /\s+/, ($body // '');
    @items = grep { $_ ne '' } @items;

    my %seen;
    my @dups;
    for my $item (@items) {
        push @dups, $item if $seen{$item}++;
    }

    $assert->ok(!@dups, 'UserCommands @EXPORT contains no duplicate symbols')
        or $assert->diag('duplicates: ' . join(', ', @dups));

    for my $sym (qw(
        mbKarmaWatch_ctx
        mbKarmaDiff_ctx
        mbKarmaGraph_ctx
        mbKarmaInfo_ctx
        mbKarmaReset_ctx
        mbPollExtend_ctx
        mbPollStatus_ctx
        mbPollVoters_ctx
        mbTriviaReset_ctx
        mbTriviaStop_ctx
        mbTriviaTop_ctx
        mbUnvote_ctx
    )) {
        my @hits = grep { $_ eq $sym } @items;
        $assert->ok(@hits == 1, "$sym exported exactly once");
    }
};
