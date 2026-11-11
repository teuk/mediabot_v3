package Mediabot::Channel::FloodRules;
use strict;
use warnings;

# Read-only CHANNEL_FLOOD boundary. Receives only a DBI-compatible handle and
# channel ID; owns no bot, cache, clock, logger or transport.
# Distinguish an absent row from a false prepare/execute result. DBI exceptions
# propagate unchanged. Preserve the existing statement call order and failure
# semantics; the admission policy owns defaults, caching and fail-open choices.
sub read {
    my ($dbh, $id_channel) = @_;
    my $sth = $dbh->prepare(
        "SELECT nbmsg_max, duration, timetowait FROM CHANNEL_FLOOD WHERE id_channel = ?"
    );
    if ($sth && $sth->execute($id_channel)) {
        my $row = $sth->fetchrow_hashref;
        $sth->finish;
        return $row ? { status => 'found', row => $row } : { status => 'missing' };
    }
    no warnings 'once';
    return { status => 'error', error => $DBI::errstr };
}

1;
