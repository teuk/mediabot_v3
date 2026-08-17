# t/cases/829_mb648_doctor_systemd_updater.t
# =============================================================================
# mb648 — Mediabot Doctor, round 2 : systemd + updater/deployment.
#
# Locks the rules, not a particular host:
#   - runtime manager / marker / actual unit contract are independent truths;
#   - a lying marker is FAIL, a safe old unit without marker is WARN;
#   - updater eligibility reuses Mediabot::Update semantics;
#   - non-Git deployments are normal;
#   - archive scanning is exact-family only;
#   - 0660/0640 on a genuinely private runtime group is not a false warning.
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

    my $loaded = do $TOOL;
    $assert->ok($loaded, 'mb648-829: Doctor loads');
    $assert->is($main::PROBES{systemd}{round}, 2,
        'mb648-829: systemd is implemented in round 2');
    $assert->is($main::PROBES{updater}{round}, 2,
        'mb648-829: updater is implemented in round 2');

    # ------------------------------------------------------------------
    # [1] systemd: the three truths must remain separate
    # ------------------------------------------------------------------
    my $sprobe = $main::PROBES{systemd};
    my $ctx = { observed_pid => 1234 };

    my @safe = $sprobe->{evaluate}->({
        pid => 1234,
        cgroup_readable => 1,
        unit => 'mediabot@dev.service',
        environ_readable => 1,
        marker_present => 1,
        marker_safe => 1,
        systemctl => '/usr/bin/systemctl',
        properties => {
            Restart => 'always',
            ExitType => 'cgroup',
            SuccessExitStatus => '75',
            RestartPreventExitStatus => '75',
        },
    }, $ctx);
    my %safe = map { $_->{id} => $_ } @safe;
    $assert->is($safe{'systemd.runtime_manager'}{level}, 'ok',
        'mb648-829: systemd runtime manager is independently OK');
    $assert->is($safe{'systemd.safe_update_marker'}{level}, 'ok',
        'mb648-829: process marker is independently OK');
    $assert->is($safe{'systemd.actual_contract'}{level}, 'ok',
        'mb648-829: actual lifecycle contract is independently OK');
    $assert->is($safe{'systemd.contract_consistency'}{level}, 'ok',
        'mb648-829: three agreeing truths are OK');

    my @lying = $sprobe->{evaluate}->({
        pid => 1234,
        cgroup_readable => 1,
        unit => 'mediabot@dev.service',
        environ_readable => 1,
        marker_present => 1,
        marker_safe => 1,
        systemctl => '/usr/bin/systemctl',
        properties => {
            Restart => 'on-failure',
            ExitType => 'main',
            SuccessExitStatus => '75',
            RestartPreventExitStatus => '75',
        },
    }, $ctx);
    my %lying = map { $_->{id} => $_ } @lying;
    $assert->is($lying{'systemd.actual_contract'}{level}, 'fail',
        'mb648-829: unsafe actual unit is FAIL');
    $assert->is($lying{'systemd.contract_consistency'}{level}, 'fail',
        'mb648-829: marker=1 cannot overrule an unsafe real unit');

    my @old = $sprobe->{evaluate}->({
        pid => 1234,
        cgroup_readable => 1,
        unit => 'mediabot@dev.service',
        environ_readable => 1,
        marker_present => 0,
        marker_safe => 0,
        systemctl => '/usr/bin/systemctl',
        properties => {
            Restart => 'always',
            ExitType => 'cgroup',
            SuccessExitStatus => '75',
            RestartPreventExitStatus => '75',
        },
    }, $ctx);
    my %old = map { $_->{id} => $_ } @old;
    $assert->is($old{'systemd.actual_contract'}{level}, 'ok',
        'mb648-829: actual safe unit stays OK without marker');
    $assert->is($old{'systemd.safe_update_marker'}{level}, 'warn',
        'mb648-829: missing marker under systemd is WARN');
    $assert->is($old{'systemd.contract_consistency'}{level}, 'warn',
        'mb648-829: safe unit plus stale process environment is visible');

    my $legacy_ctx = { observed_pid => 1234,
                       builtin_updater_eligible => 0,
                       builtin_updater_intentionally_inapplicable => 1 };
    my @legacy = $sprobe->{evaluate}->({
        pid => 1234,
        cgroup_readable => 1,
        unit => 'mediabot@undernet.service',
        environ_readable => 1,
        marker_present => 0,
        marker_safe => 0,
        systemctl => '/usr/bin/systemctl',
        properties => {
            Restart => 'on-failure',
            ExitType => 'main',
            SuccessExitStatus => '',
            RestartPreventExitStatus => '',
        },
    }, $legacy_ctx);
    my %legacy = map { $_->{id} => $_ } @legacy;
    $assert->is($legacy{'systemd.safe_update_marker'}{level}, 'info',
        'mb648-829: missing MB645 marker is INFO when built-in updater is intentionally inapplicable');
    $assert->is($legacy{'systemd.actual_contract'}{level}, 'info',
        'mb648-829: legacy systemd lifecycle is not UNSAFE when that updater contract is not used');
    $assert->like($legacy{'systemd.actual_contract'}{summary}, qr/not applicable/i,
        'mb648-829: legacy-systemd rationale names updater applicability');
    $assert->ok(!exists $legacy{'systemd.contract_consistency'},
        'mb648-829: absent marker plus legacy contract does not invent a consistency failure');

    my @legacy_but_needed = $sprobe->{evaluate}->({
        pid => 1234,
        cgroup_readable => 1,
        unit => 'mediabot@nbot.service',
        environ_readable => 1,
        marker_present => 0,
        marker_safe => 0,
        systemctl => '/usr/bin/systemctl',
        properties => {
            Restart => 'on-failure',
            ExitType => 'main',
            SuccessExitStatus => '',
            RestartPreventExitStatus => '',
        },
    }, { observed_pid => 1234, builtin_updater_eligible => 1,
         builtin_updater_intentionally_inapplicable => 0 });
    my %legacy_but_needed = map { $_->{id} => $_ } @legacy_but_needed;
    $assert->is($legacy_but_needed{'systemd.actual_contract'}{level}, 'fail',
        'mb648-829: same legacy lifecycle is FAIL when built-in updater is applicable');

    my @manual = $sprobe->{evaluate}->({
        pid => 1234,
        cgroup_readable => 1,
        environ_readable => 1,
        marker_present => 0,
        marker_safe => 0,
    }, $ctx);
    my %manual = map { $_->{id} => $_ } @manual;
    $assert->is($manual{'systemd.runtime_manager'}{level}, 'info',
        'mb648-829: manual runtime is supported, not failure');
    $assert->is($manual{'systemd.actual_contract'}{level}, 'info',
        'mb648-829: systemd contract is not applicable to manual runtime');

    $assert->ok(main::_status_has_75('75'),
        'mb648-829: numeric exit 75 recognised');
    $assert->ok(main::_status_has_75('TEMPFAIL'),
        'mb648-829: symbolic EX_TEMPFAIL recognised as 75');
    $assert->ok(!main::_status_has_75('0 1 2'),
        'mb648-829: unrelated exit statuses do not fake exit75 policy');

    # ------------------------------------------------------------------
    # [2] deployment-family isolation
    # ------------------------------------------------------------------
    my $tmp = tempdir(CLEANUP => 1);
    my $root = File::Spec->catdir($tmp, 'mediabot3');
    mkdir $root or die $!;
    for my $d (
        'mediabot3.120',
        'mediabot3.old.20260816_170238',
        'mediabot_v3.999',
        'mediabot_v3.old.20260816_170239',
        'mediabot3.old.bad',
    ) {
        mkdir File::Spec->catdir($tmp, $d) or die $!;
    }
    my $fam = main::_scan_deployment_family($root);
    $assert->ok($fam->{ok}, 'mb648-829: deployment family scan succeeds');
    $assert->is($fam->{family}, 'mediabot3',
        'mb648-829: family derives from exact current root basename');
    $assert->is(join(',', @{ $fam->{archives} }),
        'mediabot3.120,mediabot3.old.20260816_170238',
        'mb648-829: only exact mediabot3 archive forms are accepted');
    $assert->ok((grep { $_ eq 'mediabot_v3.999' } @{ $fam->{ignored_sibling_families} }),
        'mb648-829: numeric sibling deployment family is explicitly ignored');
    $assert->ok((grep { $_ eq 'mediabot_v3.old.20260816_170239' } @{ $fam->{ignored_sibling_families} }),
        'mb648-829: timestamp sibling deployment family is explicitly ignored');
    $assert->ok(!(grep { $_ eq 'mediabot3.old.bad' } @{ $fam->{archives} }),
        'mb648-829: malformed archive name is not accepted');

    # ------------------------------------------------------------------
    # [3] updater evaluator semantics
    # ------------------------------------------------------------------
    my $uprobe = $main::PROBES{updater};
    my @protected = $uprobe->{evaluate}->({
        eligible => 0,
        eligibility_reason => 'this installation is protected (/srv/mediabot on example.org) - update it manually',
        family => { ok => 1, family => 'mediabot_v3', parent => '/srv',
                    archives => [], ignored_sibling_families => [] },
        git_executable => '/usr/bin/git',
        git => { is_repo => 0 },
    }, {});
    my %protected = map { $_->{id} => $_ } @protected;
    $assert->is($protected{'updater.eligibility'}{level}, 'info',
        'mb648-829: intentional path+host protection is INFO, not degradation');
    $assert->is($protected{'updater.git'}{level}, 'info',
        'mb648-829: non-Git deployment is explicitly supported');

    my @broken = $uprobe->{evaluate}->({
        eligible => 0,
        eligibility_reason => 'install/deploy_update.sh is not executable',
        family => { ok => 1, family => 'mediabot_v3', parent => '/srv',
                    archives => [], ignored_sibling_families => [] },
        git_executable => '/usr/bin/git',
        git => { is_repo => 1, dirty_count => 3, branch => 'master', head => 'deadbeef' },
    }, {});
    my %broken = map { $_->{id} => $_ } @broken;
    $assert->is($broken{'updater.eligibility'}{level}, 'warn',
        'mb648-829: operational updater defect is WARN');
    $assert->is($broken{'updater.git'}{level}, 'warn',
        'mb648-829: dirty Git tree is WARN before an update');
    $assert->is($broken{'updater.git'}{data}{network_used}, 0,
        'mb648-829: Git diagnostic explicitly performs no network access');

    # ------------------------------------------------------------------
    # [4] private service-group config permissions
    # ------------------------------------------------------------------
    my @pw = getpwuid($>);
    my $user = $pw[0];
    my $gid  = $pw[3];
    my $fprobe = $main::PROBES{filesystem};
    my $perm_ctx = {
        expected_uid => $>, expected_gids => [ $gid ],
        expected_uid_source => 'test process',
    };
    my $private_entry = {
        id => 'config_file', kind => 'file', path => '/x/conf',
        exists => 1, is_dir => 0, mode => '0660', uid => $>, gid => $gid,
        config => 1, source => 'test',
        group_snapshot => { group_name => 'private-service', primary_users => [ $user ], members => [] },
        observer_readable => 1, observer_writable => 1, observer_executable => 0,
    };
    my @private = $fprobe->{evaluate}->([ $private_entry ], $perm_ctx);
    $assert->is($private[0]{level}, 'ok',
        'mb648-829: 0660 on a private runtime group is OK');
    $assert->like($private[0]{detail}, qr/private runtime group/,
        'mb648-829: private-group rationale remains visible');

    my $shared_entry = { %$private_entry,
        group_snapshot => { group_name => 'shared', primary_users => [ $user, 'otheruser' ], members => [] },
    };
    my @shared = $fprobe->{evaluate}->([ $shared_entry ], $perm_ctx);
    $assert->is($shared[0]{level}, 'warn',
        'mb648-829: same 0660 becomes WARN when the group is shared');
    $assert->like($shared[0]{summary}, qr/accessible beyond the runtime user/,
        'mb648-829: shared-group warning explains the actual risk');

    # ------------------------------------------------------------------
    # [5] --domain filtering must preserve probe dependencies
    # ------------------------------------------------------------------
    {
        local $main::PROBES{runtime}{collect} = sub { return {}; };
        local $main::PROBES{runtime}{evaluate} = sub {
            return (
                main::_fact(
                    domain => 'runtime', id => 'runtime.state', level => 'ok',
                    summary => 'fixture runtime', source => 'test fixture',
                    data => { running => 1, pid => 4242 },
                ),
                main::_fact(
                    domain => 'runtime', id => 'runtime.process_owner', level => 'info',
                    summary => 'fixture owner', source => 'test fixture',
                    data => { uid => 31337, gids => [ 31337 ] },
                ),
            );
        };
        local $main::PROBES{updater}{collect} = sub {
            my ($dep_ctx) = @_;
            return { seen_uid => $dep_ctx->{expected_uid} };
        };
        local $main::PROBES{updater}{evaluate} = sub {
            my ($raw) = @_;
            return main::_fact(
                domain => 'updater', id => 'updater.eligibility', level => 'info',
                summary => 'fixture updater intentionally inapplicable',
                detail => 'fixture custom deployment', source => 'test fixture',
                data => { eligible => 0, intentional => 1, seen_uid => $raw->{seen_uid} },
            );
        };
        local $main::PROBES{systemd}{collect} = sub {
            my ($dep_ctx) = @_;
            return { seen_pid => $dep_ctx->{observed_pid},
                     seen_uid => $dep_ctx->{expected_uid},
                     updater_irrelevant => $dep_ctx->{builtin_updater_intentionally_inapplicable} };
        };
        local $main::PROBES{systemd}{evaluate} = sub {
            my ($raw) = @_;
            return main::_fact(
                domain => 'systemd', id => 'systemd.dependency_fixture', level => 'ok',
                summary => 'runtime dependency visible', source => 'test fixture',
                data => { seen_pid => $raw->{seen_pid}, seen_uid => $raw->{seen_uid},
                          updater_irrelevant => $raw->{updater_irrelevant} },
            );
        };

        my $dep_ctx = {};
        my $facts = main::run_probes($dep_ctx, only => { systemd => 1 });
        $assert->is(scalar(@$facts), 1,
            'mb648-829: hidden runtime dependency does not leak runtime findings into --domain systemd');
        $assert->is($facts->[0]{domain}, 'systemd',
            'mb648-829: requested domain remains the only rendered domain');
        $assert->is($facts->[0]{data}{seen_pid}, 4242,
            'mb648-829: --domain systemd still receives PID established by runtime');
        $assert->is($facts->[0]{data}{seen_uid}, 31337,
            'mb648-829: --domain systemd still receives runtime identity context');
        $assert->ok($facts->[0]{data}{updater_irrelevant},
            'mb648-829: --domain systemd silently receives updater applicability context');
        $assert->ok($dep_ctx->{builtin_updater_intentionally_inapplicable},
            'mb648-829: hidden updater dependency enriches shared context without leaking output');

        local $main::PROBES{filesystem}{collect} = sub {
            my ($dep_ctx) = @_;
            return { seen_pid => $dep_ctx->{observed_pid},
                     seen_uid => $dep_ctx->{expected_uid} };
        };
        local $main::PROBES{filesystem}{evaluate} = sub {
            my ($raw) = @_;
            return main::_fact(
                domain => 'filesystem', id => 'filesystem.dependency_fixture', level => 'ok',
                summary => 'runtime identity dependency visible', source => 'test fixture',
                data => { seen_pid => $raw->{seen_pid}, seen_uid => $raw->{seen_uid} },
            );
        };

        my $fs_ctx = {};
        my $fs_facts = main::run_probes($fs_ctx, only => { filesystem => 1 });
        $assert->is(scalar(@$fs_facts), 1,
            'mb648-829: hidden runtime dependency does not leak runtime findings into --domain filesystem');
        $assert->is($fs_facts->[0]{data}{seen_pid}, 4242,
            'mb648-829: --domain filesystem still receives PID context');
        $assert->is($fs_facts->[0]{data}{seen_uid}, 31337,
            'mb648-829: --domain filesystem still receives runtime identity context');

        my $up_ctx = {};
        my $up_facts = main::run_probes($up_ctx, only => { updater => 1 });
        $assert->is(scalar(@$up_facts), 1,
            'mb648-829: --domain updater hides its runtime dependency');
        $assert->is($up_facts->[0]{data}{seen_uid}, 31337,
            'mb648-829: --domain updater uses the observed runtime identity');
    }
};
