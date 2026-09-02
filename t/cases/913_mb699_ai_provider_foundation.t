# t/cases/913_mb699_ai_provider_foundation.t
# =============================================================================
# MB699-A — provider-neutral AI foundation.
#
# The first 3.5 architecture step must not change any live AI behaviour yet.
# It only establishes canonical provider names, safe credential-presence checks
# and deterministic provider selection for future consumers such as +Wit.
# Existing anthropic.* and openai.* configuration remains authoritative.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }

{
    package Conf913;
    sub new { my ($class, %kv) = @_; bless \%kv, $class }
    sub get { $_[0]{ $_[1] } }
}

return sub {
    my ($assert) = @_;

    require Mediabot::AI;

    my @known = Mediabot::AI::known_providers();
    $assert->is(join(',', @known), 'anthropic,openai,gemini',
        'mb699-913: canonical provider order is deterministic');

    $assert->is(Mediabot::AI::normalize_provider('Claude'), 'anthropic',
        'mb699-913: Claude alias normalizes to anthropic');
    $assert->is(Mediabot::AI::normalize_provider(' ChatGPT '), 'openai',
        'mb699-913: ChatGPT alias normalizes to openai');
    $assert->is(Mediabot::AI::normalize_provider('gpt'), 'openai',
        'mb699-913: GPT alias normalizes to openai');
    $assert->is(Mediabot::AI::normalize_provider('GoogleAI'), 'gemini',
        'mb699-913: GoogleAI alias normalizes to Gemini');
    $assert->is(Mediabot::AI::normalize_provider('AUTO'), 'auto',
        'mb699-913: auto mode is canonicalized');
    $assert->ok(!defined Mediabot::AI::normalize_provider('mystery-ai'),
        'mb699-913: unknown provider fails closed');

    my $none = bless { conf => Conf913->new(
        'anthropic.API_KEY' => '',
        'openai.API_KEY'    => '   ',
        'gemini.API_KEY'    => '',
    ) }, 'Bot913';
    $assert->is(Mediabot::AI::provider_configured($none, 'anthropic'), 0,
        'mb699-913: empty Anthropic key is not configured');
    $assert->is(Mediabot::AI::provider_configured($none, 'openai'), 0,
        'mb699-913: whitespace OpenAI key is not configured');
    $assert->ok(!defined Mediabot::AI::select_provider($none, 'auto'),
        'mb699-913: auto fails closed when no provider is configured');

    my $both = bless { conf => Conf913->new(
        'anthropic.API_KEY' => 'anthropic-secret-never-returned',
        'openai.API_KEY'    => 'openai-secret-never-returned',
        'gemini.API_KEY'    => 'gemini-secret-never-returned',
    ) }, 'Bot913';

    my @configured = Mediabot::AI::configured_providers($both);
    $assert->is(join(',', @configured), 'anthropic,openai,gemini',
        'mb699-913: configured provider list contains names only');
    $assert->is(
        Mediabot::AI::select_provider($both->{conf}, 'auto'), 'anthropic',
        'mb699-913: provider selection also accepts a configuration object directly'
    );
    $assert->is(Mediabot::AI::select_provider($both, 'auto'), 'anthropic',
        'mb699-913: default auto order preserves Anthropic-first compatibility');
    $assert->is(
        Mediabot::AI::select_provider($both, 'auto', order => [qw(openai anthropic)]),
        'openai',
        'mb699-913: caller can choose an OpenAI-first auto order');
    $assert->is(Mediabot::AI::select_provider($both, 'chatgpt'), 'openai',
        'mb699-913: explicit OpenAI alias selects OpenAI');
    $assert->is(Mediabot::AI::select_provider($both, 'google'), 'gemini',
        'mb699-913: explicit Google alias selects Gemini');

    my $anthropic_only = bless { conf => Conf913->new(
        'anthropic.API_KEY' => 'configured',
        'openai.API_KEY'    => '',
    ) }, 'Bot913';
    $assert->ok(!defined Mediabot::AI::select_provider($anthropic_only, 'openai'),
        'mb699-913: explicit unavailable provider never silently falls back');
    $assert->is(
        Mediabot::AI::select_provider($anthropic_only, 'auto', order => [qw(openai anthropic)]),
        'anthropic',
        'mb699-913: auto mode can fall through to the next configured provider');

    my $src = do {
        open my $fh, '<:encoding(UTF-8)', 'Mediabot/AI.pm' or die $!;
        local $/;
        <$fh>;
    };
    $assert->unlike($src, qr/anthropic-secret-never-returned|openai-secret-never-returned|gemini-secret-never-returned/,
        'mb699-913: provider module contains no test or runtime credentials');
    $assert->unlike($src, qr/api\.anthropic\.com|api\.openai\.com/,
        'mb699-913: provider-neutral registry does not own HTTP endpoints');
};
