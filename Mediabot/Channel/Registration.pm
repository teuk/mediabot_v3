package Mediabot::Channel::Registration;
use strict;
use warnings;

# Read chaninfo's registration projection without command or cache authority.
# Raw fields may include the channel key: only the caller decides disclosure.
# The original statement and SQL preserve command-owned diagnostics/finish order.
sub read_for_info {
    my ($dbh, $id_channel) = @_;
    my $sql = q{
        SELECT
            U.nickname       AS nickname,
            U.last_login     AS last_login,
            C.creation_date  AS creation_date,
            C.description    AS description,
            C.`key`          AS c_key,
            C.chanmode       AS chanmode,
            C.auto_join      AS auto_join,
            C.timezone       AS timezone
        FROM USER_CHANNEL UC
        JOIN `USER`  U ON U.id_user    = UC.id_user
        JOIN CHANNEL C ON C.id_channel = UC.id_channel
        WHERE UC.id_channel = ? AND UC.level = 500
        LIMIT 1
    };
    my $sth = $dbh->prepare($sql);
    unless ($sth && $sth->execute($id_channel)) {
        return { status => 'error', statement => $sth, sql => $sql };
    }
    my $row = $sth->fetchrow_hashref();
    return {
        status => $row ? 'found' : 'missing', row => $row,
        statement => $sth, sql => $sql,
    };
}

1;
