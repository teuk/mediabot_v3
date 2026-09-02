package Mediabot::Hailo::Language;

use strict;
use warnings;
use utf8;

use Exporter 'import';

our $VERSION = '1.0';
our @EXPORT_OK = qw(
    detect_phrase_language
    resolve_hailo_language
);

my %MARKER = (
    en => { map { $_ => 1 } qw(the and you your are is this that what why with have not yes hello thanks) },
    fr => { map { $_ => 1 } qw(le la les un une et tu vous ton ta est ce ça que quoi pourquoi avec avoir pas oui bonjour merci) },
    es => { map { $_ => 1 } qw(el la los las un una y tú tu usted es esto que qué por porque con tener no sí hola gracias) },
);

sub _supported {
    my ($value) = @_;
    return 'en' unless defined($value) && !ref($value);
    my $lang = lc "$value";
    $lang =~ s/^\s+|\s+$//g;
    return $lang if $lang eq 'en' || $lang eq 'fr' || $lang eq 'es';
    return 'en';
}

sub detect_phrase_language {
    my ($text) = @_;
    return undef unless defined($text) && !ref($text) && length("$text");

    my $sample = lc "$text";
    $sample =~ tr/’/'/;
    my @tokens = $sample =~ /([\p{L}]+(?:'[\p{L}]+)?)/gu;
    return undef unless @tokens;

    my %score = (en => 0, fr => 0, es => 0);
    for my $token (@tokens) {
        for my $lang (keys %MARKER) {
            $score{$lang}++ if $MARKER{$lang}{$token};
        }
    }

    $score{fr} += 2 if $sample =~ /[àâçéèêëîïôùûüÿœ]/u;
    $score{es} += 2 if $sample =~ /[áéíóúñ¿¡]/u;
    $score{en}++ if $sample =~ /\b(?:i'm|you're|don't|can't|it's)\b/u;
    $score{fr}++ if $sample =~ /\b(?:j'|qu'|c'|n'|l'|d')/u;

    my @ranked = sort { $score{$b} <=> $score{$a} || $a cmp $b } keys %score;
    return undef if $score{$ranked[0]} < 2;
    return undef if $score{$ranked[0]} == $score{$ranked[1]};
    return $ranked[0];
}

sub resolve_hailo_language {
    my (%args) = @_;
    my $channel = _supported($args{channel_language});
    my $trigger = detect_phrase_language($args{trigger});
    my $candidate = detect_phrase_language($args{candidate});

    # The interlocutor's language wins for a confident code-switch. Otherwise
    # the channel policy is authoritative; the draft language is only useful
    # when it agrees with that policy.
    my $resolved = $trigger || $channel;
    $resolved = $candidate
        if !$trigger && defined($candidate) && $candidate eq $channel;

    return {
        language           => $resolved,
        channel_language   => $channel,
        trigger_language   => $trigger,
        candidate_language => $candidate,
    };
}

1;
