package Mediabot::DynamicTemplate;

use strict;
use warnings;
use utf8;
use Exporter 'import';
use Encode qw(decode FB_CROAK);
use Unicode::Normalize qw(NFC);
use POSIX qw(strftime);

our @EXPORT_OK = qw(normalize_name name_error template_error render_template template_help);

# IRC and DB boundaries normally supply characters. Also accept valid UTF-8
# bytes from legacy callers, without silently repairing invalid input.
sub _characters {
    my ($value) = @_;
    die "Expected text.\n" if !defined($value) || ref($value);
    return $value if utf8::is_utf8($value);
    return decode('UTF-8', $value, FB_CROAK);
}

sub normalize_name {
    return NFC(_characters($_[0]));
}

sub name_error {
    my ($name) = @_;
    my $normal = eval { normalize_name($name) };
    return 'Command name must be valid UTF-8.' if $@;
    return 'Command name too long (max 64 characters).' if length($normal) > 64;
    return 'Command name must contain Unicode letters, digits, - or _ (no spaces).'
        unless $normal =~ /\A[\p{L}\p{Nd}_-][\p{L}\p{M}\p{Nd}_-]*\z/;
    return;
}

# Compile once per invocation. Expansion never scans values inserted by an
# argument, a random nickname or a choice. No Perl evaluation is involved.
sub _parts {
    my ($text) = @_;
    $text = _characters($text);
    die "Template must fit on one IRC line.\n" if $text =~ /[\x00\x01\r\n]/;
    die "Template too long.\n" if length($text) > 4096;
    my (@parts, $end);
    $end = 0;
    while ($text =~ /%%|%(?!(?:on|dd|ddd)%)[A-Za-z][A-Za-z0-9_]+%|%(?:rand|random|choose|choice)(?![A-Za-z0-9_])|%(?:ddd|dd|on|[nNrRscbBd]|[1-9](?!\d))/g) {
        my ($start, $next, $token) = ($-[0], $+[0], $&);
        push @parts, ['text', substr($text, $end, $start - $end)] if $start > $end;
        if ($token =~ /\A%(rand|random|choose|choice)\z/) {
            my $kind = $1;
            die "Use %$kind\{...}.\n" unless substr($text, $next, 1) eq '{';
            my (@options, $value, $closed);
            $value = '';
            for ($next++; $next < length($text); $next++) {
                my $char = substr($text, $next, 1);
                if ($char eq '\\') {
                    my $escaped = substr($text, ++$next, 1);
                    die "Escape only |, {, } or \\ inside choices.\n"
                        unless $escaped =~ /\A[|{}\\]\z/;
                    $value .= $escaped;
                } elsif ($char eq '{') {
                    die "Nested templates are not supported; escape literal braces.\n";
                } elsif ($char eq '}') {
                    push @options, $value;
                    $closed = 1;
                    $next++;
                    last;
                } elsif ($char eq '|' && $kind =~ /\A(?:choose|choice)\z/) {
                    push @options, $value;
                    $value = '';
                } else {
                    $value .= $char;
                }
            }
            die "Missing closing } for %$kind.\n" unless $closed;
            if ($kind =~ /\A(?:rand|random)\z/) {
                die "Use %rand{min,max} with integers between -1000000 and 1000000.\n"
                    unless $options[0] =~ /\A\s*([+-]?[0-9]{1,7})\s*,\s*([+-]?[0-9]{1,7})\s*\z/;
                my ($lo, $hi) = (0 + $1, 0 + $2);
                die "Random bounds must satisfy -1000000 <= min <= max <= 1000000.\n"
                    if $lo < -1_000_000 || $hi > 1_000_000 || $lo > $hi;
                push @parts, ['rand', $lo, $hi];
            } else {
                die "Choose between 2 and 20 non-empty options.\n"
                    if @options < 2 || @options > 20 || grep { !/\S/ } @options;
                push @parts, ['choose', @options];
            }
            pos($text) = $next;
        } else {
            push @parts, ['token', $token];
        }
        $end = $next;
    }
    push @parts, ['text', substr($text, $end)] if $end < length($text);
    return \@parts;
}

