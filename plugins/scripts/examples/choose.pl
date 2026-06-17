#!/usr/bin/env perl
# =============================================================================
# choose.pl — Mediabot v3 reference plugin script (mediabot-script-v1), in Perl.
#
# A useful example beyond hello-world: a decision helper routed as `pchoose` in
# the sample configuration. The alias preserves Mediabot's richer built-in
# `choose` command and its history subcommand.
#
#   pchoose pizza | sushi | tacos     -> picks one of three pipe-separated options
#   pchoose heads tails               -> picks one space-separated word
#   pchoose go out | stay home        -> keeps multi-word options around `|`
#
# It shows what a real Perl plugin needs:
#   - read the mediabot-script-v1 JSON envelope on STDIN;
#   - take the command arguments and split them into options (| if present,
#     otherwise whitespace);
#   - validate input with an anti-abuse cap on the number of options;
#   - on too few options, reply with a friendly usage line (never crash);
#   - emit an explicit "ok" + "protocol", a reply action (no target -> defaults
#     to the originating channel) and a log action.
#
# Unlike the Tcl example, Perl ships a real JSON encoder (JSON::PP), so the
# option text — arbitrary user input — is escaped automatically by encode_json;
# there is no hand-rolled json_escape to get wrong.
# =============================================================================

use strict;
use warnings;
use JSON::PP qw(decode_json encode_json);

use constant MAX_OPTIONS => 50;

# --- read + parse the envelope ----------------------------------------------
my $raw = do { local $/; <STDIN> };
$raw = '' unless defined $raw;

my $payload = eval { decode_json($raw) };
$payload = {} unless ref($payload) eq 'HASH';

my $data = ref($payload->{data}) eq 'HASH' ? $payload->{data} : {};
my $nick = (defined $data->{nick} && !ref($data->{nick}) && length $data->{nick})
    ? $data->{nick}
    : 'someone';
my $command = (defined $data->{command} && !ref($data->{command}) && length $data->{command})
    ? $data->{command}
    : 'choose';
my $args = ref($data->{args}) eq 'ARRAY' ? $data->{args} : [];

# --- build the option list ---------------------------------------------------
my $text = join ' ', grep { defined } @$args;
$text =~ s/^\s+//;
$text =~ s/\s+$//;

my @options;
if ($text =~ /\|/) {
    # pipe-separated: allows multi-word options
    for my $opt (split /\|/, $text) {
        $opt =~ s/^\s+//;
        $opt =~ s/\s+$//;
        push @options, $opt if length $opt;
    }
}
else {
    # whitespace-separated single-word options
    @options = grep { length } split /\s+/, $text;
}

# anti-abuse: keep the option set bounded
@options = @options[0 .. MAX_OPTIONS - 1] if @options > MAX_OPTIONS;

# --- decide ------------------------------------------------------------------
my @actions;
if (@options < 2) {
    push @actions, {
        type => 'reply',
        text => "$nick: give me at least two options, e.g. $command pizza | sushi | tacos",
    };
}
else {
    my $pick = $options[ int(rand(scalar @options)) ];
    push @actions,
        { type => 'reply', text => "$nick: I choose: $pick" },
        { type => 'log', level => 'info',
          text => "choose: $nick picked among " . scalar(@options) . " options" };
}

# --- emit the contract -------------------------------------------------------
# encode_json escapes any special characters in the option text for us.
print encode_json({
    protocol => 'mediabot-script-v1',
    ok       => JSON::PP::true,
    actions  => \@actions,
});
