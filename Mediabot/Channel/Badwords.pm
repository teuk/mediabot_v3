package Mediabot::Channel::Badwords;
use strict;
use warnings;

# Complete read only. Cache age, diagnostics and fallback belong to the caller.
# Keep read success independent of finish(), including driver error clearing.
sub read {
    my ($dbh, $target) = @_;
    my ($sth, @words);
    my $complete = eval {
        $sth = $dbh->prepare(
            "SELECT badword FROM CHANNEL"
            . " JOIN BADWORDS ON BADWORDS.id_channel = CHANNEL.id_channel"
            . " WHERE CHANNEL.name = ?"
        ) or die "badword_prepare\n";
        $sth->execute($target) or die "badword_execute\n";
        while (my $row = $sth->fetchrow_hashref) {
            die "badword_row\n" unless ref($row) eq 'HASH';
            next unless defined $row->{badword};
            die "badword_value\n" if ref($row->{badword});
            push @words, lc($row->{badword});
        }
        die "badword_fetch\n" if $sth->err;
        1;
    };
    # Capture success before finish(), which may clear a driver's error flag.
    eval { $sth->finish } if $sth;
    return $complete ? { status => 'ok', words => \@words } : { status => 'error' };
}

1;
