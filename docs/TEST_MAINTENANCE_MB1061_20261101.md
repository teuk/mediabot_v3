# MB1061 — Keep executable regressions and remove historical pins

Base: qualified MB1060 on MB1059, from
`snap_mediabot_v3_teuk_20261101_135555.zip`.
VERSION remains `3.8dev-20261101_125511` in the prepared sources;
the installed native commit helper chooses its next timestamp.

## Actual pruning

Sixty-five complete cases are deleted. Another 167 one-line assertions that
only require a literal historical `mbNNN-Bn` comment are removed from 132
remaining cases. Runtime side-effect marker files, authentication boundaries,
secret/redaction checks and real success/failure assertions are retained.
This deliberately stops enforcing historical wording and implementation shape;
it does not claim every removed constraint has an exact runtime equivalent,
or that pruning can prove no regression is possible.

The default full command still discovers every remaining case. No default
filter, cached result, skip-on-failure rule, parallel executor or subtest-count
compression is introduced. MB1060's ETA and Chromium fixture fix remain intact.

## Removed cases

| Case | Decision |
| --- | --- |
| `1006_mb710_reanimator_runtime_wiring.t` | Retire historical source-location and wiring regexps; preserve executable Spark, VDM, Partyline/plugin and update-state scenarios. No runtime route or default is removed. |
| `1010_mb710_reanimator_adaptive_wiring.t` | Retire historical source-location and wiring regexps; preserve executable Spark, VDM, Partyline/plugin and update-state scenarios. No runtime route or default is removed. |
| `1014_mb710_mosaic_runtime_wiring.t` | Retire historical source-location and wiring regexps; preserve executable Spark, VDM, Partyline/plugin and update-state scenarios. No runtime route or default is removed. |
| `1036_mb723b_session_request_security.t` | Retire historical release/help/audit prose and tests of other tests. Native release/version checks, the security audit, mbweb Node behavior tests and actual command handlers remain. |
| `1039_mb724_cross_cutting_security_contract.t` | Retire historical release/help/audit prose and tests of other tests. Native release/version checks, the security audit, mbweb Node behavior tests and actual command handlers remain. |
| `1041_mb726_release_rehearsal_contract.t` | Retire historical release/help/audit prose and tests of other tests. Native release/version checks, the security audit, mbweb Node behavior tests and actual command handlers remain. |
| `1044_mb727_stable_release_contract.t` | Retire historical release/help/audit prose and tests of other tests. Native release/version checks, the security audit, mbweb Node behavior tests and actual command handlers remain. |
| `1045_mb728_github_release_identity.t` | Retire historical release/help/audit prose and tests of other tests. Native release/version checks, the security audit, mbweb Node behavior tests and actual command handlers remain. |
| `104_configure_generated_runtime_keys.t` | Retire sample/wizard wording, key-location, default-example and documentation repetition; preserve native configuration, DCC/authentication, empty-secret and fresh-install checks. |
| `1093_mb750_partyline_plugin_doctor.t` | Retire historical source-location and wiring regexps; preserve executable Spark, VDM, Partyline/plugin and update-state scenarios. No runtime route or default is removed. |
| `1096_mb751_partyline_plugin_failures.t` | Retire historical source-location and wiring regexps; preserve executable Spark, VDM, Partyline/plugin and update-state scenarios. No runtime route or default is removed. |
| `1099_mb752_partyline_manual_quarantine.t` | Retire historical source-location and wiring regexps; preserve executable Spark, VDM, Partyline/plugin and update-state scenarios. No runtime route or default is removed. |
| `110_conn_bind_ip_config_defaults.t` | Retire sample/wizard wording, key-location, default-example and documentation repetition; preserve native configuration, DCC/authentication, empty-secret and fresh-install checks. |
| `111_configure_connection_optional_keys.t` | Retire sample/wizard wording, key-location, default-example and documentation repetition; preserve native configuration, DCC/authentication, empty-secret and fresh-install checks. |
| `112_sample_no_legacy_radio_keys.t` | Retire sample/wizard wording, key-location, default-example and documentation repetition; preserve native configuration, DCC/authentication, empty-secret and fresh-install checks. |
| `1130_mb764_partyline_v3_overview.t` | Retire historical source-location and wiring regexps; preserve executable Spark, VDM, Partyline/plugin and update-state scenarios. No runtime route or default is removed. |
| `1147_mb772_update_plugin_state_preservation.t` | Retire historical source-location and wiring regexps; preserve executable Spark, VDM, Partyline/plugin and update-state scenarios. No runtime route or default is removed. |
| `122_contrib_icecast_usage_and_source.t` | Retire sample/wizard wording, key-location, default-example and documentation repetition; preserve native configuration, DCC/authentication, empty-secret and fresh-install checks. |
| `123_contrib_icecast_source_selection.t` | Retire sample/wizard wording, key-location, default-example and documentation repetition; preserve native configuration, DCC/authentication, empty-secret and fresh-install checks. |
| `127_configure_no_dead_alternate_nick_prompt.t` | Retire sample/wizard wording, key-location, default-example and documentation repetition; preserve native configuration, DCC/authentication, empty-secret and fresh-install checks. |
| `132_db_install_config_update_message.t` | Retire sample/wizard wording, key-location, default-example and documentation repetition; preserve native configuration, DCC/authentication, empty-secret and fresh-install checks. |
| `136_conf_servers_write_network_safe.t` | Retire sample/wizard wording, key-location, default-example and documentation repetition; preserve native configuration, DCC/authentication, empty-secret and fresh-install checks. |
| `167_chatgpt_json_structure_guard.t` | Retire old helper-name, expression-spelling, response-layout and caller wiring pins; preserve native provider/client, URL identity, metadata shape, UTF-8/byte-budget and AI state regressions. |
| `170_fortnite_stats_nested_hash_guards.t` | Retire old helper-name, expression-spelling, response-layout and caller wiring pins; preserve native provider/client, URL identity, metadata shape, UTF-8/byte-budget and AI state regressions. |
| `172_display_youtube_details_structure_guards.t` | Retire old helper-name, expression-spelling, response-layout and caller wiring pins; preserve native provider/client, URL identity, metadata shape, UTF-8/byte-budget and AI state regressions. |
| `173_youtube_oembed_requires_hash.t` | Retire old helper-name, expression-spelling, response-layout and caller wiring pins; preserve native provider/client, URL identity, metadata shape, UTF-8/byte-budget and AI state regressions. |
| `174_fortnite_response_must_be_hash.t` | Retire old helper-name, expression-spelling, response-layout and caller wiring pins; preserve native provider/client, URL identity, metadata shape, UTF-8/byte-budget and AI state regressions. |
| `179_chatgpt_openai_runtime_config.t` | Retire old helper-name, expression-spelling, response-layout and caller wiring pins; preserve native provider/client, URL identity, metadata shape, UTF-8/byte-budget and AI state regressions. |
| `182_openai_fallback_model.t` | Retire old helper-name, expression-spelling, response-layout and caller wiring pins; preserve native provider/client, URL identity, metadata shape, UTF-8/byte-budget and AI state regressions. |
| `184_openai_admin_profiles.t` | Retire old helper-name, expression-spelling, response-layout and caller wiring pins; preserve native provider/client, URL identity, metadata shape, UTF-8/byte-budget and AI state regressions. |
| `199_youtube_colors_transparent_background.t` | Retire old helper-name, expression-spelling, response-layout and caller wiring pins; preserve native provider/client, URL identity, metadata shape, UTF-8/byte-budget and AI state regressions. |
| `200_urltitle_badge_reset_stringify.t` | Retire old helper-name, expression-spelling, response-layout and caller wiring pins; preserve native provider/client, URL identity, metadata shape, UTF-8/byte-budget and AI state regressions. |
| `203_youtube_helpers_getdetails_regression.t` | Retire old helper-name, expression-spelling, response-layout and caller wiring pins; preserve native provider/client, URL identity, metadata shape, UTF-8/byte-budget and AI state regressions. |
| `205_youtube_search_http_guard_regression.t` | Retire old helper-name, expression-spelling, response-layout and caller wiring pins; preserve native provider/client, URL identity, metadata shape, UTF-8/byte-budget and AI state regressions. |
| `207_helpers_http_guard_regression.t` | Retire old helper-name, expression-spelling, response-layout and caller wiring pins; preserve native provider/client, URL identity, metadata shape, UTF-8/byte-budget and AI state regressions. |
| `224_external_claude_history.t` | Retire old helper-name, expression-spelling, response-layout and caller wiring pins; preserve native provider/client, URL identity, metadata shape, UTF-8/byte-budget and AI state regressions. |
| `226_external_claude_ratelimit.t` | Retire old helper-name, expression-spelling, response-layout and caller wiring pins; preserve native provider/client, URL identity, metadata shape, UTF-8/byte-budget and AI state regressions. |
| `227_external_claude_callback.t` | Retire old helper-name, expression-spelling, response-layout and caller wiring pins; preserve native provider/client, URL identity, metadata shape, UTF-8/byte-budget and AI state regressions. |
| `235_external_claude_persona.t` | Retire old helper-name, expression-spelling, response-layout and caller wiring pins; preserve native provider/client, URL identity, metadata shape, UTF-8/byte-budget and AI state regressions. |
| `381_help_table_recent_cleanup.t` | Retire historical release/help/audit prose and tests of other tests. Native release/version checks, the security audit, mbweb Node behavior tests and actual command handlers remain. |
| `431_mb192_sample_conf_scriptdryrun_docs.t` | Retire sample/wizard wording, key-location, default-example and documentation repetition; preserve native configuration, DCC/authentication, empty-secret and fresh-install checks. |
| `598_mb378_configure_fresh_existing_drift_workflow.t` | Retire sample/wizard wording, key-location, default-example and documentation repetition; preserve native configuration, DCC/authentication, empty-secret and fresh-install checks. |
| `631_mb416_precommit_audit_contracts.t` | Retire historical release/help/audit prose and tests of other tests. Native release/version checks, the security audit, mbweb Node behavior tests and actual command handlers remain. |
| `701_mb490_help_stats_collision.t` | Retire historical release/help/audit prose and tests of other tests. Native release/version checks, the security audit, mbweb Node behavior tests and actual command handlers remain. |
| `721_mb512_release_packaging_contract.t` | Retire historical release/help/audit prose and tests of other tests. Native release/version checks, the security audit, mbweb Node behavior tests and actual command handlers remain. |
| `788_mb605_precommit_truthfulness.t` | Retire historical release/help/audit prose and tests of other tests. Native release/version checks, the security audit, mbweb Node behavior tests and actual command handlers remain. |
| `811_mb628_precommit_runtime_test_coherence.t` | Retire historical release/help/audit prose and tests of other tests. Native release/version checks, the security audit, mbweb Node behavior tests and actual command handlers remain. |
| `819_mb639_remote_version_precommit_truth.t` | Retire historical release/help/audit prose and tests of other tests. Native release/version checks, the security audit, mbweb Node behavior tests and actual command handlers remain. |
| `903_mb693_rss_runtime_scheduler.t` | Retire historical source-location and wiring regexps; preserve executable Spark, VDM, Partyline/plugin and update-state scenarios. No runtime route or default is removed. |
| `906_mb694_rss_command_polish.t` | Retire historical source-location and wiring regexps; preserve executable Spark, VDM, Partyline/plugin and update-state scenarios. No runtime route or default is removed. |
| `92_radio_sample_conf_icecast_keys.t` | Retire sample/wizard wording, key-location, default-example and documentation repetition; preserve native configuration, DCC/authentication, empty-secret and fresh-install checks. |
| `94_sample_conf_runtime_keys.t` | Retire sample/wizard wording, key-location, default-example and documentation repetition; preserve native configuration, DCC/authentication, empty-secret and fresh-install checks. |
| `955_mb703_spark_runtime_wiring_disarmed.t` | Retire historical source-location and wiring regexps; preserve executable Spark, VDM, Partyline/plugin and update-state scenarios. No runtime route or default is removed. |
| `959_mb703_spark_runtime_ai_wiring.t` | Retire historical source-location and wiring regexps; preserve executable Spark, VDM, Partyline/plugin and update-state scenarios. No runtime route or default is removed. |
| `964_mb703_spark_arm_runtime_contract.t` | Retire historical source-location and wiring regexps; preserve executable Spark, VDM, Partyline/plugin and update-state scenarios. No runtime route or default is removed. |
| `966_mb703_spark_event_runtime_lifecycle.t` | Retire historical source-location and wiring regexps; preserve executable Spark, VDM, Partyline/plugin and update-state scenarios. No runtime route or default is removed. |
| `96_sample_conf_metrics_keys.t` | Retire sample/wizard wording, key-location, default-example and documentation repetition; preserve native configuration, DCC/authentication, empty-secret and fresh-install checks. |
| `977_mb704_vdm_dispatch_contract.t` | Retire historical source-location and wiring regexps; preserve executable Spark, VDM, Partyline/plugin and update-state scenarios. No runtime route or default is removed. |
| `97_sample_conf_dcc_single_block.t` | Retire sample/wizard wording, key-location, default-example and documentation repetition; preserve native configuration, DCC/authentication, empty-secret and fresh-install checks. |
| `983_mb704_spark_vdm_runtime_wiring.t` | Retire historical source-location and wiring regexps; preserve executable Spark, VDM, Partyline/plugin and update-state scenarios. No runtime route or default is removed. |
| `984_mb704_spark_vdm_delivery_authority.t` | Retire historical source-location and wiring regexps; preserve executable Spark, VDM, Partyline/plugin and update-state scenarios. No runtime route or default is removed. |
| `98_sample_conf_retention_keys.t` | Retire sample/wizard wording, key-location, default-example and documentation repetition; preserve native configuration, DCC/authentication, empty-secret and fresh-install checks. |
| `993_mb708_portal_runtime_wiring.t` | Retire historical source-location and wiring regexps; preserve executable Spark, VDM, Partyline/plugin and update-state scenarios. No runtime route or default is removed. |
| `998_mb709_spark_action_runtime_wiring.t` | Retire historical source-location and wiring regexps; preserve executable Spark, VDM, Partyline/plugin and update-state scenarios. No runtime route or default is removed. |
| `99_sample_conf_libera_key.t` | Retire sample/wizard wording, key-location, default-example and documentation repetition; preserve native configuration, DCC/authentication, empty-secret and fresh-install checks. |