sub template_error {
    my ($text) = @_;
    my $decoded = eval { _characters($text) };
    return 'Template must be valid UTF-8 text.' if $@;
    return 'Template must not be empty.' unless $decoded =~ /\S/;
    # PUBLIC_COMMANDS.action is VARCHAR(255); reserve 11 for "PRIVMSG %c ".
    return 'Action text too long (max 244 characters).' if length($decoded) > 244;
    eval { _parts($decoded) };
    if ($@) {
        my $error = $@;
        $error =~ s/\s+at .*? line \d+.*\z//s;
        $error =~ s/\s+\z//;
        return $error;
    }
    return;
}

sub render_template {
    my ($text, %ctx) = @_;
    my $parts = _parts($text);
    my $nick = _characters($ctx{nick} // '');
    my $channel = _characters($ctx{channel} // '');
    my $command = _characters($ctx{command} // '');
    my @args = map { _characters($_ // '') } @{ $ctx{args} // [] };
    my $args = join(' ', @args);
    my $spaced = $command;
    $spaced =~ s/_/ /g;
    my %values = (
        '%%' => '%', '%n' => @args ? $args : $nick, '%N' => $nick,
        '%c' => $channel, '%s' => $spaced,
        '%nick%' => $nick, '%channel%' => $channel, '%command%' => $command,
        '%args%' => $args, '%target%' => @args ? $args[0] : $nick,
    );
    my $now = $ctx{now} // time;
    $values{'%date%'} = strftime('%Y-%m-%d', localtime($now));
    $values{'%time%'} = strftime('%H:%M', localtime($now));
    for my $index (1 .. 9) { $values{"%$index"} = $args[$index - 1] // '' }
    my $random = $ctx{random} // sub { int(rand($_[0])) };
    my $draw = sub {
        my ($size) = @_;
        my $value = $random->($size);
        die "Invalid random result.\n"
            unless defined($value) && $value =~ /\A[0-9]+\z/ && $value < $size;
        return $value;
    };
    my $out = '';
    for my $part (@$parts) {
        my ($kind, @data) = @$part;
        my $value;
        if ($kind eq 'text') { $value = $data[0] }
        elsif ($kind eq 'rand') { $value = $data[0] + $draw->($data[1] - $data[0] + 1) }
        elsif ($kind eq 'choose') { $value = $data[$draw->(scalar @data)] }
        else {
            my $token = $data[0];
            if (exists $values{$token}) { $value = $values{$token} }
            elsif ($token =~ /\A%[rR]\z/) {
                $values{$token} = _characters($ctx{random_nick} ? ($ctx{random_nick}->() // $nick) : $nick);
                $value = $values{$token};
            } elsif ($token =~ /\A%(?:on|[bB])\z/) {
                $values{$token} = $token eq '%on'
                    ? ($draw->(2) ? 'oui' : 'non') : ($draw->(2) ? 'true' : 'false');
                $value = $values{$token};
            } elsif ($token eq '%yesno%') { $value = $draw->(2) ? 'oui' : 'non' }
            elsif ($token eq '%bool%') { $value = $draw->(2) ? 'true' : 'false' }
            elsif ($token eq '%d') { $value = 1 + $draw->(10) }
            elsif ($token eq '%dd') { $value = 10 + $draw->(90) }
            elsif ($token eq '%ddd') { $value = 100 + $draw->(900) }
            else { $value = $token } # Unknown named placeholders remain literal.
        }
        die "Template result must fit on one IRC line.\n" if $value =~ /[\x00\x01\r\n]/;
        $out .= $value;
        die "Template result too long (max 4096 characters).\n" if length($out) > 4096;
    }
    return $out;
}

sub template_help {
    return (
        'Names: Unicode letters/digits, - and _; max 64 characters. Text: max 244 characters.',
        'Caller: %N or %nick%; target: %target%; all arguments (caller if absent): %n; arguments only: %args%; positions: %1 .. %9.',
        'Channel: %c or %channel%; command: %command% (%s changes _ to spaces); date/time: %date%, %time%; random nick: %r / %R.',
        'Random integer: %rand{min,max} (inclusive, -1000000 .. 1000000); choice: %choose{tea|coffee|water}; yes/no: %yesno% or %on; boolean: %bool% or %b / %B.',
        'Legacy numbers: %d = 1..10, %dd = 10..99, %ddd = 100..999. Literal percent: %%; choices are literal; escape |, {, }, \\ with \\.',
        'Preview privately with testcmd <command> [arguments]; holdcmd <command> on|off|toggle; help addcmd / help modcmd for syntax.',
    );
}

1;
