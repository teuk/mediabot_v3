# t/cases/525_mb303_external_module_test_ownership.t
# =============================================================================
# MB303: regression tests must inspect the module that owns each implementation
# after Mediabot::External was split into Claude, YouTube, URL and Spotify.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_mb303 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path
        or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my %owners = (
        'URL.pm' => [qw(
            140_external_chromium_timeout_kill_escalation.t
            141_external_facebook_handler.t
            143_external_facebook_fallback_all_urls.t
            152_external_x_handler_chromium.t
            200_urltitle_badge_reset_stringify.t
            202_generic_urltitle_cleanup_regression.t
        )],
        'Claude.pm' => [qw(
            147_tmdb_utf8_query_and_lang_safety.t
            148_tmdb_result_iteration_robust.t
            149_tmdb_repair_mojibake_query.t
            158_tmdb_results_must_be_array.t
            159_external_ctx_args_defensive.t
            167_chatgpt_json_structure_guard.t
            179_chatgpt_openai_runtime_config.t
            182_openai_fallback_model.t
            186_openai_system_prompt_config.t
            208_chatgpt_http_guard_debug5_regression.t
            210_tmdb_final_message_truncate_regression.t
            211_tmdb_logger_no_warn_regression.t
            220_external_claude_api.t
            222_external_claude_chanset_gate.t
            224_external_claude_history.t
            226_external_claude_ratelimit.t
            227_external_claude_callback.t
            235_external_claude_persona.t
        )],
        'YouTube.pm' => [qw(
            150_youtube_search_uses_imported_uri_escape_utf8.t
            151_youtube_search_same_colors_as_link.t
            169_youtube_search_three_results_colored.t
            170_fortnite_stats_nested_hash_guards.t
            171_fortnite_stats_mode_fallback.t
            172_display_youtube_details_structure_guards.t
            173_youtube_oembed_requires_hash.t
            174_fortnite_response_must_be_hash.t
            199_youtube_colors_transparent_background.t
            203_youtube_helpers_getdetails_regression.t
            204_youtube_helpers_ownership_regression.t
            205_youtube_search_http_guard_regression.t
            212_fortnite_comment_cleanup_regression.t
            223_external_yt_search.t
            74_fortniteid_db_safety.t
        )],
        'Spotify.pm' => [qw(
            201_spotify_rich_metadata_regression.t
        )],
    );

    for my $owner (sort keys %owners) {
        for my $file (@{ $owners{$owner} }) {
            my $src = _slurp_mb303(
                File::Spec->catfile('.', 't', 'cases', $file)
            );

            $assert->like(
                $src,
                qr/File::Spec->catfile\('\.',\s*'Mediabot',\s*'External',\s*'\Q$owner\E'\)/,
                "$file inspects External/$owner"
            );

            $assert->unlike(
                $src,
                qr/File::Spec->catfile\('\.',\s*'Mediabot',\s*'External\.pm'\)/,
                "$file no longer inspects only the External.pm facade"
            );
        }
    }

    my $t149 = _slurp_mb303('t/cases/149_tmdb_repair_mojibake_query.t');
    $assert->like(
        $t149,
        qr/require Mediabot::External::Claude;/,
        'TMDB mojibake test loads the implementation owner'
    );
    $assert->like(
        $t149,
        qr/Mediabot::External::Claude::_repair_utf8_mojibake/,
        'TMDB mojibake test calls the implementation owner'
    );

    my $t201 = _slurp_mb303('t/cases/201_spotify_rich_metadata_regression.t');
    $assert->unlike(
        $t201,
        qr/# _handle_applemusic/,
        'Spotify extraction no longer depends on an old monolith marker'
    );

    my $t220 = _slurp_mb303('t/cases/220_external_claude_api.t');
    $assert->like(
        $t220,
        qr/_claude_send_and_parse/,
        'Claude API test covers the extracted Anthropic transport helper'
    );

    my $t222 = _slurp_mb303('t/cases/222_external_claude_chanset_gate.t');
    $assert->like(
        $t222,
        qr/my \$answer = _claude_send_and_parse/,
        'Claude gate test compares against the real helper call'
    );

    my $t224 = _slurp_mb303('t/cases/224_external_claude_history.t');
    $assert->like(
        $t224,
        qr/\$send_body/,
        'Claude history test covers helper-owned response history'
    );
};
