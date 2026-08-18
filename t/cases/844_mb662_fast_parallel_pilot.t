#!/usr/bin/perl
use strict;
use warnings;
use FindBin;
use File::Spec;

return sub {
    my ($assert) = @_;

    my $root = File::Spec->catdir($FindBin::Bin, '..', '..');
    my $pilot = File::Spec->catfile($root, 't', 'fast_parallel.pl');

    my $capture = sub {
        my (@args) = @_;

        my $pid = open(my $fh, '-|');
        if (!defined $pid) {
            return ('', 255);
        }

        if ($pid == 0) {
            open STDERR, '>&', STDOUT;
            chdir $root or exit 254;
            {
                no warnings 'exec';
                exec($^X, $pilot, @args);
            }
            exit 254;
        }

        local $/;
        my $out = <$fh> // '';
        close $fh;
        return ($out, $? >> 8);
    };

    my ($plan, $plan_rc) = $capture->('--jobs', '2', '--plan-only');

    $assert->is($plan_rc, 0,
        'mb662-844: two-job parallel pilot plan exits successfully');

    $assert->like(
        $plan,
        qr/Selected fast files\s*:\s*(\d+)/,
        'mb662-844: plan exposes selected fast-lane size',
    );
    my ($selected) = $plan =~ /Selected fast files\s*:\s*(\d+)/;

    $assert->like(
        $plan,
        qr/Parallel PURE files\s*:\s*(\d+)/,
        'mb662-844: plan exposes parallel PURE candidate count',
    );
    my ($parallel) = $plan =~ /Parallel PURE files\s*:\s*(\d+)/;

    $assert->like(
        $plan,
        qr/Serial sentinels\s*:\s*(\d+)/,
        'mb662-844: plan exposes serial sentinel count',
    );
    my ($serial) = $plan =~ /Serial sentinels\s*:\s*(\d+)/;

    $assert->is($serial, 11,
        'mb662-844: all eleven MB661 sentinels remain serial');

    $assert->is(
        ($parallel // 0) + ($serial // 0),
        $selected,
        'mb662-844: parallel plus serial stages cover the whole fast lane once',
    );

    my ($shard1) = $plan =~ /shard 1\s*:\s*(\d+)\s+file/;
    my ($shard2) = $plan =~ /shard 2\s*:\s*(\d+)\s+file/;

    $assert->ok(
        defined($shard1) && defined($shard2)
            && $shard1 > 0 && $shard2 > 0,
        'mb662-844: both deterministic parallel shards are non-empty',
    );

    $assert->is(
        ($shard1 // 0) + ($shard2 // 0),
        $parallel,
        'mb662-844: shard coverage equals the parallel candidate set',
    );

    $assert->like(
        $plan,
        qr/only non-sentinel primary PURE files overlap/,
        'mb662-844: plan states the conservative overlap policy',
    );

    $assert->like(
        $plan,
        qr/NOT equivalent to full suite/,
        'mb662-844: pilot explicitly refuses full-suite equivalence',
    );

    my ($bad_low, $bad_low_rc) = $capture->('--jobs', '1', '--plan-only');
    $assert->ok(
        $bad_low_rc != 0 && $bad_low =~ /between 2 and 4/,
        'mb662-844: jobs below conservative range fail closed',
    );

    my ($bad_high, $bad_high_rc) = $capture->('--jobs', '5', '--plan-only');
    $assert->ok(
        $bad_high_rc != 0 && $bad_high =~ /between 2 and 4/,
        'mb662-844: jobs above conservative range fail closed',
    );

    open my $fh, '<', $pilot or do {
        $assert->fail("mb662-844: cannot read $pilot");
        return;
    };
    my $src = do { local $/; <$fh> };
    close $fh;

    $assert->like(
        $src,
        qr/--expect-assertions/,
        'mb662-844: pilot can prove aggregate assertion equivalence explicitly',
    );

    $assert->unlike(
        $src,
        qr/\bsystem\s*\(/,
        'mb662-844: pilot does not delegate through a shell system() call',
    );
};
