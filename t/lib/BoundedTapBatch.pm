package BoundedTapBatch;
use strict;
use warnings;
use Exporter 'import';
use IO::Handle ();
use File::Temp qw(tempdir);
use File::Basename qw(basename);
use POSIX qw(WNOHANG _exit setsid);
use Errno qw(EINTR);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC sleep);
our @EXPORT_OK = qw(approved_case run_batch);

# Explicitly reviewed offline cases only. Classifier tags never grant admission.
# See docs/DEVELOPING.md, MB1336, for resources and exclusions.
my %approved = map { $_ => 1 } qw(
    1167_mb807_dynamic_registry.t
    1187_mb818_meta_runtime.t
    1192_mb820_meta_local_knowledge.t
    1196_mb822_provider_probe.t
    1202_mb826_open_domain_requests.t
    1222_mb838_xauth_commands.t
    1226_mb840_async_delivery_context.t
    1230_mb842_metaai_chanset.t
    1231_mb842_metaai_rights_delivery.t
    1232_mb842_channel_tool.t
    1240_mb846_meta_delivery_recovery.t
    1245_mb849_dtc_shared_display.t
    1271_mb862_dtc_clipped_delivery.t
    1279_mb867_youtube_response_contract.t
    1282_mb868_rss_validator_lifecycle.t
    1286_mb871_facebook_cache_identity.t
    1287_mb871_x_cache_identity.t
    1291_mb873_dtc_search_delivery.t
    1296_mb876_external_module_boundaries.t
    1300_mb878_tmdb_module_boundaries.t
    1302_mb879_text_budget_contracts.t
    1304_mb880_irc_module_contracts.t
    1306_mb881_irc_output_policy.t
    1308_mb881_irc_sanitizer_audit.t
    1322_mb948_roadmap_completion.t
    1337_mb961_reminder_snapshot_and_delay.t
    1339_mb963_reminder_local_calendar.t
    1358_mb982_karma_hyphenated_targets.t
    1359_mb983_trivia_stop_lifecycle.t
    1361_mb985_duel_atomic_karma.t
    1365_mb990_trivia_languages.t
    1367_mb992_poll_weighted_prefix.t
    1368_mb993_roll_default_modifiers.t
    1369_mb994_birthday_read_errors.t
    1370_mb995_choose_zero_history.t
    1371_mb996_choose_distinct_options.t
    1373_mb998_weather_compare_cache_age.t
    1376_mb1001_meteo_compare_alias.t
    1378_mb1003_weather_cache_clock.t
    1381_mb1006_chance_numeric_tokens.t
    1382_mb1007_trivia_answer_deadline.t
    1384_mb1009_urgent_reminder_delay.t
    1385_mb1010_poll_vote_tokens.t
    1392_mb1017_channel_case_duels.t
    1397_mb1022_release37_final_gate.t
    1398_mb1025_compat_stable_vocabulary.t
    1405_mb1032_shell_channel_context.t
    1407_mb1034_poll_channel_case.t
    1408_mb1035_karma_graph_window.t
    1409_mb1036_operator_cooldown_identity.t
    1423_mb1050_ban_expiry_retry.t
    1426_mb1053_radar_calendar_window.t
    1429_mb1056_channel_flood_identity.t
    1430_mb1057_dcc_numeric_boundaries.t
    1431_mb1058_native_alias_inventory.t
    1432_mb1059_community_storage_suite.t
    1433_mb1059_quote_storage_suite.t
    1434_mb1059_user_read_suite.t
    1435_mb1061_external_behavior_suite.t
    1436_mb1061_ai_behavior_suite.t
    1540_mb1334_ai_contracts.t
    1540_mb1334_contracts_contracts.t
    1540_mb1334_native_contracts.t
    1540_mb1334_text_contracts.t
    1541_mb1335_delivery_contracts.t
    1541_mb1335_lifecycle_contracts.t
    197_partyline_login_no_password_select.t
    236_usercommands_karmahist.t
    335_antiflood_chanflood_public_only.t
    512_mb289_choose_reference_plugin.t
    520_mb298_calc_reference_plugin.t
    691_mb480_stats_achievements.t
);
sub approved_case { return $approved{basename($_[0])} // 0 }

sub run_batch {
    my ($files, %opts) = @_;
    my $jobs = $opts{jobs} // 2;
    my $timeout = $opts{timeout} // 300;
    die 'jobs must be 1 or 2' unless $jobs == 1 || $jobs == 2;
    die 'timeout must be positive' unless $timeout > 0;
    my $dir = tempdir('mediabot-tap-batch-XXXXXX', TMPDIR=>1, CLEANUP=>1);
    my (%running, $next);
    $next = 0;
    my $now = sub { clock_gettime(CLOCK_MONOTONIC) };
    my $stop = sub {
        my ($pid) = @_;
        # The exec interpreter owns its process group; never signal our group.
        kill 'KILL', -$pid;
        kill 'KILL', $pid;
        my $waited;
        do { $waited = waitpid($pid, 0) } while $waited < 0 && $! == EINTR;
        return $?;
    };
    my $ok = eval {
        local $SIG{INT} = sub { die "TAP batch interrupted\n" };
        local $SIG{TERM} = sub { die "TAP batch terminated\n" };
        local $SIG{HUP} = local $SIG{PIPE} = sub { die "TAP batch output interrupted\n" };
        while ($next < @$files || keys %running) {
            while ($next < @$files && keys(%running) < $jobs) {
                my $index = $next++;
                my $file = $files->[$index];
                my $path = "$dir/$index.tap";
                STDOUT->flush; STDERR->flush;
                my $pid = fork();
                die "Cannot fork TAP case: $!" unless defined $pid;
                if (!$pid) {
                    $SIG{INT} = $SIG{TERM} = $SIG{HUP} = $SIG{PIPE} = 'DEFAULT';
                    setsid() >= 0 or _exit(254);
                    open STDIN, '<', '/dev/null' or _exit(254);
                    open STDOUT, '>:raw', $path or _exit(254);
                    open STDERR, '>&', STDOUT or _exit(254);
                    chdir $opts{root} or _exit(254);
                    no warnings 'exec';
                    exec $^X, "-I$opts{root}/t/lib", "-I$opts{root}", $file;
                    _exit(254);
                }
                $running{$pid} = {file=>$file, path=>$path, started=>$now->()};
                $opts{on_start}->($file) if $opts{on_start};
            }
            for my $pid (sort {$a <=> $b} keys %running) {
                my $row = $running{$pid};
                my $waited = waitpid($pid, WNOHANG);
                my $status = $?;
                next if $waited < 0 && $! == EINTR;
                die "Cannot reap TAP case $pid: $!" if $waited < 0;
                my $elapsed = $now->() - $row->{started};
                my $expired = !$waited && $elapsed >= $timeout;
                if ($expired) { $status = $stop->($pid); $waited = $pid }
                next unless $waited;
                # A leader can exit before its descendants. Retire only its own
                # session group before reading TAP or admitting another suite.
                # Keep the saved leader status: cleanup must not mask failure.
                kill 'KILL', -$pid;
                delete $running{$pid};
                my $output = '';
                if (open my $fh, '<:raw', $row->{path}) { local $/; $output = <$fh> // '' }
                if ($expired) {
                    $output .= "\nBail out! isolated case exceeded ${timeout}s\n";
                    $status ||= 256;
                }
                $opts{on_finish}->($row->{file}, {output=>$output, status=>$status,
                    closed=>$status == 0, elapsed=>$elapsed, timed_out=>$expired ? 1 : 0});
            }
            sleep(0.01) if keys %running;
        }
        1;
    };
    my $error = $@;
    unless ($ok) {
        $stop->($_) for keys %running;
        die $error;
    }
    return 1;
}
1;