## Fewer interpreter starts, identical behavior assertions

Twenty-five unchanged regression fragments move from `t/cases` into
`t/scenarios/ai` and `t/scenarios/external`. Only their per-file final TAP plan
becomes a true final return; two fresh-process suites provide the final plan.
Each scenario retains its lexical scope, distinct fixture packages and scoped
symbol overrides. Internal cold-load checks still execute fresh children.
All 1,480 ordinary assertions remain individually visible in TAP and counted by
the full runner. There is no aggregate success assertion replacing them.

Both suites also pass in reverse order. An injected ordinary failed assertion,
a false final return and a missing fragment each produce a nonzero result;
no scenario is silently skipped. Conservative resource classification retains
FILESYSTEM/PROCESS/DB/NETWORK rather than admitting the suites as PURE.

| Old case | Preserved fragment |
| --- | --- |
| `1292_mb874_horoscope_sign_contract.t` | `t/scenarios/external/1292_mb874_horoscope_sign_contract.pl` |
| `1293_mb874_horoscope_text_budget.t` | `t/scenarios/external/1293_mb874_horoscope_text_budget.pl` |
| `1294_mb875_fortnite_status_contract.t` | `t/scenarios/external/1294_mb875_fortnite_status_contract.pl` |
| `1295_mb875_fortnite_display_scalars.t` | `t/scenarios/external/1295_mb875_fortnite_display_scalars.pl` |
| `1297_mb876_external_entrypoint_compatibility.t` | `t/scenarios/external/1297_mb876_external_entrypoint_compatibility.pl` |
| `1298_mb877_tmdb_optional_fields.t` | `t/scenarios/external/1298_mb877_tmdb_optional_fields.pl` |
| `1299_mb877_tmdb_utf8_budget.t` | `t/scenarios/external/1299_mb877_tmdb_utf8_budget.pl` |
| `1301_mb878_tmdb_compatibility_and_tls.t` | `t/scenarios/external/1301_mb878_tmdb_compatibility_and_tls.pl` |
| `1184_mb818_meta_providers.t` | `t/scenarios/ai/1184_mb818_meta_providers.pl` |
| `1185_mb818_meta_memory.t` | `t/scenarios/ai/1185_mb818_meta_memory.pl` |
| `1186_mb818_meta_chat_web.t` | `t/scenarios/ai/1186_mb818_meta_chat_web.pl` |
| `1188_mb818_meta_parallel_workers.t` | `t/scenarios/ai/1188_mb818_meta_parallel_workers.pl` |
| `1193_mb821_researched_answer_quality.t` | `t/scenarios/ai/1193_mb821_researched_answer_quality.pl` |
| `1198_mb824_passage_catalogue.t` | `t/scenarios/ai/1198_mb824_passage_catalogue.pl` |
| `1206_mb829_maintenance_state.t` | `t/scenarios/ai/1206_mb829_maintenance_state.pl` |
| `1225_mb839_hailo_completion_ownership.t` | `t/scenarios/ai/1225_mb839_hailo_completion_ownership.pl` |
| `1248_mb851_hailo_unicode_brains.t` | `t/scenarios/ai/1248_mb851_hailo_unicode_brains.pl` |
| `1249_mb851_hailo_unicode_nicks.t` | `t/scenarios/ai/1249_mb851_hailo_unicode_nicks.pl` |
| `1316_mb942_hailo_context_freshness.t` | `t/scenarios/ai/1316_mb942_hailo_context_freshness.pl` |
| `1319_mb945_hailo_handoff_authority.t` | `t/scenarios/ai/1319_mb945_hailo_handoff_authority.pl` |
| `1418_mb1045_hailo_nick_identity.t` | `t/scenarios/ai/1418_mb1045_hailo_nick_identity.pl` |
| `1419_mb1046_ai_context_cache.t` | `t/scenarios/ai/1419_mb1046_ai_context_cache.pl` |
| `1420_mb1047_ai_reset_pending.t` | `t/scenarios/ai/1420_mb1047_ai_reset_pending.pl` |
| `1421_mb1048_meta_stage_ownership.t` | `t/scenarios/ai/1421_mb1048_meta_stage_ownership.pl` |
| `1422_mb1049_ai_shared_limits.t` | `t/scenarios/ai/1422_mb1049_ai_shared_limits.pl` |

