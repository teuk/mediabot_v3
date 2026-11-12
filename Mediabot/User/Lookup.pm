package Mediabot::User::Lookup;
use strict;
use warnings;

# Open the original ordered candidate cursor. The caller owns row-by-row
# matching, diagnostics and finish, including historical failure cleanup.
sub open_candidates {
    my ($dbh) = @_;
    my $sth = $dbh->prepare(q{
        SELECT
            u.id_user,
            u.nickname,
            u.username,
            u.id_user_level,
            u.auth,
            u.info1,
            u.info2,
            GROUP_CONCAT(uh.hostmask ORDER BY uh.id_user_hostmask SEPARATOR ',') AS hostmasks
        FROM USER u
        LEFT JOIN USER_HOSTMASK uh ON uh.id_user = u.id_user
        GROUP BY
            u.id_user,
            u.nickname,
            u.username,
            u.id_user_level,
            u.auth,
            u.info1,
            u.info2
        ORDER BY u.id_user
    });
    my $ok = $sth && $sth->execute;
    return { ok => $ok ? 1 : 0, statement => $sth };
}

1;
