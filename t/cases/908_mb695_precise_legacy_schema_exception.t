# t/cases/908_mb695_precise_legacy_schema_exception.t
use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;

return sub {
    my ($assert) = @_;

    my $root = File::Spec->catdir($Bin, '..', '..');

    my %path = (
        checker => File::Spec->catfile(
            $root, 'tools', 'check_schema_drift.pl'
        ),
        doctor => File::Spec->catfile(
            $root, 'tools', 'mediabot_doctor.pl'
        ),
        test830 => File::Spec->catfile(
            $root, 't', 'cases',
            '830_mb649_doctor_database_migrations.t'
        ),
        docs => File::Spec->catfile(
            $root, 'docs', 'DB_MIGRATIONS.md'
        ),
    );

    my %text;

    for my $name (sort keys %path) {
        open my $fh, '<', $path{$name} or do {
            $assert->ok(
                0,
                "mb695-908: cannot open $path{$name}: $!"
            );
            return;
        };

        local $/;
        $text{$name} = <$fh>;
        close $fh;
    }

    $assert->ok(
        index(
            $text{checker},
            q{'allow-extra-column=s@' => \@allow_extra_columns}
        ) >= 0,
        'mb695-908: checker exposes repeatable exact extra-column allowance',
    );

    $assert->like(
        $text{checker},
        qr/sub\s+parse_allowed_extra_columns\b/,
        'mb695-908: checker validates allowance values',
    );

    $assert->like(
        $text{checker},
        qr/expected TABLE[.]COLUMN/,
        'mb695-908: malformed allowance fails closed',
    );

    $assert->like(
        $text{checker},
        qr/my \$extra_key = "\$t[.]\$c"/,
        'mb695-908: exact TABLE.COLUMN identity is used',
    );

    $assert->like(
        $text{checker},
        qr/next if \$allowed_extra_columns\{\$extra_key\}/,
        'mb695-908: only explicitly allowed extra columns are skipped',
    );

    $assert->like(
        $text{checker},
        qr/'ignore-extra'\s*=>/,
        'mb695-908: broad option remains available for explicit diagnostics',
    );

    $assert->unlike(
        $text{checker},
        qr/USER[.]hostmasks_legacy/,
        'mb695-908: generic checker does not hard-code project legacy state',
    );

    (my $doctor_code = $text{doctor}) =~ s/^\s*#.*$//mg;

    $assert->unlike(
        $doctor_code,
        qr/['"]--ignore-extra['"]/,
        'mb695-908: Doctor no longer executes blanket ignore-extra',
    );

    $assert->like(
        $text{doctor},
        qr/['"]--allow-extra-column['"]\s*,\s*
           ['"]USER[.]hostmasks_legacy['"]/x,
        'mb695-908: Doctor permits exactly USER.hostmasks_legacy',
    );

    $assert->like(
        $text{test830},
        qr/exact legacy-column allowance/,
        'mb695-908: historical 830 contract is updated explicitly',
    );

    $assert->like(
        $text{docs},
        qr/--allow-extra-column USER[.]hostmasks_legacy/,
        'mb695-908: operator guide uses precise compatibility allowance',
    );

    $assert->like(
        $text{docs},
        qr/Any other extra table or column remains\s+schema drift/s,
        'mb695-908: unrelated extra objects remain drift',
    );

    my $help = qx{$^X "$path{checker}" --help 2>&1};

    $assert->is(
        $? >> 8,
        0,
        'mb695-908: checker --help succeeds',
    );

    $assert->like(
        $help,
        qr/--allow-extra-column X[.]Y/,
        'mb695-908: precise option is visible in operator help',
    );
};