## Literal-comment assertions removed

These are comment-identifier pins only. Native marker files that detect
unauthorized script execution, protocol markers and diagnostic checks stay.

| Existing case | Removed comment assertions |
| --- | --- |
| `442_mb226_scriptrunner_declared_failure.t` | 1 |
| `448_mb234_script_action_runner_single_target_guard.t` | 1 |
| `449_mb235_script_action_runner_timer_name_guard.t` | 1 |
| `450_mb236_scriptrunner_runtime_cap_clamp.t` | 1 |
| `451_mb237_script_json_action_count_guard.t` | 2 |
| `452_mb238_scriptdryrun_apply_runtime_guard.t` | 1 |
| `453_mb239_script_error_list_guard.t` | 2 |
| `454_mb241_scriptrunner_run_plan_argv_guard.t` | 1 |
| `455_mb242_plugin_replace_listener_cleanup.t` | 3 |
| `456_mb243_script_action_runner_single_logger_lookup.t` | 1 |
| `457_mb244_plugin_manager_unregister_cleanup.t` | 1 |
| `458_mb245_scriptdryrun_respects_plugin_enabled_flag.t` | 2 |
| `459_mb246_scriptrunner_stdin_cap_guard.t` | 1 |
| `460_mb247_plugin_manager_direct_replace_cleanup.t` | 1 |
| `461_mb248_plugin_manager_same_object_replace_guard.t` | 1 |
| `462_mb249_plugin_manager_load_same_object_replace_guard.t` | 1 |
| `463_mb250_script_action_runner_scalar_contract.t` | 1 |
| `464_mb251_script_action_runner_log_level_scalar.t` | 1 |
| `465_mb252_scriptrunner_ok_field_contract.t` | 1 |
| `466_mb253_scriptrunner_protocol_field_contract.t` | 1 |
| `467_mb254_scriptrunner_action_type_scalar_contract.t` | 1 |
| `468_mb256_script_error_scalar_contract.t` | 2 |
| `469_mb257_scriptrunner_stdin_scalar_contract.t` | 1 |
| `470_mb258_plugin_manager_refaddr_identity_guard.t` | 1 |
| `471_mb259_script_action_runner_ok_flag_contract.t` | 1 |
| `479_mb265_scriptrunner_broken_symlink_containment.t` | 1 |
| `480_mb266_plugin_manager_conf_fallback_refs.t` | 2 |
| `481_mb267_script_action_runner_response_errors_contract.t` | 2 |
| `482_mb268_scriptdryrun_command_scalar_contract.t` | 1 |
| `483_mb269_scriptdryrun_context_scalar_contract.t` | 3 |
| `484_mb270_script_action_runner_context_target_scalar.t` | 1 |
| `485_mb271_scriptrunner_event_scalar_contract.t` | 1 |
| `486_mb272_scriptrunner_runtime_limits_scalar_contract.t` | 1 |
| `487_mb273_scriptrunner_script_path_scalar_contract.t` | 1 |
| `489_mb275_event_bus_scalar_identity_contract.t` | 1 |
| `490_mb276_plugin_manager_scalar_identifiers.t` | 2 |
| `491_mb277_event_bus_listener_error_scalar.t` | 1 |
| `492_mb278_scriptrunner_execution_plan_scalar_contract.t` | 3 |
| `493_mb279_plugin_manager_error_scalar_contract.t` | 2 |
| `494_mb280_scriptrunner_language_scalar_contract.t` | 2 |
| `497_mb283_scriptrunner_script_dir_scalar_contract.t` | 1 |
| `499_mb285_scriptrunner_payload_object_contract.t` | 1 |
| `501_mb287_scriptrunner_encode_payload_object_contract.t` | 1 |
| `502_mb288_scriptrunner_run_plan_stdin_json_object.t` | 1 |
| `503_mb289_scriptrunner_event_data_simple_contract.t` | 1 |
| `513_mb290_script_action_runner_top_error_scalar_contract.t` | 2 |
| `519_mb297_commit_secret_scanner_precision.t` | 2 |
| `551_mb329_calc_eval_allowlist.t` | 1 |
| `559_mb339_trivia_answer_word_boundary.t` | 1 |
| `560_mb340_partyline_peer_ip_ipv6.t` | 1 |
| `562_mb343_partyline_bruteforce_per_ip.t` | 1 |
| `564_mb345_claude_history_user_first.t` | 1 |
| `565_mb346_channel_report_accuracy.t` | 1 |
| `566_mb347_achievements_msg_filter.t` | 1 |
| `567_mb348_publictext_filter_sweep.t` | 3 |
| `568_mb349_chanlog_message_filter.t` | 1 |
| `569_mb350_ban_expiry_single_clock.t` | 1 |
| `570_mb351_report_wallclock_anchor.t` | 1 |
| `571_mb352_partyline_bruteforce_map_bound.t` | 1 |
| `574_mb355_calendar_date_arithmetic.t` | 1 |
| `575_mb356_scheduler_lifecycle_generation.t` | 2 |
| `576_mb357_report_isolation_and_tie_determinism.t` | 1 |
| `577_mb358_get_int_diagnostics.t` | 1 |
| `580_mb361_hailo_unavailable_runtime_guard.t` | 3 |
| `581_mb362_auth_metrics_late_wiring.t` | 2 |
| `582_mb363_liquidsoap_line_injection_guard.t` | 1 |
| `583_mb364_metrics_http_header_limit.t` | 1 |
| `584_mb365_partyline_exception_redaction.t` | 1 |
| `585_mb366_partyline_input_bound_and_close_idempotence.t` | 2 |
| `586_mb367_partyline_command_error_redaction.t` | 1 |
| `587_mb368_atomic_config_reload.t` | 1 |
| `588_mb369_timer_irc_write_crlf_guard.t` | 1 |
| `589_mb370_hailo_adaptive_chatter.t` | 1 |
| `590_mb371_hailo_ratio_command_direct_semantics.t` | 1 |
| `591_mb372_auth_session_lifecycle.t` | 1 |
| `592_mb373_nick_regex_quotemeta.t` | 1 |
| `595_mb376_ai_truncation_suffix_byte_budget.t` | 1 |
| `596_mb377_auth_nick_session_rekey.t` | 1 |
| `599_mb380_cpan_installer_script_dir.t` | 2 |
| `600_mb381_cpan_permissions_runtime_user_verify.t` | 2 |
| `602_mb384_private_payload_log_redaction.t` | 1 |
| `616_mb398_youtube_duration_days.t` | 1 |
| `617_mb399_birthday_local_calendar.t` | 1 |
| `618_mb400_achievements_save_integrity.t` | 1 |
| `623_mb405_url_extract_balanced_parens.t` | 1 |
| `624_mb406_url_routing_host_anchored.t` | 3 |
| `625_mb407_channels_canonical_lc_key.t` | 1 |
| `627_mb409_antiflood_negative_cache.t` | 1 |
| `629_mb411_channel_id_cached_helper.t` | 1 |
| `630_mb415_ai_summary_public_lines_help.t` | 1 |
| `632_mb417_ytdlp_argument_injection_guard.t` | 1 |
| `637_mb422_ytsearch_duration_days.t` | 1 |
| `641_mb426_wordcount_accent_safe_split.t` | 1 |
| `642_mb427_compat_mood_accent_safe.t` | 1 |
| `643_mb428_quote_excerpt_utf8_safe.t` | 1 |
| `645_mb430_achievements_channel_lc_key.t` | 1 |
| `646_mb431_pollextend_expired_anchor.t` | 1 |
| `648_mb433_birthday_feb29_observance.t` | 1 |
| `650_mb435_precommit_audit_fixes.t` | 2 |
| `651_mb436_define_accent_safe.t` | 1 |
| `653_mb438_weather_accent_url.t` | 1 |
| `654_mb439_ytsearch_accent_query.t` | 1 |
| `655_mb440_ban_enforce_raw_hostmask.t` | 1 |
| `656_mb441_chronos_excerpt_utf8.t` | 1 |
| `657_mb442_safecalc_integer_modulo.t` | 1 |
| `658_mb443_trivia_answer_accent_boundary.t` | 1 |
| `659_mb444_horoscope_local_prng.t` | 1 |
| `660_mb445_quotegame_accent_boundary.t` | 1 |
| `661_mb446_mood_emoji_decode.t` | 1 |
| `663_mb448_chromium_url_boundary.t` | 1 |
| `664_mb449_startup_integrity_check.t` | 1 |
| `665_mb450_achievements_hourband_shortcircuit.t` | 1 |
| `666_mb453_karma_gift_giver_offbyone.t` | 1 |
| `669_mb456_precommit_audit_fixes.t` | 3 |
| `673_mb460_note_search_index_matches_del.t` | 1 |
| `675_mb462_help_chunked_list_no_empty_prefix.t` | 1 |
| `678_mb465_bcrypt_lazy_migration.t` | 2 |
| `679_mb466_bcrypt_installer_and_ident_upgrade.t` | 1 |
| `693_mb482_refresh_channel_hash_casefold.t` | 1 |
| `725_mb525_script_timer_apply.t` | 1 |
| `726_mb527_partyline_script_timers.t` | 2 |
| `728_mb529_channel_event_routing.t` | 2 |
| `730_mb531_route_config_envelope.t` | 1 |
| `731_mb532_plugin_arc_consolidation.t` | 1 |
| `734_mb536_partyline_event_windows.t` | 1 |
| `735_mb537_conf_hot_refresh.t` | 1 |
| `737_mb540_bridge_metrics.t` | 1 |
| `741_mb544_lusers_debug_partyline.t` | 2 |
| `742_mb545_topic_action_gate.t` | 1 |
| `747_mb552_network_envelope_status.t` | 1 |
| `748_mb554_kick_action_gatekeeper.t` | 1 |
| `753_mb562_no_mojibake.t` | 1 |

## Operator boundary

The delivery can continue with MB1059 pending or committed, and MB1060 pending
or committed. It first recognizes exact qualified file contents, applies the
included MB1060 fix only when needed, then applies MB1061. A repeated complete
application is recognized without reapplying patches. Known earlier additions
and removals are included in staging if they are still pending.

The server must pass the visible full suite with --progress and ETA, security,
startup integrity and command inventory checks before the dev-only restart.
A stable new PID is checked before the installed interactive commit.sh runs.
VERSION remains native-managed; no production service or schema is changed.
See delivered QUALIFICATION.md for measured totals, timings and limitations.
