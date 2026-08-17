# t/cases/828_mb647_doctor_core_local_probes.t
# =============================================================================
# mb647 — Mediabot Doctor, round 1 : noyau, modele de faits, sondes locales.
#
# This test locks behaviour, including the concrete regressions found by the
# contradictory review after the first implementation:
#   - real required DB keys, never invented config names;
#   - closed fact model (invalid programmer input must not become INFO);
#   - invalid CLI/root must not return a reassuring RC=0;
#   - runtime identity = tree/executable AND --conf;
#   - filesystem checks executable/config/symlink/runtime-identity permissions;
#   - JSON v1 has READY/DEGRADED/UNSAFE semantics.
# =============================================================================

use strict;
use warnings;
use utf8;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;
use File::Temp qw(tempdir);

my $TOOL = File::Spec->catfile($Bin, '..', '..', 'tools', 'mediabot_doctor.pl');

return sub {
    my ($assert) = @_;

    $assert->ok(-f $TOOL, 'mb647-828: Doctor exists');
    $assert->ok(-x $TOOL, 'mb647-828: Doctor is executable');
    my $compile = `$^X -c "$TOOL" 2>&1`;
    $assert->like($compile, qr/syntax OK/, 'mb647-828: Doctor compiles');

    my $loaded = do $TOOL;
    $assert->ok($loaded, 'mb647-828: loadable as a library without side effects');

    # ---------------------------------------------------------------------
    # [1] Closed model and seven-domain interface
    # ---------------------------------------------------------------------
    $assert->is(join(',', @main::DOMAINS),
        'runtime,systemd,config,database,updater,filesystem,migrations',
        'mb647-828: seven domains are frozen');
    $assert->is(main::SCHEMA_VERSION(), 1,
        'mb647-828: JSON fact schema is v1');
    $assert->is(join(',', @main::LEVELS), 'ok,info,unknown,warn,fail',
        'mb647-828: unknown remains distinct from warn/fail');

    my $fact = main::_fact(
        domain => 'config', id => 'config.test', level => 'warn',
        summary => 'test', source => 'test');
    $assert->is(join(',', sort keys %$fact), 'data,domain,id,level,source,summary',
        'mb647-828: a fact has the expected closed shape');
    $assert->is($fact->{source}, 'test',
        'mb647-828: provenance is retained');

    for my $case (
        [ 'unknown level',
          sub { main::_fact(domain=>'config',id=>'x',level=>'catastrophe',
                            summary=>'x',source=>'t') },
          qr/unknown level/ ],
        [ 'unknown domain',
          sub { main::_fact(domain=>'wizardry',id=>'x',level=>'info',
                            summary=>'x',source=>'t') },
          qr/unknown domain/ ],
        [ 'missing source',
          sub { main::_fact(domain=>'config',id=>'x',level=>'info',summary=>'x') },
          qr/missing source/ ],
        [ 'missing id',
          sub { main::_fact(domain=>'config',level=>'info',summary=>'x',source=>'t') },
          qr/missing id/ ],
        [ 'missing summary',
          sub { main::_fact(domain=>'config',id=>'x',level=>'info',source=>'t') },
          qr/missing summary/ ],
        [ 'unknown field',
          sub { main::_fact(domain=>'config',id=>'x',level=>'info',
                            summary=>'x',source=>'t', surprise=>1) },
          qr/unknown field/ ],
    ) {
        my ($name, $code, $re) = @$case;
        my $ok = eval { $code->(); 1 };
        $assert->ok(!$ok, "mb647-828: $name is rejected, not silently normalised");
        $assert->like($@, $re, "mb647-828: $name explains the programming error");
    }

    # ---------------------------------------------------------------------
    # [2] Secrets never enter context/facts
    # ---------------------------------------------------------------------
    for my $k (qw(MAIN_PROG_DBPASS API_KEY CLIENT_SECRET AUTH_TOKEN NICKSERV_PASSWORD)) {
        $assert->ok(main::is_secret_key($k),
            "mb647-828: '$k' is recognised as secret");
    }
    $assert->ok(!main::is_secret_key('MAIN_PROG_DBHOST'),
        'mb647-828: an ordinary key is not a secret');

    my $dir  = tempdir(CLEANUP => 1);
    my $conf = File::Spec->catfile($dir, 'mediabot.conf');
    open my $cfh, '>', $conf or die $!;
    print {$cfh} "[mysql]\n";
    print {$cfh} "MAIN_PROG_DDBNAME=mediabotv3\n";
    print {$cfh} "MAIN_PROG_DBPASS=hunter2\n";
    close $cfh;

    my $tree = File::Spec->rel2abs(File::Spec->catdir($Bin, '..', '..'));
    my $ctx = main::build_context(root => $tree, conf => $conf);

    $assert->ok(!defined $ctx->{conf_values}{'mysql.MAIN_PROG_DBPASS'},
        'mb647-828: secret value never enters context');
    $assert->is($ctx->{conf_values}{'mysql.MAIN_PROG_DDBNAME'}, 'mediabotv3',
        'mb647-828: non-secret DDBNAME is read normally');

    my $cprobe = $main::PROBES{config};
    my $raw = $cprobe->{collect}->($ctx);
    $assert->ok($raw->{defined_in_conf}{'mysql.MAIN_PROG_DBPASS'}{secret},
        'mb647-828: secret presence is retained');
    $assert->ok(!exists $raw->{defined_in_conf}{'mysql.MAIN_PROG_DBPASS'}{value},
        'mb647-828: secret value is absent even from raw probe facts');

    my @cf = $cprobe->{evaluate}->($raw, $ctx);
    my $dump = join "\n", map {
        ($_->{summary} // '') . ' ' . ($_->{detail} // '')
        . ' ' . join(',', grep { defined && !ref } values %{ $_->{data} // {} })
    } @cf;
    $assert->ok($dump !~ /hunter2/,
        'mb647-828: secret never appears in evaluated findings');

    # ---------------------------------------------------------------------
    # [3] Required config keys use real Mediabot sources of truth
    # ---------------------------------------------------------------------
    $assert->ok(exists $raw->{read_by_code}{'mysql.MAIN_PROG_DDBNAME'},
        'mb647-828: scanner sees real mysql.MAIN_PROG_DDBNAME');
    $assert->ok(exists $raw->{read_by_code}{'mysql.MAIN_PROG_DBUSER'},
        'mb647-828: scanner sees real mysql.MAIN_PROG_DBUSER');
    $assert->ok(!exists $raw->{read_by_code}{'mysql.MAIN_PROG_DBNAME'},
        'mb647-828: invented single-D DBNAME is not treated as code truth');
    $assert->ok(!exists $raw->{read_by_code}{'connection.CONN_SERVER_HOSTNAME'},
        'mb647-828: invented CONN_SERVER_HOSTNAME is not treated as code truth');
    $assert->ok(!exists $raw->{read_by_code}{'connection.CONN_SERVER_PORT'},
        'mb647-828: invented CONN_SERVER_PORT is not treated as code truth');

    my ($req) = grep { $_->{id} eq 'config.required_keys' } @cf;
    $assert->is($req->{level}, 'fail',
        'mb647-828: missing truly required DBUSER is a FAIL');
    $assert->ok((grep { $_ eq 'mysql.MAIN_PROG_DBUSER' } @{ $req->{data}{missing} }),
        'mb647-828: missing DBUSER is named');
    $assert->ok(!(grep { /CONN_SERVER_(?:HOSTNAME|PORT)/ } @{ $req->{data}{missing} }),
        'mb647-828: invented connection keys cannot become required');

    # Add DBUSER: the two fatal DB keys are now present.
    open $cfh, '>>', $conf or die $!;
    print {$cfh} "MAIN_PROG_DBUSER=mediabot\n";
    close $cfh;
    my $ctx2 = main::build_context(root => $tree, conf => $conf);
    my $raw2 = $cprobe->{collect}->($ctx2);
    my @cf2 = $cprobe->{evaluate}->($raw2, $ctx2);
    my ($req2) = grep { $_->{id} eq 'config.required_keys' } @cf2;
    $assert->is($req2->{level}, 'ok',
        'mb647-828: DDBNAME + DBUSER satisfy fatal DB requirements');
    $assert->is(scalar @{ $req2->{data}{missing} }, 0,
        'mb647-828: no invented required key remains');

    # No Perl sources => UNKNOWN, never a false OK.
    {
        my $empty = tempdir(CLEANUP => 1);
        my $ectx = main::build_context(root => $empty, conf => $conf);
        my @ef = $cprobe->{evaluate}->($cprobe->{collect}->($ectx), $ectx);
        $assert->is($ef[0]{level}, 'unknown',
            'mb647-828: no source to analyse means UNKNOWN');
    }

    # Missing configuration is allowed for inspecting an unconfigured source
    # tree; it is UNKNOWN/DEGRADED, not a broken tree.
    {
        my $missing_conf = File::Spec->catfile($dir, 'does-not-exist.conf');
        my $mctx = main::build_context(root => $tree, conf => $missing_conf);
        my @mf = $cprobe->{evaluate}->($cprobe->{collect}->($mctx), $mctx);
        $assert->is($mf[0]{level}, 'unknown',
            'mb647-828: missing instance config is UNKNOWN, not FAIL');
    }

    # ---------------------------------------------------------------------
    # [4] Runtime identity = executable/tree AND --conf
    # ---------------------------------------------------------------------
    my $rprobe = $main::PROBES{runtime};

    {
        my $pid = File::Spec->catfile($dir, 'stale.pid');
        open my $p, '>', $pid or die $!; print {$p} "999999\n"; close $p;
        local $ctx2->{conf_values}{'main.MAIN_PID_FILE'} = $pid;
        my @rf = $rprobe->{evaluate}->($rprobe->{collect}->($ctx2), $ctx2);
        my ($st) = grep { $_->{id} eq 'runtime.state' } @rf;
        $assert->is($st->{level}, 'warn',
            'mb647-828: stale PID is reported');
        $assert->is($st->{data}{stale_pid_file}, 1,
            'mb647-828: stale PID is explicitly identified');
    }

    {
        my $pid = File::Spec->catfile($dir, 'self.pid');
        open my $p, '>', $pid or die $!; print {$p} "$$\n"; close $p;
        local $ctx2->{conf_values}{'main.MAIN_PID_FILE'} = $pid;
        my @rf = $rprobe->{evaluate}->($rprobe->{collect}->($ctx2), $ctx2);
        my ($st) = grep { $_->{id} eq 'runtime.state' } @rf;
        $assert->ok($st->{level} eq 'fail' || $st->{level} eq 'unknown',
            'mb647-828: recycled/foreign PID is never reported as this bot');
        my ($own) = grep { $_->{id} eq 'runtime.process_owner' } @rf;
        $assert->ok($own && defined $own->{data}{uid},
            'mb647-828: runtime identity is derived from observed process');
    }

    my $main_prog = File::Spec->catfile($tree, 'mediabot.pl');
    my $good_raw = {
        root_exists => 1, root_has_main => 1, tree_version => '3.4dev-test',
        pid_file => '/tmp/test.pid', pid_file_readable => 1, pid => 4242,
        alive => 1, proc_cwd => $tree,
        argv => [ '/usr/bin/perl', $main_prog, "--conf=$conf" ],
        proc_uid => $>, proc_gid => $( + 0, proc_groups => [ $( + 0 ],
    };
    my @good_rt = $rprobe->{evaluate}->($good_raw, $ctx2);
    my ($good_state) = grep { $_->{id} eq 'runtime.state' } @good_rt;
    my ($good_conf)  = grep { $_->{id} eq 'runtime.config_identity' } @good_rt;
    $assert->is($good_state->{level}, 'ok',
        'mb647-828: matching tree executable is confirmed');
    $assert->is($good_state->{data}{invocation_mode}, 'perl',
        'mb647-828: runtime records that mediabot.pl is launched through perl');
    $assert->is($good_conf->{level}, 'ok',
        'mb647-828: matching --conf is independently confirmed');
    $assert->is($good_conf->{data}{config_confirmed}, 1,
        'mb647-828: config identity records positive proof');

    my $wrong_conf_raw = { %$good_raw,
        argv => [ '/usr/bin/perl', $main_prog, '--conf=/tmp/other.conf' ] };
    my @wrong_rt = $rprobe->{evaluate}->($wrong_conf_raw, $ctx2);
    my ($wrong_conf) = grep { $_->{id} eq 'runtime.config_identity' } @wrong_rt;
    $assert->is($wrong_conf->{level}, 'fail',
        'mb647-828: right tree with wrong --conf is a FAIL');
    $assert->ok(!$wrong_conf->{data}{config_confirmed},
        'mb647-828: wrong configuration is not identity-confirmed');

    my $no_conf_raw = { %$good_raw,
        argv => [ '/usr/bin/perl', $main_prog ] };
    my @no_conf_rt = $rprobe->{evaluate}->($no_conf_raw, $ctx2);
    my ($no_conf) = grep { $_->{id} eq 'runtime.config_identity' } @no_conf_rt;
    $assert->is($no_conf->{level}, 'fail',
        'mb647-828: running Mediabot without expected --conf is a FAIL');

    my $src = do {
        open my $fh, '<:encoding(UTF-8)', $TOOL or die $!;
        local $/; <$fh>
    };
    $assert->ok($src !~ /['"]mediabot['"]\s*(?:eq|==)/,
        'mb647-828: system user is not hardcoded');

    # ---------------------------------------------------------------------
    # [5] Filesystem round-1 perimeter and identity-aware permissions
    # ---------------------------------------------------------------------
    my $fprobe = $main::PROBES{filesystem};
    my $fr = [ $fprobe->{collect}->($ctx2) ];
    my %ids = map { $_->{id} => 1 } @$fr;
    for my $id (qw(main_program version_file module_dir sample_conf config_file
                   project_dir parent_dir achievements)) {
        $assert->ok($ids{$id}, "mb647-828: filesystem collects $id");
    }

    {
        my @ff = $fprobe->{evaluate}->(
            [ { id => 'achievements', key => 'main.ACHIEVEMENTS_PATH',
                kind => 'file', path => "$dir/nowhere.json", exists => 0,
                source => 'test' } ], $ctx2);
        $assert->is($ff[0]{level}, 'info',
            'mb647-828: absent legacy achievements JSON is INFO');
        $assert->is($ff[0]{data}{legacy_fallback}, 'unknown',
            'mb647-828: JSON fallback truth stays with future DB probe');
    }

    {
        my $direct_ctx = { %$ctx2, main_program_invocation_mode => 'direct' };
        my @ff = $fprobe->{evaluate}->(
            [ { id => 'main_program', kind => 'file', path => '/x/mediabot.pl',
                exists => 1, is_dir => 0, mode => '0640', uid => $>, gid => $( + 0,
                executable => 1, required => 1, source => 'test',
                observer_readable => 1, observer_writable => 1, observer_executable => 0 } ],
            $direct_ctx);
        $assert->is($ff[0]{level}, 'fail',
            'mb647-828: direct mediabot.pl execution without +x is FAIL');
        $assert->like($ff[0]{summary}, qr/executes mediabot\.pl directly/,
            'mb647-828: direct-execution failure explains why +x is required');
    }

    {
        my $perl_ctx = { %$ctx2, main_program_invocation_mode => 'perl',
                         main_program_launcher => '/usr/bin/perl' };
        my @ff = $fprobe->{evaluate}->(
            [ { id => 'main_program', kind => 'file', path => '/x/mediabot.pl',
                exists => 1, is_dir => 0, mode => '0640', uid => $>, gid => $( + 0,
                executable => 1, required => 1, source => 'test',
                observer_readable => 1, observer_writable => 1, observer_executable => 0 } ],
            $perl_ctx);
        $assert->is($ff[0]{level}, 'warn',
            'mb647-828: perl-launched mediabot.pl without +x is packaging WARN, not runtime FAIL');
        $assert->like($ff[0]{summary}, qr/launched through perl/,
            'mb647-828: interpreted launch explains why runtime remains viable');
    }

    {
        my @ff = $fprobe->{evaluate}->(
            [ { id => 'config_file', kind => 'file', path => '/x/conf',
                exists => 1, is_dir => 0, mode => '0644', uid => $>, gid => $( + 0,
                config => 1, source => 'test',
                observer_readable => 1, observer_writable => 1, observer_executable => 0 } ],
            $ctx2);
        $assert->is($ff[0]{level}, 'warn',
            'mb647-828: overly broad config permissions are WARN');
        $assert->like($ff[0]{summary}, qr/expose access to other users/,
            'mb647-828: config permission warning explains why');
    }

    {
        my @ff = $fprobe->{evaluate}->(
            [ { id => 'main_program', kind => 'file', path => '/x/link',
                exists => 0, lstat_exists => 1, is_symlink => 1,
                broken_symlink => 1, symlink_target => '/missing',
                required => 1, source => 'test' } ], $ctx2);
        $assert->is($ff[0]{level}, 'fail',
            'mb647-828: broken symlink on required path is FAIL');
    }

    {
        my $perm_ctx = { %$ctx2, expected_uid => 4242,
                         expected_gids => [ 4343 ],
                         expected_uid_source => 'test process' };
        my @ff = $fprobe->{evaluate}->(
            [ { id => 'log_file', kind => 'file', path => '/x/log',
                exists => 1, is_dir => 0, mode => '0400',
                uid => 4242, gid => 4343, writable => 1, source => 'test',
                observer_readable => 1, observer_writable => 1, observer_executable => 0 } ],
            $perm_ctx);
        $assert->is($ff[0]{level}, 'warn',
            'mb647-828: runtime identity writeability is evaluated from mode/uid/gids');
        $assert->like($ff[0]{summary}, qr/not writable by the observed runtime identity/,
            'mb647-828: Doctor does not confuse observer/root access with bot access');
    }

    {
        my @ff = $fprobe->{evaluate}->(
            [ { id => 'config_file', kind => 'file', path => '/x/missing.conf',
                exists => 0, config => 1, source => 'test' } ], $ctx2);
        $assert->is($ff[0]{level}, 'info',
            'mb647-828: missing config does not make source tree filesystem FAIL');
    }

    # ---------------------------------------------------------------------
    # [6] Seven-domain interface survives later Doctor rounds
    # ---------------------------------------------------------------------
    $assert->is($main::PROBES{systemd}{round}, 2,
        'mb647-828: systemd interface remains the round-2 domain');
    $assert->is($main::PROBES{updater}{round}, 2,
        'mb647-828: updater interface remains the round-2 domain');
    $assert->is($main::PROBES{database}{round}, 3,
        'mb647-828: database interface is now implemented by round 3');
    $assert->is($main::PROBES{migrations}{round}, 3,
        'mb647-828: migrations interface is now implemented by round 3');

    # ---------------------------------------------------------------------
    # [7] Probe failure isolation
    # ---------------------------------------------------------------------
    {
        local $main::PROBES{filesystem}{collect} = sub { die "boom\n" };
        my $facts = main::run_probes($ctx2);
        my ($err) = grep { $_->{id} eq 'filesystem.probe_error' } @$facts;
        $assert->ok($err, 'mb647-828: probe exception becomes a finding');
        $assert->is($err->{level}, 'unknown',
            'mb647-828: failed probe is UNKNOWN, not reassuring OK');
        $assert->ok(scalar(@$facts) > 5,
            'mb647-828: one probe cannot kill remaining domains');
    }

    # ---------------------------------------------------------------------
    # [8] READY / DEGRADED / UNSAFE and strict semantics
    # ---------------------------------------------------------------------
    my $ready = main::build_report($ctx2, [
        main::_fact(domain=>'runtime',id=>'a',level=>'ok',summary=>'fine',source=>'t'),
        main::_fact(domain=>'config',id=>'b',level=>'info',summary=>'note',source=>'t'),
    ]);
    $assert->is($ready->{result}, 'READY',
        'mb647-828: OK/INFO only => READY');
    $assert->is(main::exit_code_for($ready, 0), 0,
        'mb647-828: READY exits zero');

    my $warn = main::build_report($ctx2, [
        main::_fact(domain=>'config',id=>'c',level=>'warn',summary=>'fragile',source=>'t'),
    ]);
    $assert->is($warn->{result}, 'DEGRADED',
        'mb647-828: WARN => DEGRADED');
    $assert->is(main::exit_code_for($warn, 0), 0,
        'mb647-828: WARN remains zero in normal mode');
    $assert->is(main::exit_code_for($warn, 1), 1,
        'mb647-828: WARN fails in strict mode');

    my $unknown = main::build_report($ctx2, [
        main::_fact(domain=>'runtime',id=>'d',level=>'unknown',summary=>'cannot know',source=>'t'),
    ]);
    $assert->is($unknown->{result}, 'DEGRADED',
        'mb647-828: UNKNOWN => DEGRADED');
    $assert->is(main::exit_code_for($unknown, 0), 0,
        'mb647-828: UNKNOWN remains zero in normal mode');
    $assert->is(main::exit_code_for($unknown, 1), 1,
        'mb647-828: UNKNOWN fails in strict mode');

    my $unsafe = main::build_report($ctx2, [
        main::_fact(domain=>'runtime',id=>'e',level=>'fail',summary=>'broken',source=>'t'),
    ]);
    $assert->is($unsafe->{result}, 'UNSAFE',
        'mb647-828: FAIL => UNSAFE');
    $assert->is(main::exit_code_for($unsafe, 0), 1,
        'mb647-828: UNSAFE always exits non-zero');

    my $text = main::render_text($ready);
    $assert->like($text, qr/Result:\s+READY/,
        'mb647-828: text renderer exposes global result');
    my $json = main::render_json($ready);
    $assert->like($json, qr/"schema_version"\s*:\s*1/,
        'mb647-828: JSON carries schema v1');
    $assert->like($json, qr/"result"\s*:\s*"READY"/,
        'mb647-828: JSON carries global result');
    require JSON::PP;
    my $back = JSON::PP->new->decode($json);
    $assert->is($back->{result}, 'READY',
        'mb647-828: JSON result survives decode');

    # ---------------------------------------------------------------------
    # [9] Concrete CLI regressions: typo domain and invalid root
    # ---------------------------------------------------------------------
    {
        my $out = File::Spec->catfile($dir, 'bad-domain.out');
        system("$^X \"$TOOL\" --domain databse > \"$out\" 2>&1");
        my $rc = $? >> 8;
        $assert->is($rc, 2,
            'mb647-828: unknown --domain exits 2');
        open my $fh, '<', $out or die $!; local $/; my $txt = <$fh>; close $fh;
        $assert->like($txt, qr/Unknown domain 'databse'/,
            'mb647-828: unknown domain is explicit');
    }

    {
        my $bad_root = File::Spec->catdir($dir, 'definitely-no-mediabot');
        my $out = File::Spec->catfile($dir, 'bad-root.out');
        system("$^X \"$TOOL\" --root \"$bad_root\" --domain runtime > \"$out\" 2>&1");
        my $rc = $? >> 8;
        $assert->is($rc, 1,
            'mb647-828: nonexistent root cannot return RC=0');
        open my $fh, '<', $out or die $!; local $/; my $txt = <$fh>; close $fh;
        $assert->like($txt, qr/Result:\s+UNSAFE/,
            'mb647-828: nonexistent root is UNSAFE');
    }

    {
        my $missing_conf = File::Spec->catfile($dir, 'not-configured.conf');
        my $out = File::Spec->catfile($dir, 'missing-conf.out');
        system("$^X \"$TOOL\" --root \"$tree\" --conf \"$missing_conf\" "
             . "--domain config > \"$out\" 2>&1");
        my $rc = $? >> 8;
        $assert->is($rc, 0,
            'mb647-828: unconfigured source tree remains inspectable in normal mode');
        open my $fh, '<', $out or die $!; local $/; my $txt = <$fh>; close $fh;
        $assert->like($txt, qr/Result:\s+DEGRADED/,
            'mb647-828: missing config is DEGRADED, not READY or UNSAFE');
    }
};
