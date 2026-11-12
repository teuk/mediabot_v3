package Mediabot::Channel::Flags;
use strict;
use warnings;

# Raw chaninfo rows, in database order. Disclosure, matching, presentation and
# statement cleanup remain the command's responsibility.
sub read_for_info {
    my ($dbh, $id_channel) = @_;
    my $sql = q{
        SELECT CL.chanset
        FROM CHANNEL_SET  CS
        JOIN CHANSET_LIST CL ON CL.id_chanset_list = CS.id_chanset_list
        WHERE CS.id_channel = ?
    };
    my $sth = $dbh->prepare($sql);
    unless ($sth && $sth->execute($id_channel)) {
        return { status => 'error', statement => $sth, sql => $sql };
    }
    my @rows;
    while (my $row = $sth->fetchrow_hashref()) {
        push @rows, $row;
    }
    return { status => 'ok', rows => \@rows, statement => $sth, sql => $sql };
}

1;
